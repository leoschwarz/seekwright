#!/usr/bin/env python3
"""Fail-closed comparison of the pinned MCP runner's server results."""

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

CAUSES = {"sdk_protocol_defect", "fixture_gap", "runner_issue", "unsupported_feature", "unresolved"}
RUN_LINE = re.compile(r"^=== Running scenario: (\S+) ===$", re.MULTILINE)
RESULT_DIR = re.compile(r"^server-(.+)-(\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-\d+Z)$")


def ids(path, *, allow_empty=False):
    values = [line.strip() for line in path.read_text().splitlines() if line.strip() and not line.startswith("#")]
    if len(values) != len(set(values)) or (not values and not allow_empty):
        raise ValueError(f"manifest has duplicate IDs or is empty: {path}")
    return values


def runner_list(text):
    match = re.search(r"Server scenarios \(test against a server\):\n(.*?)(?:\n\s*Client scenarios|\n\s*Run and reported)", text, re.S)
    if not match:
        raise ValueError("cannot parse official runner server list")
    return re.findall(r"^\s+- (\S+)\s*$", match.group(1), re.M)


def runner_unscored(text):
    match = re.search(r"Run and reported, but never scored:\n(.*)", text, re.S)
    if not match:
        raise ValueError("cannot parse official runner unscored list")
    return re.findall(r"^\s+- (\S+) \[server\]\s*$", match.group(1), re.M)


def exact(label, actual, expected, errors):
    counts = Counter(actual)
    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    duplicates = sorted(k for k, v in counts.items() if v != 1)
    if missing or extra or duplicates:
        errors.append(f"{label}: missing={missing}, extra={extra}, duplicates={duplicates}")


def load_baseline(path, manifest, errors):
    if path is None:
        return {}
    try:
        def unique_object(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError(f"duplicate baseline key: {key}")
                result[key] = value
            return result

        document = json.loads(path.read_text(), object_pairs_hook=unique_object)
        entries = document["expected_failures"]
        if not isinstance(entries, dict):
            raise ValueError("expected_failures must be an object")
        for scenario, entry in entries.items():
            if scenario not in manifest:
                errors.append(f"baseline unknown scenario: {scenario}")
            checks = entry.get("checks") if isinstance(entry, dict) else None
            if not isinstance(checks, dict) or not checks:
                errors.append(f"baseline missing checks map: {scenario}")
                continue
            for check_id, classification in checks.items():
                label = f"{scenario}/{check_id}"
                if not isinstance(check_id, str) or not check_id:
                    errors.append(f"baseline invalid check ID: {label}")
                if not isinstance(classification, dict) or classification.get("cause") not in CAUSES:
                    errors.append(f"baseline invalid cause: {label}")
                    continue
                if not isinstance(classification.get("reason"), str) or not classification["reason"].strip():
                    errors.append(f"baseline missing reason: {label}")
                if classification["cause"] == "unresolved" and (
                    not isinstance(classification.get("evidence"), str) or not classification["evidence"].strip()
                ):
                    errors.append(f"unresolved baseline check needs specific evidence: {label}")
        return entries
    except (OSError, ValueError, KeyError, TypeError) as exc:
        errors.append(f"baseline parser error: {exc}")
        return {}


def read_checks(path):
    checks = json.loads(path.read_text())
    if not isinstance(checks, list) or not checks:
        raise ValueError("checks.json is empty or not an array")
    if any(not isinstance(c, dict) or c.get("status") not in {"SUCCESS", "FAILURE", "WARNING", "SKIPPED", "INFO"} or not isinstance(c.get("id"), str) or not c["id"] for c in checks):
        raise ValueError("unknown check status or invalid check object")
    failed = [c["id"] for c in checks if c["status"] in {"FAILURE", "WARNING"}]
    if len(failed) != len(set(failed)):
        raise ValueError("duplicate failed check IDs")
    if failed:
        result = "fail"
    elif any(c["status"] == "SUCCESS" for c in checks):
        result = "pass"
    else:
        result = "skipped"
    return checks, failed, result


def observed_evidence(check):
    message = check.get("errorMessage")
    if isinstance(message, str) and message:
        return f"{check['status']}: {message}"
    return json.dumps(check, sort_keys=True)


def compare_pending(manifest, base, report_path, classifications_path=None):
    errors = []
    expected = ids(manifest, allow_empty=True)
    report = {"mode": "pending", "scored": False, "scenarios": {}, "errors": errors}
    classifications = {}
    if classifications_path is not None:
        try:
            classifications = json.loads(classifications_path.read_text())
            if not isinstance(classifications, dict):
                raise ValueError("pending classifications must be an object")
        except (OSError, ValueError) as exc:
            errors.append(f"pending classifications unavailable or malformed: {exc}")
            classifications = {}
    for scenario in sorted(set(classifications) - set(expected)):
        errors.append(f"stale pending classification scenario: {scenario}")
    if not base.is_dir():
        errors.append(f"pending result directory missing: {base}")
    else:
        exact("pending scenario directories", [p.name for p in base.iterdir() if p.is_dir()], expected, errors)
    for scenario in expected:
        entry = {"result": "inconclusive", "cause": "unresolved", "runner_exit_code": None, "checks_path": None}
        report["scenarios"][scenario] = entry
        runner_ok = True
        try:
            code = int((base / f"{scenario}.exit-code").read_text().strip())
            entry["runner_exit_code"] = code
            if code not in (0, 1):
                errors.append(f"pending runner crash or timeout: {scenario}: exit {code}")
                runner_ok = False
        except (OSError, ValueError) as exc:
            errors.append(f"pending runner exit missing: {scenario}: {exc}")
            runner_ok = False
        try:
            stdout = (base / f"{scenario}.stdout").read_text()
            if f"Running client scenario '{scenario}'" not in stdout:
                errors.append(f"pending runner output malformed: {scenario}")
                runner_ok = False
        except OSError as exc:
            errors.append(f"pending runner stdout missing: {scenario}: {exc}")
            runner_ok = False
        scenario_dir = base / scenario
        paths = [p for p in scenario_dir.iterdir() if p.is_dir()] if scenario_dir.is_dir() else []
        matching = [p for p in paths if RESULT_DIR.fullmatch(p.name) and RESULT_DIR.fullmatch(p.name).group(1) == scenario]
        if len(paths) != 1 or len(matching) != 1:
            entry["reason"] = "result directory missing, duplicate, or unexpected"
            errors.append(f"pending result directories missing, duplicate or unexpected: {scenario}")
            continue
        checks_path = matching[0] / "checks.json"
        entry["checks_path"] = str(checks_path.relative_to(base.parent))
        try:
            checks, failed, result = read_checks(checks_path)
            entry["result"] = result
            if result != "skipped":
                entry.pop("cause", None)
            entry["failed_check_ids"] = failed
            entry["check_counts"] = dict(Counter(c["status"] for c in checks))
            known = classifications.get(scenario, {})
            if isinstance(known, dict):
                observed_ids = {c["id"] for c in checks}
                for check_id in sorted(set(known) - observed_ids):
                    errors.append(f"stale pending classification check: {scenario}/{check_id}")
            observations = {c["id"]: observed_evidence(c) for c in checks if c["id"] in failed}
            entry["failed_checks"] = {}
            for check_id in failed:
                reason = known.get(check_id) if isinstance(known, dict) else None
                entry["failed_checks"][check_id] = (
                    {"cause": "fixture_gap", "reason": reason}
                    if isinstance(reason, str) and reason.strip()
                    else {"cause": "unresolved", "reason": "New unscored failure has not been triaged", "evidence": observations[check_id]}
                )
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            entry["reason"] = str(exc)
            errors.append(f"pending checks unavailable or malformed: {scenario}: {exc}")
        if not runner_ok:
            entry["result"] = "inconclusive"
            entry["cause"] = "unresolved"
            entry["reason"] = "runner execution or output failed; see the scenario stdout and exit code"
            entry["stdout_path"] = str(base / f"{scenario}.stdout")
    report["gate"] = "pass" if not errors else "fail"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"pending (unscored): gate={report['gate']}; report={report_path}")
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 0 if not errors else 1


