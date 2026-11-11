#!/usr/bin/env bash
# Live run of the pinned official MCP conformance runner against the mcp-caps
# fixture in this directory.
#
# Structure and the fail-closed gates are mcp-kit's (v0.2.0,
# scripts/run_live_mcp_conformance.sh and test/conformance/compare_results.py,
# MIT — see README.md, "Provenance"): same pinned runner, same requirements
# manifest, same comparator, so a number produced here is comparable to the
# 37/37 upstream records. What differs is the fixture (built through
# Mcp_caps.Registry / Server.of_registry) and the expected-failures baseline,
# which classifies this fixture's declared surface.
#
# Default `dune runtest` never runs this: it needs Node and an npm fetch.
#
#   test/conformance/run_live.sh /tmp/mcp-caps-conformance-results
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <new-or-empty-output-directory>" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
output_dir=$(mkdir -p "$1" && cd "$1" && pwd)
conformance_dir="$repo_root/test/conformance"
runner="$conformance_dir/node_modules/.bin/conformance"
manifest="$conformance_dir/requirements-2026-07-28-server.txt"
pending_manifest="$conformance_dir/pending-2026-07-28-server.txt"
baseline="${MCP_CONFORMANCE_BASELINE:-$conformance_dir/expected-failures-2026-07-28-server.json}"
fixture_pid=''
fixture_url=''
fixture_root=''
phase='initialization'

