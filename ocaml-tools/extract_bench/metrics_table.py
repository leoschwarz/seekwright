"""The checked-in extraction table: [test/corpus_html/metrics.md].

Three backends over one corpus, in one table a reader can compare: the port's
[stdlib] backend, the Python oracle's [stdlib] backend, and the oracle's
[trafilatura] backend. It is an operator's run, not a gate step — [py_bench.py]
needs the Python venv, and a timing column is a property of the machine the run
happened on, which is why the header records that machine.

The rows come from the runners, and the runners are the only place the metrics
are defined: [bench.exe --json] writes the port's rows using [extract_metrics.ml]
— the same module the [dune runtest] gate uses — and [py_bench.py] writes the
oracle's rows with the same rules restated in Python for the oracle's own
backends. This program decides nothing: it aligns the rows case by case and
writes the table. That is deliberate. A table that recomputed verdicts would be a
third definition of [title_ok], and the one that a reader trusts.

    dune exec ocaml-tools/extract_bench/bench.exe -- --json test/corpus_html \
        > tmp/bench/ocaml.jsonl
    .venv/bin/python ocaml-tools/extract_bench/py_bench.py test/corpus_html \
        > tmp/bench/python.jsonl
    .venv/bin/python ocaml-tools/extract_bench/metrics_table.py \
        tmp/bench/ocaml.jsonl tmp/bench/python.jsonl
"""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
import sys
from datetime import date
from pathlib import Path

BACKENDS = ("ocaml-stdlib", "python-stdlib", "trafilatura")
COLUMNS = (
    ("backend", "backend"),
    ("id", "case"),
    ("category", "family"),
    ("bytes", "fixture B"),
    ("outcome", "answer"),
    ("essential", "essential"),
    ("boiler", "boiler"),
    ("title", "title"),
    ("unicode", "unicode"),
    ("chars", "codepoints"),
    ("repl", "U+FFFD"),
    ("ms", "median ms"),
)


def read_rows(paths: list[Path]) -> dict[str, dict[str, dict[str, object]]]:
    """Rows by case id and backend, from the JSON lines the runners print."""
    table: dict[str, dict[str, dict[str, object]]] = {}
    for path in paths:
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            table.setdefault(str(row["id"]), {})[str(row["backend"])] = row
    return table


def cell(row: dict[str, object], column: str) -> str:
    """One measured cell, in the shape a reader compares across backends."""
    if column == "backend":
        return str(row["backend"])
    if column == "id":
        return str(row["id"])
    if column == "category":
        return str(row["category"])
    if column == "bytes":
        return f"{row['bytes']}"
    if column == "outcome":
        # The answer's shape, from the row rather than from what the case asked:
        # a refusal, an empty page, or text.
        outcome = str(row["outcome"])
        return "refusal" if outcome.startswith("refusal") else (
            "empty" if row["codepoints"] == 0 else "text"
        )
    if column == "essential":
        return f"{row['essential_hit']}/{row['essential_total']}"
    if column == "boiler":
        return f"{row['boiler_hit']}/{row['boiler_total']}"
    if column == "title":
        return "ok" if row["title_ok"] else "-"
    if column == "unicode":
        return "-" if row["unicode_total"] == 0 else ("ok" if row["unicode_ok"] else "MISS")
    if column == "chars":
        return f"{row['codepoints']}"
    if column == "repl":
        return f"{row['replacements']}"
    if column == "ms":
        return f"{float(row['median_ms']):.2f}"
    raise KeyError(column)


