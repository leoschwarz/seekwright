"""The oracle half of the F6.2 extraction benchmark.

Runs the two Python backends — ``seekwright.extractors.stdlib`` and
``seekwright.extractors.trafilatura`` — over the corpus in
[test/corpus_html/] and prints one metric row per case, in the same JSON shape
[bench.ml] writes, so [metrics_table.py] can put the three backends side by side.

This is an operator command, not a gate step: it needs the Python venv, and it
measures time and memory, which are properties of a machine rather than of a
tree. The metrics are copied from [extract_metrics.ml] name for name — same
whitespace tolerance, same codepoint counting, same median-of-runs — because a
comparison between backends is only worth making when the numbers mean the same
thing on both sides.

Run it with the checkout's own interpreter, the one that carries the oracle and
its extras::

    .venv/bin/python ocaml-tools/extract_bench/py_bench.py test/corpus_html
"""

from __future__ import annotations

import json
import os
import re
import statistics
import sys
import time

from seekwright.extractors.base import ExtractionFailed
from seekwright.extractors.stdlib import StdlibExtractor
from seekwright.extractors.trafilatura import TrafilaturaExtractor

_WS_RUNS = re.compile(r"[ \t\r\n\f]+")


def collapse(text: str) -> str:
    return _WS_RUNS.sub(" ", text).strip()


def contains(haystack: str, needle: str) -> bool:
    needle = collapse(needle)
    if not needle:
        return True
    return needle in collapse(haystack)


def count_hits(haystack: str, needles: list[str]) -> int:
    return sum(1 for needle in needles if contains(haystack, needle))


def misses(haystack: str, needles: list[str]) -> list[str]:
    return [needle for needle in needles if not contains(haystack, needle)]


def codepoints(text: str) -> int:
    return len(text)


def replacement_chars(text: str) -> int:
    return text.count("\ufffd")


def load_cases(directory: str) -> list[dict]:
    with open(os.path.join(directory, "cases.json"), encoding="utf-8") as handle:
        manifest = json.load(handle)
    cases = []
    for case in manifest["cases"]:
        fixture = case.get("file") or case["id"]
        with open(os.path.join(directory, "fixtures", fixture), "rb") as handle:
            case["body"] = handle.read()
        cases.append(case)
    return cases


def run_one(backend, body: bytes, content_type: str | None):
    """The backend's answer, or the refusal, in the same shape as the OCaml side."""
    try:
        result = backend.extract(body, content_type)
    except ExtractionFailed as exc:
        return "refusal", str(exc), None, 0
    return "text", result.text, result.title, result.total_chars


def time_extract(backend, body: bytes, content_type: str | None, runs: int) -> float:
    """Median milliseconds over [runs] runs — same rule as [bench.ml]'s."""
    samples = []
    for _ in range(runs):
        start = time.perf_counter()
        try:
            backend.extract(body, content_type)
        except ExtractionFailed:
            pass
        samples.append((time.perf_counter() - start) * 1000.0)
    return statistics.median(samples)


def row_of(backend, name: str, case: dict) -> dict:
    body = case["body"]
    content_type = case.get("content_type")

    outcome, text, title, total = run_one(backend, body, content_type)
    outcome2, text2, title2, _ = run_one(backend, body, content_type)
    deterministic = text == text2 and title == title2

    if outcome == "refusal":
        outcome = f"refusal:{text}"
        text = ""

    expected_title = case.get("title")
    rule = case.get("title_rule", "exact")
    if rule == "none":
        title_ok = title is None or expected_title is None
    elif rule == "any":
        title_ok = title is not None
    else:
        title_ok = title is not None and expected_title is not None and collapse(title) == collapse(expected_title)

    unicode_list = case.get("unicode", [])
    both = text + "\n" + (title or "")
    return {
        "backend": name,
        "id": case["id"],
        "fixture": case.get("file") or case["id"],
        "category": case.get("category", ""),
        "kind": case.get("kind", "html"),
        "expect": case.get("expect", "text"),
        "outcome": outcome,
        "outcome_matches_expect": case.get("expect", "text") == outcome,
        "essential_hit": count_hits(both, case.get("essential", [])),
        "essential_total": len(case.get("essential", [])),
        "boiler_hit": count_hits(both, case.get("boilerplate", [])),
        "boiler_total": len(case.get("boilerplate", [])),
        "title_ok": title_ok,
        "unicode_ok": all(contains(both, u) for u in unicode_list),
        "unicode_total": len(unicode_list),
        "deterministic": deterministic,
        "essential_missed": misses(both, case.get("essential", [])),
        "boiler_missed": misses(both, case.get("boilerplate", [])),
        "codepoints": codepoints(text),
        "bytes": len(body),
        "replacements": replacement_chars(text),
        "median_ms": round(time_extract(backend, body, content_type, runs=5), 3),
    }


def main(argv: list[str]) -> int:
    directories = [a for a in argv[1:] if not a.startswith("--")]
    if len(directories) != 1:
        print("usage: py_bench.py <corpus-dir>", file=sys.stderr)
        return 2
    cases = load_cases(directories[0])
    if not cases:
        print("py_bench: the corpus manifest named no cases", file=sys.stderr)
        return 1
    backends = [("python-stdlib", StdlibExtractor()), ("trafilatura", TrafilaturaExtractor())]
    for name, backend in backends:
        for case in cases:
            print(json.dumps(row_of(backend, name, case), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
