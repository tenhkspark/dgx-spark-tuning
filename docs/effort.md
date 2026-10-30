# Reasoning effort: what the dial actually changes

`deepseek-v4.1-flash` accepts `reasoning_effort` at `none`, `low`, `high`, `xhigh` and
`max` (`off`, `minimal` and `medium` return 400). The dial does not make the engine
faster; it changes how much of a fixed output budget goes to hidden reasoning tokens.

## It moves tokens per step, so it moves tok/s

Speculative decoding accepts a draft when the target model would have produced the same
tokens. Reasoning text is less predictable than prose, so acceptance falls and each engine
step advances fewer tokens.

| same build, same prompt, thinking off vs on | tokens/step | tok/s |
| --- | --- | --- |
| `reasoning_effort: none` (prose) | 2.500 | 83.4 |
| default, reasoning on (prose) | 2.297 | 70.9 |

That is the same engine, the same weights, the same day. Comparing a tok/s figure without
the effort setting is comparing two different benchmarks.

## What we run

Work runs at `high` by default; we move to `xhigh` and then `max` only when a task fails
verification. The reasoning is cost and reliability, not a quality ceiling: a large study
of eight models across four benchmarks found that fixed-max effort costs up to 42× the
lowest setting on tasks every level solves, and sometimes loses tasks a lower level
solved ([arXiv 2610.34491](https://arxiv.org/abs/2610.34491)).

Benchmarks pin the effort and record it. Ours are measured with `thinking off` for decode
comparisons, because that is the only arm where the author's reference numbers and ours
describe the same work.

## A trap worth naming

A single short request right after a warm-up can read 85 tok/s on a build whose
300-second steady-state number is 70.5. The 300-second window is the measurement; the
burst is an artefact of the first seconds. Two of our own comparisons died on this before
we stopped trusting single requests.

## How to compare two efforts

```sh
./bin/spark --cluster-config <config> bench \
  --suite <suite-with-extra_body-reasoning_effort> --compare none
```

A servebench suite step can carry `extra_body`, so one suite per effort is ten minutes:

```json
{"id": "c1", "command": "run",
 "args": {"mode": "closed", "concurrency": 1, "warmup": 60, "duration": 300,
          "extra_body": {"reasoning_effort": "high"}}}
```

Same seed, no other clients, one effort per run. Anything else is noise.
