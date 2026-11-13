"""Dump one case through each oracle backend, for reading beside the OCaml dump.

    .venv/bin/python ocaml-tools/extract_bench/dump_case.py test/corpus_html article-plain

The OCaml side is [bench.exe --case <id>]; this is the same print on the oracle
side, so a row in the metric table that shows two backends disagreeing can be
explained by reading the two extractions against each other.
"""

from __future__ import annotations

import json
import sys

from seekwright.extractors.stdlib import StdlibExtractor
from seekwright.extractors.trafilatura import TrafilaturaExtractor

BACKENDS = {"stdlib": StdlibExtractor, "trafilatura": TrafilaturaExtractor}


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: dump_case.py <corpus-dir> <case-id> [backend...]", file=sys.stderr)
        return 2
    directory, case_id = argv[1], argv[2]
    names = argv[3:] or list(BACKENDS)
    with open(f"{directory}/cases.json", encoding="utf-8") as handle:
        cases = {c["id"]: c for c in json.load(handle)["cases"]}
    case = cases.get(case_id)
    if case is None:
        print(f"dump_case: no case {case_id}", file=sys.stderr)
        return 1
    with open(f"{directory}/fixtures/{case.get('file') or case_id}", "rb") as handle:
        body = handle.read()
    for name in names:
        backend = BACKENDS[name]()
        print(f"===== {name} =====")
        try:
            result = backend.extract(body, case["content_type"])
        except Exception as exc:  # noqa: BLE001 - the refusal is the answer here
            print(f"--- refusal ---\n{exc}")
            continue
        print(f"--- title ---\n{result.title}")
        print(f"--- text ---\n{result.text}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
