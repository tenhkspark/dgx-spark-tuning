# Watchdogs: heat, and an API that lies

Two watchdogs, two very different failure modes. Both are read-only until they decide
something is actually wrong, both keep a state file so a flapping condition does not turn
into an alert storm, and both can be run once by hand for testing.

## 1. Thermal watchdog (every 5 minutes)

Alarms when any of these is true on any node:

| Condition | Meaning |
| --- | --- |
| hottest ACPI zone ≥ 78 °C | the case is hot; the fan curve should already be at state 8+ |
| GPU ≥ 75 °C | sustained load is outrunning the curve |
| fan state == 0 | the 0-RPM trap — act now, this is the one that costs a power cycle |
| fan daemon unreachable *and* the boot baseline reads 0 | EC or daemon failure |

The fan check deliberately uses the **current driven state**, not the boot-time baseline.
Two of our units record `baseline fan1=0` at boot while running perfectly at state 8, so a
baseline-only check produces false alarms forever.

Deduplication: one alert per node per 30 minutes. Alerts append to a single file that a
forwarder ships wherever you like (we send it to a chat room).

```sh
cp configs/nodes.example.txt configs/nodes.txt   # name + ssh target, first line is the head
./scripts/thermal-watch.sh --check               # one pass, print what it sees
./scripts/thermal-watch.sh                        # one pass, append alerts
```

Run it from a machine that can reach every node, under cron or a systemd timer:

```cron
*/5 * * * * /opt/dgx-spark-tuning/scripts/thermal-watch.sh
```

## 2. API watchdog (every 60 seconds)

The API answering is not proof the cluster is healthy: a head node can serve `/v1/models`
while a worker container is dead, and the next real request fails. So the check is two
parts:

1. `GET /v1/models` on the head — with a short timeout.
2. `docker inspect` on every node — all four containers must report `Running`.

Three consecutive failures trigger a **second opinion**: another node tries the same API
call. Only if that also fails is the cluster considered dead. This matters because the
watchdog itself usually runs on a machine outside the cluster, and a Wi-Fi blip there looks
exactly like a dead engine. Restarting a healthy 1M-context cluster costs 2–4 minutes of
downtime and confuses every client; the second opinion prevents that.

After a restart: a 30-minute cooldown, so a genuinely broken start does not loop. A stop
file (`touch <state dir>/api-watchdog.stop`) disables restarts entirely without editing
anything.

```sh
./scripts/api-watchdog.sh --check     # one pass; prints head, containers, decision
./scripts/api-watchdog.sh             # one pass, restart if warranted
```

Configuration is environment-driven: `HEAD_URL`, `NODES_FILE`, `CONTAINER`,
`RESTART_CMD`, `STATE_DIR`. The restart command is whatever starts your cluster
(`cluster start --replace --apply`, wrapped in `systemd-run` if you want it detached from
the watchdog's session).

## What we explicitly do not automate

- **No auto-reboot on temperature.** A hot node under load is a siting problem; rebooting
  it loses the evidence and the work.
- **No "restart on first failure".** One failed probe is noise. Three plus a second
  opinion is a fact.
- **No silent fixes.** Every restart writes a line to the log with the reason and the
  probes that justified it. If you cannot reconstruct why the cluster restarted at 03:14,
  the watchdog is lying to you.

## Alert hygiene

Both scripts print a single heartbeat line per run to stdout and only append to the alert
file on a real condition. If you pipe them to cron mail, you will get mail only when
something is wrong — which is the only schedule that survives contact with a real month.
