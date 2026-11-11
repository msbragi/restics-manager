#!/usr/bin/env bash
# Orchestrator: inspect, initialize and test local cold backups. Preserves initially running containers during cold backups.
# stdout: JSON Lines; stderr: human-readable diagnostics.
set -Eeuo pipefail

# Configuration lives alongside the orchestrator by default. It is parsed as
# data (never sourced as shell code). Environment variables take precedence.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BACKUP_CONFIG="${BACKUP_CONFIG:-$SCRIPT_DIR/backup.env}"

read_config() {
  local line key value
  [[ -e "$BACKUP_CONFIG" || -L "$BACKUP_CONFIG" ]] || return 0
  if [[ ! -f "$BACKUP_CONFIG" || ! -r "$BACKUP_CONFIG" || -L "$BACKUP_CONFIG" ]]; then
    printf 'ERROR: invalid or unreadable configuration file: %s\n' "$BACKUP_CONFIG" >&2
    return 2
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ ! "$line" =~ ^([A-Z_]+)=(.*)$ ]]; then
      printf 'ERROR: invalid configuration entry\n' >&2
      return 2
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    # No shell quoting/expansion: values must be literal absolute paths
    # (except RESTIC_IMAGE, which is a literal image reference).
    case "$key" in
      BACKUP_ROOT|STACKS_DIR|REPOSITORIES_DIR|RESTIC_PASSWORD_FILE|BACKUP_LOG_DIR|RESTORE_DIR)
        if [[ "$value" != /* || "$value" == *$'\n'* ]]; then
          printf 'ERROR: %s must be an absolute path\n' "$key" >&2
          return 2
        fi ;;
      RESTIC_CHECK_TIMEOUT|RESTIC_BACKUP_TIMEOUT|DOCKER_TIMEOUT)
        [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ && "$value" =~ [1-9] ]] || return 2 ;;
      RESTIC_IMAGE)
        if [[ -z "$value" || "$value" =~ [[:space:]] ]]; then
          printf 'ERROR: invalid RESTIC_IMAGE\n' >&2
          return 2
        fi ;;
      *) printf 'ERROR: unknown configuration key %s\n' "$key" >&2; return 2 ;;
    esac
    # Environment overrides file config. No eval/source.
    if [[ ! -v $key ]]; then
      printf -v "$key" '%s' "$value"
    fi
  done < "$BACKUP_CONFIG"
}

read_config || exit 2
BACKUP_ROOT="${BACKUP_ROOT:-$SCRIPT_DIR}"
STACKS_DIR="${STACKS_DIR:-$BACKUP_ROOT/stacks}"
REPOSITORIES_DIR="${REPOSITORIES_DIR:-$BACKUP_ROOT/backup-repositories}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$BACKUP_ROOT/backup-secrets/restic.password}"
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic:0.19.1}"
BACKUP_LOG_DIR="${BACKUP_LOG_DIR:-$BACKUP_ROOT/backup-logs}"
RESTORE_DIR="${RESTORE_DIR:-$BACKUP_ROOT/restores}"
readonly RESTORE_DIR
readonly BACKUP_LOG_DIR
readonly BACKUP_ROOT STACKS_DIR REPOSITORIES_DIR RESTIC_PASSWORD_FILE RESTIC_IMAGE
MODE="${1:---check}"
ERRORS=0
ENABLED=0
RESTIC_SOURCE=""
RUN_ID="$(date -u +'%Y%m%dT%H%M%SZ')-$$"
EVENTS=()
INIT_TARGETS=()
REPO_STATUS=""
BACKUP_TARGETS=()
BACKUP_STOP_FLAGS=()
BACKUP_INIT_TARGETS=()
RESTIC_CHECK_TIMEOUT="${RESTIC_CHECK_TIMEOUT:-60}"
RESTIC_BACKUP_TIMEOUT="${RESTIC_BACKUP_TIMEOUT:-3600}"
DOCKER_TIMEOUT="${DOCKER_TIMEOUT:-30}"
declare -A DESCRIPTOR_HASHES=()
RUN_TEMP=""
ACTIVE_CONTAINER=""
ENGINE_OUTPUT=""
ENGINE_DIAGNOSTIC=""
RESTORE_IDS=()
RESTORE_STACK=""


# --- Output ---------------------------------------------------------------
# Encode JSON strings using Bash builtins only (no subprocess per field).
# Bash strings cannot contain NUL; all other ASCII control bytes are escaped.
json_quote() {
  local value="$1" dest="$2" octal char escape i
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  for ((i=1; i<32; i++)); do
    (( i == 9 || i == 10 || i == 13 )) && continue
    printf -v octal '%03o' "$i"
    printf -v char '%b' "\\$octal"
    printf -v escape '\\u%04x' "$i"
    value=${value//"$char"/"$escape"}
  done
  printf -v "$dest" '"%s"' "$value"
}

emit_event() {
  local event="$1" stack="$2" status="$3" detail="$4"
  local j_run j_time j_event j_stack j_status j_detail timestamp
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  json_quote "$RUN_ID" j_run
  json_quote "$timestamp" j_time
  json_quote "$event" j_event
  json_quote "$stack" j_stack
  json_quote "$status" j_status
  json_quote "$detail" j_detail
  EVENTS+=("{\"run_id\":$j_run,\"timestamp\":$j_time,\"event\":$j_event,\"stack\":$j_stack,\"status\":$j_status,\"detail\":$j_detail}")
}

flush_events() {
  if ((${#EVENTS[@]})); then
    printf '%s\n' "${EVENTS[@]}"
  fi
}

log_info()  { printf 'INFO: %s\n' "$*" >&2; }
log_warn()  { printf 'WARN: %s\n' "$*" >&2; }
log_error() { printf 'ERROR: %s\n' "$*" >&2; }

record_error() {
  local stack="$1" detail="$2"
  ERRORS=$((ERRORS + 1))
  log_error "${stack}: ${detail}"
  emit_event 'validation_error' "$stack" 'error' "$detail"
}

usage() {
  printf 'Usage: %s [--check|--init|--backup|--help]\n' "$0"
  printf '%s\n' '--check validates descriptors and opens repository config; it does not check data integrity.'
  printf '%s\n' '--backup initializes missing repositories automatically; --init performs initialization only.'
  printf '%s\n' '--backup stops and restores running containers when docker-stop=true.'
}

# --- Preconditions --------------------------------------------------------
parse_arguments() {
  case "$MODE" in
    --check|--init|--backup|auto) ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  if (( $# > 1 )); then usage >&2; exit 2; fi
}

# Validate overrides too; configuration values must never change command semantics.
check_requirements() {
  local key value
  for key in BACKUP_ROOT STACKS_DIR REPOSITORIES_DIR RESTIC_PASSWORD_FILE BACKUP_LOG_DIR RESTORE_DIR; do
    value="${!key}"
    if [[ "$value" != /* || "$value" =~ [[:cntrl:]] || "$value" == *,* ]]; then
      record_error '' "$key must be an absolute path without control characters or comma"
      return 1
    fi
  done
  for key in RESTIC_CHECK_TIMEOUT RESTIC_BACKUP_TIMEOUT DOCKER_TIMEOUT; do
    value="${!key}"
    if [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?$ || ! "$value" =~ [1-9] ]]; then
      record_error '' "$key must be a positive duration in seconds"
      return 1
    fi
  done
  if [[ -z "$RESTIC_IMAGE" || "$RESTIC_IMAGE" == -* || "$RESTIC_IMAGE" =~ [[:space:]] ]]; then
    record_error '' 'invalid RESTIC_IMAGE'
    return 1
  fi
  for key in timeout python3 sha256sum mktemp stat flock; do
    command -v "$key" >/dev/null 2>&1 || { record_error '' "required tool unavailable: $key"; return 1; }
  done
  if ! safe_directory "$STACKS_DIR" || ! safe_directory "$REPOSITORIES_DIR"; then
    record_error '' 'stack/repository base directory missing, inaccessible or linked'
    return 1
  fi
}

# Reject symlinks in all components, including ancestors of configured paths.
no_symlink_components() {
  local path="$1" part cursor=""
  local -a parts
  IFS=/ read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    [[ -z "$part" ]] && continue
    [[ "$part" != . && "$part" != .. ]] || return 1
    cursor+="/$part"
    [[ ! -L "$cursor" ]] || return 1
  done
}

safe_directory() {
  no_symlink_components "${1%/}" && [[ -d "$1" && -r "$1" && -x "$1" ]]
}

safe_password() {
  no_symlink_components "$RESTIC_PASSWORD_FILE" &&
    [[ -f "$RESTIC_PASSWORD_FILE" && -r "$RESTIC_PASSWORD_FILE" && -s "$RESTIC_PASSWORD_FILE" ]]
}

prepare_runtime() {
  [[ -n "$RUN_TEMP" ]] && return 0
  RUN_TEMP="$(mktemp -d)" || { record_error '' 'cannot create private working directory'; return 1; }
  chmod 700 "$RUN_TEMP" || return 1
}

cleanup_container() {
  [[ -n "$ACTIVE_CONTAINER" ]] || return 0
  if ! timeout --kill-after=2s "${DOCKER_TIMEOUT}s" docker rm -f "$ACTIVE_CONTAINER" >/dev/null 2>&1; then
    record_error '' "container cleanup failed: $ACTIVE_CONTAINER; inspect Docker manually"
    return 1
  fi
  ACTIVE_CONTAINER=""
}

finish() {
  local code=$?
  trap - EXIT
  trap '' INT TERM
  cleanup_container || code=1
  restore_stack || code=1
  [[ -z "$RUN_TEMP" ]] || rm -rf -- "$RUN_TEMP"
  flush_events
  exit "$code"
}

interrupted() {
  emit_event interrupted '' error "signal=$1"
  exit "$2"
}

# Preserve diagnostics privately and redact the actual password before writing logs.
# Raw engine streams exist only inside the private temporary directory.
preserve_diagnostics() {
  local name="$1" operation="$2" error_file="$3" output_file="$4" result="$5" log_file
  if [[ ! -e "$BACKUP_LOG_DIR" && ! -L "$BACKUP_LOG_DIR" ]]; then
    no_symlink_components "$BACKUP_LOG_DIR" && mkdir -m 700 -- "$BACKUP_LOG_DIR" || return 1
  fi
  if ! safe_directory "$BACKUP_LOG_DIR" || [[ ! -O "$BACKUP_LOG_DIR" ]] ||
      [[ "$(stat -c %a -- "$BACKUP_LOG_DIR")" != 700 ]]; then
    record_error "$name" 'diagnostic directory must be owned by current user with mode 700'
    return 1
  fi
  log_file="$(mktemp "$BACKUP_LOG_DIR/engine-$RUN_ID-XXXXXX.log")" || return 1
  if ! python3 - "$RESTIC_PASSWORD_FILE" "$error_file" "$output_file" "$log_file" "$result" <<'PYLOG'
import pathlib, sys
password, err, out, log, result = sys.argv[1:]
secret = pathlib.Path(password).read_bytes().rstrip(b"\r\n")
data = pathlib.Path(err).read_bytes()
if result != '0':
    data += b"\n--- engine stdout ---\n" + pathlib.Path(out).read_bytes()
if secret:
    import json
    # Also redact JSON-escaped forms returned by structured engine errors.
    for token in {secret, json.dumps(secret.decode('utf-8', errors='replace'))[1:-1].encode()}:
        if token:
            data = data.replace(token, b"[REDACTED]")
pathlib.Path(log).write_bytes(data)
PYLOG
  then
    rm -f -- "$log_file"
    record_error "$name" 'cannot preserve sanitized engine diagnostics'
    return 1
  fi
  ENGINE_DIAGNOSTIC="$log_file"
  log_warn "$name: $operation exit=$result; diagnostics: $log_file"
  emit_event engine_diagnostics "$name" info "operation=$operation; exit=$result; log=$log_file"
}

# One bounded invocation for all Restic operations. Repo RW for Restic locks;
# password and backup sources RO. No data mounts are supplied to probes/init.
run_engine() {
  local name="$1" operation="$2" duration="$3" result=0 error_file repo="$REPOSITORIES_DIR/$1"
  shift 3
  local -a command
  ENGINE_DIAGNOSTIC=""
  prepare_runtime || return 1
  ENGINE_OUTPUT="$(mktemp "$RUN_TEMP/stdout-XXXXXX")" || return 1
  error_file="$(mktemp "$RUN_TEMP/stderr-XXXXXX")" || return 1
  if ! safe_password || ! safe_directory "$repo"; then
    record_error "$name" 'engine password/repository unavailable or unsafe'
    return 1
  fi
  if [[ "$RESTIC_SOURCE" == 'host executable:'* ]]; then
    command=(env RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" restic "$@")
  else
    ACTIVE_CONTAINER="restic-$RUN_ID-$RANDOM"
    command=(docker run --rm --pull never --name "$ACTIVE_CONTAINER" --network none
      --mount "type=bind,src=$repo,dst=/repository"
      --mount "type=bind,src=$RESTIC_PASSWORD_FILE,dst=/run/secrets/restic.password,readonly"
      -e RESTIC_REPOSITORY=/repository -e RESTIC_PASSWORD_FILE=/run/secrets/restic.password)
    if [[ "$operation" == backup ]]; then
      command+=(--mount "type=bind,src=$STACKS_DIR,dst=/stacks,readonly")
    fi
    command+=("$RESTIC_IMAGE" "$@")
  fi
  timeout --kill-after=5s "${duration}s" "${command[@]}" >"$ENGINE_OUTPUT" 2>"$error_file" || result=$?
  if [[ -n "$ACTIVE_CONTAINER" ]]; then
    if ((result)); then cleanup_container || result=1; else ACTIVE_CONTAINER=""; fi
  fi
  if ((result)) || [[ -s "$error_file" ]]; then
    preserve_diagnostics "$name" "$operation" "$error_file" "$ENGINE_OUTPUT" "$result" || result=1
  fi
  emit_event engine_complete "$name" "$([[ "$result" == 0 ]] && printf success || printf error)" "operation=$operation; exit=$result"
  return "$result"
}

detect_restic() {
  if command -v restic >/dev/null 2>&1; then
    RESTIC_SOURCE="host executable: $(command -v restic)"
  elif command -v docker >/dev/null 2>&1 && timeout --kill-after=2s "${DOCKER_TIMEOUT}s" docker image inspect "$RESTIC_IMAGE" >/dev/null 2>&1; then
    RESTIC_SOURCE="local Docker image: $RESTIC_IMAGE"
  fi
  if [[ -n "$RESTIC_SOURCE" ]]; then
    log_info "RESTIC detected ($RESTIC_SOURCE)"
    emit_event 'restic_detected' '' 'ready' "$RESTIC_SOURCE"
  else
    log_warn "RESTIC not detected (host or local image $RESTIC_IMAGE)"
    emit_event 'restic_detected' '' 'unavailable' "$RESTIC_IMAGE"
  fi
}

# --- Repository inspection (read-only action; temporary Restic lock allowed) -----------------------------
check_repository() {
  local name="$1" repo="$REPOSITORIES_DIR/$1" result
  REPO_STATUS="error"
  if ! safe_directory "$REPOSITORIES_DIR"; then
    record_error "$name" 'repository base is inaccessible or unsafe'
    return 0
  fi

  if [[ ! -e "$repo" && ! -L "$repo" ]]; then
    REPO_STATUS="not_initialized"
    log_info "  REPOSITORY: NOT_INITIALIZED ($repo)"
    emit_event 'repository_status' "$name" 'not_initialized' "$repo"
    return 0
  fi
  if ! safe_directory "$repo"; then
    record_error "$name" "repository path is not a real directory: $repo"
    emit_event 'repository_status' "$name" 'error' "$repo"
    return 0
  fi
  if [[ ! -e "$repo/config" && ! -L "$repo/config" ]]; then
    # An existing empty directory is a valid candidate for future init.
    if [[ -z "$(ls -A -- "$repo" 2>/dev/null)" && -r "$repo" && -x "$repo" ]]; then
      REPO_STATUS="not_initialized"
      log_info "  REPOSITORY: NOT_INITIALIZED ($repo; empty directory)"
      emit_event 'repository_status' "$name" 'not_initialized' "$repo"
    else
      record_error "$name" "repository directory exists but has no Restic config: $repo"
      emit_event 'repository_status' "$name" 'error' "$repo"
    fi
    return 0
  fi
  if [[ -z "$RESTIC_SOURCE" ]]; then
    REPO_STATUS="unknown"
    record_error "$name" "repository cannot be verified: Restic unavailable ($repo)"
    emit_event 'repository_status' "$name" 'unknown' 'Restic unavailable'
    return 0
  fi
  if ! safe_password; then
    record_error "$name" "Restic password file missing or unreadable: $RESTIC_PASSWORD_FILE"
    emit_event 'repository_status' "$name" 'error' 'password file unavailable'
    return 0
  fi

  if run_engine "$name" probe "$RESTIC_CHECK_TIMEOUT" cat config; then
    result=ready
  else
    result=error
  fi
  if [[ "$result" == ready ]]; then
    REPO_STATUS="ready"
    log_info "  REPOSITORY: READY ($repo)"
    emit_event 'repository_status' "$name" 'ready' "$repo"
  else
    record_error "$name" "repository cannot be opened with current Restic credentials: $repo"
    emit_event 'repository_status' "$name" 'error' "$repo"
  fi
}

# --- Descriptor -----------------------------------------------------------
validate_path() {
  local stack="$1" rel="$2" cursor segment
  local -a segments
  if [[ -z "$rel" || "$rel" == /* || "$rel" == '.' || "$rel" == '..' || "$rel" == ../* || "$rel" == */../* || "$rel" == */.. ]]; then
    return 1
  fi
  IFS='/' read -r -a segments <<< "$rel"
  cursor="${stack%/}"
  for segment in "${segments[@]}"; do
    [[ -n "$segment" && "$segment" != '.' && "$segment" != '..' ]] || return 1
    cursor="$cursor/$segment"
    [[ ! -L "$cursor" ]] || return 1
  done
  [[ -e "$cursor" && -r "$cursor" ]]
}

