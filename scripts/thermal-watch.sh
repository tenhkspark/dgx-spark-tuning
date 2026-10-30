#!/usr/bin/env bash
# thermal-watch.sh — watch heat and fan state across DGX Spark nodes.
#
#   ./thermal-watch.sh            # one pass; append an alert per real condition
#   ./thermal-watch.sh --check    # one pass; print readings, write nothing
#
# Node list: configs/nodes.txt ("name host" per line, first line is the head).
# Alerts go to alerts.log (or $ALERT_FILE). One alert per node per DEDUPE_SEC.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NODES_FILE=${NODES_FILE:-$ROOT/configs/nodes.txt}
ALERT_FILE=${ALERT_FILE:-$ROOT/alerts.log}
STATE_DIR=${STATE_DIR:-$ROOT/state}
ACPI_LIMIT=${ACPI_LIMIT:-78}
GPU_LIMIT=${GPU_LIMIT:-75}
DEDUPE_SEC=${DEDUPE_SEC:-1800}
SSH="ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

[ -r "$NODES_FILE" ] || { echo "missing node list: $NODES_FILE" >&2; exit 1; }
mkdir -p "$STATE_DIR"
now=$(date +%s)
exit_code=0

while read -r name host _; do
  case "$name" in ''|'#'*) continue ;; esac
  [ -n "${host:-}" ] || continue

  out=$($SSH "$host" '
    gpu=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d " ")
    acpi=$(for z in /sys/class/thermal/thermal_zone*/temp; do [ -r "$z" ] && echo $(( $(cat "$z" 2>/dev/null) / 1000 )); done | sort -rn | head -1)
    fan=$(sudo -n /usr/local/sbin/dgx-fan-control status 2>/dev/null | sed -n "s/^state=\([0-9]*\)\/.*/\1/p")
    if [ ! -x /usr/local/sbin/dgx-fan-control ]; then
      echo "${gpu:-NA} ${acpi:-NA} nofan"
    else
      echo "${gpu:-NA} ${acpi:-NA} ${fan:-NA}"
    fi
  ' 2>/dev/null)

  if [ -z "$out" ]; then
    echo "$name: unreachable"
    exit_code=1
    continue
  fi

  read -r gpu acpi fan <<< "$out"

  reason=""
  case "$acpi" in ''|*[!0-9]*) ;; *) [ "$acpi" -ge "$ACPI_LIMIT" ] && reason="acpi ${acpi}C" ;; esac
  case "$gpu" in ''|*[!0-9]*) ;; *) [ "$gpu" -ge "$GPU_LIMIT" ] && reason="${reason:+$reason / }gpu ${gpu}C" ;; esac
  case "$fan" in
    ''|*[!0-9]*) reason="${reason:+$reason / }fan state unreadable" ;;
    *) [ "$fan" -eq 0 ] && reason="${reason:+$reason / }fan 0 rpm (EC or daemon)" ;;
  esac

  if [ -z "$reason" ]; then
    echo "$name: gpu=${gpu}C acpi=${acpi}C fan=${fan} ok"
    continue
  fi

  echo "$name: gpu=${gpu}C acpi=${acpi}C fan=${fan} ALERT: $reason"
  exit_code=1
  if [ "$CHECK_ONLY" -eq 1 ]; then
    continue
  fi

  last_file="$STATE_DIR/$name.last"
  if [ -r "$last_file" ]; then
    last=$(cat "$last_file" 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -lt "$DEDUPE_SEC" ]; then
      echo "  (deduped, last alert $((now - last))s ago)"
      continue
    fi
  fi

  printf '%s %s gpu=%s acpi=%s fan=%s %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$gpu" "$acpi" "$fan" "$reason" >> "$ALERT_FILE"
  printf '%s\n' "$now" > "$last_file"
done < "$NODES_FILE"

exit "$exit_code"
