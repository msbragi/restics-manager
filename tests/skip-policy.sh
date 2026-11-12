#!/usr/bin/env bash
set -Eeuo pipefail
command -v jq >/dev/null || { printf 'SKIP: jq is required\n' >&2; exit 77; }
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
BACKUP_CONFIG="$test_root/backup.env"
: > "$BACKUP_CONFIG"
STACKS_DIR="$test_root/stacks"
source "$(dirname "$0")/../stacks-backup.sh"
initialize_config
MODE=--backup
mkdir -p "$STACKS_DIR/media"
printf 'video test data\n' > "$STACKS_DIR/media/video.mp4"
printf 'docker-stop=skip\nvideo.mp4\n' > "$STACKS_DIR/media/.backup"
log_info() { :; }
log_warn() { :; }
record_error() { ERRORS=$((ERRORS+1)); }
check_repository() { REPO_STATUS=ready; }
engine_calls=0
application_calls=0
docker() { printf 'Unexpected Docker invocation\n' >&2; return 1; }
snapshot_stack() { application_calls=$((application_calls+1)); return 1; }
ensure_stack_stopped() { application_calls=$((application_calls+1)); return 1; }
stop_stack() { application_calls=$((application_calls+1)); return 1; }
restore_stack() { application_calls=$((application_calls+1)); return 1; }
run_engine() {
  engine_calls=$((engine_calls+1))
  [[ "$*" == *'/stacks/media/video.mp4'* ]]
  ENGINE_OUTPUT="$test_root/summary"
  printf '{"message_type":"summary","snapshot_id":"%064d"}\n' 0 > "$ENGINE_OUTPUT"
}

# No Compose file exists. Exercise real descriptor parsing, preflight,
# path collection and acquisition with only the Restic engine simulated.
run_backup_targets
[[ "$engine_calls" == 1 && "$application_calls" == 0 && "$ERRORS" == 0 ]]
[[ "${BACKUP_STOP_FLAGS[0]}" == skip ]]

# Omitting, duplicating or misspelling the directive still fails validation.
for directive in '' 'docker-stop=unknown' $'docker-stop=skip\ndocker-stop=true'; do
  printf '%s\nvideo.mp4\n' "$directive" > "$STACKS_DIR/media/.backup"
  ERRORS=0
  inspect_stack "$STACKS_DIR/media/" media
  ((ERRORS > 0))
  unset 'DESCRIPTOR_HASHES[media]'
  if collect_backup_paths media; then exit 1; fi
done

# Existing policies must still consult container state and refuse this fixture.
for policy in false true; do
  printf 'docker-stop=%s\nvideo.mp4\n' "$policy" > "$STACKS_DIR/media/.backup"
  ERRORS=0; ENABLED=0
  BACKUP_TARGETS=(); BACKUP_STOP_FLAGS=(); BACKUP_INIT_TARGETS=()
  if run_backup_targets; then exit 1; fi
done
[[ "$engine_calls" == 1 && "$application_calls" == 2 ]]
printf 'PASS: skip without Compose, no application lifecycle calls, strict directives, true/false protections\n'
