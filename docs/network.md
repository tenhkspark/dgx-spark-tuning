# Routing the ring: giving every node a wired path to every other node

The recipe's control plane (`master_addr`, `VLLM_HOST_IP`, `GLOO/TP/NCCL_SOCKET_IFNAME`)
carries a few packets per engine step. Put it on Wi-Fi and every delayed packet stalls a
step: on our four nodes that cost 16.8% of single-stream decode (71.4 → 83.4 tok/s) with
tokens/step unchanged. The mechanism is [spark-ds41f#712](https://github.com/christopherowen/spark-ds41f/issues/712).

Moving the control plane onto the ring's CX-7 links needs two things: addresses that
reach, and routes that exist after a reboot. This page is the second part.

## The cabling we assume

Neighbours only — no switch. Each node has two ring ports, one to each neighbour, and the
ring closes 1-2-3-4-1:

| node | ring address | reaches neighbour over | neighbour |
| --- | --- | --- | --- |
| 1 | 10.40.0.1 | 10.40.0.0/24 | 2 at 10.40.1.1 |
| 2 | 10.40.1.1 | 10.40.1.0/24 | 3 at 10.40.2.1 |
| 3 | 10.40.2.1 | 10.40.2.0/24 | 4 at 10.40.3.1 |
| 4 | 10.40.3.1 | 10.40.3.0/24 | 1 at 10.40.0.1 |

The interface is `enp1s0f0np0` on every node. Each node already routes to its two
neighbours because both addresses sit on a connected subnet. The opposite node does not:
node 1 has no route to 10.40.2.0/24 even though node 2 can reach it.

## The routes

Add the two missing subnets on each node, pointing at the neighbour that can forward.
`ip_forward` is already 1 on DGX OS; confirm it.

```
# node 1
ip route replace 10.40.1.0/24 via 10.40.0.2
ip route replace 10.40.2.0/24 via 10.40.0.2

# node 2
ip route replace 10.40.2.0/24 via 10.40.1.2
ip route replace 10.40.3.0/24 via 10.40.0.1

# node 3
ip route replace 10.40.0.0/24 via 10.40.1.1
ip route replace 10.40.3.0/24 via 10.40.1.1

# node 4
ip route replace 10.40.0.0/24 via 10.40.3.2
ip route replace 10.40.1.0/24 via 10.40.3.2
```

`replace` rather than `add` so re-running is safe. Result on our hardware:

| path | mean RTT | max |
| --- | --- | --- |
| to a neighbour | 0.20–0.58 ms | 0.83 ms |
| to the opposite node | 1.24 ms | 1.94 ms |
| Wi-Fi management, for comparison | 3.8–4.4 ms | 14–68 ms |

## Making it survive a reboot

`ip route` is not persistent. A oneshot unit re-applies it after the network is up; it
retries because the ring interface can take a moment to appear.

```ini
[Unit]
Description=DGX Spark ring control-plane routes
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for i in $(seq 1 30); do ip route replace 10.40.1.0/24 via 10.40.0.2; ip route replace 10.40.2.0/24 via 10.40.0.2; exit 0; sleep 2; done; exit 1'

[Install]
WantedBy=multi-user.target
```

Install once per node, with that node's two routes:

```sh
sudo install -m 0644 dgx-ring-routes.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now dgx-ring-routes.service
```

Note the `ExecStart` is one `bash -c` string; systemd does not run shell syntax otherwise.

## Point the control plane at the ring

In the cluster config, three fields and the node map:

```json
"distributed": { "master_addr": "10.40.0.1", "master_port": "9999" },
"environment": {
  "GLOO_SOCKET_IFNAME": "enp1s0f0np0",
  "TP_SOCKET_IFNAME":   "enp1s0f0np0"
},
"shapes": { "tp4-ring": { "environment": { "NCCL_SOCKET_IFNAME": "enp1s0f0np0" } } }
```

and a copy of the node map whose `management_ip` entries are the ring addresses, because
`VLLM_HOST_IP` is rendered from `management_ip`. SSH, the API bind and your shell keep
using the management network: the API binds `0.0.0.0`, so nothing on the LAN changes.

## Verify

```sh
for ip in 10.40.0.1 10.40.1.1 10.40.2.1 10.40.3.1; do
  ping -c 2 -W 1 "$ip" >/dev/null && echo "$ip ok" || echo "$ip FAIL"
done
systemctl is-enabled dgx-ring-routes
docker inspect spark-ds41f --format '{{json .Config.Env}}' | grep -o '"GLOO_SOCKET_IFNAME=[^"]*"'
```

Then measure: single-stream decode should move by roughly 15% on the same build if the
Wi-Fi was the control plane before.

## When this stops being the right answer

- **A switch arrives.** With an L2 fabric every node is one hop away and these routes
  become wrong; delete the unit before re-cabling.
- **The ring addresses change.** The routes are literal addresses; a new subnet means a
  new unit. Keep `dgx-ring-routes.service` next to the node map that names the same
  addresses.
- **You only have one node.** Nothing here applies; keep the control plane on the
  management interface.

Rollback is `sudo systemctl disable --now dgx-ring-routes` and putting the three config
fields back on the management interface. Both are one command; do them together, because
a half-switched control plane is worse than either end state.
