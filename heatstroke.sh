#!/bin/bash
#
# Heatstroke — detects runaway processes and sends macOS notifications.
#
# Runs every 60s via launchd. Tracks which PIDs sustain high CPU across
# consecutive checks. Sends a notification (with click-to-kill) when a
# process has been hot for NOTIFY_AFTER consecutive checks, once per episode.
#
# Compatible with macOS default bash 3.2 (no associative arrays).

set -euo pipefail

# --- Config ---
CPU_THRESHOLD=80        # % CPU (ps decaying average) to consider "high"
NOTIFY_AFTER=15         # hot checks before the episode's one notification (~15 min)
COOL_READINGS_TOLERATED=1  # cool checks in a row that don't end an episode
PROC_COUNT_WARN=${HEATSTROKE_PROC_COUNT_WARN:-2500}  # total processes at which each check logs a PROCS line (normal is ~1000-1500)
# Use per-user state dir to avoid symlink attacks in world-writable /tmp
STATE_DIR="${HOME}/.local/state/heatstroke"
mkdir -p "$STATE_DIR"
STATE_FILE="${STATE_DIR}/state"
LOG_FILE="${STATE_DIR}/watchdog.log"

# System processes that routinely spike and should be ignored entirely.
IGNORE_LIST="
# Core OS / window server
kernel_task
WindowServer
launchd
loginwindow
Dock
Finder
SystemUIServer
cfprefsd
opendirectoryd
fseventsd
hidd
powerd
diskarbitrationd
configd
syslogd
notifyd
UserEventAgent
securityd
coreaudiod
corebrightnessd
watchdogd
logd
runningboardd
launchservicesd

# Spotlight / indexing — spike during re-index, after OS updates, on new drives
mds
mds_stores
mdworker_shared
mdworker
corespotlightd
spotlightknowledged

# Photos / media analysis — spike for hours during large imports or after OS upgrades
# Note: mediaanalysisd has a history of Apple bugs that keep it pegged for days;
# if duration-aware alerting is ever added, it would be a good candidate to revisit.
mediaanalysisd
photoanalysisd
photolibraryd
cloudphotod

# iCloud / sync — spike after returning from offline, on large iCloud libraries
bird
cloudd
nsurlsessiond
nsurlstoraged
accountsd

# Software updates / installation — spike during download, staging, and install
softwareupdated
installd
mobileassetd
idleassetsd
storeaccountd

# Security / Gatekeeper / XProtect — run on schedule or on every new app launch
XProtectService
XProtectRemediator
syspolicyd
amfid
secd

# Siri / speech / on-device ML — spike on Siri use, dictation, and model updates
assistantd
corespeechd
suggestd
triald
intelligenceplatformd
neuralengined

# Network / discovery
bluetoothd
airportd
mDNSResponder
networkd
netbiosd
trustd

# Time Machine / backup — run hourly, heavy on first backup
backupd
backupd-helper

# Video conferencing — pegs CPU during calls (video encode/decode, virtual
# backgrounds, screen share). Expected and non-actionable; you won't kill it
# mid-meeting. A genuinely-stuck Zoom won't alert — see notes for the tradeoff.
zoom.us
aomhost
CptHost
caphost

# Other system services
symptomsd
thermalmonitord
locationd
rapportd
distnoted
sharingd
diskimagesiod
sandboxd
revisiond
oahd
"

# Coding agents. Their descendants are deliberate work and never alert; a runaway left
# behind when the agent exits gets reparented to launchd, so it alerts as usual.
AGENT_NAMES="
claude
codex
cursor-agent
"

# --- Helpers ---

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

is_ignored() {
  echo "$IGNORE_LIST" | grep -qxF "$1"
}

