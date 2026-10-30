#!/usr/bin/env bash
# checks.sh — fail on secrets, personal identifiers, broken relative links or bad bash.
# Runs in CI and by hand: ./scripts/checks.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
note() { printf '%s\n' "$*"; }

note "== secrets and personal identifiers =="
hits=$(grep -rInE \
  '(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[abp]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' \
  --exclude-dir=.git --exclude-dir=.github . 2>/dev/null)
if [ -n "$hits" ]; then note "$hits"; note "FAIL: possible secret"; fail=1; else note "no secrets found"; fi

hits=$(grep -rInE '(192\.168\.[0-9]+\.[0-9]+|100\.[0-9]+\.[0-9]+\.[0-9]+|[A-Za-z0-9-]+\.ts\.net|/Users/[a-z]+/|/home/[a-z]+/)' \
  --exclude-dir=.git --exclude-dir=.github . 2>/dev/null | grep -v 'scripts/checks.sh')
if [ -n "$hits" ]; then note "$hits"; note "FAIL: personal or internal identifier"; fail=1; else note "no personal identifiers"; fi

note "== bash syntax =="
for f in scripts/*.sh; do
  if bash -n "$f"; then note "ok $f"; else note "FAIL $f"; fail=1; fi
done

note "== relative links =="
python3 - <<'PY' || fail=1
import pathlib, re, sys
bad = []
for md in pathlib.Path(".").rglob("*.md"):
    if ".git" in md.parts:
        continue
    for m in re.finditer(r"\]\(([^)#]+)(#[^)]*)?\)", md.read_text(encoding="utf-8", errors="replace")):
        target = m.group(1)
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        p = (md.parent / target).resolve()
        if not p.exists():
            bad.append(f"{md}: {target}")
if bad:
    print("\n".join(bad))
    print("FAIL: broken relative links")
    sys.exit(1)
print("all relative links resolve")
PY

if [ "$fail" -ne 0 ]; then
  note "== checks failed =="
  exit 1
fi
note "== all checks passed =="
