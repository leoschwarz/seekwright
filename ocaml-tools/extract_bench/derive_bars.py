"""Re-derive the recorded quality bar in [gen_fixtures.ml] from measured rows.

The bar is a regression floor, not an aspiration: it is written from what the
port's backend answers today, so a change that loses something fails a run, and
a change that wins something only moves the floor when an operator re-runs this
and commits the new number. This program is the instrument that moves it, in the
shape [tools/surface.py --write] has in the Python tree: it rewrites the numbers
in the source that owns them, and [gen_fixtures --check] fails anyone who edits
the corpus manifest without changing that source.

    .venv/bin/python ocaml-tools/extract_bench/derive_bars.py test/corpus_html \
        tmp/bench/ocaml.jsonl

The oracle's rows are read for the comparison table only. The bar the gate
enforces is the port's own: a floor the port clears by miles is not pinned, and
a floor another implementation cannot reach is still one the port has to keep.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

def measured_rows(paths: list[str]) -> dict[str, dict[str, object]]:
    """The port's own row per case, from the JSON [bench.exe --json] prints."""
    by_case: dict[str, dict[str, object]] = {}
    for path in paths:
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            if row["backend"] == "ocaml-stdlib":
                by_case[str(row["id"])] = row
    return by_case


def bar(measured: dict[str, object]) -> dict[str, object]:
    """The five bar fields, from the case's measured row.

    The title and unicode verdicts already carry the case's [title_rule] and
    [unicode] list, because [extract_metrics.ml] applies them before it writes a
    row, so re-deriving reads a row rather than re-deciding what the case asks.
    """
    # A time ceiling has to survive a loaded machine, so it is a multiple of the
    # measurement rather than the measurement itself: four times the median, over
    # a floor that covers the noise of a cold process. It catches a quadratic
    # blow-up on a big page; it is not a performance target.
    median_ms = float(measured["median_ms"])
    return {
        "bar_essential_min": int(measured["essential_hit"]),
        "bar_boiler_max": max(0, int(measured["boiler_hit"])),
        "bar_title_ok": bool(measured["title_ok"]),
        "bar_unicode_ok": bool(measured["unicode_ok"]),
        "bar_max_ms": max(25, int(median_ms * 4 + 25)),
    }


def patch_source(source: str, bars: dict[str, dict[str, object]]) -> tuple[str, int]:
    """Rewrite each case's bar fields in [gen_fixtures.ml]'s case table.

    A case record starts at its [id] field and ends where the next one starts, so
    the edit stays inside the record whose bar is being re-derived.
    """
    changed = 0
    out = source
    for cid, values in bars.items():
        start = out.find(f'      id = "{cid}";')
        if start < 0:
            print(f"derive_bars: no case {cid} in gen_fixtures.ml", file=sys.stderr)
            return out, changed
        end = out.find('      id = "', start + 1)
        block = out[start : end if end > 0 else len(out)]
        new_block = block
        for field, value in values.items():
            text = "true" if value is True else "false" if value is False else str(value)
            pattern = re.compile(rf"({re.escape(field)} = )(?:true|false|\d+)")
            new_block, n = pattern.subn(rf"\g<1>{text}", new_block, count=1)
            if n == 0:
                print(f"derive_bars: no {field} in the {cid} record", file=sys.stderr)
                return out, changed
        if new_block != block:
            out = out[:start] + new_block + out[end if end > 0 else len(out) :]
            changed += 1
    return out, changed


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: derive_bars.py <corpus-dir> <row-jsonl> [<more-jsonl>...]", file=sys.stderr)
        return 2
    corpus = Path(argv[1])
    manifest_path = corpus / "cases.json"
    generator = Path(__file__).with_name("gen_fixtures.ml")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    measured = measured_rows(argv[2:])
    missing = [str(c["id"]) for c in manifest["cases"] if str(c["id"]) not in measured]
    if missing:
        print(f"derive_bars: no measured row for {', '.join(missing)}", file=sys.stderr)
        return 1
    bars = {cid: bar(measured[cid]) for cid in measured}
    source, changed = patch_source(generator.read_text(encoding="utf-8"), bars)
    if changed:
        generator.write_text(source, encoding="utf-8")
    print(f"re-derived the bar for {changed} of {len(bars)} cases in {generator}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
