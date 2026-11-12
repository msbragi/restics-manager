#!/usr/bin/env bash
# File-only restores: never starts containers or overwrites an existing tree.
set -Eeuo pipefail
RESTORE_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$RESTORE_SCRIPT_DIR/stacks-backup.sh"

restore_usage() {
  cat <<'HELP'
Usage:
  sudo bash stacks-restore.sh [-c FILE | --config FILE] --list
  sudo bash stacks-restore.sh [-c FILE | --config FILE] --list NAME
  sudo bash stacks-restore.sh [-c FILE | --config FILE] NAME --snapshot ID|latest
  bash stacks-restore.sh --help

Options:
  -c, --config FILE  Configuration file (overrides BACKUP_CONFIG).
                    Default: backup.env alongside the scripts.
  --list [NAME]     List repositories or snapshots of one stack.
  NAME --snapshot ID|latest
                    Restore a snapshot; ID prefixes must be unambiguous
                    and contain at least 8 hexadecimal characters.
  -h, --help        Show this help. No operation also shows help.

Examples:
  sudo bash stacks-restore.sh -c .backup-test.env --list
  sudo bash stacks-restore.sh --config backup.env demo --snapshot latest

Lists print tables on stdout. Restore prints its destination and snapshot ID.
DISPONIBILE indica presenza in Restic, non integrità o restore verificati.
HELP
}

restore_requirements() {
  local key value
  for key in timeout jq date mktemp stat; do
    command -v "$key" >/dev/null || { log_error "missing tool: $key"; return 1; }
  done
  for key in BACKUP_ROOT REPOSITORIES_DIR RESTIC_PASSWORD_FILE BACKUP_LOG_DIR RESTORE_DIR; do
    value="${!key}"
    [[ "$value" == /* && "$value" != *,* && ! "$value" =~ [[:cntrl:]] ]] || return 1
  done
  for value in "$RESTIC_CHECK_TIMEOUT" "$RESTIC_BACKUP_TIMEOUT" "$RESTIC_PULL_TIMEOUT" "$DOCKER_TIMEOUT"; do
    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ && "$value" =~ [1-9] ]] || return 1
  done
  [[ -n "$RESTIC_IMAGE" && "$RESTIC_IMAGE" != -* && ! "$RESTIC_IMAGE" =~ [[:space:]] ]] || return 1
  safe_directory "$REPOSITORIES_DIR" && safe_password || {
    log_error 'repository base or password unavailable; run with sudo if required'; return 1;
  }
  detect_restic || return 1
  [[ -n "$RESTIC_SOURCE" ]] || return 1
}

valid_name() {
  [[ -n "$1" && "$1" != .* && "$1" != */* && ! "$1" =~ [[:cntrl:]] ]]
}

load_snapshots() {
  local name="$1"
  valid_name "$name" && safe_directory "$REPOSITORIES_DIR/$name" || return 1
  [[ -f "$REPOSITORIES_DIR/$name/config" ]] || return 1
  run_engine "$name" snapshots "$RESTIC_CHECK_TIMEOUT" snapshots --json || return 1
  SNAPSHOT_FILE="$ENGINE_OUTPUT"
  jq -es 'length == 1 and (.[0] | type == "array" and all(.[];
    type == "object" and (.id | type == "string" and test("^[0-9a-f]{64}$"))
    and (.time | type == "string" and (explode | all(.[]; . >= 32)))))' \
    "$SNAPSHOT_FILE" >/dev/null
}

list_snapshots() {
  local name="$1"
  load_snapshots "$name" || { log_error "$name: cannot list snapshots"; return 1; }
  local rows timestamp id formatted
  rows="$(jq -r 'sort_by(.time) | reverse | .[] | [.time, .id] | @tsv' "$SNAPSHOT_FILE")" || return 1
  printf '%-21s  %-12s  ID SNAPSHOT\n' 'DATA (UTC)' STATO
  printf '%-21s  %-12s  %s\n' '---------------------' '------------' '----------------------------------------------------------------'
  while IFS=$'\t' read -r timestamp id; do
    [[ -n "$timestamp" ]] || continue
    formatted="$(date -u -d "$timestamp" '+%Y-%m-%d %H:%M:%S')" || return 1
    printf '%-21s  %-12s  %s\n' "$formatted" DISPONIBILE "$id"
  done <<< "$rows"
}