# Prints "PID NAME" for each ancestor of a PID in the process snapshot, nearest first
ancestors_of() {
  echo "$process_snapshot" | awk -v target="$1" '
    NR > 1 {
      comm = $0
      sub(/^ *[0-9]+ +[0-9]+ +[0-9.]+ +/, "", comm)
      sub(/.*\//, "", comm)
      parent[$1] = $2
      name[$1] = comm
    }
    END {
      pid = parent[target]
      while (pid + 0 > 0 && !(pid in seen)) {
        seen[pid] = 1
        print pid, name[pid]
        pid = parent[pid]
      }
    }'
}

# e.g. "Cursor Helper (Plugin)(961) < Cursor(960) < launchd(1)"
parent_chain() {
  ancestors_of "$1" | awk '{ pid = $1; $1 = ""; sub(/^ /, ""); printf "%s%s(%s)", (NR > 1 ? " < " : ""), $0, pid }'
}

started_by_agent() {
  local ancestor
  while read -r _ ancestor; do
    [[ -n "$ancestor" ]] && echo "$AGENT_NAMES" | grep -qxF "$ancestor" && return 0
  done <<< "$(ancestors_of "$1")"
  return 1
}

send_notification() {
  local pid="$1" name="$2" cpu="$3" duration_min="$4"

  # Name is already sanitized at collection time (alphanumeric, dash, underscore, dot, space only)
  # Verify process name still matches before killing to guard against PID reuse
  local click_action="bash -c 'echo \"\$(date +%F\\ %T) CLICKED: ${name} (PID ${pid})\" >> \"${LOG_FILE}\"; cur=\$(ps -p ${pid} -o comm= 2>/dev/null); [[ \"\${cur##*/}\" == \"${name}\" ]] && kill ${pid}'"

  # Use our bundled Heatstroke.app (a rebranded terminal-notifier) so
  # notifications show the custom icon and "Heatstroke" app name.
  local notifier="${HOME}/Applications/Heatstroke.app/Contents/MacOS/terminal-notifier"
  if [[ -x "$notifier" ]]; then
    "$notifier" \
      -title "Heatstroke" \
      -subtitle "${name} (PID ${pid}) — ${cpu}% CPU" \
      -message "High CPU for ~${duration_min} min. Click to kill." \
      -execute "$click_action" \
      -group "heatstroke-${pid}" \
      -sound default \
      </dev/null 2>/dev/null || true
  elif command -v terminal-notifier &>/dev/null; then
    terminal-notifier \
      -title "Heatstroke" \
      -subtitle "${name} (PID ${pid}) — ${cpu}% CPU" \
      -message "High CPU for ~${duration_min} min. Click to kill." \
      -execute "$click_action" \
      -group "heatstroke-${pid}" \
      -sound default \
      </dev/null 2>/dev/null || true
  else
    osascript -e "display notification \"${name} (PID ${pid}) at ${cpu}% for ~${duration_min} min\" with title \"Heatstroke\"" 2>/dev/null || true
  fi
}

# Lookup a value from state lines. Usage: state_lookup "$lines" "$pid" "field"
# State line format: PID COUNT COOL NAME (COUNT = hot readings this episode, COOL = cool readings in a row)
state_lookup() {
  local lines="$1" pid="$2" field="$3"
  local line
  line=$(echo "$lines" | grep "^${pid} " | head -1) || true
  if [[ -z "$line" ]]; then
    echo ""
    return
  fi
  case "$field" in
    count) echo "$line" | awk '{print $2}' ;;
    cool)  echo "$line" | awk '{print $3}' ;;
    name)  echo "$line" | awk '{$1=""; $2=""; $3=""; print}' | sed 's/^ *//' ;;
  esac
}

append_state() {
  if [[ -z "$new_state" ]]; then
    new_state="$1"
  else
    new_state="${new_state}
$1"
  fi
}

is_number() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

# --- Read previous state ---
prev_state=""
if [[ -f "$STATE_FILE" ]]; then
  prev_state=$(cat "$STATE_FILE")
fi

# --- Get current high-CPU processes ---
process_snapshot=$(ps -axo pid,ppid,pcpu,comm 2>/dev/null) || true

# Collect into a newline-delimited string: "PID CPU NAME"
hot_processes=""

while read -r pid ppid cpu comm; do
  [[ -z "$pid" || "$pid" == "PID" ]] && continue

  # Strip decimal from cpu (e.g., "95.3" -> "95")
  cpu_int="${cpu%.*}"
  [[ -z "$cpu_int" ]] && continue
  [[ "$cpu_int" -lt "$CPU_THRESHOLD" ]] 2>/dev/null && continue

  # Extract short name from full path, sanitize to prevent injection
  name="${comm##*/}"
  name=$(echo "$name" | tr -cd '[:alnum:] ._-')
  [[ -z "$name" ]] && continue

  is_ignored "$name" && continue
  started_by_agent "$pid" && continue

  if [[ -z "$hot_processes" ]]; then
    hot_processes="${pid} ${cpu} ${name}"
  else
    hot_processes="${hot_processes}
${pid} ${cpu} ${name}"
  fi
done <<< "$process_snapshot"

# --- Build new state and act ---
new_state=""

