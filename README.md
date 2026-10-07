<div align="center">
  <h1>🌡️ Heatstroke</h1>
  <p>A macOS background agent that catches runaway processes before they drain your battery</p>
</div>

<hr />

Runaway processes silently pegging your CPU at 100% can drain your battery in no time — and you'll never notice with Activity Monitor closed.

Heatstroke runs quietly in the background, and when a process has been running too hot for too long, you get a native macOS notification with a **click-to-kill** action. When the process cools down, the notification auto-dismisses.

<br />
<div align="center">
  <table>
    <tr>
      <th>🔍 Detect</th>
      <th>🔔 Notify</th>
      <th>💀 Kill</th>
    </tr>
    <tr>
      <td>Samples CPU every 60s<br/>Flags anything above 80%<br/>for ~15 min straight</td>
      <td>One native macOS notification<br/>per episode, with process<br/>name, PID, and CPU percentage</td>
      <td>Click the notification<br/>to kill the process</td>
    </tr>
  </table>
</div>
<br />

System processes (`WindowServer`, `mds`, `launchd`, etc.) are automatically ignored, as is anything started by a coding agent (`claude`, `codex`, `cursor-agent`). A process an agent leaves behind after it exits still alerts.

## Requirements

- macOS
- [`terminal-notifier`](https://github.com/julienXX/terminal-notifier) (optional, recommended) — enables rich click-to-kill notifications. Without it, Heatstroke falls back to basic macOS notifications via `osascript` (no click-to-kill).

  ```sh
  brew install terminal-notifier
  ```

## Installation

```sh
git clone https://github.com/bowernite/heatstroke.git
cd heatstroke
make install
```

That's it. It runs at login and checks every 60 seconds.

`make install` builds a custom `Heatstroke.app` (a rebranded `terminal-notifier` with a 🌡️ icon) and installs it to `~/Applications`, so notifications show up as "Heatstroke" with their own icon in Notification Center.

## Commands

Run `make` to see all available commands:

```
  app          Build the stub Heatstroke.app (icon + bundle ID for notifications)
  install      Build app, install, and load the launch agent
  uninstall    Unload and remove the launch agent and app
  start        Load the launch agent
  stop         Unload the launch agent
  restart      Restart the launch agent
  status       Show whether the agent is running
  log          Tail the log
  test         Run the test suite
```

## Configuration

Edit the top of [`heatstroke.sh`](heatstroke.sh):

| Variable | Default | Description |
|---|---|---|
| `CPU_THRESHOLD` | `80` | % CPU to consider "high" |
| `NOTIFY_AFTER` | `15` | Hot checks before the episode's one notification (~15 min) |
| `COOL_READINGS_TOLERATED` | `1` | Cool checks in a row that don't end an episode |

Then `make restart`.

## Logs

```sh
make log
# ~/.local/state/heatstroke/watchdog.log
```

Auto-rotated at 1MB. Entries include `NOTIFY` (with the process's parent chain), `RESOLVED`, and `CLICKED` events.
