#!/bin/bash
#
# Test suite for heatstroke.sh
# Tests state management, notification logic, log rotation, and edge cases.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCHDOG="$SCRIPT_DIR/heatstroke.sh"

# Use an isolated test dir so we don't touch real state
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
  else
    fail "$label (expected='$expected', actual='$actual')"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    pass "$label"
  else
    fail "$label (expected to contain '$needle')"
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    fail "$label (should NOT contain '$needle')"
  else
    pass "$label"
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [[ -f "$path" ]]; then
    pass "$label"
  else
    fail "$label (file '$path' does not exist)"
  fi
}

# We need a version of the script that uses our test dirs and a fake ps.
# Create a wrapper that overrides HOME and PATH so the script writes to TEST_DIR
# and uses our mock ps.
setup_test() {
  local test_name="$1"
  echo ""
  echo "--- $test_name ---"

  # Clean test dirs
  rm -rf "$TEST_DIR/home" "$TEST_DIR/bin" "$TEST_DIR/log"
  mkdir -p "$TEST_DIR/home/.local/state" "$TEST_DIR/bin"

  # State/log will end up in $TEST_DIR/home/.local/state/heatstroke/
  STATE_DIR="$TEST_DIR/home/.local/state/heatstroke"
  STATE_FILE="$STATE_DIR/state"
  LOG_FILE="$STATE_DIR/watchdog.log"
}

# Run the watchdog with a mock ps output
# $1 = mock ps output (including header line)
run_watchdog() {
  local mock_ps_output="$1"

  # Create a mock ps that returns our fake data
  cat > "$TEST_DIR/bin/ps" << 'MOCK_PS_HEADER'
#!/bin/bash
MOCK_PS_HEADER
  # Append the output
  echo "cat << 'ENDOFPS'" >> "$TEST_DIR/bin/ps"
  echo "$mock_ps_output" >> "$TEST_DIR/bin/ps"
  echo "ENDOFPS" >> "$TEST_DIR/bin/ps"
  chmod +x "$TEST_DIR/bin/ps"

  # Create a mock terminal-notifier that logs calls
  cat > "$TEST_DIR/bin/terminal-notifier" << 'EOF'
#!/bin/bash
echo "NOTIFICATION: $@" >> "${HOME}/.local/state/heatstroke/notifications.log"
EOF
  chmod +x "$TEST_DIR/bin/terminal-notifier"

  # Run watchdog with overridden HOME and PATH
  HOME="$TEST_DIR/home" PATH="$TEST_DIR/bin:/usr/bin:/bin" bash "$WATCHDOG"
}

get_state() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
  else
    echo ""
  fi
}

get_log() {
  if [[ -f "$LOG_FILE" ]]; then
    cat "$LOG_FILE"
  else
    echo ""
  fi
}

get_notifications() {
  local nf="$TEST_DIR/home/.local/state/heatstroke/notifications.log"
  if [[ -f "$nf" ]]; then
    cat "$nf"
  else
    echo ""
  fi
}


# ============================================================
# TEST 1: No high-CPU processes -> empty state
# ============================================================
setup_test "No high-CPU processes"

run_watchdog "  PID  %CPU COMM
    1   0.0 /sbin/launchd
  500   2.3 /usr/bin/something
  800  10.0 /Applications/Safari.app/Contents/MacOS/Safari"

state=$(get_state)
assert_eq "State is empty" "" "$state"


# ============================================================
# TEST 2: One high-CPU process -> tracked in state with count=1
# ============================================================
setup_test "One high-CPU process appears"

run_watchdog "  PID  %CPU COMM
    1   0.0 /sbin/launchd
12345  95.3 /Applications/MyApp.app/Contents/MacOS/MyApp
  800  10.0 /usr/bin/other"

state=$(get_state)
assert_contains "State tracks PID 12345" "$state" "12345 1 MyApp"


# ============================================================
# TEST 3: Counter increments across runs
# ============================================================
setup_test "Counter increments across consecutive runs"

