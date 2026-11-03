#!/bin/bash
# Runs the daemon against a fake hwmon tree: no hardware is touched.
set -u
DAEMON="$(cd "$(dirname "$0")/.." && pwd)/fan-daemon.sh"
ROOT=$(mktemp -d)
PID=
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$ROOT"' EXIT
fails=0

setup() {
  rm -rf "${ROOT:?}"/*
  mkdir -p "$ROOT"/hwmon0 "$ROOT"/hwmon1 "$ROOT"/hwmon2
  echo it8771 > "$ROOT/hwmon0/name"
  echo 2 > "$ROOT/hwmon0/pwm2_enable"
  echo 69 > "$ROOT/hwmon0/pwm2"
  echo 3000 > "$ROOT/hwmon0/fan2_input"
  echo coretemp > "$ROOT/hwmon1/name"
  echo 55000 > "$ROOT/hwmon1/temp1_input"
  echo drivetemp > "$ROOT/hwmon2/name"
  echo 40000 > "$ROOT/hwmon2/temp1_input"
}
start() {
  HWMON_ROOT=$ROOT INTERVAL=1 PWM_MIN=80 "$DAEMON" > "$ROOT/log" 2>&1 &
  PID=$!
  sleep 1.5
}
stop() { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; }
pwm() { cat "$ROOT/hwmon0/pwm2"; }
check() {  # description actual expected
  if [ "$2" = "$3" ]; then echo "ok   - $1 ($2)"; else echo "FAIL - $1: got $2, expected $3"; fails=$((fails + 1)); fi
}

setup; start
check "idle at 55 C: straight onto the curve" "$(pwm)" 105
check "manual mode" "$(cat "$ROOT/hwmon0/pwm2_enable")" 1
echo 2 > "$ROOT/hwmon0/pwm2_enable"; sleep 1.2
check "back to manual if the chip resets" "$(cat "$ROOT/hwmon0/pwm2_enable")" 1
echo 56000 > "$ROOT/hwmon1/temp1_input"; sleep 1.2
check "one degree up: rises" "$(pwm)" 110
echo 55000 > "$ROOT/hwmon1/temp1_input"; sleep 2.2
check "one degree down: hysteresis, holds" "$(pwm)" 110
echo 90000 > "$ROOT/hwmon1/temp1_input"; sleep 1.2
check "above CPU_MAX: straight to maximum" "$(pwm)" 255
echo 50000 > "$ROOT/hwmon1/temp1_input"; sleep 1.2
# The exact value depends on how many cycles fall within the wait: it just must not plunge.
[ "$(pwm)" -lt 255 ] && [ "$(pwm)" -ge 235 ]; check "cooling down: ramps down" $? 0
stop

setup; echo 68000 > "$ROOT/hwmon2/temp1_input"; start
check "SSD at 68 C: the SSD curve wins" "$(pwm)" 241
stop

setup; start
echo 0 > "$ROOT/hwmon0/fan2_input"; sleep 4.5
check "fan stopped: PWM at maximum" "$(pwm)" 255
grep -q "fan stopped" "$ROOT/log"; check "fan stopped: logged" $? 0
stop

setup; start
rm "$ROOT/hwmon1/temp1_input"; sleep 1.5
kill -0 "$PID" 2>/dev/null; check "unreadable CPU: daemon exits" $? 1
wait "$PID" 2>/dev/null; check "unreadable CPU: exit code" $? 1
HWMON_ROOT=$ROOT "$DAEMON" --failsafe > /dev/null
check "failsafe: PWM at maximum" "$(pwm)" 255
check "failsafe: manual mode" "$(cat "$ROOT/hwmon0/pwm2_enable")" 1

setup
HWMON_ROOT=$ROOT PWM_MIN=abc "$DAEMON" > /dev/null 2>&1; check "invalid configuration: rejected" $? 1
PID=

[ "$fails" -eq 0 ] && echo "all tests passed" || { echo "$fails tests failed"; exit 1; }
