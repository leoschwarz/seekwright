"""The oracle's answer per corpus case, in the shape [digest_cases.exe --digest]
prints, so the two outputs diff.

The parity claim this serves: the port's stdlib backend and the oracle's stdlib
backend return the same bytes. [Digest.to_hex] in OCaml and [hashlib.md5] here
are the same function over the same bytes, so a matching line is byte-parity for
that case's text and title, and a differing line names the case to read.

    dune exec ocaml-tools/extract_bench/digest_cases.exe -- --digest test/corpus_html \
        > tmp/bench/ocaml_digest.txt
    .venv/bin/python ocaml-tools/extract_bench/py_digest.py test/corpus_html \
        > tmp/bench/python_digest.txt
    diff tmp/bench/ocaml_digest.txt tmp/bench/python_digest.txt
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from py_bench import load_cases  # noqa: E402

from seekwright.extractors.base import ExtractionFailed  # noqa: E402
from seekwright.extractors.stdlib import StdlibExtractor  # noqa: E402


def digest(value: str | None) -> str:
    return "-" if value is None else hashlib.md5(value.encode("utf-8")).hexdigest()


def main(argv: list[str]) -> int:
    backend = StdlibExtractor()
    for case in load_cases(argv[1]):
        try:
            result = backend.extract(case["body"], case["content_type"])
        except ExtractionFailed as exc:
            print(f"{case['id']:<26} refusal={exc}")
            continue
        print(
            f"{case['id']:<26} text={digest(result.text)} chars={result.total_chars} "
            f"title={digest(result.title)}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