if [[ -n "$hot_processes" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pid=$(echo "$line" | awk '{print $1}')
    cpu=$(echo "$line" | awk '{print $2}')
    name=$(echo "$line" | awk '{$1=""; $2=""; print}' | sed 's/^ *//')

    prev_count=$(state_lookup "$prev_state" "$pid" "count")
    prev_name=$(state_lookup "$prev_state" "$pid" "name")

    # Default to 0 if no previous entry or if state file is corrupted
    is_number "$prev_count" || prev_count=0

    # If PID was reused by a different process, reset counter
    if [[ -n "$prev_name" && "$prev_name" != "$name" ]]; then
      prev_count=0
    fi

    count=$((prev_count + 1))
    append_state "${pid} ${count} 0 ${name}"

    if [[ "$count" -eq "$NOTIFY_AFTER" ]]; then
      log "NOTIFY: ${name} (PID ${pid}) at ${cpu}% CPU for ~${count} min; parents: $(parent_chain "$pid")"
      send_notification "$pid" "$name" "$cpu" "$count"
    fi
  done <<< "$hot_processes"
fi

# Tracked processes that are cool now: keep them through a short dip, then resolve
if [[ -n "$prev_state" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pid=$(echo "$line" | awk '{print $1}')

    if [[ -n "$hot_processes" ]] && echo "$hot_processes" | grep -q "^${pid} "; then
      continue
    fi

    prev_count=$(state_lookup "$line" "$pid" "count")
    prev_cool=$(state_lookup "$line" "$pid" "cool")
    prev_name=$(state_lookup "$line" "$pid" "name")
    is_number "$prev_count" || prev_count=0
    is_number "$prev_cool" || prev_cool=0

    cool=$((prev_cool + 1))
    if [[ "$cool" -le "$COOL_READINGS_TOLERATED" ]]; then
      append_state "${pid} ${prev_count} ${cool} ${prev_name}"
      continue
    fi

    if [[ "$prev_count" -ge "$NOTIFY_AFTER" ]]; then
      log "RESOLVED: ${prev_name} (PID ${pid}) dropped below threshold after ~${prev_count} min"
      # </dev/null: terminal-notifier posts piped stdin (here, the loop's remaining state lines) as a notification
      notifier="${HOME}/Applications/Heatstroke.app/Contents/MacOS/terminal-notifier"
      if [[ -x "$notifier" ]]; then
        "$notifier" -remove "heatstroke-${pid}" </dev/null 2>/dev/null || true
      elif command -v terminal-notifier &>/dev/null; then
        terminal-notifier -remove "heatstroke-${pid}" </dev/null 2>/dev/null || true
      fi
    fi
  done <<< "$prev_state"
fi

# --- Process-count spikes ---
# A fork loop starves the whole user (every fork then fails with EAGAIN) long before any one process runs hot,
# so record the culprit while it's still running: the busiest parent and busiest command.
proc_total=$(echo "$process_snapshot" | awk 'NR > 1' | wc -l | tr -d ' ')
if [[ "$proc_total" -ge "$PROC_COUNT_WARN" ]]; then
  proc_limit=$(sysctl -n kern.maxprocperuid 2>/dev/null || echo "?")
  proc_top=$(echo "$process_snapshot" | awk '
    NR > 1 {
      comm = $0
      sub(/^ *[0-9]+ +[0-9]+ +[0-9.]+ +/, "", comm)
      sub(/.*\//, "", comm)
      name[$1] = comm
      kids[$2]++
      same[comm]++
    }
    END {
      for (p in kids) if (kids[p] > kmax) { kmax = kids[p]; kp = p }
      for (c in same) if (same[c] > smax) { smax = same[c]; sc = c }
      printf "busiest parent %s(%s) has %d children; most common command %s x%d", name[kp], kp, kmax, sc, smax
    }')
  log "PROCS: ${proc_total} running (per-user limit ${proc_limit}); ${proc_top}"
fi

# --- Write new state (atomic) ---
# Use printf to avoid writing a trailing newline when state is empty
printf '%s' "$new_state" > "${STATE_FILE}.tmp"
mv "${STATE_FILE}.tmp" "$STATE_FILE"

# --- Log rotation: keep under 1MB ---
if [[ -f "$LOG_FILE" ]]; then
  # wc -c is portable across GNU/BSD stat differences
  log_size=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
  if [[ "$log_size" -gt 1048576 ]]; then
    tail -500 "$LOG_FILE" > "${LOG_FILE}.tmp"
    mv "${LOG_FILE}.tmp" "$LOG_FILE"
    log "Log rotated"
  fi
fi
