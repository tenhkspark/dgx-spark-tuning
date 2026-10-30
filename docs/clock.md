# GPU clock: no ceiling, a 2,500 MHz floor

## The usual advice, and why we skip it

The common DGX Spark tuning thread caps the GPU clock (`nvidia-smi -lgc 0,2200` or
similar) to keep the box cool. On a single node running short chats that works fine. On a
four-node cluster serving a 1M-context model it costs exactly the work that hurts most:
prefill is compute-bound, and decode steps beside a long prompt are as well. A 2,200 MHz
ceiling takes roughly a quarter of the clock away and hands back a few degrees we did not
need.

We do the opposite: leave the ceiling alone, pin a floor, and manage heat with the fans
and with power/temperature monitoring.

## What we set

```sh
nvidia-smi -lgc 2500,3003     # floor 2,500 MHz, ceiling stays at the hardware maximum
```

On GB10, `nvidia-smi` reports a 2,418 MHz default application clock and a 3,003 MHz
maximum, and lists no supported-clock table. The floor sits just above the clock the
units settle at under load anyway, so it does not overclock anything — it stops the clock
from *dropping* when the machine thinks it is idle.

Effective floor after the driver rounds to its own steps: `clocks.sm` reads 2,496 MHz,
which is the nearest step at or above the request.

## Why a floor helps prefill

With no floor, a mostly idle node runs at 2,300–2,450 MHz and only climbs when load
arrives. Every prefill that starts after an idle gap begins at the low end. Over a day of
chat traffic that is a visible tax on time-to-first-token.

The floor also removes one source of run-to-run variance. In a 16-stream closed loop the
per-node SM clock held 2,489–2,496 MHz (p10 2,489, max 2,515), with no clock-event
reasons and no thermal or power throttle. Nodes differed by up to ~13 MHz, which is why
the slowest rank paces every all-reduce — a fixed floor makes that comparison honest.

## Install

The unit is a oneshot that runs after `nvidia-persistenced` (not after
`multi-user.target`, which can hang on DGX OS and leave the unit queued forever).

```sh
sudo ./scripts/clock-floor.sh --apply
```

It writes `/etc/systemd/system/gpu-clock-floor.service`, enables it, and applies the lock
immediately. Dry run is the default:

```sh
./scripts/clock-floor.sh          # prints the unit and the exact nvidia-smi command
```

## Verify

```sh
systemctl status gpu-clock-floor --no-pager
nvidia-smi --query-gpu=clocks.sm,clocks.max.sm,power.draw,temperature.gpu --format=csv
```

`clocks.sm` should sit at or just above 2,500 MHz at idle and climb toward 3,003 under
load. If it reads below 2,450 with the unit active, the driver rejected the request — check
`journalctl -u gpu-clock-floor`.

## What it costs

The chip no longer idles at 2,300–2,450 MHz, so it burns a few watts more and runs a
degree or two warmer when nothing is happening. We did not isolate that delta with a
dedicated idle test — the same four nodes serve the chat traffic that would measure it —
so treat the size as an estimate, not a measurement.

If you care more about a silent idle than about prefill, skip the floor entirely; the rest
of this repository works either way. What we would not do is add a clock cap to compensate:
that buys back the idle watts by taking a quarter of the clock away under load, which is
the opposite trade.

## Rollback

```sh
sudo nvidia-smi -rgc                        # reset immediately, this boot only
sudo systemctl disable --now gpu-clock-floor
```

`-rgc` is not persistent, so disabling the unit is what makes the change stick.

## Notes

- Memory clock is not reported on GB10 (`N/A`); there is nothing to pin there.
- Do not combine the floor with an upper cap "for safety". Pick one philosophy: either the
  chip runs and the fans handle it, or the chip is capped and prefill pays. Mixing the two
  gives you the cost without the benefit.
- Verify with real traffic, not a synthetic loop, before you conclude anything about
  tokens per second.
