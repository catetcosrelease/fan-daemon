#!/bin/bash
# Dynamic fan control for Gigabyte BRIX mini PCs (IT8771E chip).
# Each source (CPU, SSD) has its own curve: the highest PWM wins.
# The chip's automatic curve gets stuck instead of recalculating continuously,
# so the PWM is driven directly from software.
#
# Any serious fault makes the daemon exit with an error: ExecStopPost sets the
# fan to full speed and systemd retries after RestartSec.
set -u

HWMON_ROOT=${HWMON_ROOT:-/sys/class/hwmon}
FAN_CHIP=${FAN_CHIP:-it8771}
PWM_CHANNEL=${PWM_CHANNEL:-2}
CPU_MIN_C=${CPU_MIN_C:-50}     # at or below this temperature: PWM_MIN
CPU_MAX_C=${CPU_MAX_C:-85}     # at or above this temperature: PWM_MAX
SSD_MIN_C=${SSD_MIN_C:-45}
SSD_MAX_C=${SSD_MAX_C:-70}
PWM_MIN=${PWM_MIN:-80}
PWM_MAX=${PWM_MAX:-255}
STEP_UP=${STEP_UP:-30}         # maximum PWM change per cycle, going up
STEP_DOWN=${STEP_DOWN:-5}      # same, going down
HYSTERESIS=${HYSTERESIS:-8}    # only go down if the target is at least this far below
INTERVAL=${INTERVAL:-10}       # seconds between recalculations
LOG_EVERY=${LOG_EVERY:-60}     # cycles between status lines in the journal
STALL_CYCLES=${STALL_CYCLES:-3}  # cycles at 0 RPM before the fan counts as stopped

fatal() {
  echo "ERROR: $*" >&2
  exit 1
}

# The read helpers leave the value in REPLY: no forks on every cycle.
find_hwmon() {
  local d n
  for d in "$HWMON_ROOT"/hwmon*; do
    { IFS= read -r n < "$d/name"; } 2>/dev/null && [ "$n" = "$1" ] && { REPLY=$d; return 0; }
  done
  return 1
}

read_int() {
  { IFS= read -r REPLY < "$1"; } 2>/dev/null && [[ $REPLY =~ ^-?[0-9]+$ ]]
}

# Highest temperature among all drivetemp sensors (0 if none responds).
# The list is reread on every cycle: the module can appear after startup.
read_ssd() {
  local d n max=0
  for d in "$HWMON_ROOT"/hwmon*; do
    { IFS= read -r n < "$d/name"; } 2>/dev/null && [ "$n" = drivetemp ] || continue
    read_int "$d/temp1_input" && [ "$REPLY" -gt "$max" ] && max=$REPLY
  done
  REPLY=$max
}

curve() {  # temperature(mC) min(C) max(C)
  local t=$1 lo=$(( $2 * 1000 )) hi=$(( $3 * 1000 ))
  if [ "$t" -le "$lo" ]; then
    REPLY=$PWM_MIN
  elif [ "$t" -ge "$hi" ]; then
    REPLY=$PWM_MAX
  else
    REPLY=$(( PWM_MIN + (t - lo) * (PWM_MAX - PWM_MIN) / (hi - lo) ))
  fi
}

failsafe() {
  find_hwmon "$FAN_CHIP" || fatal "$FAN_CHIP not found: cannot force the fan"
  echo 1 > "$REPLY/pwm${PWM_CHANNEL}_enable"
  echo 255 > "$REPLY/pwm${PWM_CHANNEL}"
  echo "failsafe: fan at full speed"
}

if [ "${1:-}" = "--failsafe" ]; then
  failsafe
  exit $?
fi

for v in PWM_CHANNEL CPU_MIN_C CPU_MAX_C SSD_MIN_C SSD_MAX_C PWM_MIN PWM_MAX \
         STEP_UP STEP_DOWN HYSTERESIS INTERVAL LOG_EVERY STALL_CYCLES; do
  [[ ${!v} =~ ^[0-9]+$ ]] || fatal "invalid configuration: $v=${!v}"
