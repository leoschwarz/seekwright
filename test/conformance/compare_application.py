#!/usr/bin/env python3
"""Fail-closed comparison of the pinned MCP runner against the application.

The fixture comparator (`compare_results.py`) scores a server against the
runner's expected failures: it asks "which declared surface does this fixture
fail to answer?". This one asks a different question, because seekwright is not
a conformance fixture: it implements three tools (`search`, `fetch`, `answer`)
and a transport, and it deliberately declares no resources, prompts, rich
content, progress, MRTR or tasks. Pointing the runner's 37 scored scenarios at
it and counting passes would measure how much of the *fixture's* surface it
happens to resemble, not whether its own surface is MCP-conformant.

So every check in `application-classification-2026-07-28-server.json` carries a
class, and this script enforces:

- `applicable` checks must pass. They are the obligations a server with this
  surface has: `tools/list` and every tool schema on the wire, the modern
  stateless protocol, DNS-rebinding protection, HTTP header validation,
  caching hints, concurrent POST streams, and the SEP-2164 error shape for a
  resource that does not exist.
- every other class is an explicit exclusion, and its observed status must
  equal the recorded expectation. A check that starts passing, or starts
  failing differently, is a failure here — the classification is a baseline,
  not a loose assertion.
- the runner's scenario list must still be exactly the pinned 37 scored plus
  the classified unscored set, and every scenario must produce exactly one
  result directory and exactly the classified check IDs. A runner upgrade, a
  dropped check or a renamed scenario fails instead of silently shrinking the
  baseline.

`oracle-parity` marks a check the Python implementation fails identically, so
it cannot distinguish the port either way. `port-divergence` marks a check
where the Python oracle behaves differently: it is still excluded from
seekwright's three-tool contract, but it is a recorded difference, not a
silent one.

The raw "n of 37" tally is written into the report as a footnote. It is not
the gate and not the headline: several scenarios pass by answering an empty
list, which no more demonstrates a feature than a refusal does.
"""

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

from compare_results import RESULT_DIR, exact, ids, read_checks, runner_list, runner_unscored

STATUSES = {"SUCCESS", "FAILURE", "WARNING", "SKIPPED", "INFO"}
SCENARIO_CLASSES = {"applicable", "mixed", "fixture-declaration", "absent-feature"}
CHECK_CLASSES = {"applicable", "fixture-declaration", "absent-feature", "oracle-parity", "port-divergence"}
FAILING = {"FAILURE", "WARNING"}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate classification key: {key}")
        result[key] = value
    return result


def load_classification(path, errors):
    try:
        document = json.loads(path.read_text(), object_pairs_hook=unique_object)
    except (OSError, ValueError) as exc:
        errors.append(f"classification unavailable or malformed: {exc}")
        return None
    if not isinstance(document, dict):
        errors.append("classification must be an object")
        return None
    runner = document.get("runner")
    if not isinstance(runner, dict) or not isinstance(runner.get("version"), str):
        errors.append("classification.runner.version is required")
    for group, required in (("scenarios", True), ("unscored", True), ("classes", True)):
        if not isinstance(document.get(group), dict) or (required and not document[group]):
            errors.append(f"classification.{group} must be a non-empty object")
    scenarios = document.get("scenarios")
    unscored = document.get("unscored")
    if not isinstance(scenarios, dict) or not isinstance(unscored, dict):
        return None
    for group_name, group in (("scenarios", scenarios), ("unscored", unscored)):
        for scenario, entry in group.items():
            label = f"{group_name}/{scenario}"
            if not isinstance(entry, dict):
                errors.append(f"{label}: entry must be an object")
                continue
            if entry.get("class") not in SCENARIO_CLASSES:
                errors.append(f"{label}: invalid scenario class {entry.get('class')!r}")
            if not isinstance(entry.get("reason"), str) or not entry["reason"].strip():
                errors.append(f"{label}: missing reason")
            checks = entry.get("checks")
            if not isinstance(checks, dict) or not checks:
                errors.append(f"{label}: missing checks map")
                continue
            for check_id, check in checks.items():
                check_label = f"{label}/{check_id}"
                if not isinstance(check, dict):
                    errors.append(f"{check_label}: entry must be an object")
                    continue
                if check.get("class") not in CHECK_CLASSES:
                    errors.append(f"{check_label}: invalid check class {check.get('class')!r}")
                if check.get("expect") not in STATUSES:
                    errors.append(f"{check_label}: invalid expectation {check.get('expect')!r}")
                count = check.get("count", 1)
                if not isinstance(count, int) or isinstance(count, bool) or count < 1:
                    errors.append(f"{check_label}: count must be a positive integer")
                if check.get("class") == "applicable" and check.get("expect") not in {"SUCCESS", "INFO"}:
                    errors.append(f"{check_label}: an applicable check cannot be expected to {check.get('expect')}")
                if check.get("class") != "applicable" and not isinstance(check.get("reason"), str):
                    errors.append(f"{check_label}: an excluded check needs a reason")
            if entry.get("class") == "applicable":
                excluded = sorted(
                    check_id for check_id, check in checks.items()
                    if isinstance(check, dict) and check.get("class") != "applicable"
                )
                if excluded:
                    errors.append(f"{label}: applicable scenario contains excluded checks: {excluded}")
            elif entry.get("class") in {"fixture-declaration", "absent-feature"}:
                stray = sorted(
                    check_id for check_id, check in checks.items()
                    if isinstance(check, dict) and check.get("class") == "applicable"
                    and check_id != "wire-schema-valid"
                )
                if stray:
                    errors.append(f"{label}: non-applicable scenario claims applicable checks: {stray}")
    return document


