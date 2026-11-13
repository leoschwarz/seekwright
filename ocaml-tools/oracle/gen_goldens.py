"""Pin the goldens under ``test/differential/golden/``.

For every corpus input, run the Python projection (the oracle answer, from
``projections.py``) and the OCaml projection (``drive.exe`` over the same
directory), and write one golden file per case:

- the two agree  -> ``verification: differential-golden`` with just the
  ``--- oracle`` section;
- they differ    -> the (area, case) must be listed in ``DIVERGENCES`` with a
  reason, and the golden pins both sides: ``--- oracle`` and ``--- port``. The
  runner then requires the port to keep producing its pinned section *and* to
  still disagree with the oracle, so a divergence that silently closes flips
  the suite too.

An unregistered mismatch is an error, never a silent golden: the decision to
accept a divergence is made here, in the open, and lands in the golden's
``reason`` line.

Run from the repository root:

    dune build test/differential/drive.exe
    python3 ocaml-tools/oracle/gen_goldens.py [area ...]
"""

from __future__ import annotations

import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import projections

from seekwright.config import KNOWN_PROVIDERS, api_key_env_var

CORPUS = ROOT / "test" / "differential" / "corpus"
GOLDEN = ROOT / "test" / "differential" / "golden"
DRIVE = ROOT / "_build" / "default" / "test" / "differential" / "drive.exe"

_ILL_FORMED_STEP_REASON = (
    "the oracle decodes the corpus with Python's utf-8 and errors='replace', which spends one U+FFFD per "
    "maximal ill-formed subsequence; lib/text/utf8.ml's next_index steps by the lead byte's nominal width "
    "and only clamps at the end of the string, without checking that the continuation bytes follow, so the "
    "codepoint count differs. This is a lib/text defect pinned rather than fixed (lib/** is outside this "
    "corpus's ownership): every walk that consumes it — count, take, slices, strip, words, lines, roundtrip — "
    "inherits it, and the cases below are the ones that reach it."
)

_ILL_FORMED_ROUNDTRIP_REASON = (
    "the same step as text/10, seen through decode-and-re-encode: of_string reads this lead and the two bytes "
    "after it as one three-byte codepoint, so the round trip does not return the input bytes, while the oracle's "
    "errors='replace' form is lossy but stable. Pinned to say in the open that the port is not byte-identical on "
    "ill-formed input; the sentence is the port's behaviour, not a target."
)

_TRAILING_LINE_REASON = (
    "splitlines appends the tail after every break, so a string ending in a break gains a final empty line; "
    "Python's str.splitlines() drops it ('a\\nb\\n' is two lines, not three). test/test_text.ml pins the port's "
    "reading as intended and utf8.mli's doc-comment claims Python parity — the comment is what is wrong, and the "
    "behaviour is the port's. lib/** is outside this corpus's ownership, so the difference is pinned and raised."
)

_LONE_CR_REASON = (
    "is_line_boundary deliberately omits CR, which test/test_text.ml and utf8.mli both record as load-bearing for "
    "the fetch path's CSV reader (it refuses a bare carriage return itself, which it can only see if the split "
    "leaves it in). Python's str.splitlines() breaks on CR and treats CRLF as one break, so the CRLF line keeps "
    "its CR here and a lone CR does not break at all."
)

_NON_PRINTABLE_REPR_REASON = (
    "py_repr passes every non-ASCII codepoint through as its UTF-8 bytes by design (a log line is read by a "
    "machine that keeps UTF-8, and rewriting a printable would hide what the page said), where Python's repr "
    "escapes a non-printable such as U+00A0 or U+200B. The port's rule is the contract and the two reprs are not "
    "interchangeable on non-printable non-ASCII; pinned so the boundary is measured, not assumed."
)

_MALFORMED_SANITIZE_REASON = (
    "the oracle projection must read the corpus through a text decode (its sanitizer takes str), so an "
    "ill-formed byte arrives as U+FFFD before the escape pass runs; the port's sanitizer is byte-faithful and "
    "passes the original bytes through. The pass itself agrees on every case the walk does not touch: same "
    "count, same idempotence, same reversibility. The bytes reach the two sanitizers differently, not the rule."
)