done
[ "$CPU_MIN_C" -lt "$CPU_MAX_C" ] && [ "$SSD_MIN_C" -lt "$SSD_MAX_C" ] \
  && [ "$PWM_MIN" -lt "$PWM_MAX" ] && [ "$PWM_MAX" -le 255 ] \
  || fatal "invalid configuration: inconsistent thresholds"

find_hwmon "$FAN_CHIP" || fatal "$FAN_CHIP not found"
IT_HWMON=$REPLY
find_hwmon coretemp || fatal "coretemp not found"
CORE_HWMON=$REPLY
PWM_FILE=$IT_HWMON/pwm$PWM_CHANNEL
ENABLE_FILE=$IT_HWMON/pwm${PWM_CHANNEL}_enable
FAN_FILE=$IT_HWMON/fan${PWM_CHANNEL}_input

echo 1 > "$ENABLE_FILE" || fatal "cannot set manual mode"
echo "start: $FAN_CHIP pwm$PWM_CHANNEL, CPU $CPU_MIN_C-$CPU_MAX_C C, SSD $SSD_MIN_C-$SSD_MAX_C C, PWM $PWM_MIN-$PWM_MAX"

pwm=-1   # the first cycle goes straight to the target, with no ramp
cycle=0
stall=0
while true; do
  # An unreadable or out-of-range CPU must never look "cold".
  read_int "$CORE_HWMON/temp1_input" && [ "$REPLY" -gt 0 ] && [ "$REPLY" -lt 125000 ] \
    || fatal "invalid CPU temperature: '${REPLY:-}'"
  cpu=$REPLY
  curve "$cpu" "$CPU_MIN_C" "$CPU_MAX_C"
  target=$REPLY

  read_ssd
  ssd=$REPLY
  curve "$ssd" "$SSD_MIN_C" "$SSD_MAX_C"
  [ "$REPLY" -gt "$target" ] && target=$REPLY

  rpm=-1
  read_int "$FAN_FILE" && rpm=$REPLY
  if [ "$rpm" -eq 0 ]; then
    stall=$(( stall + 1 ))
    [ "$stall" -eq "$STALL_CYCLES" ] && echo "WARNING: fan stopped, PWM at maximum" >&2
  else
    [ "$stall" -ge "$STALL_CYCLES" ] && echo "fan running again: $rpm RPM"
    stall=0
  fi
  [ "$stall" -ge "$STALL_CYCLES" ] && target=$PWM_MAX

  # A chip reset (or sensors -s) can put it back in automatic mode.
  if read_int "$ENABLE_FILE" && [ "$REPLY" -ne 1 ]; then
    echo "pwm${PWM_CHANNEL}_enable was $REPLY: back to manual"
    echo 1 > "$ENABLE_FILE" || fatal "cannot set manual mode"
  fi

  if [ "$pwm" -lt 0 ] || [ "$target" -ge "$PWM_MAX" ]; then
    pwm=$target
  elif [ "$target" -gt "$pwm" ]; then
    pwm=$(( pwm + STEP_UP < target ? pwm + STEP_UP : target ))
  elif [ "$target" -lt $(( pwm - HYSTERESIS )) ]; then
    pwm=$(( pwm - STEP_DOWN > target ? pwm - STEP_DOWN : target ))
  fi

  echo "$pwm" > "$PWM_FILE" || fatal "PWM write failed"

  if [ $(( cycle % LOG_EVERY )) -eq 0 ]; then
    echo "cpu=$(( cpu / 1000 ))C ssd=$(( ssd / 1000 ))C target=$target pwm=$pwm rpm=$rpm"
  fi
  cycle=$(( cycle + 1 ))
  sleep "$INTERVAL"
done