def totals(rows: list[dict[str, object]]) -> dict[str, str]:
    """The figures the table is read for: what each backend kept and cost."""
    hit = sum(int(r["essential_hit"]) for r in rows)
    total = sum(int(r["essential_total"]) for r in rows)
    leaked = sum(int(r["boiler_hit"]) for r in rows)
    boiler = sum(int(r["boiler_total"]) for r in rows)
    title = sum(1 for r in rows if r["title_ok"])
    unicode_ok = sum(1 for r in rows if r["unicode_ok"] or int(r["unicode_total"]) == 0)
    chars = sum(int(r["codepoints"]) for r in rows)
    ms = sum(float(r["median_ms"]) for r in rows)
    answers = {
        "text": sum(1 for r in rows if r["outcome"] == "text" and int(r["codepoints"]) > 0),
        "refusal": sum(1 for r in rows if str(r["outcome"]).startswith("refusal")),
        "empty": sum(1 for r in rows if r["outcome"] == "text" and int(r["codepoints"]) == 0),
    }
    return {
        "backend": str(rows[0]["backend"]),
        "id": f"{len(rows)} cases",
        "category": "",
        "bytes": f"{sum(int(r['bytes']) for r in rows)}",
        "outcome": (
            f"{answers['text']}t/{answers['refusal']}r"
            if answers["refusal"]
            else f"{answers['text']}t"
        ),
        "essential": f"{hit}/{total}",
        "boiler": f"{leaked}/{boiler}",
        "title": f"{title}",
        "unicode": f"{unicode_ok}",
        "chars": f"{chars}",
        "repl": f"{sum(int(r['replacements']) for r in rows)}",
        "ms": f"{ms:.1f}",
    }


def provenance() -> list[str]:
    """Who ran this, where, and against what — the timing column needs it."""
    rev = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True
    ).stdout.strip()
    dirty = bool(
        subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True).stdout.strip()
    )
    versions = []
    try:  # the two oracle libraries the oracle rows were measured against
        import trafilatura  # type: ignore

        versions.append(f"trafilatura {trafilatura.__version__}")
    except Exception:
        versions.append("trafilatura (version unreadable)")
    return [
        f"Generated by [ocaml-tools/extract_bench/metrics_table.py] on {date.today().isoformat()}.",
        f"Tree {rev}{' (dirty)' if dirty else ''}; "
        f"{platform.system()} {platform.release()}, {platform.machine()}; "
        + "; ".join(versions)
        + f"; Python {platform.python_version()}.",
        "Timing is a property of that machine, not of the tree; the content columns are.",
        "The bar the gate enforces is per case in [cases.json]; this table is the",
        "measurement that bar was derived from, beside the two oracle backends.",
    ]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="metrics_table.py")
    parser.add_argument("rows", nargs="+", type=Path)
    parser.add_argument("--out", type=Path, default=Path("test/corpus_html/metrics.md"))
    args = parser.parse_args(argv[1:])

    table = read_rows(args.rows)
    order: list[str] = []
    for row in args.rows:
        for line in row.read_text(encoding="utf-8").splitlines():
            if line.strip():
                cid = str(json.loads(line)["id"])
                if cid not in order:
                    order.append(cid)

    widths = [len(label) for _, label in COLUMNS]
    rendered: list[list[str]] = []
    for cid in order:
        for backend in BACKENDS:
            row = table[cid].get(backend)
            if row is None:
                continue
            cells = [cell(row, key) for key, _ in COLUMNS]
            for i, c in enumerate(cells):
                widths[i] = max(widths[i], len(c))
            rendered.append(cells)
        for backend in BACKENDS:
            pass

    def line(cells: list[str]) -> str:
        return "| " + " | ".join(c.ljust(w) for c, w in zip(cells, widths)) + " |"

    out: list[str] = [
        "# Extraction corpus: the three backends measured",
        "",
        *[f"> {p}" for p in provenance()],
        "",
        "`essential` is the share of the page's essential phrases the answer holds;",
        "`boiler` is the furniture it leaked (lower is better); `codepoints` is the volume it",
        "returned; `U+FFFD` is what its decoder gave up on. `answer` is the shape of the",
        "reply: text, empty, or a named refusal.",
        "",
        line([label for _, label in COLUMNS]),
        line(["-" * w for w in widths]),
    ]
    for cells in rendered:
        out.append(line(cells))
    out.append("")
    out.append("## Totals, per backend")
    out.append("")
    by_backend: dict[str, list[dict[str, object]]] = {}
    for cid in order:
        for backend, row in table[cid].items():
            by_backend.setdefault(backend, []).append(row)
    out.append(line([label for _, label in COLUMNS]))
    out.append(line(["-" * w for w in widths]))
    for backend in BACKENDS:
        rows = by_backend.get(backend, [])
        if rows:
            out.append(line([totals(rows)[key] for key, _ in COLUMNS]))
    out.append("")

    args.out.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"wrote {args.out}: {len(rendered)} rows over {len(order)} cases")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
