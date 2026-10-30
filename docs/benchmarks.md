# Measuring: what we run, and the four traps in the way

Every performance number in this repository comes from the recipe's own benchmark:

```sh
./bin/spark --cluster-config <config> bench                  # quality gate + decode
./bin/spark --cluster-config <config> bench --suites prefill \
  --prefill-sizes 32768,65536,131072,262144,524288,1000000   # prefill
./bin/spark --cluster-config <config> bench \
  --decode-cases prose-nothink,code-nothink --compare none    # thinking off
```

The benchmark cools the nodes first, discards a warm-up sample per point, then samples
until the 95% interval is narrow enough. It also records the thermal envelope, memory and
any foreign requests that arrived during the run.

## Trap 1: a hand-rolled request loop reads low

A loop that times `POST /chat/completions` from the client includes time to first token in
what it calls prefill speed. On our cluster that understated prefill by about 15%
(6,256 against 7,240 tok/s on the same build). Our first published numbers had this
error; they are gone from this repository, and the history says so.

## Trap 2: the prefix cache answers your "prefill"

The server caches prompt prefixes. Send the same 32K document twice and the second run
measures cache lookup, not prefill: we saw a 162,995 tok/s reading that way. Salt the
prompt, or use the benchmark's own filler text, which is different per run.

## Trap 3: someone else is using the GPU

The engine serves this cluster's chat traffic and its watchdogs. Two requests during a
300-second window moved the sample by several percent, and the benchmark reports it as
`foreign_requests` and marks the run noisy. Stop the watchdog for the run and keep the
conversation off the cluster; a run that says it was not alone is not a measurement.

## Trap 4: thinking on and thinking off are different benchmarks

`reasoning_effort` changes how much of the output is reasoning text. That changes
speculative acceptance (tokens per step) and therefore tok/s. The default decode cases
generate reasoning text — on our runs `reasoning_share` was 1.0, meaning all 256 output
tokens were reasoning — while the `-nothink` cases generate the answer itself. Comparing
one arm to the other is meaningless; the tokens/step are not even close (2.297 against
2.500 on the same build). See [effort.md](effort.md).

## Results

| | 1025 | 1030 |
| --- | --- | --- |
| Prefill 32K | — | 7,990 tok/s |
| Prefill 128K | — | 7,854 tok/s |
| Prefill 1M | — | 5,828 tok/s |
| Decode, prose, thinking off | 80.5 ±0.5% | 83.4 ±1.0% |
| Decode, code, thinking off | 118.5 ±2.0% | 122.1 ±1.8% |
| Engine step, prose | 29.71 ms | 28.64 ms |
| Tokens/step, prose / code | 2.500 / 4.339 | 2.500 / 4.339 |
| Quality gate | 5/5 | 5/5 |
| KV pool | 6,512,700 tokens | 11,554,122 tokens |
| GPU max, 1M prefill | — | 72–77 °C, 0 ms throttling |

Both arms use the ring control plane. The full set, including the Wi-Fi comparison and
the effort runs, is in [results-1030.md](results-1030.md).

## How the numbers were wrong twice before they were right

Worth reading if you plan to publish your own.

1. The first comparison used the request loop from trap 1, and reported a 17% prefill gain
   that was really the difference between two differently-wrong methods.
2. The second compared thinking-on runs against the author's thinking-off reference, and
   reported a 6% decode regression that was mostly the text mix.
3. The third found the actual cause of the remaining gap: the control plane was on Wi-Fi.
   Moving it to the ring links raised single-stream decode by 16.8% with tokens/step
   unchanged ([network.md](network.md), [spark-ds41f#712](https://github.com/christopherowen/spark-ds41f/issues/712)).

Each correction changed the conclusion. Publish the method with the number, or the number
is not worth much.
