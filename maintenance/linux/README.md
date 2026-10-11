# Linux Maintenance Script

`maintain.sh` is a confirmation-gated maintenance script for Ubuntu on WSL2. It reclaims disk space from package-manager caches, developer-tool caches, Docker build cache, and old archived system logs.

## Quick start

Preview every available action without changing the system:

```bash
bash ~/scripts/maintenance/linux/maintain.sh
```

Run maintenance interactively:

```bash
bash ~/scripts/maintenance/linux/maintain.sh --apply
```

In apply mode, type `yes` for only the actions you want to run. Press Enter for an action to skip it.

Show the built-in help:

```bash
bash ~/scripts/maintenance/linux/maintain.sh --help
```

## What it cleans

| Module | Cleanup action |
| --- | --- |
| APT | Unused dependency packages and downloaded package archives |
| npm | Downloaded npm package cache |
| pnpm | Unused pnpm store entries, when pnpm is installed |
| pip | Downloaded packages and wheel cache for `/usr/bin/python3` |
| Go | Build/test cache and downloaded module cache, when Go is installed |
| Docker | Unused build cache only |
| Journal | Archives older than 7 days, then older archives until archived journal usage is at most 200 MB |

## What it preserves

The script does not delete project directories, `node_modules`, Python virtual environments, Docker images, Docker containers, or Docker volumes.

Cache cleanup can make the next package install or build slower because files may need to download or rebuild again. APT `autoremove` can remove packages that APT considers unused, so always read its simulated list and its final prompt before approving it.

## Safety behavior

- Dry-run is the default and does not execute cleanup commands.
- Apply mode asks separately for every cleanup action.
- The script must run as your normal user, not as root.
- Commands that need elevated permission use `sudo` only after you approve their action.
- A command failure stops the script and records the error in its log.
- Tools that are not installed or unavailable are skipped.

## Logs and space report

Each run writes a timestamped log under:

```text
~/.local/state/maintenance/
```

The script shows disk usage before and after maintenance, then reports the net change on the Linux root filesystem. Docker Desktop storage can live outside that filesystem, so Docker cleanup may not appear in this number.

## Validate changes to the script

```bash
bash -n ~/scripts/maintenance/linux/maintain.sh
bash ~/scripts/maintenance/linux/maintain.sh --dry-run
```

`bash -n` checks Bash syntax. The dry-run shows every planned action without deleting cache files or removing packages.
