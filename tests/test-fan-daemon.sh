#!/bin/bash
# Runs the daemon against a fake hwmon tree: no hardware is touched.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON=$REPO/fan-daemon.sh
ROOT=$(mktemp -d)
export BOOST_FILE=$ROOT/run/boost STATE_FILE=$ROOT/run/state.json
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
  mkdir -p "$ROOT/run"
}
start() {
  HWMON_ROOT=$ROOT INTERVAL=1 LOG_EVERY=1 PWM_MIN=80 "$DAEMON" > "$ROOT/log" 2>&1 &
  PID=$!
  sleep 1.5
}
stop() { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=; }
pwm() { cat "$ROOT/hwmon0/pwm2"; }
state() {  # python expression on the parsed state file, e.g. s["fan"]["pwm"]
  python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$STATE_FILE" "$1" 2>/dev/null
}
cpu() { echo "$1" > "$ROOT/hwmon1/temp1_input"; }
check() {  # description actual expected
  if [ "$2" = "$3" ]; then echo "ok   - $1 ($2)"; else echo "FAIL - $1: got $2, expected $3"; fails=$((fails + 1)); fi
}
between() {  # description actual low high
  if [ "$2" -ge "$3" ] && [ "$2" -le "$4" ]; then echo "ok   - $1 ($2)"; else echo "FAIL - $1: got $2, expected $3-$4"; fails=$((fails + 1)); fi
}

setup; start
check "idle at 55 C: straight onto the curve" "$(pwm)" 105
check "state: valid JSON, version 1" "$(state 's["version"]')" 1
check "state: CPU median" "$(state 's["cpu"]["median_mc"]')" 55000
check "state: SSD median" "$(state 's["ssd"]["median_mc"]')" 40000
check "state: fan" "$(state '[s["fan"][k] for k in ("rpm","pwm","target","pwm_min","pwm_max","pwm_enable","stalled")]')" "[3000, 105, 105, 80, 255, 1, False]"
check "state: no boost" "$(state '[s["boost"][k] for k in ("active","pwm","expires")]')" "[False, 0, None]"
between "state: fresh" "$(( $(date +%s) - $(state 's["updated"]') ))" 0 2
check "manual mode" "$(cat "$ROOT/hwmon0/pwm2_enable")" 1
echo 2 > "$ROOT/hwmon0/pwm2_enable"; sleep 1.2
check "back to manual if the chip resets" "$(cat "$ROOT/hwmon0/pwm2_enable")" 1
cpu 75000; sleep 0.6; cpu 55000; sleep 2.5
grep -q "cpu=75C" "$ROOT/log"; check "single spike: it was read" $? 0
check "single spike: ignored" "$(pwm)" 105
check "state: spike in raw, not in median" "$(state '[s["cpu"]["raw_mc"], s["cpu"]["median_mc"]]')" "[55000, 55000]"
cpu 60000; sleep 3.2
check "sustained rise: followed after two readings" "$(pwm)" 130
cpu 92000; sleep 1.2
check "critical raw reading: straight to maximum" "$(pwm)" 255
cpu 50000; sleep 3.2
between "cooling down: ramps down" "$(pwm)" 230 250
stop

setup; echo 68000 > "$ROOT/hwmon2/temp1_input"; start
check "SSD at 68 C: the SSD curve wins" "$(pwm)" 241
stop
setup; rm -r "$ROOT/hwmon2"; start
check "no SSD: null in the state" "$(state '[s["ssd"]["raw_mc"], s["ssd"]["median_mc"]]')" "[None, None]"
check "no SSD: CPU curve only" "$(pwm)" 105
stop

setup; start
mkdir -p "$ROOT/run"
echo "200 $(( $(date +%s) + 100 ))" > "$BOOST_FILE"; sleep 4.5
check "boost: ramps up to the boost floor" "$(pwm)" 200
grep -q "boost: PWM at least 200" "$ROOT/log"; check "boost: logged" $? 0
check "state: boost active with expiry" "$(state '[s["boost"]["active"], s["boost"]["pwm"], s["boost"]["expires"] > s["updated"]]')" "[True, 200, True]"
echo "200 $(( $(date +%s) - 1 ))" > "$BOOST_FILE"; sleep 2.2
between "expired boost: ramps down" "$(pwm)" 180 195
grep -q "boost over" "$ROOT/log"; check "expired boost: logged" $? 0
echo "garbage" > "$BOOST_FILE"; sleep 1.2
grep -q "ERROR" "$ROOT/log"; check "malformed boost file: ignored" $? 1
stop

setup; start
echo 0 > "$ROOT/hwmon0/fan2_input"; sleep 4.5
check "fan stopped: PWM at maximum" "$(pwm)" 255
grep -q "fan stopped" "$ROOT/log"; check "fan stopped: logged" $? 0
check "state: stalled" "$(state 's["fan"]["stalled"]')" True
stop

setup; start
rm "$ROOT/hwmon1/temp1_input"; sleep 1.5
kill -0 "$PID" 2>/dev/null; check "unreadable CPU: daemon exits" $? 1
wait "$PID" 2>/dev/null; check "unreadable CPU: exit code" $? 1
PID=
HWMON_ROOT=$ROOT "$DAEMON" --failsafe > /dev/null
check "failsafe: PWM at maximum" "$(pwm)" 255
check "failsafe: manual mode" "$(cat "$ROOT/hwmon0/pwm2_enable")" 1
[ -e "$STATE_FILE" ]; check "failsafe: state file removed" $? 1

setup
HWMON_ROOT=$ROOT PWM_MIN=abc "$DAEMON" > /dev/null 2>&1; check "invalid configuration: rejected" $? 1
HWMON_ROOT=$ROOT CPU_CRIT_C=80 "$DAEMON" > /dev/null 2>&1; check "critical below maximum: rejected" $? 1

"$REPO/fan-boost" 60 150
read -r p e < "$BOOST_FILE"
check "fan-boost: PWM written" "$p" 150
between "fan-boost: expiry" "$(( e - $(date +%s) ))" 58 60
"$REPO/fan-boost" off
[ -e "$BOOST_FILE" ]; check "fan-boost off: file removed" $? 1
"$REPO/fan-boost" soon > /dev/null 2>&1; check "fan-boost: bad arguments rejected" $? 2
"$REPO/fan-boost" 60 300 > /dev/null 2>&1; check "fan-boost: PWM above 255 rejected" $? 2

FAN_BOOST=$REPO/fan-boost "$REPO/fan-vzdump-hook" job-start
[ -e "$BOOST_FILE" ]; check "hook job-start: boost on" $? 0
FAN_BOOST=$REPO/fan-boost "$REPO/fan-vzdump-hook" backup-end
[ -e "$BOOST_FILE" ]; check "hook other phases: boost unchanged" $? 0
FAN_BOOST=$REPO/fan-boost "$REPO/fan-vzdump-hook" job-end
[ -e "$BOOST_FILE" ]; check "hook job-end: boost off" $? 1
FAN_BOOST=/nonexistent "$REPO/fan-vzdump-hook" job-start; check "hook: exits 0 even when fan-boost fails" $? 0

[ "$fails" -eq 0 ] && echo "all tests passed" || { echo "$fails tests failed"; exit 1; }
