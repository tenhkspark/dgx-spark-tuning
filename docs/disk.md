# Disk and logs: move, never delete

Four nodes hold a lot of weights, images and logs, and the easy cleanup command is the
dangerous one. The rules below are what we actually follow.

## Rule 1: `rm` is not a cleanup tool

Everything goes to a trash directory with a timestamp, so a wrong call is recoverable
until you empty it yourself:

```sh
./scripts/trash.sh ~/models/old-checkpoint ~/logs/run-0912.log
```

On Linux the script uses `gio trash` (the desktop trash, with `trashinfo` so the restore
path is recorded). If `gio` is missing it falls back to `~/.local/share/Trash/files` plus a
matching `.trashinfo`.

## Rule 2: logs survive the restart

A recreated container discards its json-file log. The crash you are trying to debug is
then gone, and you get to debug a clean restart instead. Copy logs out *before* any stop:

```sh
docker logs --tail 5000 <container> > ~/logs/<container>-$(date -u +%Y%m%dT%H%M%SZ).log
```

Do this for every node in the cluster, not just the head: the interesting failure is
almost always on a worker.

## Rule 3: one month unused means "candidate", not "delete"

A simple inventory keeps the decision objective:

```sh
# name, size, last used file time — one line per weight directory
find ~/models ~/.cache/huggingface/hub -maxdepth 2 -mindepth 1 -type d \
  -printf '%TY-%Tm-%Td %12k KB %p\n' | sort -k1,1
```

Anything untouched for 30 days is a deletion *candidate*. Deleting still needs a person's
decision, because weights are expensive to fetch and impossible to guess at later.

Two traps we hit:

- **Hugging Face cache stubs.** A snapshot directory can be a few MB of symlinks pointing
  into `blobs/`. Deleting the snapshot does nothing; deleting `blobs/` breaks neighbouring
  models that share the store. Check `du -sh` on the blob, not the snapshot.
- **Shared blobs.** Two models can share the same blob set. Remove both or neither.

## Rule 4: do not prune what is running

`docker system prune` looks harmless and is not: it can take the image the cluster is
about to restart into. List first, prune by exact ID, and never prune while a start is in
flight.

```sh
docker images --format '{{.ID}}\t{{.Repository}}:{{.Tag}}\t{{.Size}}' | sort -k3 -h
```

## What did not work

Dropping page cache for memory pressure returned about 200 MB and was measured to be
useless; we removed the cron job instead of keeping a ritual. If memory is tight, the
answer is fewer concurrent sequences or a smaller KV pool, not `echo 3 > drop_caches`.

## Where the space actually goes

Weights first, container images second, logs third. Logs are the only category you can
delete without losing capability, and they are also the only category you will want after
an incident — which is why they get copied out and rotated, not removed in a panic.
