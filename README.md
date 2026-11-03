# FLS

A small macOS utility that kills whatever is using too much memory, so a leak can't take the whole machine down.

FLS has two parts:

- **The watchdog** (`fls.c`) checks memory every 5 seconds and does the killing. launchd keeps it running.
- **The menu bar app** (`menu.swift`) shows memory use and changes the watchdog's settings. It kills nothing itself, so protection keeps working if the app quits or hangs.

## What gets killed

Each check applies the first rule that matches:

1. **One process over `--limit`:** only that process is killed.
2. **One app over `--limit`:** the whole app is killed.
3. **All apps together over `--total`, if set:** the biggest app is killed.

An app is every process inside one `.app` bundle (Chrome and its helpers), or every process running one executable (all `node` processes).

A kill sends SIGTERM, waits 5 seconds, then sends SIGKILL to anything still running. Each kill is logged and shown as a notification.

Memory is `phys_footprint`, the number in Activity Monitor's Memory column. It includes compressed and swapped memory, which `ps` leaves out.

## Build

Requires the Xcode Command Line Tools (`xcode-select --install`).

```sh
./build.sh
```

This creates the `FLS` command-line tool and `FLS.app`.

## Use the menu bar app

```sh
open FLS.app
```

Choose **Turn On** from the menu to start protection. Choosing a limit also turns it on.

The menu bar shows one of these:

| Title | Meaning |
| --- | --- |
| `59G` | Protection is on, and all apps are using 59 GB |
| `59G` in red | Protection is on, and you're within 10% of a limit |
| Dim `FLS` | Protection is off |

Protection comes back after a restart, but the icon doesn't. To keep the icon, add `FLS.app` under System Settings → General → Login Items.

The menu offers limits of 40, 60 or 80 GB, and total limits of 60 to 90 GB. Use `install.sh` for other values.

## Use the command line

```sh
./FLS --list                         # show the biggest apps now
./FLS --limit 60 --dry-run           # log what would be killed, kill nothing
./install.sh --limit 60 --total 80   # run now and at every login
./uninstall.sh                       # stop and remove from login
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--limit GB` | 80 | Kill a process, or a whole app, above this much memory |
| `--total GB` | off | Also kill the biggest app when all apps together pass this |
| `--interval S` | 5 | Seconds between checks |
| `--dry-run` | | Log what would be killed, but kill nothing |
| `--only TEXT` | | Only look at apps whose path contains `TEXT` |
| `--list` | | Show the biggest apps, then exit |

Don't try a low limit without `--dry-run` or `--only`, because it will kill real apps.

## Choosing a limit

A Mac can run out of memory with no single app near `--limit`, when many mid-size processes add up. Check how yours crashed before picking a number. macOS writes a report for each out-of-memory event to `/Library/Logs/DiagnosticReports/JetsamEvent-*.ips`.

On the 48 GB Mac FLS was built on, 8 out-of-memory events happened at 76–115 GB in total, with no app above about 54 GB. A `--limit` of 60 or 80 wouldn't have triggered on any of them, but `--total 80` would have triggered on 7.

The trade-off is that `--total` kills the biggest app, which may not be the one that's leaking.

## Limits

- It only sees your own processes, so anything run by root or another user is not covered.
- Anything under `/System/Library/CoreServices/`, such as Finder, Dock and loginwindow, is never killed.
- All processes of one executable count as one app, so the app rule can kill every `node` process at once.

## Where things live

| What | Path |
| --- | --- |
| Log | `~/Library/Logs/FLS.log` |
| Running copy of the watchdog | `~/Library/Application Support/FLS/FLS` |
| launchd job and its current settings | `~/Library/LaunchAgents/com.fls.monitor.plist` |

The watchdog runs from a copy because macOS privacy protection can stop launchd running programs from `~/Desktop`.

`uninstall.sh` removes the launchd job and the running copy, and keeps this folder and the log.