def require_exact(label, actual, expected, errors):
    exact(label, actual, expected, errors)


def require_multiset(label, actual, expected, errors):
    """Like require_exact, but check IDs may repeat within one scenario.

    The runner reuses an ID for the same assertion driven through different
    inputs (`sep-2243-server-reject-invalid-headers` appears five times in
    `http-header-validation`), so the classification carries a `count` and the
    comparison is over occurrences, not just the ID set.
    """
    actual_counts = Counter(actual)
    expected_counts = Counter(expected)
    missing = sorted((expected_counts - actual_counts).elements())
    extra = sorted((actual_counts - expected_counts).elements())
    if missing or extra:
        errors.append(f"{label}: missing={missing}, extra={extra}")


def run_summary(checks):
    failed = [check["id"] for check in checks if check.get("status") in FAILING]
    if failed:
        return "fail"
    if any(check.get("status") == "SUCCESS" for check in checks):
        return "pass"
    return "inconclusive"


def compare(args):
    errors = []
    classification = load_classification(args.classification, errors)
    expected = ids(args.manifest)
    report = {
        "mode": "application",
        "manifest": str(args.manifest),
        "classification": str(args.classification),
        "errors": errors,
        "scenarios": {},
        "run": {},
    }
    if classification is None:
        report["gate"] = "fail"
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1

    artifact_root = args.results.parent
    metadata_ok = True
    for key, filename in (
        ("date_utc", "run-date-utc.txt"),
        ("server_commit", "server-commit.txt"),
        ("runner_version", "runner-version.txt"),
        ("node_version", "node-version.txt"),
        ("npm_version", "npm-version.txt"),
        ("command", "runner-command.txt"),
        ("server_identity", "server-identity.txt"),
    ):
        try:
            report["run"][key] = (artifact_root / filename).read_text().strip()
        except OSError as exc:
            errors.append(f"run metadata missing ({filename}): {exc}")
            metadata_ok = False
    expected_version = classification["runner"]["version"]
    if report["run"].get("runner_version") != expected_version:
        errors.append(
            f"runner version changed: expected {expected_version!r}, "
            f"observed {report['run'].get('runner_version')!r}"
        )
        metadata_ok = False
    try:
        status_lines = (artifact_root / "working-tree-status.txt").read_text().splitlines()
        report["run"]["working_tree_status_count"] = len(status_lines)
    except OSError as exc:
        errors.append(f"run metadata missing (working-tree-status.txt): {exc}")
        metadata_ok = False

    scored = list(expected)
    unscored = []
    runner_ok = metadata_ok
    try:
        list_text = args.list_output.read_text()
        before = len(errors)
        require_exact("official scored list", runner_list(list_text), scored, errors)
        unscored = runner_unscored(list_text)
        if len(unscored) != len(set(unscored)) or set(unscored) & set(scored):
            errors.append("official unscored list contains duplicates or scored IDs")
        require_exact("classified unscored list", sorted(unscored), sorted(classification["unscored"]), errors)
        if len(errors) != before:
            runner_ok = False
    except (OSError, ValueError) as exc:
        errors.append(f"runner list parser error: {exc}")
        runner_ok = False

    require_exact("classification scored scenarios", sorted(classification["scenarios"]), sorted(scored), errors)

    try:
        stdout = args.stdout.read_text()
        before = len(errors)
        executed = re.findall(r"^=== Running scenario: (\S+) ===$", stdout, re.MULTILINE)
        require_exact("executed scenarios", executed, scored + unscored, errors)
        if "=== SUMMARY ===" not in stdout:
            errors.append("runner summary missing")
        if len(errors) != before:
            runner_ok = False
    except OSError as exc:
        errors.append(f"runner stdout missing: {exc}")
        runner_ok = False

    try:
        exit_code = int(args.exit_code.read_text().strip())
        report["runner_exit_code"] = exit_code
        if exit_code not in (0, 1):
            errors.append(f"runner crashed or timed out: exit {exit_code}")
            runner_ok = False
    except (OSError, ValueError) as exc:
        errors.append(f"runner exit code missing: {exc}")
        runner_ok = False

    found = {}
    if not args.results.is_dir():
        errors.append(f"runner result directory missing: {args.results}")
    else:
        for item in args.results.iterdir():
            if not item.is_dir():
                continue
            name = item.name
            match = RESULT_DIR.fullmatch(name)
            if not match:
                errors.append(f"unrecognized result directory: {name}")
                continue
            scenario = match.group(1)
            if scenario not in scored and scenario not in unscored:
                errors.append(f"result directory for unknown scenario: {name}")
                continue
            found.setdefault(scenario, []).append(item)
        require_exact("result directories", sorted(found), sorted(scored + unscored), errors)
        for scenario, paths in found.items():
            if len(paths) != 1:
                errors.append(f"duplicate result directory for {scenario}: {len(paths)}")

    observed = {}
    raw = {}
    for scenario in scored + unscored:
        entry = {"class": classification["scenarios"].get(scenario, classification["unscored"].get(scenario, {})).get("class")}
        report["scenarios"][scenario] = entry
        paths = found.get(scenario, [])
        if len(paths) != 1:
            errors.append(f"missing or duplicate result directory: {scenario}")
            entry["result"] = "inconclusive"
            raw[scenario] = "inconclusive"
            continue
        checks_path = paths[0] / "checks.json"
        try:
            checks, failed, result = read_checks(checks_path)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            errors.append(f"checks unavailable or malformed: {scenario}: {exc}")
            entry["result"] = "inconclusive"
            raw[scenario] = "inconclusive"
            continue
        observed[scenario] = checks
        raw[scenario] = run_summary(checks)
        entry["checks_path"] = str(checks_path.relative_to(args.results.parent))
        entry["checks"] = {check["id"]: check["status"] for check in checks}
        entry["check_counts"] = dict(Counter(check["status"] for check in checks))
        if failed:
            entry["failed_check_ids"] = failed

    if not runner_ok:
        for entry in report["scenarios"].values():
            entry["result"] = "inconclusive"

    check_classes = Counter()
    check_statuses = Counter()
    applicable_checks = Counter()
    excluded_but_runner_passes = []
    for group_name, group in (("scenarios", classification["scenarios"]), ("unscored", classification["unscored"])):
        for scenario, classified in group.items():
            checks = observed.get(scenario)
            if checks is None:
                continue
            expected_checks = classified["checks"]
            expected_ids = []
            for check_id, expected_check in expected_checks.items():
                expected_ids.extend([check_id] * expected_check.get("count", 1))
            require_multiset(f"{group_name}/{scenario} check IDs", sorted(check["id"] for check in checks), sorted(expected_ids), errors)
            applicable_failed = []
            for check_id, expected_check in expected_checks.items():
                occurrences = [check for check in checks if check["id"] == check_id]
                klass = expected_check["class"]
                for check in occurrences:
                    status = check.get("status")
                    check_classes[klass] += 1
                    check_statuses[status] += 1
                    if klass == "applicable":
                        applicable_checks[status] += 1
                        if status in FAILING:
                            applicable_failed.append(check_id)
                    if status != expected_check["expect"]:
                        errors.append(
                            f"{group_name}/{scenario}/{check_id}: expected {expected_check['expect']}, observed {status}"
                        )
            if applicable_failed:
                errors.append(f"{group_name}/{scenario}: applicable checks failed: {applicable_failed}")
            if classified["class"] == "applicable" and applicable_failed:
                errors.append(f"{group_name}/{scenario}: an applicable scenario must pass every check")
            entry = report["scenarios"].get(scenario, {})
            entry["raw"] = raw.get(scenario, "inconclusive")
            if classified["class"] in {"fixture-declaration", "absent-feature"}:
                entry["result"] = "excluded"
            elif applicable_failed:
                entry["result"] = "fail"
            else:
                entry["result"] = "pass"
            if entry["result"] == "excluded" and raw.get(scenario) == "pass":
                excluded_but_runner_passes.append(scenario)

    if not runner_ok:
        for entry in report["scenarios"].values():
            entry["result"] = "inconclusive"

    scored_raw = Counter(raw.get(scenario, "inconclusive") for scenario in scored)
    unscored_raw = Counter(raw.get(scenario, "inconclusive") for scenario in unscored)
    report["tallies"] = {
        "scenarios_by_class": dict(Counter(
            entry["class"] for entry in report["scenarios"].values()
        )),
        "checks_by_class": dict(check_classes),
        "check_statuses": dict(check_statuses),
        "applicable_checks": dict(applicable_checks),
        "scored_scenarios": {key: scored_raw[key] for key in ("pass", "fail", "inconclusive")},
        "unscored_scenarios": {key: unscored_raw[key] for key in ("pass", "fail", "inconclusive")},
        "scored_total": len(scored),
        "unscored_total": len(unscored),
        "excluded_scenarios_that_the_runner_passes": sorted(excluded_but_runner_passes),
    }
    report["applicable_check_total"] = sum(applicable_checks.values())
    report["gate"] = "fail" if errors else "pass"
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "application: "
        f"{report['applicable_check_total']} applicable checks "
        f"({sum(v for k, v in applicable_checks.items() if k in {'SUCCESS', 'INFO'})} passed), "
        f"{sum(check_classes.values())} checks classified; gate={report['gate']}; report={args.report}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 0 if not errors else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--classification", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--stdout", type=Path, required=True)
    parser.add_argument("--exit-code", type=Path, required=True)
    parser.add_argument("--list-output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    return compare(args)


if __name__ == "__main__":
    sys.exit(main())
