# fan-daemon

Dynamic fan control for Proxmox nodes running on Gigabyte BRIX mini PCs with an IT8771E chip.

The chip's automatic curve gets stuck instead of recalculating continuously, so the daemon drives
the PWM directly from the CPU and SSD temperatures.

## How it works

Every 10 seconds the daemon:

1. reads the CPU temperature (`coretemp`, package) and the SSD temperatures (`drivetemp`);
2. calculates a PWM for each source from its own linear curve and keeps the highest;
3. moves towards that value with a ramp:

| Situation | Behaviour |
|---|---|
| First cycle after startup | goes straight to the calculated value |
| Temperature rising | at most +30 PWM per cycle |
| Curve at maximum | straight to `PWM_MAX` |
| Temperature falling | at most -5 PWM per cycle, and only if the calculated value is at least 8 lower |

The ramp stops short CPU temperature spikes from making the fan speed swing.

### Fault behaviour

| Event | Reaction |
|---|---|
| CPU temperature unreadable or out of range | the daemon exits with an error, the fan goes to full speed, systemd retries after 5 s |
| Service stopped or terminated (including `kill -9`) | `ExecStopPost` sets the fan to full speed |
| Fan at 0 RPM for 3 cycles | PWM at maximum and a warning in the journal |
| Chip back in automatic mode | the daemon sets it to manual again and logs it |
| SSD unreadable | carries on with the CPU curve only |

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
| `SSD_MIN_C` / `SSD_MAX_C` | 45 / 70 | SSD curve range, in °C |
| `PWM_MIN` / `PWM_MAX` | 80 / 255 | PWM limits |
| `STEP_UP` / `STEP_DOWN` | 30 / 5 | maximum change per cycle |
| `HYSTERESIS` | 8 | minimum gap before the PWM starts going down |
| `INTERVAL` | 10 | seconds between cycles |
| `LOG_EVERY` | 60 | cycles between status lines in the journal |
| `STALL_CYCLES` | 3 | cycles at 0 RPM before the warning |
| `FAN_CHIP` / `PWM_CHANNEL` | it8771 / 2 | chip and channel to drive |

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
in `config/`. It then installs the daemon, the unit and the configuration, loads the `it87` and
`drivetemp` modules, makes them persistent in `/etc/modules-load.d/fan-daemon.conf`, enables the
service and restarts it.

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
cpu=52C ssd=42C target=90 pwm=90 rpm=3260
```

## Uninstalling

The `hwmonN` number can change, so first check which one has the name `it8771`.

```bash
systemctl disable --now fan-daemon
```

```bash
grep -l it8771 /sys/class/hwmon/hwmon*/name
```

```bash
echo 2 > /sys/class/hwmon/hwmonN/pwm2_enable
```