list_stacks() {
  local repo name count result=0
  local width=5
  for repo in "$REPOSITORIES_DIR"/*; do
    [[ -d "$repo" || -L "$repo" ]] || continue
    name="${repo##*/}"
    ((${#name} <= width)) || width=${#name}
  done
  printf '\nBackup disponibili\n'
  printf '%-*s  %8s  %s\n' "$width" STACK SNAPSHOT STATO
  printf '%-*s  %8s  %s\n' "$width" "$(printf '%*s' "$width" '' | tr ' ' '-')" '--------' '-----------'
  shopt -s nullglob
  for repo in "$REPOSITORIES_DIR"/*; do
    [[ -d "$repo" || -L "$repo" ]] || continue
    name="${repo##*/}"
    if ! valid_name "$name"; then log_error 'invalid repository name'; result=1; continue; fi
    if ! load_snapshots "$name"; then
      printf '%-*s  %8s  %s\n' "$width" "$name" '-' ERRORE; result=1; continue
    fi
    count="$(jq -r length "$SNAPSHOT_FILE")"
    printf '%-*s  %8s  %s\n' "$width" "$name" "$count" "$([[ "$count" == 0 ]] && printf VUOTO || printf DISPONIBILE)"
  done
  return "$result"
}

select_snapshot() {
  local selector="$1"
  jq -er --arg selector "$selector" '
    (if $selector == "latest" then sort_by(.time) | reverse | .[:1]
     elif ($selector | test("^[0-9a-f]{8,64}$")) then
       map(select(.id | startswith($selector)))
     else [] end) |
    if length == 1 then .[0].id else error("Snapshot missing, invalid or ambiguous") end
  ' "$SNAPSHOT_FILE"
}

snapshot_restore_reference() {
  local selected="$1"
  jq -er --arg selected "$selected" '
    .[] | select(.id == $selected) | .paths as $paths |
    if ($paths | type) != "array" or
       ($paths | all(.[]; type == "string") | not)
    then error("Invalid snapshot paths") else
      [$paths[] | select(endswith("/.backup"))] as $markers |
      if ($markers | length) != 1 then error("Cannot identify stack root") else
        ($markers[0] | rtrimstr("/.backup")) as $root |
        if ($root | startswith("/")) and ($root != "" and $root != "/") and
           ($root | split("/") | all(.[]; . != "." and . != "..")) and
           ($paths | all(.[]; startswith($root + "/") and
             (split("/") | all(.[]; . != "." and . != ".."))))
        then .id + ":" + $root else error("Unexpected paths outside stack root") end
      end
    end
  ' "$SNAPSHOT_FILE"
}

restore_snapshot() {
  local name="$1" selector="$2" selected destination restore_ref result=0 err output
  (( EUID == 0 )) || { log_error 'restore requires root to preserve ownership'; return 2; }
  load_snapshots "$name" || return 1
  selected="$(select_snapshot "$selector")" || return 1
  restore_ref="$(snapshot_restore_reference "$selected")" || return 1
  if ! no_symlink_components "${RESTORE_DIR%/}"; then
    log_error 'RESTORE_DIR contains a link or unsafe path component'; return 1
  fi
  if [[ ! -e "$RESTORE_DIR" ]]; then
    (umask 077; mkdir -p -- "$RESTORE_DIR") || return 1
  fi
  if ! safe_directory "$RESTORE_DIR" || [[ ! -O "$RESTORE_DIR" || ! -w "$RESTORE_DIR" ]]; then
    log_error 'RESTORE_DIR must be a writable directory owned by the current user'; return 1
  fi
  destination="$(mktemp -d "$RESTORE_DIR/restore-$name-${selected:0:8}-XXXXXX")" || return 1
  printf 'Restore directory: %s\nSnapshot: %s\n' "$destination" "$selected"
  prepare_runtime || return 1
  ACTIVE_CONTAINER="restic-restore-$RUN_ID-$RANDOM"
  timeout --kill-after=5s "${RESTIC_BACKUP_TIMEOUT}s" docker run --rm --pull never \
    --name "$ACTIVE_CONTAINER" --network none \
    --mount "type=bind,src=$REPOSITORIES_DIR/$name,dst=/repository" \
    --mount "type=bind,src=$RESTIC_PASSWORD_FILE,dst=/run/secrets/restic.password,readonly" \
    --mount "type=bind,src=$destination,dst=/restore" \
    -e RESTIC_REPOSITORY=/repository -e RESTIC_PASSWORD_FILE=/run/secrets/restic.password \
    "$RESTIC_IMAGE" restore "$restore_ref" --target /restore --verify || result=$?
  if ((result)); then cleanup_container || true; else ACTIVE_CONTAINER=''; fi
  if ((result)); then
    log_error "restore failed (exit=$result); partial files retained: $destination"
    return "$result"
  fi
  printf 'Restore verified: %s\n' "$destination"
}

restore_main() {
  parse_config_arguments "$@" || { restore_usage >&2; return 2; }
  if ((CLI_HELP || ${#CLI_ARGS[@]} == 0)); then restore_usage; return 0; fi
  set -- "${CLI_ARGS[@]}"
  # Reject invalid invocations before reading configuration or contacting Docker.
  if [[ $# == 1 && "$1" == --list ]] ||
     { [[ $# == 2 && "$1" == --list && "$2" != -* ]] && valid_name "$2"; } ||
     { [[ $# == 3 && "$1" != -* && "$2" == --snapshot && -n "$3" && "$3" != -* ]] && valid_name "$1"; }; then
    :
  else
    log_error 'invalid or incomplete restore operation'
    restore_usage >&2
    return 2
  fi
  initialize_config || return 2
  trap finish EXIT
  trap 'interrupted INT 130' INT
  trap 'interrupted TERM 143' TERM
  if [[ $# == 1 && "$1" == --list ]]; then
    restore_requirements && list_stacks
  elif [[ $# == 2 && "$1" == --list ]] && valid_name "$2"; then
    restore_requirements && list_snapshots "$2"
  elif [[ $# == 3 && "$2" == --snapshot ]] && valid_name "$1"; then
    restore_requirements && restore_snapshot "$1" "$3"
  else
    restore_usage >&2; return 2
  fi
}
# Listing/restore output is a human interface; engine events stay off stdout.
flush_events() { :; }
restore_main "$@"
