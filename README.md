# fan-daemon

Dynamic fan control for Proxmox nodes running on Gigabyte BRIX mini PCs with an IT8771E chip.

The chip's automatic curve gets stuck instead of recalculating continuously, so the daemon drives
the PWM directly from the CPU and SSD temperatures.

## How it works

Every 10 seconds the daemon:

1. reads the CPU temperature (`coretemp`, package) and the SSD temperatures (`drivetemp`);
2. takes the median of the last three readings of each, so that a single spike is ignored;
3. calculates a PWM for each source from its own linear curve and keeps the highest;
4. raises it to the boost floor, if a boost is active (see [Boost before known loads](#boost-before-known-loads));
5. moves towards that value with a ramp:

| Situation | Behaviour |
|---|---|
| First cycle after startup | goes straight to the calculated value |
| Temperature rising | at most +30 PWM per cycle |
| Curve at maximum, or one raw CPU reading at `CPU_CRIT_C` | straight to `PWM_MAX` |
| Temperature falling | at most -5 PWM per cycle, and only if the calculated value is at least 8 lower |

### Why the median

Sampled every 2 seconds, the CPU package temperature jumps up to 15 °C and back, in step with the
load: the die has almost no thermal mass, so the temperature reacts within the same sample and no
load signal gives an earlier warning. The SSD controller sensor jumps up to 12 °C in 2 seconds, often
with no writes at all. The fan cools the heatsink, which changes over minutes, so it cannot prevent
either kind of spike, and chasing them only makes the fan speed swing.

The median of three readings (30 seconds) drops an isolated spike and follows a real rise within
20 seconds. Replayed on recorded data, it halves how much the PWM moves per cycle. Safety still
works on the raw reading: a single CPU reading at `CPU_CRIT_C` (90 °C) sets full speed at once.

### Boost before known loads

Since temperature spikes cannot be anticipated from the load, the only real head start comes from
loads that are known in advance, such as a nightly backup. `fan-boost` raises the minimum PWM for a
while by writing `/run/fan-daemon/boost`:

```bash
fan-boost 1800
```

```bash
fan-boost 600 200
```

```bash
fan-boost off
```

Without a PWM it uses `BOOST_PWM` from `/etc/default/fan-daemon` (160). The boost always has an
expiry, so it cannot get stuck. Two pieces use it:

| Piece | When | Boost |
|---|---|---|
| `fan-preboost.timer` | 23:55 every day | 30 minutes |
| `fan-vzdump-hook` (vzdump `script:`) | from `job-start` to `job-end` or `job-abort` | up to 2 hours |

The timer cools the heatsink for five minutes before a backup that starts at 00:00, and the hook
keeps the boost for as long as the backup actually runs. To move the timer, override `OnCalendar`
with `systemctl edit fan-preboost.timer`. The hook always exits 0, because a failing vzdump hook
aborts the backup.

### Fault behaviour

| Event | Reaction |
|---|---|
| CPU temperature unreadable or out of range | the daemon exits with an error, the fan goes to full speed, systemd retries after 5 s |
| Service stopped or terminated (including `kill -9`) | `ExecStopPost` sets the fan to full speed |
| Fan at 0 RPM for 3 cycles | PWM at maximum and a warning in the journal |
| Chip back in automatic mode | the daemon sets it to manual again and logs it |
| SSD unreadable | carries on with the CPU curve only |
| Boost file missing, malformed or expired | ignored |

This means `systemctl stop fan-daemon` leaves the fan at **100%**, by design.
To go back to the chip's curve, see [Uninstalling](#uninstalling).

## Hardware

| Board | CPU | SSD | Chip | Channel | `PWM_MIN` |
|---|---|---|---|---|---:|
| MMLP7AP-00 | i7-4500U | Transcend TS256GMSA230S | IT8771E | `pwm2` / `fan2` | 70 |
| MMLP5AP-00 | i5-4200U | Samsung 840 EVO mSATA | IT8771E | `pwm2` / `fan2` | 80 |

On these boards `pwm1` and `pwm3` have no fan attached (0 RPM), and the daemon leaves them alone.

### Measured RPM

Step test on three MMLP7AP-00 nodes, 7 seconds per step:

| PWM | Node A | Node B | Node C |
|---:|---:|---:|---:|
| 255 | 6490 | 6617 | 5672 |
| 200 | 5443 | 5625 | 4787 |
| 160 | 4687 | 4891 | 3901 |
| 130 | 4041 | 4245 | 3391 |
| 110 | 3552 | 3770 | 2973 |
| 90 | 3000 | 3245 | 2528 |
| 80 | 2689 | 2947 | 2288 |
| 70 | 2368 | 2636 | 2027 |
| 60 | 2033 | 2303 | 1739 |
| 50 | 1666 | 1945 | 1433 |
| 40 | 1264 | 1551 | 1083 |
| 30 | 680 | 856 | 678 |

The fan did not stop even at PWM 30, the lowest value tested. `PWM_MIN=70` therefore leaves a good
margin, and at idle it gives an RPM similar to the automatic curve (about 2700-3400 RPM).
This test was not run on the MMLP5AP-00.

## Configuration

Defaults are in `fan-daemon.sh`. Board-specific values are in `config/<board_name>.conf`, which is
installed as `/etc/default/fan-daemon`.

| Variable | Default | Meaning |
|---|---:|---|
| `CPU_MIN_C` / `CPU_MAX_C` | 50 / 85 | CPU curve range, in °C |
| `CPU_CRIT_C` | 90 | a single raw CPU reading this high sets `PWM_MAX` |
| `SSD_MIN_C` / `SSD_MAX_C` | 45 / 70 | SSD curve range, in °C |
| `PWM_MIN` / `PWM_MAX` | 80 / 255 | PWM limits |
| `STEP_UP` / `STEP_DOWN` | 30 / 5 | maximum change per cycle |
| `HYSTERESIS` | 8 | minimum gap before the PWM starts going down |
| `INTERVAL` | 10 | seconds between cycles |
| `LOG_EVERY` | 60 | cycles between status lines in the journal |
| `STALL_CYCLES` | 3 | cycles at 0 RPM before the warning |
| `FAN_CHIP` / `PWM_CHANNEL` | it8771 / 2 | chip and channel to drive |
| `BOOST_PWM` | 160 | PWM floor used by `fan-boost` when none is given |
| `BOOST_FILE` | `/run/fan-daemon/boost` | where `fan-boost` and the daemon meet |

## Installing

From a machine with root SSH access to the node:

```bash
./deploy.sh node.example.lan
```

Any further arguments are passed to `ssh` and `scp`, for example to go through a jump host:

```bash
./deploy.sh node.example.lan -J root@jump.example.lan
```

The script reads the board name from the node and refuses to continue if there is no matching file
in `config/`. It then installs the daemon, `fan-boost`, the vzdump hook, the units and the
configuration, loads the `it87` and `drivetemp` modules, makes them persistent in
`/etc/modules-load.d/fan-daemon.conf`, enables the timer and the service, and restarts the service.

vzdump accepts a single hook script: the deploy adds `script: /usr/local/sbin/fan-vzdump-hook` to
`/etc/vzdump.conf` only if no other script is set, and otherwise prints a warning and leaves it alone.
A backup job that sets its own `script` overrides it.

## Testing

The tests use a fake hwmon tree, so they don't touch any hardware:

```bash
tests/test-fan-daemon.sh
```

## Monitoring

```bash
systemctl status fan-daemon
```

```bash
journalctl -u fan-daemon -f
```

The journal gets a status line every 10 minutes:

```
cpu=52C ssd=42C target=90 pwm=90 rpm=3260 boost=0
```

The temperatures in it are the raw readings, the target already uses the median. The start and
end of a boost are logged too.

## Uninstalling

The `hwmonN` number can change, so first check which one has the name `it8771`.

```bash
systemctl disable --now fan-preboost.timer fan-daemon
```

Remove the `script: /usr/local/sbin/fan-vzdump-hook` line from `/etc/vzdump.conf`, then:

```bash
grep -l it8771 /sys/class/hwmon/hwmon*/name
```

```bash
echo 2 > /sys/class/hwmon/hwmonN/pwm2_enable
```
