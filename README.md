# 🌡️ Heatstroke

Heatstroke is a macOS background agent that watches for runaway processes and alerts you before they silently drain your battery.

When a process sustains high CPU for ~3 minutes, you get a native notification with a **click-to-kill** action. It auto-dismisses when the process cools down.

---

## How it works

Heatstroke runs every 60 seconds via `launchd`. Each run it:

1. Samples CPU usage across all processes with `ps`
2. Tracks which PIDs have been above **80% CPU** across consecutive checks
3. After **3 consecutive checks** (~3 min), sends a notification
4. Re-notifies every **5 minutes** if the process is still hot
5. Dismisses the notification automatically when CPU drops

System processes (`WindowServer`, `mds`, `launchd`, etc.) are ignored entirely.

---

## Requirements

- macOS
- [`terminal-notifier`](https://github.com/julienXX/terminal-notifier) — for rich click-to-kill notifications (`brew install terminal-notifier`)

---

## Installation

```sh
git clone https://github.com/bowernite/heatstroke.git
cd heatstroke
make install
```

---

## Usage

```
  install      Symlink plist and load the launch agent
  uninstall    Unload and remove the launch agent
  start        Load the launch agent
  stop         Unload the launch agent
  restart      Restart the launch agent
  status       Show whether the agent is running
  log          Tail the log
  test         Run the test suite
```

---

## Configuration

Edit the constants at the top of `heatstroke.sh`:

| Variable | Default | Description |
|---|---|---|
| `CPU_THRESHOLD` | `80` | % CPU to consider "high" |
| `NOTIFY_AFTER` | `3` | Consecutive checks before first notification |
| `RE_NOTIFY_INTERVAL` | `5` | Re-notify every N checks if still hot |

After changing, run `make restart`.

---

## Logs

```sh
make log
# or directly: ~/.local/state/heatstroke/watchdog.log
```

Logs are auto-rotated at 1MB.
