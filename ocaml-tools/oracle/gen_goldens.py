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

# Accepted divergences, keyed by (area, case): the reason the two trees answer
# differently and why that is fine rather than a bug to chase. Every mismatch
# must appear here, or be classifiable by one of the two systematic rules
# below, or regeneration stops. An unexplained mismatch is never a silent
# golden.
DIVERGENCES: dict[tuple[str, str], str] = {
    (
        "sanitize",
        "09-lone-continuation",
    ): "the oracle projection must read the corpus through a text decode (its sanitizer takes str), so the ill-formed byte arrives as U+FFFD before it is called; the port's sanitizer is byte-faithful and passes the lone continuation byte through. The escape pass itself agrees: same count, same reversibility, same idempotence.",
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
