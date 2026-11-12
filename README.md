# Restics Manager

Bash scripts for local Restic backups of Docker Compose stacks. Each stack opts in through a `.backup` file and gets a separate encrypted Restic repository. Repositories share the password configured for the environment.

**Status: experimental.** See [TODO.md](TODO.md) for validation results and remaining work before production use.

## Requirements

- Linux with Bash 4 or newer, `jq`, GNU coreutils, and `flock`.
- Docker Engine for all Restic operations; Docker Compose v2 for stack inspection and container lifecycle operations.
- Access to the configured image registry on first use if the Restic image is not already present. The default image is `restic/restic:0.19.1`.
- Root privileges for repository initialization and backups; sufficient permissions for listing and restoring files.

The host needs `jq` for JSON processing, including when Restic runs in Docker. Python is not required. `jq` may need to be installed separately through your Linux distribution's package manager.

The scripts run on the host and start temporary Restic containers directly. No Compose service for Restic is needed, and a host Restic executable is not used. Site Compose files remain necessary for stack lifecycle operations. Paths, image and timeouts are configured in `backup.env`; the password stays in the separate secret file referenced there.

**Docker is required by both scripts**, including repository checks, snapshot listings and restores. Installing the standalone Restic binary on the host does not remove this requirement: the scripts currently invoke Restic exclusively through Docker.

Using standalone Restic requires code changes to replace the container invocations and map container paths to host paths. A configuration change alone is not sufficient. For backups of Docker Compose stacks, Docker and Compose would still be needed to inspect, stop and restart application containers, even with a standalone Restic backend. Running the scripts entirely without Docker would require adapting that stack lifecycle logic as well. These standalone modes are not currently implemented.

## Setup

Clone the repository and enter its directory:

```bash
git clone https://github.com/msbragi/restics-manager.git
cd restics-manager
```

Edit the included `backup.env` to match your machine's paths. This file is versioned and contains settings and the password file path, not the password itself. Keep secret values in the separate password file.

Use literal, absolute paths without shell quotes or variable expansion. For example:

```dotenv
BACKUP_ROOT=/opt/restics-manager
STACKS_DIR=/opt/stacks
REPOSITORIES_DIR=/opt/restics-manager/backup-repositories
RESTIC_PASSWORD_FILE=/opt/restics-manager/backup-secrets/restic.password
BACKUP_LOG_DIR=/opt/restics-manager/backup-logs
RESTORE_DIR=/opt/restics-manager/restores
RESTIC_IMAGE=restic/restic:0.19.1
RESTIC_PULL_TIMEOUT=600
RESTIC_CHECK_TIMEOUT=60
RESTIC_BACKUP_TIMEOUT=3600
DOCKER_TIMEOUT=30
STOP_RECOVERY_TIMEOUT=120
```

Adjust the paths for your machine. Create the stack and repository base directories before running the scripts. Store a nonempty Restic password in the configured password file and restrict its access, for example with directory mode `700` and file mode `600`. Keep a separate, secure copy of this password: it is needed to recover your backups.

Configuration defaults to `backup.env` in the script directory. Both scripts accept `--config FILE` or `-c FILE`, before or after the operation. This takes precedence over the legacy `BACKUP_CONFIG` environment variable. An explicitly selected file that is missing or unreadable is an error. Environment variables for individual settings still override file values. Without configuration, `BACKUP_ROOT` defaults to the script directory; stacks default to `BACKUP_ROOT/stacks`, and the other data directories follow the layout above. Configured paths must not contain symlink components. `BACKUP_ROOT` supplies defaults only: explicit directory settings can point elsewhere.

```bash
sudo bash stacks-backup.sh --config .backup-test.env --check
sudo bash stacks-backup.sh -c .backup-test.env --backup
sudo bash stacks-restore.sh -c .backup-test.env --list
sudo bash stacks-restore.sh -c .backup-test.env timeout --snapshot latest
```

