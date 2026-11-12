#!/usr/bin/env bash
set -Eeuo pipefail
# Load definitions without executing the CLI or installing exit traps.
source <(sed '/^if \[\[.*BASH_SOURCE\[0\]/,$d' "$(dirname "$0")/../stacks-backup.sh")
initialize_config
RUN_TEMP=$(mktemp -d)
trap 'rm -rf "$RUN_TEMP"' EXIT
DOCKER_OUTPUT="$RUN_TEMP/output"
log_info() { :; }
record_error() { ERRORS=$((ERRORS+1)); }
emit_event() { :; }
a=$(printf 'a%.0s' {1..64})
b=$(printf 'b%.0s' {1..64})
snapshot_stack() { STACK_STATES="$a running"$'\n'"$b exited"; }
ensure_stack_stopped() { return 0; }
lifecycle_docker() {
  local op=$2; shift 2
  calls+="$op:$*;"
  case "$op" in
    stop) return "${STOP_RESULT:-0}" ;;
    inspect)
      if [[ "$*" == *ExitCode* ]]; then
        printf '%s\n' "${EXIT_STATE:-exited 0 false}" > "$DOCKER_OUTPUT"
      else
        printf '%s\n' running > "$DOCKER_OUTPUT"
      fi ;;
    start) return "${START_RESULT:-0}" ;;
  esac
}
calls=''
stop_stack demo
[[ ${#RESTORE_IDS[@]} == 1 && ${RESTORE_IDS[0]} == "$a" ]]
restore_stack
[[ ${#RESTORE_IDS[@]} == 0 && "$calls" != *"$b"* ]]
STOP_RESULT=124; calls=''
if stop_stack demo; then exit 1; fi
[[ ${RESTORE_IDS[0]} == "$a" ]]
restore_stack
[[ "$calls" == *"start:start $a"* ]]
STOP_RESULT=0; EXIT_STATE='exited 137 false'
if stop_stack demo; then exit 1; fi
restore_stack
EXIT_STATE='exited 0 false'
stop_stack demo
START_RESULT=1
if restore_stack; then exit 1; fi
[[ ${RESTORE_IDS[0]} == "$a" ]]
START_RESULT=0
restore_stack
# Exercise batch ordering and backup failure recovery.
run_check() { BACKUP_TARGETS=(demo other); BACKUP_STOP_FLAGS=(true false); BACKUP_INIT_TARGETS=(demo); }
collect_backup_paths() { :; }
init_repository() { calls+='init;'; }
backup_stack() { calls+="backup:$1;"; return 1; }
calls=''
if run_backup_targets; then exit 1; fi
[[ "$calls" == init\;* && "$calls" == *"backup:demo;start:start $a"* && "$calls" == *'backup:other;'* ]]
[[ ${#RESTORE_IDS[@]} == 0 ]]
printf 'PASS: running/stopped preservation, stop timeout, unclean exit, restart failure/retry, init ordering, backup failure recovery\n'