inspect_stack() {
  local stack="$1" name="$2" descriptor
  descriptor="${stack%/}/.backup"
  local line stop_seen=0 stop_value='' rel errors_before="$ERRORS"
  local -a declared=()

  if ! safe_directory "${stack%/}"; then
    record_error "$name" 'stack directory inaccessible or linked'
    return 0
  fi
  if [[ -L "$descriptor" || ( -e "$descriptor" && ! -f "$descriptor" ) ]]; then
    record_error "$name" 'descriptor must be a regular file, not a link'
    return 0
  fi
  if [[ ! -f "$descriptor" ]]; then
    log_info "STACK $name: skipped (no .backup)"
    emit_event 'stack_skipped' "$name" 'disabled' 'no .backup'
    return 0
  fi
  ENABLED=$((ENABLED + 1))
  log_info "STACK $name: checking $descriptor"
  emit_event 'stack_discovered' "$name" 'enabled' "$descriptor"
  if [[ ! -r "$descriptor" ]]; then
    record_error "$name" 'descriptor not readable'
    return 0
  fi
  local descriptor_hash
  descriptor_hash="$(sha256sum < "$descriptor")" || { record_error "$name" 'cannot hash descriptor'; return 0; }
  DESCRIPTOR_HASHES["$name"]="${descriptor_hash%% *}"
  log_info "  INCLUDE: .backup (automatic)"
  emit_event 'include' "$name" 'ok' '.backup'

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    if [[ "$line" == docker-stop=* ]]; then
      stop_seen=$((stop_seen + 1))
      stop_value="${line#docker-stop=}"
      continue
    fi
    if [[ "$line" == *=* ]]; then
      record_error "$name" "unknown directive: $line"
      continue
    fi
    rel="${line%/}"
    if ! validate_path "$stack" "$rel"; then
      record_error "$name" "missing, unreadable or unsafe relative path: $line"
      continue
    fi
    declared+=("$rel")
    log_info "  INCLUDE: $line"
    emit_event 'include' "$name" 'ok' "$line"
  done < "$descriptor"

  if ((stop_seen != 1)) || [[ "$stop_value" != true && "$stop_value" != false ]]; then
    record_error "$name" 'docker-stop=true|false must appear exactly once'
  else
    log_info "  Docker stop: $stop_value"
    emit_event 'docker_stop_policy' "$name" 'ok' "$stop_value"
  fi
  if ((${#declared[@]} == 0)); then
    record_error "$name" 'no valid paths declared'
  fi
  check_repository "$name"
  if [[ "$MODE" == '--backup' && "$ERRORS" == "$errors_before" ]]; then
    BACKUP_TARGETS+=("$name")
    BACKUP_STOP_FLAGS+=("$stop_value")
    if [[ "$REPO_STATUS" == not_initialized ]]; then
      BACKUP_INIT_TARGETS+=("$name")
    fi
  fi
  if [[ "$MODE" == "--init" && "$ERRORS" == "$errors_before" && "$REPO_STATUS" == "not_initialized" ]]; then
    INIT_TARGETS+=("$name")
  fi
}

# --- Execution modes ------------------------------------------------------
run_check() {
  local stack name
  if ! safe_directory "$STACKS_DIR"; then
    record_error '' 'stack directory inaccessible or linked'
    return 1
  fi
  shopt -s nullglob
  for stack in "$STACKS_DIR"/*/; do
    [[ -d "$stack" ]] || continue
    name="$(basename "$stack")"
    inspect_stack "$stack" "$name"
  done
  if ((ENABLED == 0)); then
    record_error '' 'no enabled stacks; no work can be verified'
  fi
  log_info "SUMMARY: $ENABLED enabled stack(s), $ERRORS validation error(s)"
  if ((ERRORS > 0)); then
    emit_event 'summary' '' 'error' "$ENABLED enabled; $ERRORS validation errors"
    return 1
  fi
  emit_event 'summary' '' 'success' "$ENABLED enabled; 0 validation errors"
}

# --init: global validation must finish before writing anything.
init_repository() {
  local name="$1" repo="$REPOSITORIES_DIR/$1" entries
  # Refuse to initialize a nonempty directory, a symlink, or a repository
  # that appeared after the read-only preflight.
  if [[ -e "$repo" || -L "$repo" ]]; then
    if ! safe_directory "$repo" || ! entries="$(ls -A -- "$repo")" || [[ -n "$entries" ]]; then
      record_error "$name" "repository location changed or is nonempty: $repo"
      return 1
    fi
  else
    if ! mkdir -m 700 -- "$repo"; then
      record_error "$name" "cannot create repository directory: $repo"
      return 1
    fi
  fi
  log_info "STACK $name: initializing repository $repo"
  emit_event 'repository_init_started' "$name" 'started' "$repo"
  if ! run_engine "$name" init "$RESTIC_CHECK_TIMEOUT" init; then
    record_error "$name" "repository initialization failed: $repo"
    return 1
  fi
  check_repository "$name"
  if [[ "$REPO_STATUS" != ready ]]; then
    record_error "$name" "initialized repository failed verification: $repo"
    return 1
  fi
  emit_event 'repository_initialized' "$name" 'success' "$repo"
}

acquire_run_lock() {
  local lock_path="$REPOSITORIES_DIR/.stacks-backup.lock"
  if ! safe_directory "$REPOSITORIES_DIR" || [[ -L "$lock_path" || ( -e "$lock_path" && ! -f "$lock_path" ) ]]; then
    record_error '' 'unsafe orchestrator lock path'
    return 1
  fi
  if ! { exec {RUN_LOCK_FD}>>"$lock_path"; }; then
    record_error '' 'cannot open orchestrator lock'
    return 1
  fi
  if ! flock -n "$RUN_LOCK_FD"; then
    record_error '' 'another init/backup invocation is active'
    return 1
  fi
}

run_init() {
  local name
  # This mode mutates only repository directories, never application stacks.
  if (( EUID != 0 )); then
    record_error '' '--init requires root privileges'
    return 2
  fi
  if [[ -z "$RESTIC_SOURCE" ]]; then
    record_error '' 'Restic unavailable; cannot initialize repositories'
    return 2
  fi
  if ! safe_password; then
    record_error '' 'Restic password file unavailable or unsafe'
    return 2
  fi
  if [[ ! -d "$REPOSITORIES_DIR" || -L "$REPOSITORIES_DIR" ]]; then
    record_error '' 'repository base directory missing or unsafe'
    return 2
  fi
  acquire_run_lock || return 1
  # Reuse the same validation as --check; refuse all writes if any stack fails.
  run_check || return 1
  for name in "${INIT_TARGETS[@]}"; do
    init_repository "$name" || return 1
  done
  log_info "INIT SUMMARY: ${#INIT_TARGETS[@]} repository(s) initialized; $ERRORS error(s)"
  emit_event 'init_summary' '' 'success' "${#INIT_TARGETS[@]} initialized; $ERRORS errors"
}

# Run Docker with bounded execution and private, sanitized diagnostics.
lifecycle_docker() {
  local name="$1" operation="$2" result=0 err
  shift 2
  prepare_runtime || return 1
  DOCKER_OUTPUT="$(mktemp "$RUN_TEMP/docker-out-XXXXXX")" || return 1
  err="$(mktemp "$RUN_TEMP/docker-err-XXXXXX")" || return 1
  timeout --kill-after=2s "${DOCKER_TIMEOUT}s" docker "$@" >"$DOCKER_OUTPUT" 2>"$err" || result=$?
  if ((result)); then
    preserve_diagnostics "$name" "$operation" "$err" "$DOCKER_OUTPUT" "$result" || true
    record_error "$name" "$operation failed (exit=$result)"
  fi
  return "$result"
}

# Snapshot full container IDs, including stopped containers and Compose orphans.
# Transitional, paused and unknown states are refused before any stop.
snapshot_stack() {
  local name="$1" stack="$STACKS_DIR/$1" parsed
  [[ -f "$stack/docker-compose.yml" && ! -L "$stack/docker-compose.yml" ]] || {
    record_error "$name" 'docker-compose.yml missing or linked'; return 1;
  }
  lifecycle_docker "$name" compose compose --project-directory "$stack" \
    -f "$stack/docker-compose.yml" ps --all --no-trunc --format json || return 1
  if ! parsed="$(python3 - "$DOCKER_OUTPUT" <<'PYSTATE'
import json, pathlib, re, sys
try:
    text = pathlib.Path(sys.argv[1]).read_text().strip()
    rows = json.loads(text) if text.startswith('[') else [json.loads(x) for x in text.splitlines()]
    assert isinstance(rows, list)
    seen = set()
    for row in rows:
        cid, state = row['ID'], row['State']
        assert re.fullmatch('[0-9a-f]{64}', cid) and cid not in seen
        assert state in ('running', 'exited', 'created')
        seen.add(cid)
        print(cid, state)
except (ValueError, KeyError, TypeError, AssertionError, OSError):
    sys.exit(1)
PYSTATE
  )"; then
    record_error "$name" 'unsafe or unknown Compose container state'; return 1
  fi
  STACK_STATES="$parsed"
}

restore_stack() {
  local id result=0 state
  local -a failed=()
  for id in "${RESTORE_IDS[@]}"; do
    if lifecycle_docker "$RESTORE_STACK" start start "$id" &&
       lifecycle_docker "$RESTORE_STACK" inspect inspect --format '{{.State.Status}}' "$id"; then
      state="$(cat "$DOCKER_OUTPUT")"
      if [[ "$state" == running ]]; then
        emit_event container_restored "$RESTORE_STACK" success "$id"
        continue
      fi
    fi
    record_error "$RESTORE_STACK" "cannot restore container $id; manual recovery required"
    failed+=("$id"); result=1
  done
  RESTORE_IDS=("${failed[@]}")
  return "$result"
}

stop_stack() {
  local name="$1" id state
  snapshot_stack "$name" || return 1
  RESTORE_STACK="$name"
  RESTORE_IDS=()
  while read -r id state; do
    [[ -n "$id" ]] || continue
    emit_event container_initial_state "$name" info "$id $state"
    [[ "$state" == running ]] && RESTORE_IDS+=("$id")
  done <<< "$STACK_STATES"
  # Register recovery before the stop request, including partial failures.
  if ((${#RESTORE_IDS[@]})); then
    # Never force-kill an application on expiry: bound the client wait instead.
    lifecycle_docker "$name" stop stop --timeout -1 "${RESTORE_IDS[@]}" || return 1
    for id in "${RESTORE_IDS[@]}"; do
      lifecycle_docker "$name" inspect inspect --format '{{.State.Status}} {{.State.ExitCode}} {{.State.OOMKilled}}' "$id" || return 1
      state="$(cat "$DOCKER_OUTPUT")"
      if [[ "$state" != 'exited 0 false' ]]; then
        record_error "$name" "container did not exit cleanly: $id ($state)"; return 1
      fi
    done
  fi
  ensure_stack_stopped "$name"
}

# --- Local cold backup ---------------------------------------------------
ensure_stack_stopped() {
  local name="$1" stack="$STACKS_DIR/$1" result=0 output error_file
  if [[ ! -f "$stack/docker-compose.yml" || -L "$stack/docker-compose.yml" ]]; then
    record_error "$name" 'docker-compose.yml missing or linked; cannot verify containers'
    return 1
  fi
  prepare_runtime || return 1
  output="$(mktemp "$RUN_TEMP/compose-XXXXXX")" || return 1
  error_file="$(mktemp "$RUN_TEMP/compose-error-XXXXXX")" || return 1
  timeout --kill-after=2s "${DOCKER_TIMEOUT}s" docker compose --project-directory "$stack" \
    -f "$stack/docker-compose.yml" ps --all --format json >"$output" 2>"$error_file" || result=$?
  if ((result)); then
    preserve_diagnostics "$name" compose "$error_file" "$output" "$result" || true
    record_error "$name" "cannot inspect Compose states (exit=$result)"
    return 1
  fi
  if ! python3 - "$output" <<'PYSTATES'
import json, pathlib, sys
try:
    text = pathlib.Path(sys.argv[1]).read_text().strip()
    # Compose supports a JSON array or one object per line, depending on version.
    if not text:
        containers = []
    elif text.startswith('['):
        containers = json.loads(text)
    else:
        containers = [json.loads(line) for line in text.splitlines()]
    if not isinstance(containers, list):
        sys.exit(1)
    for container in containers:
        if not isinstance(container, dict) or container.get('State') not in ('exited', 'created'):
            sys.exit(1)
except (ValueError, OSError):
    sys.exit(1)
PYSTATES
  then
    record_error "$name" 'container active, state unknown or invalid Compose response; cold backup refused'
    return 1
  fi
}

# Re-read the descriptor and construct the exact set of paths to acquire.
# The entire stack folder is mounted RO at /stacks inside the container.
collect_backup_paths() {
  local name="$1" descriptor="$STACKS_DIR/$1/.backup" line rel hash_before hash_after stop_count=0
  if ! safe_directory "$STACKS_DIR/$name" || [[ -L "$descriptor" || ! -f "$descriptor" || ! -r "$descriptor" ]]; then
    record_error "$name" 'descriptor or stack changed or became inaccessible'
    return 1
  fi
  hash_before="$(sha256sum < "$descriptor")" || return 1
  hash_before="${hash_before%% *}"
  if [[ -n "${DESCRIPTOR_HASHES[$name]:-}" && "${DESCRIPTOR_HASHES[$name]}" != "$hash_before" ]]; then
    record_error "$name" 'descriptor changed since preflight'
    return 1
  fi
  BACKUP_PATHS=("/stacks/$name/.backup")
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ "$line" == docker-stop=* ]]; then
      stop_count=$((stop_count + 1))
      [[ "$line" == docker-stop=false || "$line" == docker-stop=true ]] || return 1
      continue
    fi
    [[ "$line" != *=* ]] || { record_error "$name" 'unknown descriptor directive'; return 1; }
    rel="${line%/}"
    if ! validate_path "$STACKS_DIR/$name/" "$rel"; then
      record_error "$name" "backup path changed since preflight: $rel"
      return 1
    fi
    BACKUP_PATHS+=("/stacks/$name/$rel")
  done < "$descriptor"
  hash_after="$(sha256sum < "$descriptor")" || return 1
  if ((stop_count != 1)) || [[ "${hash_after%% *}" != "$hash_before" ]]; then
    record_error "$name" 'descriptor invalid or changed during collection'
    return 1
  fi
  DESCRIPTOR_HASHES["$name"]="$hash_before"

}

backup_stack() {
  local name="$1" result=0 start=$SECONDS snapshot_id hash_after path
  local -a paths
  collect_backup_paths "$name" || return 1
  # Recheck immediately before each acquisition, not only before the entire batch.
  ensure_stack_stopped "$name" || return 1
  paths=("${BACKUP_PATHS[@]}")
  if [[ "$RESTIC_SOURCE" == 'host executable:'* ]]; then
    paths=()
    for path in "${BACKUP_PATHS[@]}"; do paths+=("$STACKS_DIR/${path#/stacks/}"); done
  fi
  emit_event backup_started "$name" started "paths=${#paths[@]}"
  run_engine "$name" backup "$RESTIC_BACKUP_TIMEOUT" backup --json --host "$name" "${paths[@]}" || result=$?
  ensure_stack_stopped "$name" || result=1
  if ((result == 0)); then
    # Parse stdout alone; stderr is separate and cannot break the JSON stream.
    if ! snapshot_id="$(python3 - "$ENGINE_OUTPUT" <<'PYSNAPSHOT'
import json, re, sys
summaries = []
try:
    with open(sys.argv[1]) as stream:
        for line in stream:
            obj = json.loads(line)
            if not isinstance(obj, dict):
                sys.exit(1)
            if obj.get('message_type') == 'summary':
                summaries.append(obj.get('snapshot_id'))
except (ValueError, OSError):
    sys.exit(1)
if len(summaries) != 1 or not isinstance(summaries[0], str) or not re.fullmatch(r'[0-9a-f]{64}', summaries[0]):
    sys.exit(1)
print(summaries[0])
PYSNAPSHOT
    )"; then
      record_error "$name" 'backup returned success but no valid snapshot ID; inspect repository snapshots before retrying'
      preserve_diagnostics "$name" snapshot_parse /dev/null "$ENGINE_OUTPUT" 1 || true
      result=1
    fi
    hash_after="$(sha256sum < "$STACKS_DIR/$name/.backup")" || result=1
    if [[ "${hash_after%% *}" != "${DESCRIPTOR_HASHES[$name]}" ]]; then
      record_error "$name" 'descriptor changed during backup; snapshot requires review'
      result=1
    fi
  fi
  if ((result)); then
    record_error "$name" "backup failed or requires review (exit=$result)"
    emit_event backup_complete "$name" error "exit=$result; duration_s=$((SECONDS-start))"
    return 1
  fi
  log_info "STACK $name: backup complete; snapshot $snapshot_id"
  emit_event backup_complete "$name" success "snapshot_id=$snapshot_id; duration_s=$((SECONDS-start))"
}

run_backup() {
  if (( EUID != 0 )); then
    record_error '' '--backup requires root privileges'
    return 2
  fi
  if [[ -z "$RESTIC_SOURCE" ]]; then
    record_error '' 'Restic unavailable; backup refused'
    return 2
  fi
  if ! command -v timeout >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1; then
    record_error '' 'timeout and docker must be available for the cold-backup pilot'
    return 2
  fi
  if ! safe_password; then
    record_error '' 'Restic password file missing or unreadable'
    return 2
  fi
  acquire_run_lock || return 1
  run_backup_targets
}

# Called only after CLI privilege/dependency checks; also exercised with fixtures.
run_backup_targets() {
  local i name overall=0
  # Global preflight: no stopping, no initializations, no backup on validation error.
  run_check || return 1
  for i in "${!BACKUP_TARGETS[@]}"; do
    name="${BACKUP_TARGETS[$i]}"
    if [[ "${BACKUP_STOP_FLAGS[$i]}" == true ]]; then
      snapshot_stack "$name" || overall=1
    elif ! ensure_stack_stopped "$name"; then
      overall=1
    fi
  done
  ((overall == 0)) || return 1
  # Initialize only after every descriptor, repository and container preflight
  # passed. init_repository rechecks for races and refuses nonempty locations.
  for name in "${BACKUP_INIT_TARGETS[@]}"; do
    init_repository "$name" || return 1
  done
  for i in "${!BACKUP_TARGETS[@]}"; do
    name="${BACKUP_TARGETS[$i]}"
    # Revalidate the descriptor before any lifecycle mutation.
    collect_backup_paths "$name" || { overall=1; continue; }
    if [[ "${BACKUP_STOP_FLAGS[$i]}" == true ]]; then
      if ! stop_stack "$name"; then
        overall=1
        restore_stack || return 1
        continue
      fi
    fi
    backup_stack "$name" || overall=1
    restore_stack || return 1
  done
  if ((overall)); then
    emit_event 'backup_summary' '' 'error' 'one or more backups failed'
    return 1
  fi
  emit_event 'backup_summary' '' 'success' "${#BACKUP_TARGETS[@]} stack(s) completed"
  log_info "BACKUP SUMMARY: ${#BACKUP_TARGETS[@]} stack(s) completed"
}

main() {
  parse_arguments "$@"
  check_requirements || return 2
  detect_restic
  if [[ "$MODE" == '--init' ]]; then
    run_init
    return $?
  fi
  if [[ "$MODE" == '--backup' ]]; then
    run_backup
    return $?
  fi
  if [[ -z "$RESTIC_SOURCE" ]]; then
    record_error '' 'Restic unavailable; repository verification incomplete'
    return 2
  fi
  run_check
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
trap finish EXIT
trap 'interrupted INT 130' INT
trap 'interrupted TERM 143' TERM
main "$@"
fi

