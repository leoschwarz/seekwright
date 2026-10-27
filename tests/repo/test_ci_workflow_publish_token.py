"""`gh` in the release run reads GH_TOKEN, a variable the runner never sets.

`build and upload the wheel` calls `gh release view` and `gh release create`, and
`install the published wheel in a clean venv` calls it again to read the asset URL.
Actions hands the run token over as `${{ github.token }}` -- a workflow context,
not an environment variable -- so a job carrying only `permissions:` fails those
steps with `gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN
environment variable`. It fails in the wheel step: the wheel is built, nothing is
published, no image exists, and the release needs a second run of the same tag.

The registry login spends the same token. `GITHUB_TOKEN` is not one of the
runner's default variables either, so `echo "${GITHUB_TOKEN}" | docker login ...`
pipes an empty password and fails further down the same run. The label belongs on
the job, not on one step: a step that grows a `gh` call later inherits it instead
of repeating the same failure.

The token's scopes are the same failure one wrapper up. A `permissions:` block
zeroes every scope it does not name, so `contents: write` alone leaves the run's
token unable to write a package, and `docker push ghcr.io/...` answers
`permission_denied: write_package` at the last step that writes anything. Both
the credential and the scope it is spent with are checked here.

These checks read the workflow as text, the way
`tests/repo/test_ci_workflow_publish_tag_guard.py` and its siblings read it: the
runner consumes the file, not Python. They fail if the job stops setting GH_TOKEN,
if it moves into a single step, if the package write goes away, or if any step
spends a token variable the runner does not set.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "publish.yml"

# A job-level mapping, at the indent the runner reads a job key at, its entries,
# and the `steps:` key the block has to precede to be the job's and not a step's.
JOB_KEY = re.compile(r"^    (\w+):\s*$")
JOB_ENTRY = re.compile(r"^      (\w+):\s*(.+?)\s*$")
JOB_STEPS = re.compile(r"^    steps:\s*$")
GH_CALL = re.compile(r"\bgh\s+(?:release|api|run)\b")
DOCKER_LOGIN = re.compile(r"\bdocker login\b")
UNSET_TOKEN = re.compile(r"\$\{?GITHUB_TOKEN\}?")

# A step header and the run block under it -- the same line reads the sibling
# workflow modules make.
STEP_HEADER = re.compile(r"^      - name: (.+?)\s*$")
RUN_BLOCK = re.compile(r"^        run: \|\s*$")


def step_lines(name: str) -> list[str]:
    """The shell of one named step, dedented, in file order."""
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        header = STEP_HEADER.match(line)
        if header is None or header.group(1) != name:
            continue
        following = lines[index + 1 :]
        block = [i for i, entry in enumerate(following) if RUN_BLOCK.match(entry)]
        assert block, f"{WORKFLOW.relative_to(ROOT)}: step {name!r} has no run: block"
        body: list[str] = []
        for entry in following[block[0] + 1 :]:
            if entry.strip() and not entry.startswith("          "):
                break
            body.append(entry[10:])
        return body
    raise AssertionError(f"{WORKFLOW.relative_to(ROOT)}: no step named {name!r}")


def all_step_bodies() -> list[tuple[str, list[str]]]:
    """Every named step in the file, with its shell."""
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    names = [
        header.group(1)
        for header in (STEP_HEADER.match(line) for line in lines)
        if header is not None
    ]
    return [(name, step_lines(name)) for name in names]


def job_mapping(key: str) -> tuple[dict[str, str], int]:
    """One job-level mapping by key, and the line index of that key."""
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    starts = [
        i
        for i, line in enumerate(lines)
        if (found := JOB_KEY.match(line)) is not None and found.group(1) == key
    ]
    assert starts, (
        f"{WORKFLOW.relative_to(ROOT)}: the job declares no {key}:, so nothing it "
        "holds reaches the steps"
    )
    values: dict[str, str] = {}
    for line in lines[starts[0] + 1 :]:
        if not line.strip():
            continue
        entry = JOB_ENTRY.match(line)
        if entry is None:
            break
        values[entry.group(1)] = entry.group(2)
    return values, starts[0]


def test_the_job_hands_the_run_token_over_as_GH_TOKEN() -> None:
    """The job's env carries GH_TOKEN from the run token context, above `steps:`."""
    values, at = job_mapping("env")
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    steps = [i for i, line in enumerate(lines) if JOB_STEPS.match(line)]
    assert steps and at < steps[0], (
        f"{WORKFLOW.relative_to(ROOT)}: the env: block sits after `steps:`, so it is a "
        "step's env and the other steps still run with no GH_TOKEN"
    )
    assert values.get("GH_TOKEN") == "${{ github.token }}", (
        f"{WORKFLOW.relative_to(ROOT)}: the job's env carries no "
        "GH_TOKEN: ${{ github.token }}, so `gh release view`, `gh release create` and "
        "the asset-URL read fail with an authentication error the run reaches only "
        "after it has built the wheel"
    )


def test_the_job_grants_the_scopes_the_token_is_spent_on() -> None:
    """`packages: write` survives the `permissions:` block, or the push is refused."""
    scopes, _ = job_mapping("permissions")
    assert scopes.get("contents") in {"write", "read"}, (
        f"{WORKFLOW.relative_to(ROOT)}: the job's permissions grant no contents scope, "
        "so `gh release create` cannot write the release the tag names"
    )
    assert scopes.get("packages") == "write", (
        f"{WORKFLOW.relative_to(ROOT)}: the job's permissions carry no packages: write, "
        "and a permissions: block zeroes every scope it does not name -- so the token "
        "the registry login just validated is refused at `docker push` with "
        "permission_denied: write_package, at the last step that writes anything"
    )


def test_the_steps_that_call_gh_exist_so_that_guard_is_not_vacuous() -> None:
    """The job still holds the gh calls the env is there for."""
    calls = [
        name for name, body in all_step_bodies() if any(GH_CALL.search(l) for l in body)
    ]
    assert calls, (
        f"{WORKFLOW.relative_to(ROOT)}: no step calls `gh` any more, so the release "
        "lookup, the release create or the anonymous asset read was dropped rather "
        "than rewired"
    )


def test_no_step_spends_a_token_variable_the_runner_does_not_set() -> None:
    """The registry login pipes GH_TOKEN, and no run block names GITHUB_TOKEN."""
    offenders = [
        (name, line.strip())
        for name, body in all_step_bodies()
        for line in body
        if UNSET_TOKEN.search(line)
    ]
    assert not offenders, (
        f"{WORKFLOW.relative_to(ROOT)}: {offenders[0][0]!r} reads "
        f"${UNSET_TOKEN.pattern} in `{offenders[0][1]}`, a variable the runner does not "
        "set -- the step then runs with an empty string and fails on a credential the "
        "job already holds as GH_TOKEN"
    )
    logins = [
        line.strip()
        for _name, body in all_step_bodies()
        for line in body
        if DOCKER_LOGIN.search(line)
    ]
    assert logins, (
        f"{WORKFLOW.relative_to(ROOT)}: no step logs in to a registry, so the image "
        "push has no credential step left to check"
    )
    without_token = [line for line in logins if "${GH_TOKEN}" not in line]
    assert not without_token, (
        f"{WORKFLOW.relative_to(ROOT)}: `{without_token[0]}` does not pipe GH_TOKEN, so "
        "the login the image push depends on sends whatever else it names"
    )
