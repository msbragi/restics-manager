#!/usr/bin/env bash
set -Eeuo pipefail
command -v jq >/dev/null || { printf 'SKIP: jq is required\n' >&2; exit 77; }
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
BACKUP_CONFIG="$test_root/backup.env"
: > "$BACKUP_CONFIG"
STACKS_DIR="$test_root/stacks"
REPOSITORIES_DIR="$test_root/repos"
RESTIC_PASSWORD_FILE="$test_root/password"
BACKUP_LOG_DIR="$test_root/logs"
source <(sed '/^if \[\[.*BASH_SOURCE\[0\]/,$d' "$(dirname "$0")/../stacks-backup.sh")
initialize_config
RUN_TEMP="$test_root"
mkdir -p "$STACKS_DIR/demo" "$REPOSITORIES_DIR/demo"
: > "$STACKS_DIR/demo/docker-compose.yml"
: > "$REPOSITORIES_DIR/demo/config"
DOCKER_OUTPUT="$test_root/compose"
ENGINE_OUTPUT="$test_root/snapshots"
id=$(printf 'a%.0s' {1..64})
lifecycle_docker() { :; }
record_error() { :; }
printf '[{"ID":"%s","State":"running"}]' "$id" > "$DOCKER_OUTPUT"
snapshot_stack demo
[[ "$STACK_STATES" == "$id running" ]]
printf '{"ID":"%s","State":"exited"}\n' "$id" > "$DOCKER_OUTPUT"
snapshot_stack demo
[[ "$STACK_STATES" == "$id exited" ]]
: > "$DOCKER_OUTPUT"
snapshot_stack demo
[[ -z "$STACK_STATES" ]]
for state in paused restarting unknown; do
  printf '[{"ID":"%s","State":"%s"}]' "$id" "$state" > "$DOCKER_OUTPUT"
  if snapshot_stack demo; then exit 1; fi
done
printf '[{"ID":"%s","State":"running"},{"ID":"%s","State":"exited"}]' "$id" "$id" > "$DOCKER_OUTPUT"
if snapshot_stack demo; then exit 1; fi
printf '{broken' > "$DOCKER_OUTPUT"
if snapshot_stack demo; then exit 1; fi
# Literal metacharacters, quotes, backslashes, Unicode and multiline secrets.
secret=$'a*[?]"\\é\nsecond line'
printf '%s\r\n' "$secret" > "$RESTIC_PASSWORD_FILE"
escaped=$(printf '%s' "$secret" | jq -Rs .)
escaped=${escaped:1:${#escaped}-2}
ascii=$(printf '%s' "$secret" | jq -aRs .)
ascii=${ascii:1:${#ascii}-2}
printf '%s\n%s\n%s' "$secret" "$escaped" "$ascii" > "$test_root/err"
printf '%s' "$secret" > "$test_root/out"
clean=$(sanitize_diagnostics "$test_root/err" "$test_root/out" 1)
[[ "$clean" != *"$secret"* && "$clean" != *"$escaped"* && "$clean" != *"$ascii"* ]]
[[ "$clean" == *'[REDACTED]'* && "$clean" == *'engine stdout'* ]]
printf 'binary\0diagnostic' > "$test_root/err"
if sanitize_diagnostics "$test_root/err" "$test_root/out" 1; then exit 1; fi
# Load restore definitions without running its CLI or replacing test cleanup.
source <(sed -e '/^source /d' -e '/^trap /d' -e '/^restore_main "\$@"/d' "$(dirname "$0")/../stacks-restore.sh")
run_engine() { :; }
printf '[{"id":"%s","time":"2026-11-11T10:00:00.123456789+02:00","paths":["/stacks/demo/.backup","/stacks/demo/data"]}]' "$id" > "$ENGINE_OUTPUT"
load_snapshots demo
listing=$(list_snapshots demo)
[[ "$listing" == *'2026-11-11 08:00:00'* && "$listing" == *"$id"* ]]
printf '[]' > "$ENGINE_OUTPUT"
load_snapshots demo
for invalid in '{}' 'null' '[{"id":"short","time":"today"}]' '[] []' '[{"id":null}]'; do
  printf '%s' "$invalid" > "$ENGINE_OUTPUT"
  if load_snapshots demo; then exit 1; fi
done
printf 'PASS: Compose validation, diagnostic redaction, snapshot validation and UTC listing\n'
printf '[{"id":"%s","time":"2026-11-11T10:00:00Z","paths":["/stacks/demo/.backup","/stacks/demo/data"]}]' "$id" > "$ENGINE_OUTPUT"
load_snapshots demo
[[ "$(select_snapshot latest)" == "$id" ]]
[[ "$(select_snapshot aaaaaaaa)" == "$id" ]]
[[ "$(snapshot_restore_reference "$id")" == "$id:/stacks/demo" ]]
for selector in short missing bbbbbbbb; do
  if select_snapshot "$selector"; then exit 1; fi
done
id2="${id%a}b"
printf '[{"id":"%s","time":"2026-11-11T10:00:00Z"},{"id":"%s","time":"2026-11-12T10:00:00Z"}]' "$id" "$id2" > "$ENGINE_OUTPUT"
[[ "$(select_snapshot latest)" == "$id2" ]]
if select_snapshot aaaaaaaa; then exit 1; fi
for paths in '["/stacks/demo/.backup","/etc/passwd"]' '["/stacks/demo/.backup","/stacks/demo/../other"]' '["/stacks/demo/data"]' '["/stacks/demo/.backup","/stacks/other/.backup"]'; do
  printf '[{"id":"%s","time":"2026-11-11T10:00:00Z","paths":%s}]' "$id" "$paths" > "$ENGINE_OUTPUT"
  if snapshot_restore_reference "$id"; then exit 1; fi
done
printf 'PASS: snapshot selection, ambiguous prefixes and unsafe restore paths\n'
collect_backup_paths() { BACKUP_PATHS=(/stacks/demo/.backup); }
ensure_stack_stopped() { :; }
log_info() { :; }
preserve_diagnostics() { :; }
: > "$STACKS_DIR/demo/.backup"
hash=$(sha256sum < "$STACKS_DIR/demo/.backup")
DESCRIPTOR_HASHES[demo]=${hash%% *}
printf '{"message_type":"status"}\n{"message_type":"summary","snapshot_id":"%s"}\n' "$id" > "$ENGINE_OUTPUT"
backup_stack demo
for invalid in '[]' '{}' '{"message_type":"summary","snapshot_id":"short"}' '{broken'; do
  printf '%s' "$invalid" > "$ENGINE_OUTPUT"
  if backup_stack demo; then exit 1; fi
done
printf '{"message_type":"summary","snapshot_id":"%s"}\n{"message_type":"summary","snapshot_id":"%s"}\n' "$id" "$id" > "$ENGINE_OUTPUT"
if backup_stack demo; then exit 1; fi
printf 'PASS: backup summary validation\n'
