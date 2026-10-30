# Fans: shift the curve toward heat, never reach state 0

The full story — the 0-RPM incident, the firmware that breaks fan control, the measured
RPM at every state — is in the companion repository
[`dgx-spark-fan-tuning`](https://github.com/tenhkspark/dgx-spark-fan-tuning). This page is
the operating summary and the numbers we run.

## The curve

Upstream default is five points, and it asks for state 10–12 (10,935–13,500 rpm) even at
idle. Ours is nine points, shifted +7 °C, with state 1 as an absolute floor:

```python
PERFORMANCE_CURVE = (
    (0.0, 1),    # 2,700 rpm floor — never state 0: on this firmware state 0 can mean 0 rpm
    (52.0, 2),   # 3,600
    (57.0, 3),   # 4,500
    (62.0, 4),   # 5,400
    (66.0, 5),   # 6,300
    (70.0, 6),   # 7,200
    (73.0, 8),   # 9,000
    (76.0, 10),  # 11,250 (fan 0 saturates at 9,000)
    (78.0, 12),  # 13,500 (both fans at their maximum)
)
```

The controller's smoothing (alpha 0.35), the +2 state/2 s rise limit, the −1 state/2 s
fall limit and the 4 °C hysteresis all stay as upstream.

## What changed in practice

| | Upstream | Ours |
| --- | --- | --- |
| Idle | state 10–12, 10,935–13,500 rpm | state 2, 3,600–4,200 rpm |
| Mid load | state 8–12 | state 5–6, 5,400–7,200 rpm |
| ACPI, mid load | 60–65 °C | 65–73 °C |
| Decode speed | baseline | unchanged (700 tokens in 10.7–10.9 s) |

Honest accounting: under load we raised temperature by ~4 °C and lowered rpm by one step.
The acoustic result at full load is close to unchanged — the equilibrium simply moved
along the same fan curve. Real noise reduction needs physical placement, not a curve.

## Install

```sh
# 1. the module and daemon from the companion repository
#    (dgx_ec_fan_control module, dgx-fan-daemon.service, and the
#     dgx-fan-control.service alias their benchmark harness expects)
# 2. then replace the curve constant:
sudo ./scripts/fan-curve.sh --apply
```

The script rewrites only `PERFORMANCE_CURVE` in `/usr/local/sbin/dgx-fan-control`, keeps a
timestamped backup next to it, and restarts `dgx-fan-daemon.service`. Dry run by default.

## Verify

```sh
dgx-fan-control status                 # state=N/12 and the filtered temperature
cat /sys/class/thermal/cooling_device*/cur_state
```

State must never be 0. If it is, the daemon is not running or the module is loaded
without it — fix that before anything else.

## The 0-RPM trap, in one paragraph

Loading `dgx_ec_fan_control` without a running daemon can leave both fans stopped. The
SoC then climbs to ~96 °C and the platform clamps the GPU to 611 MHz while `nvidia-smi`
still shows ~96 % utilisation and 8–11 W. A reboot does not clear it; pull the power cable
for 30 seconds to reset the EC. This is why the curve starts at state 1 and why the
thermal watchdog alarms on state 0.

## Firmware

Do not update it. The October 2026 bundle caps the fans near 4,350 rpm and makes this
curve ineffective. We froze LVFS, masked `fwupd-refresh`, blocked the update hosts, and
blacklisted firmware packages in APT. See [security.md](security.md).

## Rollback

Restore `/usr/local/sbin/dgx-fan-control.orig-<date>` (the script leaves one) and
`systemctl restart dgx-fan-daemon`. To go back to the upstream defaults instead,
reinstall the upstream controller.