_WINDOW_NEGATIVE_REASON = (
    "not reachable through the tool surface — Model.fetch_request_of_yojson checks offset ≥ 0 and max_chars is "
    "the config constant (Default or Uncapped) — so this pins Fetcher.window_text's own boundary. Python's slice "
    "clamps or wraps a negative index: the oracle answers text taken from the end (negative offset) or a window "
    "at least partly past the end (negative cap). The port raises Invalid_argument from Array.sub on a negative "
    "offset and returns an empty window on a negative cap. Recorded as a library-boundary difference, raised in "
    "the plan rather than fixed: lib/** is outside this corpus's ownership."
)

_TRAILING_CELL_REASON = (
    "lib/fetch/tabledoc.ml's reader loses a field that is empty and last in its record: the delimiter switches to "
    "Start_field without saving, and the newline's save only happens when a byte had been read, so the trailing "
    "empty cell never reaches the header and the width follows it. Python's csv yields the empty trailing cell, "
    "so the oracle renders a third column named column3 that the port does not have. The row is padded to the "
    "header's width either way, so a file whose every line ends with a delimiter loses its last column silently "
    "rather than failing — which is why this is pinned and raised instead of normalised away."
)

_TOML_WIDE_INT_REASON = (
    "the port's TOML reader holds an integer in an OCaml int, 63 bits, and reports a value it cannot represent "
    "as invalid TOML; Python's tomllib keeps arbitrary precision and the loader accepts the document because "
    "policy.max_snippet_chars has no upper bound. The port refuses rather than truncates, so this is a capability "
    "limit stated in the wrong sentence ('invalid TOML' for a valid file) — lib/config.ml is outside this corpus's "
    "ownership, so it is pinned and raised."
)

_TOML_SUBSET_REASON = (
    "the port's TOML reader implements a subset of TOML 1.0: a hexadecimal integer (0x10) and the nan/inf float "
    "spellings are valid and tomllib reads them, while the port answers PARSE-ERR for the whole file. A parser gap "
    "in lib/config.ml, outside this corpus's ownership; pinned so the subset is measured instead of assumed. The "
    "same file with a decimal spelling is a passing case beside it."
)

_WIDE_INT_MODEL_REASON = (
    "pydantic holds a Python int of any width and FetchRequest.offset has no upper bound, so a 2**70 offset is "
    "accepted and re-encoded exactly; the port's decoder accepts a Yojson Int (or an integral Float) only and "
    "reports Intlit as a type error, so the same body is refused. Refusing is honest at a 63-bit int, but the "
    "sentence ('expected an integer, got an integer') is not — pinned and raised for the port's model layer."
)

_DUPLICATE_KEY_REASON = (
    "a body with a duplicate key has no single value: Python's json.loads keeps the last value under the first "
    "position, so the oracle re-encodes the second url/query/score; Yojson keeps both members and every lookup in "
    "the port resolves the first, so its wire object names the first. Both trees accept the body — this is a "
    "decoder difference on an ambiguous document, recorded rather than normalised, because a caller can use it to "
    "show a validator one value and the response another."
)

_REPR_IN_REFUSAL_REASON = (
    "the same repr rule as text/43, surfacing in a refusal sentence: the router quotes the requested name back "
    "through py_repr, Python's repr escapes the zero-width space as \\u200b while the port passes the codepoint "
    "through and the projection's escape renders it as \\u200b too — so the two sentences differ by one backslash. "
    "Same verdict, same wording otherwise; the difference is the repr's non-printable rule."
)

