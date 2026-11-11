# Restics Manager

Bash scripts for local Restic backups of Docker Compose stacks. Each stack opts in through a `.backup` file and gets a separate encrypted Restic repository. Repositories share the password configured for the environment.

**Status: experimental.** See [TODO.md](TODO.md) for validation results and remaining work before production use.

## Requirements

- Linux with Bash 4 or newer, Python 3, GNU coreutils, and `flock`.
- Docker Engine and Docker Compose v2 for stack inspection and container lifecycle operations.
- A local `restic` executable, or the Docker image `restic/restic:0.19.1` already downloaded. The scripts prefer the local executable and do not pull images automatically.
- Root privileges for repository initialization and backups; sufficient permissions for listing and restoring files.

The orchestrator runs directly on the host. The included `docker-compose.yml` describes a Restic service with example host paths; it is not required to launch the orchestrator.

## Setup

Clone the repository and enter its directory:

```bash
git clone https://github.com/msbragi/restics-manager.git
cd restics-manager
```

Create `backup.env` alongside the scripts. Use literal, absolute paths without shell quotes or variable expansion:

```dotenv
BACKUP_ROOT=/opt/restics-manager
STACKS_DIR=/opt/stacks
REPOSITORIES_DIR=/opt/restics-manager/backup-repositories
RESTIC_PASSWORD_FILE=/opt/restics-manager/backup-secrets/restic.password
BACKUP_LOG_DIR=/opt/restics-manager/backup-logs
RESTORE_DIR=/opt/restics-manager/restores
RESTIC_IMAGE=restic/restic:0.19.1
RESTIC_CHECK_TIMEOUT=60
RESTIC_BACKUP_TIMEOUT=3600
DOCKER_TIMEOUT=30
```

Adjust the paths for your machine. Create the stack and repository base directories before running the scripts. Store a nonempty Restic password in the configured password file and restrict its access, for example with directory mode `700` and file mode `600`. Keep a separate, secure copy of this password: it is needed to recover your backups.

Configuration defaults to `backup.env` in the script directory. Set `BACKUP_CONFIG` to select another file. Environment variables override file values. Without configuration, `BACKUP_ROOT` defaults to the script directory; stacks default to `BACKUP_ROOT/stacks`, and the other data directories follow the layout above. Configured paths must not contain symlink components.

`backup.env`, backup secrets, repositories, logs, restores, and JSONL output are excluded by `.gitignore` when stored in the default locations.

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

The scripts expect each stack's Compose file to be named `docker-compose.yml`.

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

`--check` is the default mode. It does **not** perform a Restic data integrity check. `--backup` initializes missing repositories automatically, so a separate `--init` run is optional.

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

## Validation and limits

Check shell syntax and run the simulated lifecycle checks:

```bash
bash -n stacks-backup.sh stacks-restore.sh tests/backup-lifecycle.sh
bash tests/backup-lifecycle.sh
```

The lifecycle checks simulate Docker operations. They cover container state preservation, stop timeout handling, unclean exits, restart retries, initialization order, and recovery after backup failure. They do not establish readiness for production.

Known limits tracked in [TODO.md](TODO.md):

- Recovery after a stop timeout needs further validation; a pending Docker stop may still affect a restarted container.
- SIGKILL, host crashes, or Docker daemon failures may require manual recovery.
- A container returning to `running` does not establish application readiness or correct dependency startup order.
- External processes must not write to included paths or restart containers during a backup.
- Verified restores do not replace periodic full repository integrity checks or recovery rehearsals.

Backups are local. Retention, scheduling, and off-site copies need separate operational setup.
