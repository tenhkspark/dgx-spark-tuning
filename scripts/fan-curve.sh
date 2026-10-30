#!/usr/bin/env bash
# fan-curve.sh — replace PERFORMANCE_CURVE in the upstream DGX Spark fan controller.
#
#   ./fan-curve.sh                  # dry run: show what would change
#   sudo ./fan-curve.sh --apply     # back up, rewrite, restart the daemon
#
# Requires the upstream controller and daemon (christopherowen/dgx-spark-fan-control,
# GPL-2.0) installed at /usr/local/sbin/dgx-fan-control. Only the curve constant is
# touched; every other line stays upstream's.
set -euo pipefail

TARGET=${TARGET:-/usr/local/sbin/dgx-fan-control}
DAEMON=${DAEMON:-dgx-fan-daemon.service}
APPLY=0

for arg in "$@"; do
  case $arg in
    --apply) APPLY=1 ;;
    --target=*) TARGET=${arg#*=} ;;
    --daemon=*) DAEMON=${arg#*=} ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

[ -f "$TARGET" ] || { echo "not found: $TARGET (install the upstream controller first)" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }

python3 - "$TARGET" "$APPLY" <<'PY'
import datetime
import difflib
import pathlib
import re
import shutil
import sys

path = pathlib.Path(sys.argv[1])
apply_ = sys.argv[2] == "1"

curve = '''PERFORMANCE_CURVE = (
    (0.0, 1),    # 2,700 rpm floor - never state 0: on this firmware state 0 can mean 0 rpm
    (52.0, 2),   # 3,600
    (57.0, 3),   # 4,500
    (62.0, 4),   # 5,400
    (66.0, 5),   # 6,300
    (70.0, 6),   # 7,200
    (73.0, 8),   # 9,000
    (76.0, 10),  # 11,250 (fan 0 saturates at 9,000)
    (78.0, 12),  # 13,500 (both fans at their maximum)
)'''

src = path.read_text(encoding="utf-8")
pattern = re.compile(r"^PERFORMANCE_CURVE = \(.*?^\s*\)$", re.S | re.M)
m = pattern.search(src)
if not m:
    sys.exit("PERFORMANCE_CURVE not found - upstream layout changed; apply by hand")

def pairs(text):
    return re.findall(r"\(\s*([0-9.]+)\s*,\s*([0-9]+)\s*\)", text)

old = m.group(0)
if pairs(old) == pairs(curve):
    print("curve already matches (only comments differ); nothing to do")
    sys.exit(0)

new = src[: m.start()] + curve + src[m.end():]
diff = difflib.unified_diff(
    old.splitlines(True), curve.splitlines(True),
    fromfile="current", tofile="proposed",
)
sys.stdout.writelines(diff)

if not apply_:
    print("\ndry run: nothing changed. re-run with --apply.")
    sys.exit(0)

stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
backup = path.with_name(path.name + f".orig-{stamp}")
shutil.copy2(path, backup)
path.write_text(new, encoding="utf-8")
print(f"\nbackup: {backup}")
print(f"written: {path}")
PY

if [ "$APPLY" -eq 1 ]; then
  systemctl restart "$DAEMON"
  sleep 3
  systemctl is-active "$DAEMON"
  echo "-- current state (must never be 0) --"
  /usr/local/sbin/dgx-fan-control status || true
fi
