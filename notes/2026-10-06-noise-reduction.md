# Noise reduction (2026-10-06)

Heatstroke sent ~2,800 notifications from Mar 31 to Oct 6, and roughly 97% were noise. It now waits 15 min, alerts once per episode, tolerates one cool reading, and skips processes started by coding agents. Replaying the old log under the new rules gives ~43 alerts, about 1.6 a week.

## Root causes

1. **Re-notify every 5 min**: re-notifies were 74% of all notifications. One 6-hour `zsh` runaway alone sent ~72
2. **3-min wait too short**: Python, Karma Extension, Chrome for Testing, perl, and many daemons ran 3-6 min bursts that ended on their own
3. **No hysteresis**: one reading below 80% reset the counter, so the same PID started a new episode and alerted again 3 min later (239 times)
4. **Per-PID alerts**: 9-12 parallel `yes`/`zsh` processes sent 9-12 notifications in the same second
5. **Exact-match ignore list**: `XProtectRemediatorPirrit`, `spotlightknowledged.updater`, and Cursor's `fileWatcher <hash>` got past it

## Noise vs signal

- **Signal**: something hogging CPU that nobody meant to start and nothing will stop, e.g. a stuck editor extension or language server, a misbehaving app or tab, or a CLI process left behind after its agent or terminal exited
- **Noise**: work someone (the user or an agent) started on purpose that is still attached to its owner, bursts under 15 min, and macOS daemons

The recurring `biome` alerts are signal. Those processes are the Cursor Biome extension's language server (children of Cursor's extension-host helper), with 9 episodes of 15-81 min since Sep 10. The fix belongs in Cursor (disable or upgrade the extension), and heatstroke is right to flag it.

## What changed

| Change | Why |
|---|---|
| `NOTIFY_AFTER` 3 → 15 | Almost all short bursts end on their own; 15 min still catches the biome/Meet-type cases |
| Re-notify removed (`RE_NOTIFY_INTERVAL` gone) | Alerts persist, so closing one is a deliberate "leave it"; reminders only nag. The alert still auto-clears on `RESOLVED` |
| `COOL_READINGS_TOLERATED=1` | Without it, once-per-episode would re-alert after every single dip |
| Agent filter (`AGENT_NAMES`) | A process with a `claude`/`codex`/`cursor-agent` ancestor is deliberate work. Names alone can't tell agent work from a leak, so the check walks parent processes. An orphan reparented to launchd still alerts |
| `NOTIFY` logs the parent chain | Lets the next audit check ancestry, which the old log can't |
| Clicks log `CLICKED: name (PID n)` | There was no click data; future noise rates can use real kills |

The script now takes one `ps -axo pid,ppid,pcpu,comm` snapshot per run, and the state line is `PID COUNT COOL NAME`.

## Skipped on purpose

- **Grouping same-name PIDs**: the multi-PID cases were agent or batch work that the agent filter now removes
- **Prefix matching for the ignore list**: every daemon it targeted runs 3-6 min, under the new 15-min wait

## Open questions

- **Agent-noise share is an estimate**: the old log has no PPID, so the sim dropped agent-tool names as a proxy for ancestry. The new parent-chain logging will confirm it
- **Cursor IDE agent terminals aren't filtered**: they run under Cursor helpers, the same tree as biome. If they cause noise, match Cursor's pty-host helper by name rather than "Cursor" broadly, or biome would be hidden too
