# How `maintain.sh` Works

## Purpose

The script is designed for an Ubuntu WSL2 development environment that accumulates package downloads, build artifacts, and journal logs. It focuses on reclaiming disposable cache space while leaving active development projects and Docker data intact.

## Run modes

Without arguments, the script uses dry-run mode. It detects available tools, shows the APT autoremove simulation, displays journal usage, and prints each cleanup command as a preview. It never runs a cleanup command in this mode.

`--apply` enables the cleanup actions, but does not make the script unattended. Every action requires an interactive confirmation. Only the exact answer `yes` starts an action; any other response skips it.

## Startup checks

At startup, the script:

1. Rejects execution as root.
2. Creates a private log file with permissions restricted by `umask 077`.
3. Detects whether the Linux kernel appears to be WSL2.
4. Captures Linux root filesystem usage before maintenance.

The WSL2 detection is informational. It records the environment but does not prevent the script from running on another Linux system.

## Modules

### APT

The script first runs `apt-get --simulate autoremove`, so you can inspect what APT currently considers unused. In apply mode, it separately offers:

- `sudo apt-get autoremove`, without `--purge`, so removed packages retain their configuration files.
- `sudo apt-get clean`, which removes downloaded `.deb` archives from APT's cache.

No package upgrade is performed.

### Node.js: npm and pnpm

If available, `npm cache clean --force` clears npm's shared download cache. If pnpm is available, `pnpm store prune` removes unused content from its shared store. Neither command targets project `node_modules` directories.

### Python: pip

The script intentionally calls `/usr/bin/python3 -m pip cache purge`, even when a virtual environment is active. This avoids selecting the virtual environment interpreter and targets the current user's pip cache. It does not uninstall Python packages or remove virtual environments.

### Go

When `go` is installed, the script offers two independent actions:

- `go clean -cache -testcache` removes compiled build results and cached test results.
- `go clean -modcache` removes downloaded Go modules.

Go source projects and installed executables are not targeted.

### Docker

Docker maintenance is limited to:

```bash
docker builder prune --all --force
```

This removes unused Docker build cache. It does not run `docker system prune`, and therefore does not prune images, containers, networks, or volumes. In apply mode, `docker system df` is displayed before the action to confirm the daemon can be reached and show Docker storage use.

With Docker Desktop, the action applies to the Docker endpoint selected by your current Docker context. Docker Desktop's storage may be managed separately from the Ubuntu root filesystem.

### System journal

When systemd is running, the script shows current journal usage. In apply mode it separately offers:

1. `sudo journalctl --rotate`, which rotates active journal files into archives.
2. `sudo journalctl --vacuum-time=7d --vacuum-size=200M`, which removes archived journal files older than seven days and then removes additional oldest archives until archived journal use is at most 200 MB.

Active journal files are not removed. Because the size rule can remove archived files that are newer than seven days, read the confirmation prompt carefully.

## Status and logging

Every cleanup action is classified as one of the following:

| Status | Meaning |
| --- | --- |
| `[PREVIEW]` | Dry-run displayed the command without running it |
| `[SKIPPED]` | You declined the confirmation or no interactive terminal was available |
| `[RUNNING]` | The approved command has started |
| `[DONE]` | The command completed successfully |
| `[FAILED]` | The command failed; the script stops and the log includes details |

At the end of a successful run, the action summary counts previews, completed actions, declined actions, and failures. The final disk calculation measures the net change in the Linux `/` filesystem, not all Windows or Docker Desktop storage.

## Recommended routine

Run a preview first:

```bash
bash ~/scripts/maintenance/linux/maintain.sh --dry-run
```

Review the planned actions. Then, when you want to reclaim cache space, run:

```bash
bash ~/scripts/maintenance/linux/maintain.sh --apply
```

Approve only the modules you want. The detailed log path is printed near the beginning and end of every run.