With no arguments, with only a configuration option, or with `--help`/`-h`, the scripts print usage and examples without reading configuration or contacting Docker. Invalid arguments print an error and usage and exit with status 2.

Before check, initialization, backup, listing or restore, the scripts verify Docker access and the configured image. If the image is missing, they run `docker pull` with a separate `RESTIC_PULL_TIMEOUT` (default 600 seconds), then verify it again. Pull output goes to stderr. Failure stops the operation before application containers are stopped. A present image is reused without checking for updates. `--help` does not contact Docker. Actual Restic containers use `--network none` and `--pull never`; only the preparation step downloads images. Thus the first `--check` may download an image even though it does not take a backup.

Backup secrets, repositories, logs, restores, and JSONL output are excluded by `.gitignore` when stored in the default locations. `backup.env` is included in the repository.

## Select what to back up

Create a `.backup` file inside each stack directory, for example `/opt/stacks/demo/.backup`:

```text
# Stop running containers while taking the backup.
docker-stop=true
docker-compose.yml
config
data
```

Each path is relative to the stack directory and must exist and be readable. Absolute paths, parent traversal, and symlink path components are rejected. Blank lines and comments are allowed. The `.backup` file itself is included automatically. Stacks without this file are skipped.

Include exactly one `docker-stop` directive:

- `docker-stop=true`: record the stack's container states, stop running containers, take the backup, and attempt to restart those same containers. Containers already stopped remain stopped.
- `docker-stop=false`: require the stack's containers to be stopped before taking the backup.
- `docker-stop=skip`: back up the declared paths without inspecting, stopping or restarting application containers. No Compose file is required. Suitable for ordinary directories, stable media or completed database dumps; consistency of files modified during the backup is your responsibility.

The directive is mandatory and must appear exactly once, with one of these three values. For `true` and `false`, the scripts expect each stack's Compose file to be named `docker-compose.yml`. With `skip`, Docker is still required to run the Restic image, but the application itself need not use Docker.

### Preload large media before a cold backup

For example, first back up stable video files with the application running, using this `.backup` in the same stack directory:

```text
docker-stop=skip
data/www/varie
```

After that run finishes, change the descriptor to `docker-stop=true` and include **all** required paths, including `data/www/varie`, then run `--backup` again. The final snapshot includes only the paths declared in this second run; it does not automatically merge paths from previous snapshots. Using the same repository allows Restic to reuse existing data blocks. It may still reread the large files when the selected paths change, so measure the actual downtime. Do not edit the descriptor while a backup is running. `skip` should not be used to acquire live database files.

## Back up

Run these commands from the repository directory:

```bash
# Validate descriptors and access to existing repository configurations.
sudo bash stacks-backup.sh --check

# Optional: initialize missing repositories without taking snapshots.
sudo bash stacks-backup.sh --init

# Validate all enabled stacks, initialize missing repositories, and back up.
sudo bash stacks-backup.sh --backup
```

Choose an operation explicitly; running without one shows help. `--check` does **not** perform a Restic data integrity check. `--backup` initializes missing repositories automatically, so a separate `--init` run is optional.

To process only one stack, add `--stack NAME`. The name identifies an immediate subdirectory of `STACKS_DIR`; keep `STACKS_DIR` pointing at the parent directory. The option works with all three operations, before or after the operation, and can be combined with `--config`:

```bash
sudo bash stacks-backup.sh -c backup.env --stack traefik-proxy --check
sudo bash stacks-backup.sh -c backup.env --stack traefik-proxy --init
sudo bash stacks-backup.sh -c backup.env --stack traefik-proxy --backup
```

Other stacks are not validated, initialized or backed up during these runs. Missing, inaccessible or symlinked selected directories, and missing or invalid `.backup` descriptors, are errors. Use a name, not a filesystem path. Without `--stack`, all enabled immediate subdirectories are processed as before. The selected stack's `docker-stop` policy still applies: use `skip` to back up Traefik configuration while its containers remain active.