if [[ -n $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
  echo "error: output directory must be empty: $output_dir" >&2
  exit 2
fi

cleanup() {
  local prior_status=$?
  trap - EXIT
  if [[ -n "$fixture_pid" ]]; then
    kill -- "-$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  if [[ -n "$fixture_url" ]]; then
    if ! python3 - "$fixture_url" <<'PY'
import socket, sys, time, urllib.parse
url = urllib.parse.urlparse(sys.argv[1])
for _ in range(20):
    try:
        with socket.create_connection((url.hostname, url.port), timeout=0.1):
            pass
    except OSError:
        sys.exit(0)
    time.sleep(0.1)
sys.exit(1)
PY
    then
      echo "error: fixture port remains open after cleanup" | tee "$output_dir/cleanup-error.txt" >&2
      prior_status=1
    fi
  fi
  if [[ -n "$fixture_root" ]]; then
    rm -rf "$fixture_root"
  fi
  exit "$prior_status"
}
trap cleanup EXIT

cd "$repo_root"

# The pinned runner needs Node >= 22: it imports `globSync` from `fs`, which
# Node 20 does not export, and it fails at import rather than reporting a
# version problem. The version gate turns that into a readable line.
phase='metadata'
node_major=$(node --version | sed 's/^v\([0-9]*\).*/\1/')
if [[ "$node_major" -lt 22 ]]; then
  echo "error: the pinned runner needs Node >= 22, found $(node --version)" >&2
  exit 2
fi
printf '%s\n' "$(date -u +%FT%TZ)" > "$output_dir/run-date-utc.txt"
git rev-parse HEAD > "$output_dir/server-commit.txt"
git status --porcelain --untracked-files=all > "$output_dir/working-tree-status.txt"
node --version > "$output_dir/node-version.txt"
npm --version > "$output_dir/npm-version.txt"

phase='npm-install'
timeout 300 npm ci --prefix "$conformance_dir" --ignore-scripts > "$output_dir/npm-ci.stdout" 2> "$output_dir/npm-ci.stderr"
phase='runner-list'
"$runner" --version > "$output_dir/runner-version.txt"
timeout 60 "$runner" list --server --requirements 2026-07-28 > "$output_dir/runner-list.stdout" 2> "$output_dir/runner-list.stderr"
phase='manifest-validation'
python3 - "$manifest" "$output_dir/runner-list.stdout" "$conformance_dir" <<'PY'
import importlib.util, pathlib, sys
root = pathlib.Path(sys.argv[3])
spec = importlib.util.spec_from_file_location('compare_results', root / 'compare_results.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
expected = module.ids(pathlib.Path(sys.argv[1]))
actual = module.runner_list(pathlib.Path(sys.argv[2]).read_text())
errors = []
module.exact('official runner manifest', actual, expected, errors)
if errors:
    raise SystemExit('\n'.join(errors))
PY

# The fixture's filesystem tool reads a real subtree, so the run supplies one;
# [root/note.txt] in the tree is its committed shape.
phase='fixture-startup'
fixture_root=$(mktemp -d)
cp "$conformance_dir/root/note.txt" "$fixture_root/note.txt"

# This directory's executable is the fixture unless the environment names another
# one. The override exists for one purpose: driving mcp-kit's own conformance
# fixture through this same wrapper — same pinned runner, same manifest, same
# comparator — which is what separates "the fixture fails" from "the setup is
# broken". README.md records both control runs beside the fixture's result.
if [[ -n "${MCP_CONFORMANCE_FIXTURE_BIN:-}" ]]; then
  fixture_bin="$MCP_CONFORMANCE_FIXTURE_BIN"
  # Word-split on purpose: the override carries a whole argument list, and no
  # path in it may contain whitespace.
  fixture_args=(${MCP_CONFORMANCE_FIXTURE_ARGS-})
else
  fixture_bin="$repo_root/_build/default/test/conformance/fixture.exe"
  fixture_args=(--root "$fixture_root" --http)
fi
printf '%s\n' "$fixture_bin ${fixture_args[*]}" > "$output_dir/fixture-identity.txt"
setsid "$fixture_bin" "${fixture_args[@]}" > "$output_dir/fixture.stdout" 2> "$output_dir/fixture.stderr" &
fixture_pid=$!
for ((attempt=0; attempt<300; attempt++)); do
  if [[ -s "$output_dir/fixture.stdout" ]]; then
    fixture_url=$(head -n 1 "$output_dir/fixture.stdout" | tr -d '\r')
    break
  fi
  if ! kill -0 "$fixture_pid" 2>/dev/null; then
    echo "error: fixture exited before announcing URL" >&2
    exit 1
  fi
  sleep 0.1
done
if [[ ! "$fixture_url" =~ ^http://127\.0\.0\.1:[0-9]+/mcp$ ]]; then
  echo "error: fixture did not announce a loopback MCP URL: $fixture_url" >&2
  exit 1
fi
printf '%s\n' "$fixture_url" > "$output_dir/fixture-url.txt"

readiness_body='{"jsonrpc":"2.0","id":"readiness","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
phase='fixture-readiness'
for ((attempt=0; attempt<100; attempt++)); do
  status=$(curl --silent --show-error --max-time 2 -o "$output_dir/readiness-response.json" -w '%{http_code}' \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2026-07-28' \
    -H 'Mcp-Method: server/discover' \
    --data "$readiness_body" "$fixture_url" 2> "$output_dir/readiness.stderr" || true)
  if [[ "$status" == 200 ]] && python3 - "$output_dir/readiness-response.json" <<'PY'
import json, sys
try:
    document = json.load(open(sys.argv[1]))
    assert document['jsonrpc'] == '2.0'
    assert document['id'] == 'readiness'
    assert isinstance(document['result'], dict)
except (OSError, ValueError, KeyError, AssertionError, TypeError):
    sys.exit(1)
PY
  then
    break
  fi
  if (( attempt == 99 )); then
    echo "error: modern server/discover readiness failed; HTTP status $status" >&2
    exit 1
  fi
  sleep 0.1
done

printf '%q ' "$runner" server --url "$fixture_url" --requirements 2026-07-28 --output-dir "$output_dir/required" > "$output_dir/required-command.txt"
printf '\n' >> "$output_dir/required-command.txt"
mkdir -p "$output_dir/required"
phase='required-run'
set +e
timeout --signal=TERM --kill-after=10 900 "$runner" server --url "$fixture_url" --requirements 2026-07-28 --output-dir "$output_dir/required" > "$output_dir/required.stdout" 2> "$output_dir/required.stderr"
required_exit=$?
set -e
printf '%s\n' "$required_exit" > "$output_dir/required.exit-code"

mkdir -p "$output_dir/pending"
phase='pending-run'
while IFS= read -r scenario; do
  [[ -n "$scenario" ]] || continue
  printf '%q ' "$runner" server --url "$fixture_url" --scenario "$scenario" --spec-version 2026-07-28 --output-dir "$output_dir/pending/$scenario" > "$output_dir/pending/$scenario.command.txt"
  printf '\n' >> "$output_dir/pending/$scenario.command.txt"
  mkdir -p "$output_dir/pending/$scenario"
  set +e
  timeout --signal=TERM --kill-after=10 180 "$runner" server --url "$fixture_url" --scenario "$scenario" --spec-version 2026-07-28 --output-dir "$output_dir/pending/$scenario" > "$output_dir/pending/$scenario.stdout" 2> "$output_dir/pending/$scenario.stderr"
  pending_exit=$?
  set -e
  printf '%s\n' "$pending_exit" > "$output_dir/pending/$scenario.exit-code"
done < "$pending_manifest"

phase='comparison'
set +e
python3 "$conformance_dir/compare_results.py" --mode pending \
  --manifest "$pending_manifest" --results "$output_dir/pending" \
  --pending-classifications "$conformance_dir/pending-classifications-2026-07-28-server.json" \
  --report "$output_dir/pending-report.json"
pending_gate=$?
python3 "$conformance_dir/compare_results.py" --mode required \
  --manifest "$manifest" --list-output "$output_dir/runner-list.stdout" \
  --results "$output_dir/required" --stdout "$output_dir/required.stdout" \
  --exit-code "$output_dir/required.exit-code" --baseline "$baseline" \
  --report "$output_dir/required-report.json"
required_gate=$?
set -e
if (( pending_gate != 0 || required_gate != 0 )); then
  exit 1
fi
