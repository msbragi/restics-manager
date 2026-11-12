#!/usr/bin/env bash
set -Eeuo pipefail
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
BACKUP_CONFIG="$test_root/backup.env"
: > "$BACKUP_CONFIG"
STACKS_DIR="$test_root/stacks"
source "$(dirname "$0")/../stacks-backup.sh"
initialize_config
mkdir -p "$STACKS_DIR/traefik-proxy" "$STACKS_DIR/other" "$STACKS_DIR/disabled"
printf 'docker-stop=skip\ndocker-compose.yml\n' > "$STACKS_DIR/traefik-proxy/.backup"
: > "$STACKS_DIR/traefik-proxy/docker-compose.yml"
# An unrelated malformed descriptor must not block the selected stack.
printf 'invalid-directive=true\n' > "$STACKS_DIR/other/.backup"
log_info() { :; }
record_error() { ERRORS=$((ERRORS+1)); }
check_repository() { REPO_STATUS=not_initialized; }
reset_selection() {
  ERRORS=0; ENABLED=0
  BACKUP_TARGETS=(); BACKUP_STOP_FLAGS=(); BACKUP_INIT_TARGETS=(); INIT_TARGETS=()
  DESCRIPTOR_HASHES=()
}

parse_config_arguments --check --stack traefik-proxy -c "$BACKUP_CONFIG"
parse_arguments "${CLI_ARGS[@]}"
run_check
[[ "$ENABLED" == 1 && "$ERRORS" == 0 ]]

reset_selection
parse_arguments --stack=traefik-proxy --init
run_check
[[ "${INIT_TARGETS[*]}" == traefik-proxy && "$ENABLED" == 1 ]]

reset_selection
parse_arguments --backup --stack traefik-proxy
calls=''
init_repository() { calls+="init:$1;"; }
backup_stack() { calls+="backup:$1:$2;"; }
snapshot_stack() { return 1; }
ensure_stack_stopped() { return 1; }
run_backup_targets
[[ "$calls" == 'init:traefik-proxy;backup:traefik-proxy:skip;' ]]
[[ "${BACKUP_TARGETS[*]}" == traefik-proxy ]]

for selected in absent disabled; do
  reset_selection
  parse_arguments --check --stack "$selected"
  if run_check; then exit 1; fi
  ((ERRORS > 0))
done
ln -s "$STACKS_DIR/traefik-proxy" "$STACKS_DIR/linked"
reset_selection
parse_arguments --check --stack linked
if run_check; then exit 1; fi

for selected in ../traefik-proxy /absolute . .. --check $'bad\nname'; do
  if parse_arguments --check --stack="$selected" >/dev/null 2>&1; then exit 1; fi
done
if parse_arguments --check --stack >/dev/null 2>&1; then exit 1; fi
if parse_arguments --check --stack one --stack two >/dev/null 2>&1; then exit 1; fi

# No selector preserves the normal discovery of all immediate directories.
rm "$STACKS_DIR/linked"
reset_selection
parse_arguments --check
if run_check; then exit 1; fi
[[ "$ENABLED" == 2 && "$ERRORS" -gt 0 ]]
printf 'PASS: single-stack check/init/backup, missing descriptors, unsafe names and default discovery\n'
