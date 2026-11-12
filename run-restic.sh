#!/usr/bin/env bash
# Native Restic commands against one configured repository. No stack lifecycle.
set -Eeuo pipefail

wrapper_usage() {
  cat <<'HELP'
Usage:
  sudo bash run-restic.sh [-c FILE | --config FILE] [--stack NAME] COMMAND [ARGS...]
  bash run-restic.sh --help

Options (before COMMAND):
  -c, --config FILE  Configuration file; overrides BACKUP_CONFIG.
                    Default: backup.env alongside the scripts.
  --stack NAME      Optional repository name under REPOSITORIES_DIR.
                    Without it, no repository or password is mounted;
                    Restic reports an error if the command needs a repository.
  -h, --help        Show this help without contacting Docker.

All arguments from COMMAND onward go directly to Restic, without correction.
Restic stdout, stderr and exit status are preserved. No JSONL wrapper output.
Only the repository and password file are mounted; paths refer to the container.
Application containers and .backup descriptors are not inspected or changed.

Reserved commands:
  backup, init      Use stacks-backup.sh --stack NAME --backup or --init.
  restore           Use stacks-restore.sh NAME --snapshot ID|latest.
  mount             Unsupported: needs extra mounts and privileges.
  self-update       Set RESTIC_IMAGE in the configuration instead.

Examples:
  sudo bash run-restic.sh help
  sudo bash run-restic.sh version
  sudo bash run-restic.sh --stack traefik-proxy ls --long latest
  sudo bash run-restic.sh -c backup.env --stack traefik-proxy snapshots
  sudo bash run-restic.sh --stack traefik-proxy check --read-data
  sudo bash run-restic.sh --stack traefik-proxy ls --help
HELP
}

wrapper_main() {
  local selected='' repo key value script_dir
  if (($# == 0)); then wrapper_usage; return 0; fi
  while (($#)); do
    case "$1" in
      -h|--help) wrapper_usage; return 0 ;;
      -c|--config)
        if (($# < 2)) || [[ -z "$2" || "$2" == -* ]]; then
          printf 'ERROR: %s requires a configuration file path\n' "$1" >&2
          return 2
        fi
        BACKUP_CONFIG="$2"; shift 2 ;;
      --config=*)
        BACKUP_CONFIG="${1#*=}"
        [[ -n "$BACKUP_CONFIG" ]] || { printf 'ERROR: --config requires a file path\n' >&2; return 2; }
        shift ;;
      --stack|--stack=*)
        [[ -z "$selected" ]] || { printf 'ERROR: specify --stack only once\n' >&2; return 2; }
        if [[ "$1" == --stack ]]; then
          if (($# < 2)) || [[ -z "$2" || "$2" == -* ]]; then
            printf 'ERROR: --stack requires a repository name\n' >&2
            return 2
          fi
          selected="$2"; shift 2
        else
          selected="${1#*=}"; shift
          [[ -n "$selected" ]] || { printf 'ERROR: --stack requires a repository name\n' >&2; return 2; }
        fi ;;
      --) shift; break ;;
      -*) printf 'ERROR: unknown wrapper option: %s\n' "$1" >&2; return 2 ;;
      *) break ;;
    esac
  done
  if [[ -n "$selected" && ( "$selected" == */* || "$selected" == .* || "$selected" == -* || "$selected" =~ [[:cntrl:]] ) ]]; then
    printf 'ERROR: --stack must name one repository directory, without a path\n' >&2
    return 2
  fi
  if (($# == 0)) || [[ "$1" == -* ]]; then
    printf 'ERROR: specify a Restic command after the wrapper options\n' >&2
    wrapper_usage >&2
    return 2
  fi
  # Validate before opening config, downloading images or accessing a repository.
  case "$1" in
    backup|init)
      if [[ -n "$selected" ]]; then
        printf 'ERROR: %s is reserved; use stacks-backup.sh --stack %s --%s\n' "$1" "$selected" "$1" >&2
      else
        printf 'ERROR: %s is reserved; use stacks-backup.sh --%s (optionally --stack NAME)\n' "$1" "$1" >&2
      fi
      return 2 ;;
    restore)
      printf 'ERROR: restore is reserved; use stacks-restore.sh %s --snapshot ID|latest\n' "${selected:-NAME}" >&2
      return 2 ;;
    mount)
      printf 'ERROR: mount is unsupported: additional mounts and privileges are required\n' >&2
      return 2 ;;
    self-update)
      printf 'ERROR: self-update is unsupported: configure RESTIC_IMAGE instead\n' >&2
      return 2 ;;
  esac

  # Reuse config and image preparation without changing the specialist scripts.
  # Sourcing defines functions only; it does not run their CLI or install traps.
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  source "$script_dir/stacks-backup.sh"
  initialize_config || return 2
  for key in DOCKER_TIMEOUT RESTIC_PULL_TIMEOUT; do
    value="${!key}"
    if [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?$ || ! "$value" =~ [1-9] ]]; then
      printf 'ERROR: %s must be a positive duration in seconds\n' "$key" >&2
      return 2
    fi
  done
  if [[ -z "$RESTIC_IMAGE" || "$RESTIC_IMAGE" == -* || "$RESTIC_IMAGE" =~ [[:space:]] ]]; then
    printf 'ERROR: invalid RESTIC_IMAGE\n' >&2
    return 2
  fi
  local -a mounts=()
  if [[ -n "$selected" ]]; then
    repo="$REPOSITORIES_DIR/$selected"
    for value in "$repo" "$RESTIC_PASSWORD_FILE"; do
      if [[ "$value" != /* || "$value" == *,* || "$value" =~ [[:cntrl:]] ]]; then
        printf 'ERROR: repository/password paths must be absolute without commas or control characters\n' >&2
        return 2
      fi
    done
    if ! safe_directory "$repo" || ! safe_password; then
      printf 'ERROR: selected repository or password file missing, unreadable or linked\n' >&2
      return 2
    fi
    mounts=(--mount "type=bind,src=$repo,dst=/repository"
      --mount "type=bind,src=$RESTIC_PASSWORD_FILE,dst=/run/secrets/restic.password,readonly"
      -e RESTIC_REPOSITORY=/repository
      -e RESTIC_PASSWORD_FILE=/run/secrets/restic.password)
  fi
  command -v timeout >/dev/null || { printf 'ERROR: timeout is required\n' >&2; return 2; }
  detect_restic || return 2

  # No eval, output capture, command rewriting or execution timeout. Docker
  # attaches to the native streams; exec preserves its/Restic's exit status.
  exec docker run --rm --pull never --network none -i \
    "${mounts[@]}" \
    "$RESTIC_IMAGE" "$@"
}

wrapper_main "$@"
