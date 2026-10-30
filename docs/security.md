# Security patching with the kernel, driver and firmware frozen

Four GPU nodes are a long-lived appliance, not a laptop. We want the CVE fixes and none of
the surprises, so the policy is: **user-space security updates automatically, everything
below the user space pinned.**

## The policy

| Layer | Action |
| --- | --- |
| User-space packages (openssl, sudo, ssh, systemd, curl, ...) | apply automatically, security pockets only |
| Kernel (`linux-*`) | frozen |
| NVIDIA driver, CUDA, `libcuda*` | frozen |
| Docker, containerd | frozen |
| Firmware (EC, SoC, PD, BIOS), `fwupd`, `linux-firmware` | frozen, three independent paths |

## The trap that makes "automatic updates" a lie

NVIDIA ships `/etc/apt/apt.conf.d/99update-notifier-nvidia`, which sets:

```
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
```

APT reads `apt.conf.d` in lexical order, so this file wins over the usual
`20auto-upgrades` (`1`) and the daily upgrade timer exits in under a second doing
nothing. On our units the unattended-upgrade log had not been written for three weeks while
218 updates (77 of them security) piled up. Nothing errored; the timer just said "success".

Fix: add a file that sorts after `99` and re-enables the periodic job. Copy
[`configs/apt/99zz-periodic.conf`](../configs/apt/99zz-periodic.conf) to
`/etc/apt/apt.conf.d/99zz-periodic.conf`. Leave NVIDIA's file alone — it gets rewritten on
upgrade, and a file that sorts later survives that.

The 30-second `systemd-networkd-wait-online` timeout in `apt-daily-upgrade.service` is
noise: the `ExecStartPre` line is prefixed with `-`, so a timeout cannot fail the unit.

## The blacklist

[`configs/apt/52-security-only.conf`](../configs/apt/52-security-only.conf) does two jobs:
it limits upgrades to the security origins, and it blacklists everything we froze.

```text
"linux-.*"  ".*nvidia.*"  "cuda-.*"  "libcuda.*"
"docker.*"  "containerd.*"  "dkms"
"fwupd.*"  "linux-firmware"  "dgx-spark-ota-update-meta"
"firmware-.*"  ".*-firmware.*"
```

The last three exist because a security update once pulled `fwupd` back to defaults and
re-opened the firmware path. Blacklisting the packages is the cheap way to keep that door
shut.

## Firmware: why it is frozen, and how

The October 2026 bundle (EC 3.13.7 / SoC 2.158.15 / PD 5.25) breaks fan control on these
units: the fan ceiling drops to roughly 4,350 rpm, the curve stops having any effect, and
the boxes run hot. There is no user-level workaround.

Three layers, all needed:

```sh
# 1. stop fwupd from refreshing metadata
sudo systemctl mask fwupd-refresh.service fwupd-refresh.timer

# 2. tell fwupd not to use the remote catalogue
#    /etc/fwupd/fwupd.conf → [fwupd] Enabled=false under the LVFS remote

# 3. block the update hosts at DNS
#    /etc/hosts: 0.0.0.0 fwupd.org 0.0.0.0 cdn.fwupd.org
```

Verify with `fwupdmgr get-updates` — it should report no updatable devices. Re-check after
every distro upgrade: the first two layers are the ones that get quietly reset.

## Manual patching, one node at a time

When a CVE is urgent, do not wait for the timer. Apply to one node, verify inference, then
the next:

```sh
# 1. snapshot what you are about to change
sudo mkdir -p /root/rollback-$(date +%Y%m%d) && \
  dpkg -l > /root/rollback-$(date +%Y%m%d)/versions-before.txt

# 2. security pocket only, explicit packages, keep config files
sudo apt-get install -y --only-upgrade --force-confold <packages>

# 3. verify
dpkg --audit
systemctl --failed
curl -sf http://<head>:8000/v1/models
```

Save the old `.deb` files from `/var/cache/apt/archives` into the rollback directory before
the cache rotates. Ubuntu does not keep superseded security versions in the pool, so a
package you did not save cannot be downgraded — plan for that before you need it.

## Monthly check

```sh
apt-get -s upgrade | grep -c '^Inst'          # how much is waiting
grep -c security /var/log/unattended-upgrades/unattended-upgrades.log
systemctl status apt-daily-upgrade.timer --no-pager
```

If the log has no recent entries, the `99zz` override is gone. That is the first thing to
check when "we patch automatically" stops being true.