# Accepted divergences, keyed by (area, case): the reason the two trees answer
# differently and why that is fine rather than a bug to chase. Every mismatch
# must appear here, or be classifiable by one of the two systematic rules
# below, or regeneration stops. An unexplained mismatch is never a silent
# golden.
DIVERGENCES: dict[tuple[str, str], str] = {
    (
        "sanitize",
        "09-lone-continuation",
    ): _MALFORMED_SANITIZE_REASON,
    ("sanitize", "22-malformed-mid"): _MALFORMED_SANITIZE_REASON,
    ("sanitize", "23-malformed-overlong"): _MALFORMED_SANITIZE_REASON,
    ("fetch", "43-window-offset-negative"): _WINDOW_NEGATIVE_REASON,
    ("fetch", "44-window-cap-negative"): _WINDOW_NEGATIVE_REASON,
    (
        "fetch",
        "08-url-port-range",
    ): "both trees refuse http://example.com:99999/; the sentence quotes each implementation's own parser (urlsplit's wording vs the port's rule stated in its own words). The verdict is the contract, and it agrees.",
    (
        "fetch",
        "09-url-port-word",
    ): "same as fetch/08 on a non-numeric port: refusal on both sides, wording is each parser's own.",
    (
        "config",
        "49-doc-example",
    ): "the documented example names fetch.extractor = \"trafilatura\" explicitly; the port ships one backend and refuses that name outright, where the oracle accepts it when the library is installed. The same P6 backend gap as the systematic extractor default divergence, visible here in the acceptance rather than the default.",
    (
        "model",
        "01-model-result",
    ): "pydantic's lax mode coerces the string \"0.5\" to a float and accepts the body; the port's decoder refuses string-to-number coercion. Both verdicts pinned so the gap is on the record, not in a comment.",
    (
        "model",
        "03-model-fetch-response",
    ): "the same coercion gap as model/01 on a different field: pydantic turns \"200\" into the int 200, the port's decoder refuses it. The refusal sentences themselves are not pinned (accepted difference: pydantic reports a structured error list, the port states one sentence).",
    ("tabledoc", "17-csv-trailing-delimiter"): _TRAILING_CELL_REASON,
    ("config", "86-int-past-int63"): _TOML_WIDE_INT_REASON,
    ("config", "87-int-huge"): _TOML_WIDE_INT_REASON,
    ("config", "89-int-hex"): _TOML_SUBSET_REASON,
    ("config", "93-float-nan"): _TOML_SUBSET_REASON,
    ("config", "94-float-inf"): _TOML_SUBSET_REASON,
    ("router", "08-search-unicode-request"): _REPR_IN_REFUSAL_REASON,
    ("model", "06-model-extremes"): _WIDE_INT_MODEL_REASON,
    ("model", "07-model-duplicate-keys"): _DUPLICATE_KEY_REASON,
    ("text", "10-count-lead-then-ascii"): _ILL_FORMED_STEP_REASON,
    ("text", "11-count-overlong"): _ILL_FORMED_STEP_REASON,
    ("text", "12-count-surrogate"): _ILL_FORMED_STEP_REASON,
    ("text", "30-lines-lf"): _TRAILING_LINE_REASON,
    ("text", "31-lines-trailing-break"): _TRAILING_LINE_REASON,
    ("text", "32-lines-crlf"): _LONE_CR_REASON,
    ("text", "33-lines-lone-cr"): _LONE_CR_REASON,
    ("text", "43-repr-nbsp"): _NON_PRINTABLE_REPR_REASON,
    ("text", "44-repr-zwsp"): _NON_PRINTABLE_REPR_REASON,
    ("text", "47-roundtrip-invalid"): _ILL_FORMED_ROUNDTRIP_REASON,
}

_WORDING_REASON = (
    "same verdict, different sentence: pydantic reports a structured validation list and the port states one sentence naming the key and the fault. The projection already strips the path prefix and collapses the report to one line; pinning both sentences keeps the difference visible."
)

_EXTRACTOR_REASON = (
    "the port has one extraction backend, so its default fetch.extractor is \"stdlib\"; the oracle's default is \"trafilatura\", a library this tree carries but the port has not wrapped. A P6 port decision, not a silent drift: the port refuses any other name and the oracle refuses names outside its two."
)