MOCK_PS="  PID  %CPU COMM
12345  95.3 /Applications/MyApp.app/Contents/MacOS/MyApp"

run_watchdog "$MOCK_PS"
state=$(get_state)
assert_contains "Count=1 after first run" "$state" "12345 1 MyApp"

run_watchdog "$MOCK_PS"
state=$(get_state)
assert_contains "Count=2 after second run" "$state" "12345 2 MyApp"

run_watchdog "$MOCK_PS"
state=$(get_state)
assert_contains "Count=3 after third run" "$state" "12345 3 MyApp"


# ============================================================
# TEST 4: Notification sent at NOTIFY_AFTER threshold (count=3)
# ============================================================
setup_test "Notification at threshold"

MOCK_PS="  PID  %CPU COMM
12345  95.3 /Applications/MyApp.app/Contents/MacOS/MyApp"

run_watchdog "$MOCK_PS"
run_watchdog "$MOCK_PS"

notifs=$(get_notifications)
assert_eq "No notification before threshold" "" "$notifs"

run_watchdog "$MOCK_PS"

notifs=$(get_notifications)
assert_contains "Notification sent at count=3" "$notifs" "NOTIFICATION:"
assert_contains "Notification mentions PID" "$notifs" "12345"

log=$(get_log)
assert_contains "Log has NOTIFY entry" "$log" "NOTIFY:"


# ============================================================
# TEST 5: Re-notification at correct interval
# ============================================================
setup_test "Re-notification interval"

MOCK_PS="  PID  %CPU COMM
12345  95.3 /Applications/MyApp.app/Contents/MacOS/MyApp"

# Run 8 times: notify at 3, re-notify at 8 (3 + 5)
for i in $(seq 1 8); do
  run_watchdog "$MOCK_PS"
done

notifs=$(get_notifications)
notif_count=$(echo "$notifs" | grep -c "NOTIFICATION:" || true)
assert_eq "Two notifications (initial + re-notify)" "2" "$notif_count"

log=$(get_log)
assert_contains "Log has RE-NOTIFY" "$log" "RE-NOTIFY:"


# ============================================================
# TEST 6: Process drops off -> RESOLVED log entry
# ============================================================
setup_test "Process resolved when CPU drops"

MOCK_PS_HOT="  PID  %CPU COMM
12345  95.3 /Applications/MyApp.app/Contents/MacOS/MyApp"

MOCK_PS_COLD="  PID  %CPU COMM
12345   5.0 /Applications/MyApp.app/Contents/MacOS/MyApp"

run_watchdog "$MOCK_PS_HOT"
run_watchdog "$MOCK_PS_HOT"
run_watchdog "$MOCK_PS_HOT"
run_watchdog "$MOCK_PS_COLD"

state=$(get_state)
assert_eq "State cleared after CPU drops below threshold" "" "$state"

log=$(get_log)
assert_contains "RESOLVED logged" "$log" "RESOLVED: MyApp"


# ============================================================
# TEST 7: PID reuse detection resets counter
# ============================================================
setup_test "PID reuse resets counter"

MOCK_PS_A="  PID  %CPU COMM
12345  95.3 /Applications/AppA.app/Contents/MacOS/AppA"

MOCK_PS_B="  PID  %CPU COMM
12345  95.3 /Applications/AppB.app/Contents/MacOS/AppB"

run_watchdog "$MOCK_PS_A"
run_watchdog "$MOCK_PS_A"

state=$(get_state)
assert_contains "AppA at count 2" "$state" "12345 2 AppA"

# Same PID, different name -> counter resets to 1
run_watchdog "$MOCK_PS_B"

state=$(get_state)
assert_contains "AppB at count 1 (reset)" "$state" "12345 1 AppB"


# ============================================================
# TEST 8: Ignored processes are filtered out
# ============================================================
setup_test "Ignored processes filtered"

run_watchdog "  PID  %CPU COMM
    1  99.0 /sbin/launchd
  200  99.0 /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mds
  300  99.0 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
  400  99.0 /Applications/MyApp.app/Contents/MacOS/MyApp"