Backup diagnostics go to stderr. Structured events are emitted as JSON Lines on stdout at the end of the run:

```bash
sudo bash stacks-backup.sh --backup > backup-run.jsonl
```

Check the command's exit status and diagnostics. Engine diagnostics are retained in the configured private log directory.

## Restore

```bash
# List backed-up stacks and snapshot counts.
sudo bash stacks-restore.sh --list

# List snapshots for one stack.
sudo bash stacks-restore.sh --list demo

# Restore the latest snapshot or a specific snapshot ID.
sudo bash stacks-restore.sh demo --snapshot latest
sudo bash stacks-restore.sh demo --snapshot SNAPSHOT_ID
```

Restores use Restic's `--verify` option and write into a new directory under `RESTORE_DIR`, such as `restore-demo-ID-RANDOM`. Stack contents are placed directly inside that directory. The restore script prints the destination and snapshot ID; it does not start containers or overwrite the original stack. Failed restores retain partial files for inspection.

The listing label `DISPONIBILE` means a snapshot exists in Restic; it does not certify repository integrity or a successful restore.

## Native Restic commands

`run-restic.sh` prepares the same configuration and image, optionally mounts a selected repository and password, then passes a native command directly to Restic. It does not inspect `.backup`, require a source stack directory, or manage application containers. Backup and restore orchestration remain in the specialist scripts.

```bash
sudo bash run-restic.sh help
sudo bash run-restic.sh version
sudo bash run-restic.sh --stack traefik-proxy ls --long latest
sudo bash run-restic.sh -c backup.env --stack traefik-proxy ls --long 18b4ff19
sudo bash run-restic.sh --stack traefik-proxy snapshots
sudo bash run-restic.sh --stack traefik-proxy check --read-data
```

Place `--config`/`-c` and optional `--stack NAME` **before** the native command. Everything from the command onward, including `--help` or `--config`, is passed unchanged to Restic. `--stack` selects a repository under `REPOSITORIES_DIR`. Without it, no repository or password is mounted or passed to Restic: commands like `help` and `version` work without them, while commands requiring a repository report their native error. The wrapper does not select or search repositories automatically. To find available names, list your configured `REPOSITORIES_DIR` on the host (for example, `sudo ls /opt/.backup/repositories`) and use a name with `--stack`. Configuration precedence and automatic image download are the same as in the other scripts. With no arguments or wrapper `--help`, usage is printed without contacting Docker.

The wrapper refuses these commands before preparing Docker:

| Command | Alternative |
| --- | --- |
| `backup` | `stacks-backup.sh --stack NAME --backup` |
| `init` | `stacks-backup.sh --stack NAME --init` |
| `restore` | `stacks-restore.sh NAME --snapshot ID\|latest` |
| `mount` | Unsupported: additional mounts and privileges would be required |
| `self-update` | Configure `RESTIC_IMAGE` instead |

Other command names and options are validated by Restic without spelling corrections. Native stdout and stderr are streamed directly; the wrapper does not append JSONL events or capture native diagnostics in its private log files. Restic's exit status is returned (Docker startup errors return Docker's status). Image/configuration preparation errors return status 2. There is no wrapper execution timeout on the native command; configured Docker/pull timeouts apply only to preparation.

Only the selected repository and password are mounted. File arguments refer to paths **inside the container**, not arbitrary host paths. Repository operations such as `forget`, `prune`, `unlock` and `repair` are not blocked: their normal Restic behavior applies. Native `check` verifies repository integrity, unlike the specialist `stacks-backup.sh --check`, which validates backup configuration and repository access.

## Validation and limits

Check shell syntax and run the simulated lifecycle checks:

```bash
bash -n stacks-backup.sh stacks-restore.sh tests/backup-lifecycle.sh
bash tests/backup-lifecycle.sh
bash tests/json-handling.sh
bash tests/skip-policy.sh
bash tests/stack-selection.sh
bash tests/run-restic.sh
```

The lifecycle checks simulate Docker operations. They cover container state preservation, stop timeout handling, unclean exits, restart retries, initialization order, and recovery after backup failure. They do not establish readiness for production.

Known limits tracked in [TODO.md](TODO.md):

- If stop exceeds `DOCKER_TIMEOUT`, the backup is cancelled while the same stop client is given up to `STOP_RECOVERY_TIMEOUT` additional seconds to finish. Only a successful stop completion permits automatic recovery. An error, lost connection, or expired recovery deadline leaves the outcome uncertain: the script reports container IDs for manual recovery and refuses automatic restart. The daemon may still be processing the request. Field validation is pending.
- SIGKILL, host crashes, or Docker daemon failures may require manual recovery.
- A container returning to `running` does not establish application readiness or correct dependency startup order.
- External processes must not write to included paths or restart containers during a backup.
- Verified restores do not replace periodic full repository integrity checks or recovery rehearsals.

Backups are local. Retention, scheduling, and off-site copies need separate operational setup.

## Field test: stop timeout recovery

Use a disposable stack and a separate configuration file, repository directory, and password. Set `STACKS_DIR` to a directory containing only this test stack. Do not point this test at production stacks.

Example test stack `demo/docker-compose.yml`:

```yaml
services:
  slow:
    image: busybox:1.37
    command: ["sh", "-c", "trap 'sleep 8; exit 0' TERM; while :; do sleep 1; done"]
  idle:
    image: busybox:1.37
    command: ["sleep", "3600"]
```

Its `.backup` file:

```text
docker-stop=true
docker-compose.yml
```

From the test stack directory, create both containers, then start only `slow`:

```bash
docker compose create
docker compose start slow
docker compose ps --all --no-trunc
```

Allow the container a few seconds to install its signal handler. From the script directory, run each scenario with your absolute test configuration path:

```bash
# 1. Normal stop: successful backup and recovery.
sudo env DOCKER_TIMEOUT=15 STOP_RECOVERY_TIMEOUT=20 bash stacks-backup.sh -c /absolute/path/test.env --backup > normal.jsonl
echo $?

# 2. First deadline expires, but stop completes during recovery.
sudo env DOCKER_TIMEOUT=2 STOP_RECOVERY_TIMEOUT=20 bash stacks-backup.sh -c /absolute/path/test.env --backup > recovered.jsonl
echo $?

# 3. Both deadlines expire: manual recovery required.
sudo env DOCKER_TIMEOUT=2 STOP_RECOVERY_TIMEOUT=2 bash stacks-backup.sh -c /absolute/path/test.env --backup > manual.jsonl
echo $?
```

Before each scenario, verify that `slow` is running and `idle` is still created/stopped. Expected results:

| Scenario | Exit status | Backup | Container recovery |
| --- | --- | --- | --- |
| Normal stop | 0 | New snapshot | Same `slow` ID running; `idle` unchanged |
| Stop completes during recovery | Nonzero | No snapshot for this attempt | `stop_completed_after_timeout` event; same `slow` ID restarted; `idle` unchanged |
| Recovery deadline expires | Nonzero | No snapshot for this attempt | `container_recovery_required` event with ID; no automatic restart |

After scenario 3, wait for the delayed stop to finish and inspect the reported ID. Confirm the test container has exited before manually starting it with `docker start CONTAINER_ID`; never use a still-running status alone as proof that the pending stop has finished. If the daemon or connection failed, resolve that uncertainty before restarting.

For debugging, retain the exit status, JSONL output, stderr, referenced sanitized engine log, and `docker compose ps --all --no-trunc` output before and after the attempt. Check snapshot counts with `stacks-restore.sh --list demo` using the same test configuration.