def _systematic(area: str, case: str, oracle: list[str], port: list[str]) -> str | None:
    """The reason when the difference is one of the two known systematic gaps.

    Only these two shapes classify, and each check is exact rather than a
    similarity: the port's sentence for an oracle refusal it agrees on, and the
    extractor token inside the fetch section's projection line. Everything else
    has to be named in ``DIVERGENCES``.
    """
    if (
        len(oracle) == len(port) == 1
        and oracle[0].startswith("ERR ")
        and port[0].startswith("ERR ")
    ):
        return _WORDING_REASON
    swapped = []
    for one, other in zip(oracle, port):
        if one == other:
            swapped.append(one)
        elif one.startswith("fetch,") and other.startswith("fetch,"):
            left = one.split(",")
            right = other.split(",")
            if len(left) == len(right) and left[:2] + left[3:] == right[:2] + right[3:] and left[2] == "trafilatura" and right[2] == "stdlib":
                swapped.append(one)
            else:
                return None
        else:
            return None
    if swapped:
        return _EXTRACTOR_REASON
    return None

_HEADER_ORDER = ["area", "case", "verification", "oracle", "projection", "reason"]


def _clear_key_environment() -> None:
    import os

    names = [api_key_env_var(n) for n in sorted(KNOWN_PROVIDERS)]
    names += ["SEEKWRIGHT_AGENT_API_KEY", "SEEKWRIGHT_CONFIG"]
    for name in names:
        os.environ[name] = ""


def _run_port(area: str, directory: pathlib.Path) -> dict[str, list[str]]:
    proc = subprocess.run(
        [str(DRIVE), area, str(directory)],
        capture_output=True,
        text=True,
        check=True,
        cwd=ROOT,
    )
    out: dict[str, list[str]] = {}
    for line in proc.stdout.splitlines():
        case, _, text = line.partition("\t")
        out.setdefault(case, []).append(text)
    return out


def _golden_text(area: str, case: str, verification: str, oracle: list[str], port: list[str], reason: str | None) -> str:
    lines = [
        f"area: {area}",
        f"case: {case}",
        f"verification: {verification}",
        "oracle: python",
        f"projection: {area}",
    ]
    if reason is not None:
        lines.append(f"reason: {reason}")
    body = "\n".join(lines) + "\n--- oracle\n" + "\n".join(oracle) + "\n"
    if verification == "explicit-divergence":
        body += "--- port\n" + "\n".join(port) + "\n"
    return body


def generate(area: str) -> int:
    inputs = CORPUS / area
    if not inputs.is_dir():
        raise SystemExit(f"no corpus for area {area!r}")
    project = projections.AREAS[area]
    port = _run_port(area, inputs)
    mismatches = 0
    GOLDEN.joinpath(area).mkdir(parents=True, exist_ok=True)
    for path in sorted(inputs.iterdir()):
        if area == "config":
            oracle_lines = project(str(path))
        else:
            oracle_lines = project(path.read_bytes().decode("utf-8", errors="replace"))
        case = path.stem
        port_lines = port.get(case)
        if port_lines is None:
            raise SystemExit(f"the port produced nothing for {area}/{case}")
        if oracle_lines == port_lines:
            verification, reason = "differential-golden", None
        else:
            reason = DIVERGENCES.get((area, case)) or _systematic(area, case, oracle_lines, port_lines)
            if reason is None:
                mismatches += 1
                print(f"MISMATCH {area}/{case}")
                print("  oracle: {}".format("\n          ".join(oracle_lines)))
                print("  port:   {}".format("\n          ".join(port_lines)))
                continue
            verification = "explicit-divergence"
        (GOLDEN / area / (case + ".golden")).write_text(
            _golden_text(area, case, verification, oracle_lines, port_lines, reason)
        )
    return mismatches


def main() -> None:
    if not DRIVE.exists():
        raise SystemExit("build the driver first: dune build test/differential/drive.exe")
    _clear_key_environment()
    areas = sys.argv[1:] or list(projections.AREAS)
    total = 0
    for area in areas:
        total += generate(area)
    if total:
        raise SystemExit(
            f"{total} unregistered divergence(s): accept them in DIVERGENCES with a "
            "reason, or fix the projection that drifts"
        )
    written = sum(1 for _ in GOLDEN.rglob("*.golden"))
    print(f"goldens pinned: {written} under {GOLDEN}")


if __name__ == "__main__":
    main()
