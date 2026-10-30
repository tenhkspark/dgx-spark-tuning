# Serving: one 1M-token model across four nodes

## What runs

[`christopherowen/spark-ds41f`](https://github.com/christopherowen/spark-ds41f) serving
**DeepSeek-V4.1-Flash-1017** (native weights) with tensor parallelism 4 over a
ConnectX-7 ring. The engine is Apache-2.0; we contribute configuration, not code.

```
client ──► http://<head>:8000/v1
             │  vLLM-style OpenAI API, model name: deepseek-v4.1-flash
             ▼
        spark1 (rank 0, API + tokenizer)
          ├── spark2 (rank 1)
          ├── spark3 (rank 2)
          └── spark4 (rank 3)
        ring: 1-2-3-4-1, two ConnectX-7 paths per neighbour
```

## Profile we run (`tp4-ring`)

| Setting | Value | Why |
| --- | --- | --- |
| `tensor_parallel_size` | 4 | one model across all four units |
| `max_model_len` | 1,048,576 | the whole point of the build |
| `max_num_seqs` | 16 | measured sweet spot; more thrashes the KV pool |
| `max_num_batched_tokens` | 16,384 | long-prefill budget; 8,192 costs ~5–6 % prefill |
| `kv_cache_memory_bytes` | 11,274,289,152 | fills the pool without tripping the startup guard |
| speculative | DSpark, 5 drafts, greedy draft, block rejection | free decode speed |
| prefill yield | `short`, 10 s | a long prefill pauses so short requests answer; first token beside a 32K prefill was 2.05 s on our ring |
| host reservation | ~3 GiB per node (`memguard_gib`) | keeps the host alive under a 1M prefill |

Two prerequisites that are easy to miss:

- **64 KiB pages.** The kernel must be a `-64k` build (`7.0.0-1019-nvidia-64k`). With 4 KiB
  pages the KV pool cannot hold a 1M context.
- **Memory saver.** The engine reserves host memory per node; without it a cold 1M prefill
  pushes the node into reclaim and the whole cluster stalls.

## Configuration

A minimal sanitized copy is in [`configs/cluster.local.example.json`](../configs/cluster.local.example.json).
The real file is site-specific (IPs, home paths) and stays out of git.

## Start and stop

```sh
# on the head node, from the engine checkout
./bin/spark --cluster-config experiments/<your-cluster>/cluster.local.json \
    cluster start --replace --apply

./bin/spark --cluster-config experiments/<your-cluster>/cluster.local.json \
    cluster stop --apply
```

- `--replace` is required when a container from a previous run still exists; without it the
  start fails cleanly but confusingly.
- A cold start takes 2–4 minutes: model load, NCCL handshake, KV pool allocation.
- Do not start a second copy. Two clusters on the same four units fight over GPUs and port
  8000, and the loser looks like a mysterious OOM.

## Health checks

```sh
curl -sf http://<head>:8000/v1/models
for h in spark1 spark2 spark3 spark4; do
  ssh "$h" 'docker inspect -f "{{.State.Running}}" spark-ds41f'
done
```

Both must agree. An API that answers while a worker container is down means the head is
serving a half-cluster and will fail under load — that is exactly what the API watchdog
checks (see [watchdogs.md](watchdogs.md)).

## Client

```sh
curl -s http://<head>:8000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"hello"}]}'
```

```python
from openai import OpenAI
c = OpenAI(base_url="http://<head>:8000/v1", api_key="none")
r = c.chat.completions.create(
    model="deepseek-v4.1-flash",
    messages=[{"role": "user", "content": "hello"}],
)
```

## Sizing notes

- The KV pool holds 11.02 full 1M contexts on the 1030 recipe (6.21 on 1025). Even so, plan
  for a handful of long requests, not eleven: each one also holds host memory.
- Decode steps beside a long prompt take ~1.7× a plain decode step at the 16,384 budget;
  that is the price of prefill throughput and it is worth it for long-document work.
- 16 concurrent sequences is a measured limit, not a licence limit. Going higher costs
  prefill latency for everyone; keep long jobs in their own session.
- Everything here assumes the weights fit in 4 × 128 GB unified memory with the KV pool;
  check `nvidia-smi memory.used` before blaming the engine.
