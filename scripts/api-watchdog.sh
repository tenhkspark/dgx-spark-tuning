#!/usr/bin/env bash
# api-watchdog.sh — restart the cluster only when the API and the containers are both dead.
#
#   ./api-watchdog.sh            # one pass; restart if the evidence says so
#   ./api-watchdog.sh --check    # one pass; print the decision, act on nothing
#
# Environment:
#   HEAD_URL     default http://127.0.0.1:8000/v1/models
#   NODES_FILE   default configs/nodes.txt (first line is the head)
#   CONTAINER    default spark-ds41f
#   RESTART_CMD  command that starts the cluster (empty = log only, never restart)
#   STATE_DIR    default state/
#   MISS_LIMIT   default 3        COOLDOWN_SEC default 1800
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HEAD_URL=${HEAD_URL:-http://127.0.0.1:8000/v1/models}
NODES_FILE=${NODES_FILE:-$ROOT/configs/nodes.txt}
CONTAINER=${CONTAINER:-spark-ds41f}
RESTART_CMD=${RESTART_CMD:-}
STATE_DIR=${STATE_DIR:-$ROOT/state}
MISS_LIMIT=${MISS_LIMIT:-3}
COOLDOWN_SEC=${COOLDOWN_SEC:-1800}
SSH="ssh -n -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

[ -r "$NODES_FILE" ] || { echo "missing node list: $NODES_FILE" >&2; exit 1; }
mkdir -p "$STATE_DIR"
MISS_FILE="$STATE_DIR/api.miss"
COOLDOWN_FILE="$STATE_DIR/api.cooldown"
STOP_FILE="$STATE_DIR/api-watchdog.stop"
LOG="$STATE_DIR/api-watchdog.log"

note() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >> "$LOG"
}

probe_head() {
  curl -sf -m 10 "$HEAD_URL" >/dev/null 2>&1 && echo ok || echo down
}

probe_from() { # second opinion from another node
  local host=$1 rc
  $SSH "$host" "curl -sf -m 10 '$HEAD_URL' >/dev/null" 2>/dev/null
  rc=$?
  case $rc in
    0) echo ok ;;
    255) echo unknown ;;
    *) echo down ;;
  esac
}

running_containers() { # prints "running total" and the offline names
  local n=0 total=0 down="" name host state
  while read -r name host _; do
    case "$name" in ''|'#'*) continue ;; esac
    total=$((total + 1))
    state=$($SSH "$host" "docker inspect -f '{{.State.Running}}' '$CONTAINER' 2>/dev/null" 2>/dev/null)
    if [ "$state" = "true" ]; then
      n=$((n + 1))
    else
      down="$down $name"
    fi
  done < "$NODES_FILE"
  printf '%s %s%s\n' "$n" "$total" "$down"
}

head=$(probe_head)
read -r up total down <<< "$(running_containers)"

if [ "$head" = ok ] && [ "$up" -eq "$total" ]; then
  echo 0 > "$MISS_FILE"
  note "ok head=$head containers=$up/$total"
  exit 0
fi

miss=$(cat "$MISS_FILE" 2>/dev/null || echo 0)
case "$miss" in ''|*[!0-9]*) miss=0 ;; esac
miss=$((miss + 1))
echo "$miss" > "$MISS_FILE"
note "degraded head=$head containers=$up/$total${down:+ down:$down} miss=$miss/$MISS_LIMIT"

if [ "$miss" -lt "$MISS_LIMIT" ]; then
  exit 1
fi

# Second opinion: is it the cluster, or is it this watchdog's network?
second_host=$(awk '$1 !~ /^#/ && NF >= 2 {print $2}' "$NODES_FILE" | sed -n '2p')
if [ -n "$second_host" ] && [ "$second_host" != "$(awk '$1 !~ /^#/ && NF >= 2 {print $2}' "$NODES_FILE" | sed -n '1p')" ]; then
  opinion=$(probe_from "$second_host")
  note "second opinion from $second_host: $opinion"
  if [ "$opinion" = ok ]; then
    echo 0 > "$MISS_FILE"
    note "not restarting: another node can reach the API; fix this watchdog's path instead"
    exit 1
  fi
else
  note "no second node available; relying on the local probe"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  note "check mode: would restart (RESTART_CMD=${RESTART_CMD:-unset})"
  exit 1
fi

if [ -f "$STOP_FILE" ]; then
  note "not restarting: stop file $STOP_FILE present"
  exit 1
fi

if [ -z "$RESTART_CMD" ]; then
  note "not restarting: RESTART_CMD is unset (log-only mode)"
  exit 1
fi

if [ -r "$COOLDOWN_FILE" ]; then
  last=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  age=$(( $(date +%s) - last ))
  if [ "$age" -lt "$COOLDOWN_SEC" ]; then
    note "not restarting: cooldown, ${age}s of ${COOLDOWN_SEC}s elapsed"
    exit 1
  fi
fi

note "restarting: $RESTART_CMD"
if bash -c "$RESTART_CMD" >> "$LOG" 2>&1; then
  note "restart command returned 0"
else
  note "restart command failed: rc=$?"
fi
date +%s > "$COOLDOWN_FILE"
echo 0 > "$MISS_FILE"
