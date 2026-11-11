#!/usr/bin/env bash
# File-only restores: never starts containers or overwrites an existing tree.
set -Eeuo pipefail
RESTORE_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$RESTORE_SCRIPT_DIR/stacks-backup.sh"
trap finish EXIT
trap 'interrupted INT 130' INT
trap 'interrupted TERM 143' TERM

restore_usage() {
  cat >&2 <<'HELP'
Usage:
  sudo bash stacks-restore.sh --list
  sudo bash stacks-restore.sh --list NAME
  sudo bash stacks-restore.sh NAME --snapshot ID|latest
Lists print tables on stdout. Restore prints its destination and snapshot ID.
DISPONIBILE indica presenza in Restic, non integrità o restore verificati.
HELP
}

restore_requirements() {
  local key value
  for key in timeout python3 mktemp stat; do
    command -v "$key" >/dev/null || { log_error "missing tool: $key"; return 1; }
  done
  for key in BACKUP_ROOT REPOSITORIES_DIR RESTIC_PASSWORD_FILE BACKUP_LOG_DIR RESTORE_DIR; do
    value="${!key}"
    [[ "$value" == /* && "$value" != *,* && ! "$value" =~ [[:cntrl:]] ]] || return 1
  done
  for value in "$RESTIC_CHECK_TIMEOUT" "$RESTIC_BACKUP_TIMEOUT" "$DOCKER_TIMEOUT"; do
    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ && "$value" =~ [1-9] ]] || return 1
  done
  [[ -n "$RESTIC_IMAGE" && "$RESTIC_IMAGE" != -* && ! "$RESTIC_IMAGE" =~ [[:space:]] ]] || return 1
  safe_directory "$REPOSITORIES_DIR" && safe_password || {
    log_error 'repository base or password unavailable; run with sudo if required'; return 1;
  }
  detect_restic
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
  python3 - "$SNAPSHOT_FILE" <<'PY'
import json, re, sys
try:
    rows=json.load(open(sys.argv[1]))
    assert isinstance(rows,list)
    for row in rows:
        assert re.fullmatch('[0-9a-f]{64}',row['id'])
        assert isinstance(row['time'],str)
except (ValueError, OSError, KeyError, TypeError, AssertionError):
    sys.exit(1)
PY
}

list_snapshots() {
  local name="$1"
  load_snapshots "$name" || { log_error "$name: cannot list snapshots"; return 1; }
  python3 - "$SNAPSHOT_FILE" <<'PY'
import json,sys
from datetime import datetime, timezone
print(f"{'DATA (UTC)':<21}  {'STATO':<12}  ID SNAPSHOT")
print(f"{'-'*21}  {'-'*12}  {'-'*64}")
for row in sorted(json.load(open(sys.argv[1])),key=lambda r:r['time'],reverse=True):
    date = datetime.fromisoformat(row['time'].replace('Z','+00:00')).astimezone(timezone.utc)
    print(f"{date:%Y-%m-%d %H:%M:%S}    {'DISPONIBILE':<12}  {row['id']}")
PY
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
    count="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$SNAPSHOT_FILE")"
    printf '%-*s  %8s  %s\n' "$width" "$name" "$count" "$([[ "$count" == 0 ]] && printf VUOTO || printf DISPONIBILE)"
  done
  return "$result"
}

restore_snapshot() {
  local name="$1" selector="$2" selected destination restore_ref result=0 err output
  (( EUID == 0 )) || { log_error 'restore requires root to preserve ownership'; return 2; }
  load_snapshots "$name" || return 1
  selected="$(python3 - "$SNAPSHOT_FILE" "$selector" <<'PY'
import json,re,sys
rows=json.load(open(sys.argv[1])); selector=sys.argv[2]
if selector=='latest':
    matches=sorted(rows,key=lambda r:r['time'],reverse=True)[:1]
elif re.fullmatch('[0-9a-f]{8,64}',selector):
    matches=[r for r in rows if r['id'].startswith(selector)]
else:
    matches=[]
if len(matches)!=1:
    print('Snapshot missing, invalid or ambiguous',file=sys.stderr); sys.exit(1)
print(matches[0]['id'])
PY
  )" || return 1
  # Use the stack directory stored in this snapshot, independent of the
  # current backup engine (Docker /stacks or an absolute host source path).
  restore_ref="$(python3 - "$SNAPSHOT_FILE" "$selected" <<'PYPATH'
import json, posixpath, sys
row = next(r for r in json.load(open(sys.argv[1])) if r['id'] == sys.argv[2])
paths = row.get('paths', [])
markers = [p for p in paths if p.endswith('/.backup')]
if len(markers) != 1:
    print('Cannot identify stack root from snapshot paths', file=sys.stderr); sys.exit(1)
root = posixpath.dirname(markers[0])
if not root.startswith('/') or root == '/' or any(not p.startswith(root + '/') for p in paths):
    print('Unexpected paths outside stack root', file=sys.stderr); sys.exit(1)
print(row['id'] + ':' + root)
PYPATH
  )" || return 1
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
  if [[ "$RESTIC_SOURCE" == 'host executable:'* ]]; then
    timeout --kill-after=5s "${RESTIC_BACKUP_TIMEOUT}s" env \
      RESTIC_REPOSITORY="$REPOSITORIES_DIR/$name" RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
      restic restore "$restore_ref" --target "$destination" --verify || result=$?
  else
    ACTIVE_CONTAINER="restic-restore-$RUN_ID-$RANDOM"
    timeout --kill-after=5s "${RESTIC_BACKUP_TIMEOUT}s" docker run --rm --pull never \
      --name "$ACTIVE_CONTAINER" --network none \
      --mount "type=bind,src=$REPOSITORIES_DIR/$name,dst=/repository" \
      --mount "type=bind,src=$RESTIC_PASSWORD_FILE,dst=/run/secrets/restic.password,readonly" \
      --mount "type=bind,src=$destination,dst=/restore" \
      -e RESTIC_REPOSITORY=/repository -e RESTIC_PASSWORD_FILE=/run/secrets/restic.password \
      "$RESTIC_IMAGE" restore "$restore_ref" --target /restore --verify || result=$?
    if ((result)); then cleanup_container || true; else ACTIVE_CONTAINER=''; fi
  fi
  if ((result)); then
    log_error "restore failed (exit=$result); partial files retained: $destination"
    return "$result"
  fi
  printf 'Restore verified: %s\n' "$destination"
}

restore_main() {
  if [[ $# == 1 && ( "$1" == --help || "$1" == -h ) ]]; then restore_usage; return 0; fi
  if [[ $# == 1 && "$1" == --list ]]; then
    restore_requirements && list_stacks
  elif [[ $# == 2 && "$1" == --list ]] && valid_name "$2"; then
    restore_requirements && list_snapshots "$2"
  elif [[ $# == 3 && "$2" == --snapshot ]] && valid_name "$1"; then
    restore_requirements && restore_snapshot "$1" "$3"
  else
    restore_usage; return 2
  fi
}
# Listing/restore output is a human interface; engine events stay off stdout.
flush_events() { :; }
restore_main "$@"
