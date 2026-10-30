#!/usr/bin/env bash
# clock-floor.sh — hold a GPU clock floor on a DGX Spark (GB10) across reboots.
#
#   ./clock-floor.sh                 # dry run: print the unit and the exact command
#   sudo ./clock-floor.sh --apply    # install, enable and apply now
#   sudo ./clock-floor.sh --apply --floor=2400
#
# Deliberately no ceiling: a clock cap costs prefill. Heat is the fan curve's job.
set -euo pipefail

FLOOR=${FLOOR:-2500}
APPLY=0

for arg in "$@"; do
  case $arg in
    --apply) APPLY=1 ;;
    --floor=*) FLOOR=${arg#*=} ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

case $FLOOR in ''|*[!0-9]*) echo "floor must be an integer MHz value" >&2; exit 2 ;; esac
command -v nvidia-smi >/dev/null || { echo "nvidia-smi not found" >&2; exit 1; }

MAX=$(nvidia-smi --query-gpu=clocks.max.sm --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
if [ -z "$MAX" ] || [ "$MAX" -le "$FLOOR" ]; then
  echo "cannot use floor ${FLOOR}: hardware max reads '${MAX}'" >&2
  exit 1
fi

UNIT_PATH=/etc/systemd/system/gpu-clock-floor.service
UNIT=$(cat <<EOF
[Unit]
Description=DGX Spark GPU clock floor (${FLOOR} MHz, no ceiling)
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service
ConditionPathExists=/usr/bin/nvidia-smi

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'M=\$(/usr/bin/nvidia-smi --query-gpu=clocks.max.sm --format=csv,noheader,nounits | head -1 | tr -d " "); [ -n "\$M" ] || M=${MAX}; for i in \$(seq 1 30); do /usr/bin/nvidia-smi -lgc ${FLOOR},\$M && exit 0; sleep 2; done; exit 1'

[Install]
WantedBy=multi-user.target
EOF
)

echo "== floor ${FLOOR} MHz, ceiling ${MAX} MHz (hardware maximum, not a cap) =="
echo
echo "$UNIT"
echo

if [ "$APPLY" -eq 0 ]; then
  echo "dry run: nothing changed. re-run with --apply to install ${UNIT_PATH}."
  exit 0
fi

tmp=$(mktemp)
printf '%s\n' "$UNIT" > "$tmp"
sudo install -m 0644 "$tmp" "$UNIT_PATH"
rm -f "$tmp"

sudo systemctl daemon-reload
sudo systemctl enable --now gpu-clock-floor.service

echo
systemctl status gpu-clock-floor --no-pager -n 5 || true
echo
nvidia-smi --query-gpu=clocks.sm,clocks.max.sm,power.draw,temperature.gpu --format=csv
