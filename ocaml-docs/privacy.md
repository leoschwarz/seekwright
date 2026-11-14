# Data, storage and backups (OCaml port)

The default deployment writes **nothing**. Two config keys turn the two writers
on, and each owns one path. Everything else this process touches is memory.

## What is on disk, and when

| Writer | Turned on by | What lands there | Mode |
| --- | --- | --- | --- |
| Usage journal | `[dashboard] history_path` | one append-only JSONL file, one line per call this server executed | `0644` |
| Fetch page cache | `[fetch] cache_dir` | extracted pages under one directory, with a small JSON meta record each | created by `Page_cache` through the Eio filesystem |
| Nothing else | — | no pid file, no state, no session store, no migrations | — |

`GET /healthz` reads none of it; the dashboard backfills once from the journal at
startup and then answers from memory, so the journal file is never read on the
serving path.

The journal's mode comes from the `~create:(\`If_missing 0o644)` at its
append-open site in `lib/usage.ml`; the file is opened, written and closed per
record, so a concurrent reader never sees a half line and no long-lived handle is
held.

There is **no search cache** — that is a decision, not a gap: every `search`
reaches a provider. `[fetch] cache_dir` is a page cache only, is off by default,
and its shape is bounded by three keys: `cache_ttl_seconds` (default 300),
`cache_max_entry_bytes` (default 33554432) and `cache_max_bytes` (default
268435456). It caches *extracted text*, never the upstream response body, so a
cache directory is not a copy of what a vendor sent you.

## What the journal contains

The journal is content-free by design: 37 fields across the three line kinds —
10 on a `search` line, 9 on a `fetch` line, 18 on an `answer` line — all timings,
provider, run id, result counts, cost and error class, and no query text, no URL
and no page content. `Usage` writes it and the dashboard reads it; both are the
same in-memory aggregates. The field list is pinned in
`ocaml-tools/surface.expected` ("Usage-journal fields") and in `journal_fields` in
`lib/server.ml`, so a new field is a deliberate change to the manifest.

A line appears for a call this server **executed**, a provider failure included —
a call it refused before dispatch writes nothing, so a 400 from naming a provider
this build did not compile leaves the file untouched. The file itself is created at
startup, because `Usage.create` opens it to prove the mount is writable; see
[`container.md`](container.md)'s section on mounts.

Query text and page content appear in logs only under the two explicit logging
switches, `[logging] log_queries` and `[logging] log_content`, and even then they
go to **stderr**, never into a file this process opened. Logs never carry a
traceback and never carry a secret: the discipline is enforced by an AST guard
(`test/log_guard/`), not by review.

Text that leaves the proxy goes through `sanitize_text`, which inserts one U+200B
after the opening delimiter of every model special-token literal, so a scraped
page cannot make a calling tokenizer reject the whole response. It is reversible
and idempotent.

## Backups and moves

The journal is a file you can copy:

```bash
cp "$history_path" "$history_path.$(date -u +%Y%m%d).jsonl"   # or: tar czf
```

Nothing needs to be in sync with it: the aggregates rebuild from the file at
startup, so a copy is a complete backup. Retention is not a knob —
`Usage` trims to `keep_days` (370) when it backfills, so the file stays
small without a cron job.

Under the container image, the config directory is the only thing worth a volume
(`/etc/seekwright`, read-only), and a journal only exists if you both set
`[dashboard] history_path` and mount the parent directory. See
[`container.md`](container.md).

## Wiping

```bash
rm -f "$history_path"          # usage history
rm -rf "$cache_dir"            # page cache
```

Both are safe at any time: the next start backfills from an empty journal and an
empty cache. There is no other state to clear, no key on disk (credentials come
from the environment only), and no cache an attacker could poison into a search
answer — searches are never served from a cache.

## Metrics endpoints

With `[dashboard] enabled = true` (the default) the HTTP server also serves
`GET /dashboard` (one self-contained HTML page), `GET /dashboard/data` and
`GET /dashboard/metrics` as JSON. Those three routes sit behind the same host and
origin guards as the rest of the API, and they answer 503 while the server is
draining.

`--metrics` is a separate mode, not a serving option: it prints the report and
exits, and is refused beside `--check`, `--live`, `--http`, `--host`, `--port` or
`--allowed-host`. `--json` narrows that report to machine-readable JSON and is
refused without `--metrics`. Both read the in-memory snapshot
(`Usage.snapshot`), so neither opens the journal file; the report's own
`journal` field says whether the journal is off or at what path.
