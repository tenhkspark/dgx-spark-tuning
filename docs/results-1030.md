# spark-ds41f-1030 measured on four DGX Sparks

Four nodes, GB10, TP4 ring, DeepSeek-V4.1-Flash-1017, 1M context.
All numbers from the recipe's own `bin/spark bench`, thinking off, single client,
seed 0, temperature 0. 2026-10-30/31.

## The control plane decides the tail

Our first runs used the Wi-Fi management interface (`wlP9s9`) for `master_addr`,
`VLLM_HOST_IP` and `GLOO/TP/NCCL_SOCKET_IFNAME`. Moving those onto the ring's
`enp1s0f0np0` changed single-stream decode by 16.8% on the same build:

| 1030, prose, single stream | Wi-Fi control plane | ring control plane |
| --- | --- | --- |
| output tok/s | 71.4 ±6.4% | **83.1** (83.0–83.4 over three runs) |
| decode window | 75.3 | **87.0** |
| engine step | 33.26 ms | **28.7 ms** |
| tokens/step | 2.500 | 2.500 |

Tokens per step are identical, so this is not speculation: the step itself was
shorter. Head-to-worker RTT on the ring is 0.2 ms to a neighbour and 1.2 ms to the
opposite node; the Wi-Fi was 3.8–4.4 ms with spikes.

This is the mechanism described in
[spark-ds41f#712](https://github.com/christopherowen/spark-ds41f/issues/712). On our
nodes the ring had no host routes between neighbours, so we added static routes
(each node forwards, `ip_forward=1`) and pointed the control plane at each node's
`enp1s0f0np0` address. The routes, their systemd unit and the verification are in
[network.md](network.md).

## Decode, thinking off

| | 1025 | 1030 |
| --- | --- | --- |
| prose, single stream | 80.5 ±0.5% | **83.1** (83.0–83.4, n=3) |
| prose, decode window | 84.2 | **87.0** |
| prose, engine step | 29.71 ms | **28.7 ms** |
| code, single stream | 118.5 ±2.0% | **122.3** (122.1–122.6, n=3) |
| tokens/step (prose / code) | 2.500 / 4.339 | 2.500 / 4.339 |

Both arms use the ring control plane. 1030 is 3.2% faster here and the step is
shorter; the earlier "decode got slower" reading came from thinking-on text over
Wi-Fi.

### Repeatability

Three independent runs of the decode pair, minutes apart, on the same boot:

| run | prose tok/s | code tok/s | prose step | window |
| --- | --- | --- | --- | --- |
| 00:06 | 83.4 ±1.0% | 122.1 ±1.8% | 28.64 ms | 87.3 |
| 01:00 | 83.0 ±1.6% | 122.1 ±1.5% | 28.72 ms | 86.9 |
| 01:04 | 83.1 ±0.7% | 122.6 ±0.1% | 28.75 ms | 87.0 |

Tokens per step were identical in all three (2.500 prose, 4.339 code). A 0.5% spread
across runs is the noise floor for this measurement, so anything smaller than that is
not a result.

## Prefill (1030, ring control plane)

| prompt | tok/s |
| --- | --- |
| 32K | 7,990 |
| 64K | 7,980 |
| 128K | 7,854 |
| 262K | 7,519 |
| 524K | 6,861 |
| 1M | 5,828 |

The same sizes over the Wi-Fi control plane read 7,508 / 7,601 / 7,458 / 7,216 /
6,664 / 5,675, i.e. 2.7–6.4% lower.

## Memory

| | 1025 | 1030 |
| --- | --- | --- |
| KV pool | 6,512,700 tokens | **11,554,122 tokens** |
| full 1M contexts resident | 6.2 | **11.0** |
| KV reserved | 10.5 GiB | 10.5 GiB |
| concurrent request slots | 16 | 16 |

The reserved bytes did not change; the pool holds 77% more tokens, so the KV cost
per token fell by about 44%. The 16 request slots are unchanged — 11 is how many
1M-token documents can be resident at once.

## Thermal (1M prefill, ring control plane)

| | |
| --- | --- |
| GPU max | 72–77 °C |
| system max | 82.7–84.3 °C |
| power max | 78–80 W |
| thermal slowdown | 0 ms |
| fan | state 12 during the run, back to 2–4 after |

## Method

```sh
# decode, thinking off
./bin/spark --cluster-config <config> bench \
  --decode-cases prose-nothink,code-nothink --compare none

# prefill, all sizes
./bin/spark --cluster-config <config> bench --suites prefill \
  --prefill-sizes 32768,65536,131072,262144,524288,1000000 --compare none
```

- Never measure with a hand-rolled request loop: time to first token in the prefill
  figure reads about 15% low.
- Salt the prefill prompt so the prefix cache cannot answer it.
- Stop other clients (including monitoring probes) for the run; the bench flags
  foreign requests, and a busy run adds several percent of noise.
- Pin the effort: `reasoning_effort` changes the generated text, which changes
  speculative acceptance, which changes tok/s.

## What this does not say

- Quality. 1030 has the same weights as 1025 (greedy 256/256, KL 4.2e-8), so no
  quality comparison was run.
- Decode beside a 1M prompt. Only prefill was measured at that length.
- Other sites. Four nodes, this cabling, this kernel.
