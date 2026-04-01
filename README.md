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
      <td>Samples CPU every 60s<br/>Flags anything above 80%<br/>for 3+ consecutive checks</td>
      <td>Native macOS notification<br/>with process name, PID,<br/>and CPU percentage</td>
      <td>Click the notification<br/>to kill the process.<br/>Re-notifies every 5 min</td>
    </tr>
  </table>
</div>
<br />

System processes (`WindowServer`, `mds`, `launchd`, etc.) are automatically ignored.

## Requirements

- macOS
- [`terminal-notifier`](https://github.com/julienXX/terminal-notifier) for rich click-to-kill notifications

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
| `NOTIFY_AFTER` | `3` | Consecutive checks before first notification (~3 min) |
| `RE_NOTIFY_INTERVAL` | `5` | Re-notify every N checks if still hot (~5 min) |

Then `make restart`.

## Logs

```sh
make log
# ~/.local/state/heatstroke/watchdog.log
```

Auto-rotated at 1MB. Entries include `NOTIFY`, `RE-NOTIFY`, and `RESOLVED` events.