state=$(get_state)
assert_not_contains "launchd not tracked" "$state" "launchd"
assert_not_contains "mds not tracked" "$state" "mds"
assert_not_contains "Dock not tracked" "$state" "Dock"
assert_contains "MyApp is tracked" "$state" "400 1 MyApp"


# ============================================================
# TEST 9: Multiple hot processes tracked simultaneously
# ============================================================
setup_test "Multiple hot processes"

run_watchdog "  PID  %CPU COMM
  100  95.0 /usr/bin/processA
  200  88.0 /usr/bin/processB
  300  50.0 /usr/bin/cool_process"

state=$(get_state)
assert_contains "processA tracked" "$state" "100 1 processA"
assert_contains "processB tracked" "$state" "200 1 processB"
assert_not_contains "cool_process not tracked (below threshold)" "$state" "cool_process"


# ============================================================
# TEST 10: Empty state file handled correctly
# ============================================================
setup_test "Empty state file"

mkdir -p "$STATE_DIR"
printf '' > "$STATE_FILE"

run_watchdog "  PID  %CPU COMM
12345  95.3 /Applications/MyApp.app/Contents/MacOS/MyApp"

state=$(get_state)
assert_contains "Recovers from empty state" "$state" "12345 1 MyApp"


# ============================================================
# TEST 11: State directory created if missing
# ============================================================
setup_test "State dir created automatically"

# Don't pre-create it — the script should mkdir -p
rm -rf "$TEST_DIR/home/.local"

run_watchdog "  PID  %CPU COMM
12345  95.3 /Applications/MyApp.app/Contents/MacOS/MyApp"

assert_file_exists "State file created" "$STATE_FILE"
state=$(get_state)
assert_contains "State written correctly" "$state" "12345 1 MyApp"


# ============================================================
# TEST 12: Log rotation
# ============================================================
setup_test "Log rotation at 1MB"

mkdir -p "$STATE_DIR"
# Create a >1MB log file
dd if=/dev/zero bs=1024 count=1100 2>/dev/null | tr '\0' 'x' > "$LOG_FILE"
# Add some real lines at the end so tail has something
for i in $(seq 1 600); do
  echo "2026-01-01 00:00:00 line $i" >> "$LOG_FILE"
done

original_size=$(wc -c < "$LOG_FILE" | tr -d ' ')

run_watchdog "  PID  %CPU COMM
    1   0.0 /sbin/launchd"

new_size=$(wc -c < "$LOG_FILE" | tr -d ' ')
if [[ "$new_size" -lt "$original_size" ]]; then
  pass "Log file was rotated (${original_size} -> ${new_size})"
else
  fail "Log file was not rotated (${original_size} -> ${new_size})"
fi

log=$(get_log)
assert_contains "Log rotation noted" "$log" "Log rotated"


# ============================================================
# TEST 13: Name sanitization
# ============================================================
setup_test "Name sanitization strips special chars"

run_watchdog "  PID  %CPU COMM
12345  95.3 /tmp/evil\"name\$here"

# The state should have the sanitized name
state=$(get_state)
# It should be tracked (the process isn't ignored)
assert_contains "Process tracked" "$state" "12345 1"
# The name should NOT contain quotes or dollar signs
assert_not_contains "No quotes in state" "$state" '"'
assert_not_contains "No dollar in state" "$state" '$'


# ============================================================
# TEST 14: CPU exactly at threshold
# ============================================================
setup_test "CPU exactly at threshold"

run_watchdog "  PID  %CPU COMM
12345  80.0 /usr/bin/borderline"

state=$(get_state)
# 80 is NOT less than 80, so it should be tracked
assert_contains "CPU=80 is tracked" "$state" "12345 1 borderline"


# ============================================================
# TEST 15: CPU just below threshold
# ============================================================
setup_test "CPU just below threshold"

run_watchdog "  PID  %CPU COMM
12345  79.9 /usr/bin/borderline"

state=$(get_state)
assert_eq "CPU=79 not tracked" "" "$state"


# ============================================================
# RESULTS
# ============================================================
echo ""
echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
