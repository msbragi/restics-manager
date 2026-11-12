#!/usr/bin/env bash
set -Eeuo pipefail
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/repos with spaces/traefik-proxy"
printf 'fixture password\n' > "$test_root/password"
cat > "$test_root/backup.env" <<EOF
REPOSITORIES_DIR=$test_root/repos with spaces
RESTIC_PASSWORD_FILE=$test_root/password
EOF
cat > "$test_root/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$1" >> "$MOCK_CALLS"
case "$1" in
  info) exit 0 ;;
  image) [[ ! -e "$MOCK_MISSING" ]] ;;
  pull)
    [[ "${MOCK_PULL_FAIL:-0}" == 0 ]] || exit 1
    rm -f "$MOCK_MISSING"
    printf 'pull progress\n'
    exit 0 ;;
  run)
    printf '%s\0' "$@" > "$MOCK_ARGS"
    printf 'native stdout\n'
    printf 'native stderr\n' >&2
    exit "${MOCK_STATUS:-0}" ;;
  *) exit 99 ;;
esac
DOCKER
chmod +x "$test_root/bin/docker"
export PATH="$test_root/bin:$PATH"
export MOCK_CALLS="$test_root/calls" MOCK_ARGS="$test_root/args" MOCK_MISSING="$test_root/missing"
: > "$MOCK_CALLS"
wrapper() { bash "$project_dir/run-restic.sh" "$@" > "$test_root/out" 2> "$test_root/err"; }

BACKUP_CONFIG=/missing wrapper --help
[[ ! -s "$MOCK_CALLS" ]]
for command in backup init restore mount self-update; do
  status=0
  wrapper -c /missing --stack traefik-proxy "$command" || status=$?
  [[ "$status" == 2 && ! -s "$MOCK_CALLS" ]]
done
for selector in ../escape /absolute . --bad; do
  status=0
  wrapper --stack="$selector" snapshots || status=$?
  [[ "$status" == 2 && ! -s "$MOCK_CALLS" ]]
done

# Config precedence, argument boundaries, no extra stdout and native streams.
BACKUP_CONFIG=/missing wrapper -c "$test_root/backup.env" --stack traefik-proxy ls --long 'snapshot with spaces' --help
[[ "$(cat "$test_root/out")" == 'native stdout' ]]
[[ "$(cat "$test_root/err")" == *'native stderr'* ]]
args=()
while IFS= read -r -d '' argument; do args+=("$argument"); done < "$MOCK_ARGS"
[[ "${args[*]}" == *"src=$test_root/repos with spaces/traefik-proxy,dst=/repository"* ]]
size=${#args[@]}
[[ "${args[size-4]}" == ls && "${args[size-3]}" == --long && "${args[size-2]}" == 'snapshot with spaces' && "${args[size-1]}" == --help ]]
[[ "${args[*]}" != *'dst=/stacks'* ]]

# No selector: no password/repository prerequisites or mounts. Native help,
# version and missing-repository errors remain Restic's responsibility.
cat > "$test_root/no-repository.env" <<EOF
REPOSITORIES_DIR=$test_root/not-present
RESTIC_PASSWORD_FILE=$test_root/not-present/password
EOF
for command in help version; do
  wrapper -c "$test_root/no-repository.env" "$command"
  args=()
  while IFS= read -r -d '' argument; do args+=("$argument"); done < "$MOCK_ARGS"
  [[ "${args[*]}" != *'--mount'* && "${args[*]}" != *'RESTIC_REPOSITORY='* ]]
  [[ "${args[${#args[@]}-1]}" == "$command" ]]
done
status=0
MOCK_STATUS=1 wrapper -c "$test_root/no-repository.env" snapshots || status=$?
[[ "$status" == 1 && "$(cat "$test_root/out")" == 'native stdout' ]]
status=0
wrapper -c /missing restore || status=$?
[[ "$status" == 2 ]]

# Unknown native commands/errors are not corrected or swallowed.
status=0
MOCK_STATUS=42 wrapper -c "$test_root/backup.env" --stack traefik-proxy snapshost || status=$?
[[ "$status" == 42 && "$(cat "$test_root/out")" == 'native stdout' ]]

# The image is reused when present and pulled/rechecked when missing.
[[ "$(cat "$MOCK_CALLS")" != *pull* ]]
: > "$MOCK_MISSING"
wrapper -c "$test_root/backup.env" --stack traefik-proxy snapshots
[[ "$(cat "$MOCK_CALLS")" == *pull* && "$(cat "$test_root/out")" == 'native stdout' ]]

: > "$MOCK_CALLS"
: > "$MOCK_MISSING"
status=0
MOCK_PULL_FAIL=1 wrapper -c "$test_root/backup.env" --stack traefik-proxy snapshots || status=$?
[[ "$status" == 2 && "$(cat "$MOCK_CALLS")" != *run* ]]
printf 'PASS: reserved commands, config precedence, native arguments/streams/status and image preparation\n'
