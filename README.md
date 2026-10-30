[English](README.md) | [日本語](README-ja.md) | [简体中文](README-zh.md) | [한국어](README-ko.md)

# DGX Spark cluster tuning: 4 nodes, one 1M-token model, no clock ceiling

What a four-node DGX Spark (GB10) cluster actually runs, in one place: the GPU clock
policy, the fan curve, the serving recipe, how we clean up disks without deleting
anything, how security patches get applied while the kernel and driver stay frozen, and
the two watchdogs that keep it alive. Every number below was measured on the four units,
not copied from a datasheet.

If you only want the fan curve, the deep dive lives in the companion repository
[`dgx-spark-fan-tuning`](https://github.com/tenhkspark/dgx-spark-fan-tuning) (GPL-2.0,
because it patches a GPL controller). This repository is the whole operating picture.

## The setup

```
spark1 (head, rank 0) ─┐
spark2 (rank 1)        ├── ConnectX-7 ring: 1-2-3-4-1, two paths per neighbour
spark3 (rank 2)        │    one model, tensor parallel 4, 1,048,576 tokens of context
spark4 (rank 3) ───────┘    16 concurrent sequences, ~11.3 GB KV pool
```

| Item | Value |
| --- | --- |
| Nodes | 4 × DGX Spark, GB10, 128 GB unified memory each |
| Kernel | `7.0.0-1019-nvidia-64k` (64 KiB pages, required for the 1M context) |
| Driver | `580.178.04` (frozen; see [security](docs/security.md)) |
| Engine | [`christopherowen/spark-ds41f`](https://github.com/christopherowen/spark-ds41f) (Apache-2.0), TileLang backend |
| Model | DeepSeek-V4.1-Flash-1017, native weights, TP4 ring |
| Context | 1,048,576 tokens, `max_num_seqs` 16, DSpark speculative 5 drafts |
| API | `http://<head>:8000/v1`, model name `deepseek-v4.1-flash` |

Measured with the recipe's own `bin/spark bench` on spark-ds41f-1030, 2026-10-30
(four nodes, TP4 ring, 1M context, thinking off, the control plane on the ring's wired links):

| Metric | Result |
| --- | --- |
| Prefill, 32K prompt | 7,990 tok/s |
| Prefill, 128K prompt | 7,854 tok/s |
| Prefill, 1M prompt | 5,828 tok/s |
| Decode, prose, single stream | 83.4 tok/s (87.3 across the decode window) |
| Decode, code, single stream | 122.1 tok/s (130.9 across the decode window) |
| Tokens per speculative step | 2.500 prose / 4.339 code |
| Quality gate | 5/5 |
| GPU temperature, 1M prefill | 72–77 °C, system 84 °C, 0 ms throttling |
| Fan, idle / 1M prefill | state 2–4, 3,600–4,500 rpm / state 12 |

The full set, the 1025 comparison and the effort runs are in
[docs/results-1030.md](docs/results-1030.md); how the numbers are taken, and the four
ways we got them wrong first, is in [docs/benchmarks.md](docs/benchmarks.md).

Idle figures were taken with no request in flight; the 2,500 MHz floor raises the resting temperature a few degrees.

Our earlier request-loop numbers (165 structured / 65 prose / 6,256 prefill) were measured
with a hand-rolled client and read low: a request loop includes time to first token, which
understates prefill by about 15 %. The recipe's benchmark is the only number we quote now.

## The seven settings, in brief

1. **Clock: no ceiling, a 2,500 MHz floor.** We do not cap the GPU clock. A cap trades
   prefill speed for a few degrees; a floor stops light load from dropping the clock and
   dragging prefill with it. Heat is managed by the fans and by watching power and
   temperature, not by starving the chip. → [docs/clock.md](docs/clock.md)
2. **Fans: shift the curve toward heat, never reach state 0.** The stock curve spins at
   10,000+ rpm at idle. Ours holds state 1 as the floor and shifts every threshold +7 °C.
   Idle drops to 3,600–4,200 rpm with no loss in tokens per second. → [docs/thermal.md](docs/thermal.md)
3. **Serving: one 1M-context model over four nodes.** 64 KiB pages, 11.3 GB KV pool, a
   16,384-token prefill budget, and a 3 GiB per-node host reservation so the pool fits.
   → [docs/serving.md](docs/serving.md) · [measured results](docs/results-1030.md)
4. **Network: keep the control plane off Wi-Fi.** A few packets per engine step over
   wireless cost 16.8% of single-stream decode. Ring routes and their persistence are in
   [docs/network.md](docs/network.md).
5. **Disk: move, never `rm`.** Old models, logs and containers go to the trash directory
   with a restore path; container logs are copied out *before* any restart. → [docs/disk.md](docs/disk.md)
6. **Patching: security only, kernel and firmware frozen.** Daily unattended upgrades for
   user-space security fixes, with a blacklist that keeps out kernels, NVIDIA, CUDA,
   Docker and every firmware path. → [docs/security.md](docs/security.md)
7. **Watchdogs: one for heat, one for the API.** The thermal watchdog alarms on ACPI or GPU
   temperature and on a fan that stopped; the API watchdog asks a second node before it
   restarts anything. → [docs/watchdogs.md](docs/watchdogs.md)

## Quick start

```sh
git clone https://github.com/tenhkspark/dgx-spark-tuning
cd dgx-spark-tuning

# 1. clock floor (per node, dry-run first)
sudo ./scripts/clock-floor.sh --apply

# 2. fan curve (per node; needs the upstream controller installed first)
sudo ./scripts/fan-curve.sh --apply

# 3. watchdogs (from the machine that can reach every node)
cp configs/nodes.example.txt configs/nodes.txt   # edit hosts
./scripts/thermal-watch.sh --check
./scripts/api-watchdog.sh --check
```

Each script prints what it will change and changes nothing without `--apply`.

## Read this before you touch anything

- **Firmware:** do not update it. The October 2026 bundle (EC 3.13.7 / SoC 2.158.15 / PD
  5.25) breaks fan control: the fan ceiling collapses to about 4,350 rpm on our units and
  they run hot. We froze all three update paths. See [docs/security.md](docs/security.md).
- **The 0-RPM trap:** loading the fan module without running the daemon can leave both fans
  at 0 rpm. The SoC then reaches ~96 °C and the GPU clamps to 611 MHz while `nvidia-smi`
  still reports ~96 % utilisation. Recovery needs the power cable out for 30 seconds, not
  a reboot. Details and the measured incident are in the fan repository.
- **No benchmark harness in this repository.** Numbers come from real work plus a small
  closed-loop load generator; we do not keep a benchmarking rig running on production.

## Compatibility

Tested only on four DGX Spark units running DGX OS with the kernel and driver above. The
fan curve needs the `dgx_ec_fan_control` module and the daemon from the companion
repository; the clock floor needs nothing but `nvidia-smi`. Single-node clusters can use
the clock, disk, security and watchdog parts unchanged and skip the TP4 serving section.

## Credits and licence

- Fan controller: [`christopherowen/dgx-spark-fan-control`](https://github.com/christopherowen/dgx-spark-fan-control) (GPL-2.0). We ship numbers and a patch script, not their code.
- Serving engine: [`christopherowen/spark-ds41f`](https://github.com/christopherowen/spark-ds41f) (Apache-2.0). We ship our configuration, not their code.
- Model: DeepSeek-V4.1-Flash-1017, used under its own licence.

Everything in this repository is MIT (see [LICENSE](LICENSE)). The fan curve is applied
to a GPL-2.0 file on your machine, which is why the patch itself is not redistributed
here.