def compare(args):
    errors = []
    expected = ids(args.manifest)
    report = {"mode": args.mode, "manifest": str(args.manifest), "scenarios": {}, "errors": errors}
    artifact_root = args.results.parent
    report["run"] = {}
    metadata_ok = True
    for key, filename in (("date_utc", "run-date-utc.txt"),
                          ("server_commit", "server-commit.txt"),
                          ("runner_version", "runner-version.txt"),
                          ("node_version", "node-version.txt"),
                          ("npm_version", "npm-version.txt"),
                          ("command", "required-command.txt")):
        try:
            report["run"][key] = (artifact_root / filename).read_text().strip()
        except OSError as exc:
            if args.list_output is not None:
                errors.append(f"run metadata missing ({filename}): {exc}")
                metadata_ok = False
    status_path = artifact_root / "working-tree-status.txt"
    report["run"]["working_tree_status_path"] = str(status_path)
    try:
        status_lines = status_path.read_text().splitlines()
        report["run"]["working_tree_clean"] = len(status_lines) == 0
        report["run"]["working_tree_status_count"] = len(status_lines)
    except OSError as exc:
        report["run"]["working_tree_clean"] = None
        report["run"]["working_tree_status_count"] = None
        if args.list_output is not None:
            errors.append(f"run metadata missing (working-tree-status.txt): {exc}")
            metadata_ok = False
    unscored = []
    runner_ok = metadata_ok
    if args.list_output:
        try:
            list_text = args.list_output.read_text()
            list_error_count = len(errors)
            exact("official list", runner_list(list_text), expected, errors)
            unscored = runner_unscored(list_text)
            if len(unscored) != len(set(unscored)) or set(unscored) & set(expected):
                errors.append("official unscored list contains duplicate or required IDs")
            if len(errors) != list_error_count:
                runner_ok = False
        except (OSError, ValueError) as exc:
            errors.append(f"runner list parser error: {exc}")
            runner_ok = False
    report["unscored_scenarios"] = {}
    try:
        stdout = args.stdout.read_text()
        actual = RUN_LINE.findall(stdout)
        output_error_count = len(errors)
        exact("executed scenarios", actual, expected + unscored, errors)
        if len(errors) != output_error_count:
            runner_ok = False
        if "=== SUMMARY ===" not in stdout:
            errors.append("runner summary missing")
            runner_ok = False
    except OSError as exc:
        stdout = ""
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
            match = RESULT_DIR.fullmatch(item.name)
            if not match:
                errors.append(f"unrecognized result directory: {item.name}")
                continue
            found.setdefault(match.group(1), []).append(item)
        exact("result directories", list(found), expected + unscored, errors)
        for scenario, paths in found.items():
            if len(paths) != 1:
                errors.append(f"duplicate result directory for {scenario}: {len(paths)}")
    baseline = load_baseline(args.baseline, expected, errors) if args.mode == "required" else {}
    for scenario in unscored:
        paths = found.get(scenario, [])
        outcome = {"result": "inconclusive", "checks_path": None}
        report["unscored_scenarios"][scenario] = outcome
        if len(paths) != 1:
            errors.append(f"unscored missing or duplicate result directory: {scenario}")
            continue
        path = paths[0] / "checks.json"
        outcome["checks_path"] = str(path.relative_to(args.results.parent))
        try:
            checks, failed, result = read_checks(path)
            outcome["result"] = result
            outcome["failed_check_ids"] = failed
            outcome["check_counts"] = dict(Counter(c["status"] for c in checks))
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            outcome["reason"] = str(exc)
            errors.append(f"unscored checks unavailable or malformed: {scenario}: {exc}")
    for scenario in expected:
        paths = found.get(scenario, [])
        entry = {"result": "inconclusive", "cause": "unresolved", "checks_path": None, "failed_checks": {}}
        report["scenarios"][scenario] = entry
        if len(paths) != 1:
            entry["reason"] = "missing or duplicate result directory"
            errors.append(f"inconclusive: {scenario}: {entry['reason']}")
            continue
        checks_path = paths[0] / "checks.json"
        entry["checks_path"] = str(checks_path.relative_to(args.results.parent))
        try:
            checks, failed, result = read_checks(checks_path)
            entry["failed_check_ids"] = failed
            entry["check_counts"] = dict(Counter(c["status"] for c in checks))
            observations = {c["id"]: observed_evidence(c) for c in checks if c["id"] in failed}
            entry["result"] = result
            if result == "skipped":
                entry["result"] = "inconclusive"
                entry["reason"] = "all checks skipped"
                errors.append(f"inconclusive: {scenario}: {entry['reason']}")
            else:
                entry.pop("cause", None)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            entry["reason"] = f"checks.json unavailable or malformed: {exc}"
            errors.append(f"inconclusive: {scenario}: {entry['reason']}")
            continue
        if args.mode == "required":
            prior = baseline.get(scenario)
            if entry["result"] == "fail":
                if not prior:
                    errors.append(f"unexpected failure: {scenario}")
                else:
                    prior_checks = prior.get("checks") if isinstance(prior, dict) else None
                    if not isinstance(prior_checks, dict) or set(prior_checks) != set(entry["failed_check_ids"]):
                        errors.append(f"baseline failed check IDs changed: {scenario}")
                    if isinstance(prior_checks, dict):
                        entry["failed_checks"] = {
                            check_id: prior_checks[check_id]
                            for check_id in entry["failed_check_ids"] if check_id in prior_checks
                        }
                for check_id in entry["failed_check_ids"]:
                    entry["failed_checks"].setdefault(
                        check_id,
                        {"cause": "unresolved", "reason": "New required failure has not been triaged", "evidence": observations[check_id]},
                    )
            elif prior:
                errors.append(f"stale baseline entry: {scenario}")
    if not runner_ok:
        for entry in report["scenarios"].values():
            entry["result"] = "inconclusive"
            entry["cause"] = "unresolved"
            entry["reason"] = "required runner execution or output parsing failed"
            entry["stdout_path"] = str(args.stdout)
    counts = Counter(item["result"] for item in report["scenarios"].values())
    report["counts"] = {key: counts[key] for key in ("pass", "fail", "inconclusive")}
    if report.get("runner_exit_code") == 1 and counts["fail"] == 0:
        errors.append("runner exit 1 without required scenario failure")
    report["required_execution_count"] = len(expected)
    report["unscored_execution_count"] = len(unscored)
    report["gate"] = "pass" if not errors else "fail"
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"{args.mode}: {report['counts']}; gate={report['gate']}; report={args.report}")
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 0 if not errors else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--stdout", type=Path)
    parser.add_argument("--exit-code", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--list-output", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--pending-classifications", type=Path)
    parser.add_argument("--mode", choices=("required", "pending"), default="required")
    args = parser.parse_args()
    if args.mode == "pending":
        return compare_pending(args.manifest, args.results, args.report, args.pending_classifications)
    if args.stdout is None or args.exit_code is None:
        parser.error("--stdout and --exit-code are required in required mode")
    return compare(args)


if __name__ == "__main__":
    sys.exit(main())
