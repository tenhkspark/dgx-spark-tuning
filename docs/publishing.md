# Publishing checklist

The repository is push-ready. Creating the remote is a separate, explicit step — nothing
here runs `git push`.

## Before the first push

1. `gh auth status` — the account needs `repo` scope.
2. Personal-information scan over the worktree:

   ```sh
   grep -rInE '(192\.168\.|10\.[0-9]+\.[0-9]+\.|100\.[0-9]+\.[0-9]+\.[0-9]+|\.ts\.net|/Users/[a-z]+/|/home/[a-z]+/|gho_|github_pat_|sk-[A-Za-z0-9]|AKIA|xox[abp]-|BEGIN [A-Z ]*PRIVATE KEY)' .
   ```

   The only expected hit is the pattern line itself in this file. Everything else must
   be empty. Node names stay `head`/`node2`/`node3`/`node4`; hosts stay
   `sparkN.local` or `<host>`.
3. `git log --format='%an <%ae>%n%b'` — the author is the noreply identity, with no
   `Co-Authored-By`, session URLs or tool signatures.
4. `git remote -v` is empty.
5. Scripts parse and dry-run cleanly:

   ```sh
   for f in scripts/*.sh; do bash -n "$f"; done
   ./scripts/clock-floor.sh          # prints the unit, changes nothing
   ./scripts/fan-curve.sh            # dry run; needs the upstream controller present
   ```

6. Numbers in the README match `docs/` and were measured on the same four nodes.

## Create the remote (only when asked to publish)

```sh
gh repo create <owner>/dgx-spark-tuning --public --source=. --push \
  --description "Four-node DGX Spark cluster settings: 2500 MHz clock floor with no ceiling, quiet fan curve, 1M-token TP4 serving, delete-free cleanup, security-only patching, two watchdogs."
```

Verify by reading a file back over HTTPS,
e.g. `curl -s https://raw.githubusercontent.com/<owner>/dgx-spark-tuning/main/README.md | head -3`.

## Licence notes

- This repository is MIT. It contains our configuration, scripts and docs only.
- The fan curve is applied to a GPL-2.0 file at runtime; the patch itself lives in
  `dgx-spark-fan-tuning` (GPL-2.0). Keep the credit lines in `README.md` and
  `docs/thermal.md`.
- The serving engine is Apache-2.0 and is not redistributed here; we ship our JSON sample.
