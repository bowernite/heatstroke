#!/bin/bash
#
# Heatstroke — detects runaway processes and sends macOS notifications.
#
# Runs every 60s via launchd. Tracks which PIDs sustain high CPU across
# consecutive checks. Sends a notification (with click-to-kill) when a
# process has been hot for NOTIFY_AFTER consecutive checks. Re-notifies
# every RE_NOTIFY_INTERVAL checks so it doesn't get buried.
#
# Compatible with macOS default bash 3.2 (no associative arrays).

set -euo pipefail

# --- Config ---
CPU_THRESHOLD=80        # % CPU (ps decaying average) to consider "high"
NOTIFY_AFTER=3          # consecutive checks before first notification (~3 min)
RE_NOTIFY_INTERVAL=5    # re-notify every N checks if still high (~5 min)
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

# --- Helpers ---

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

is_ignored() {
  echo "$IGNORE_LIST" | grep -qxF "$1"
}

send_notification() {
  local pid="$1" name="$2" cpu="$3" duration_min="$4"

  # Name is already sanitized at collection time (alphanumeric, dash, underscore, dot, space only)
  # Use our bundled Heatstroke.app (a rebranded terminal-notifier) so
  # notifications show the custom icon and "Heatstroke" app name.
  local notifier="${HOME}/Applications/Heatstroke.app/Contents/MacOS/terminal-notifier"
  if [[ -x "$notifier" ]]; then
    # Verify process name still matches before killing to guard against PID reuse
    "$notifier" \
      -title "Heatstroke" \
      -subtitle "${name} (PID ${pid}) — ${cpu}% CPU" \
      -message "High CPU for ~${duration_min} min. Click to kill." \
      -execute "bash -c 'cur=\$(ps -p ${pid} -o comm= 2>/dev/null); [[ \"\${cur##*/}\" == \"${name}\" ]] && kill ${pid}'" \
      -group "heatstroke-${pid}" \
      -sound default \
      2>/dev/null || true
  elif command -v terminal-notifier &>/dev/null; then
    terminal-notifier \
      -title "Heatstroke" \
      -subtitle "${name} (PID ${pid}) — ${cpu}% CPU" \
      -message "High CPU for ~${duration_min} min. Click to kill." \
      -execute "bash -c 'cur=\$(ps -p ${pid} -o comm= 2>/dev/null); [[ \"\${cur##*/}\" == \"${name}\" ]] && kill ${pid}'" \
      -group "heatstroke-${pid}" \
      -sound default \
      2>/dev/null || true
  else
    osascript -e "display notification \"${name} (PID ${pid}) at ${cpu}% for ~${duration_min} min\" with title \"Heatstroke\"" 2>/dev/null || true
  fi
}

# Lookup a value from state lines. Usage: state_lookup "$lines" "$pid" "field"
# State line format: PID COUNT NAME
# field: "count" returns field 2, "name" returns field 3+
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
    name)  echo "$line" | awk '{$1=""; $2=""; print}' | sed 's/^ *//' ;;
  esac
}

# --- Read previous state ---
prev_state=""
if [[ -f "$STATE_FILE" ]]; then
  prev_state=$(cat "$STATE_FILE")
fi

# --- Get current high-CPU processes ---
# Collect into a newline-delimited string: "PID CPU NAME"
hot_processes=""

while read -r pid cpu comm; do
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

  if [[ -z "$hot_processes" ]]; then
    hot_processes="${pid} ${cpu} ${name}"
  else
    hot_processes="${hot_processes}
${pid} ${cpu} ${name}"
  fi
done < <(ps -eo pid,pcpu,comm 2>/dev/null)

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
    if [[ -z "$prev_count" ]] || ! [[ "$prev_count" =~ ^[0-9]+$ ]]; then
      prev_count=0
    fi

    # If PID was reused by a different process, reset counter
    if [[ -n "$prev_name" && "$prev_name" != "$name" ]]; then
      prev_count=0
    fi

    count=$((prev_count + 1))

    if [[ -z "$new_state" ]]; then
      new_state="${pid} ${count} ${name}"
    else
      new_state="${new_state}
${pid} ${count} ${name}"
    fi

    if [[ "$count" -eq "$NOTIFY_AFTER" ]]; then
      log "NOTIFY: ${name} (PID ${pid}) at ${cpu}% CPU for ~${count} min"
      send_notification "$pid" "$name" "$cpu" "$count"
    elif [[ "$count" -gt "$NOTIFY_AFTER" ]]; then
      since_first=$(( count - NOTIFY_AFTER ))
      if [[ $(( since_first % RE_NOTIFY_INTERVAL )) -eq 0 ]]; then
        log "RE-NOTIFY: ${name} (PID ${pid}) at ${cpu}% CPU for ~${count} min"
        send_notification "$pid" "$name" "$cpu" "$count"
      fi
    fi
  done <<< "$hot_processes"
fi

# Log when a tracked process drops off
if [[ -n "$prev_state" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pid=$(echo "$line" | awk '{print $1}')
    prev_count=$(echo "$line" | awk '{print $2}')
    prev_name=$(echo "$line" | awk '{$1=""; $2=""; print}' | sed 's/^ *//')

    # Check if this PID is still in hot_processes
    still_hot=""
    if [[ -n "$hot_processes" ]]; then
      still_hot=$(echo "$hot_processes" | grep "^${pid} " || true)
    fi

    if [[ -z "$still_hot" && "$prev_count" -ge "$NOTIFY_AFTER" ]]; then
      log "RESOLVED: ${prev_name} (PID ${pid}) dropped below threshold after ~${prev_count} min"
      notifier="${HOME}/Applications/Heatstroke.app/Contents/MacOS/terminal-notifier"
      if [[ -x "$notifier" ]]; then
        "$notifier" -remove "heatstroke-${pid}" 2>/dev/null || true
      elif command -v terminal-notifier &>/dev/null; then
        terminal-notifier -remove "heatstroke-${pid}" 2>/dev/null || true
      fi
    fi
  done <<< "$prev_state"
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
