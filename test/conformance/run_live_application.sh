#!/usr/bin/env bash
# Live run of the pinned official MCP conformance runner against the real
# application binary (`bin/main.exe --http`), scored by applicability rather
# than by the fixture's expected failures.
#
# The fixture run next door (`run_live.sh`) asks which parts of the runner's
# fixture surface mcp-caps can declare. This one asks whether seekwright's own
# surface — three tools plus the transport — is MCP-conformant: a check is
# applicable only if it exercises that surface, and every applicable check must
# pass. `application-classification-2026-07-28-server.json` is the judgement,
# `compare_application.py` is the fail-closed gate, and README.md records the
# measured result and every exclusion.
#
# Default `dune runtest` never runs this: it needs Node, an npm fetch and a
# live loopback server. The hermetic half of the same evidence is the stdio
# transcript in `application_transcript.jsonl`, which `dune runtest` replays.
#
#   dune build bin/main.exe
#   test/conformance/run_live_application.sh /tmp/seekwright-application-conformance
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <new-or-empty-output-directory>" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
output_dir=$(mkdir -p "$1" && cd "$1" && pwd)
conformance_dir="$repo_root/test/conformance"
app_bin="$repo_root/_build/default/bin/main.exe"
runner="$conformance_dir/node_modules/.bin/conformance"
manifest="$conformance_dir/requirements-2026-07-28-server.txt"
classification="$conformance_dir/application-classification-2026-07-28-server.json"
server_pid=''
server_url=''
config_dir=''
phase='initialization'

if [[ -n $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
  echo "error: output directory must be empty: $output_dir" >&2
  exit 2
fi

if [[ ! -x "$app_bin" ]]; then
  echo "error: $app_bin is missing; run 'dune build bin/main.exe' first" >&2
  exit 2
fi

cleanup() {
  local prior_status=$?
  trap - EXIT
  if [[ -n "$server_pid" ]]; then
    kill -- "-$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [[ -n "$server_url" ]]; then
    if ! python3 - "$server_url" <<'PY'
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
      echo "error: server port remains open after cleanup" | tee "$output_dir/cleanup-error.txt" >&2
      prior_status=1
    fi
  fi
  if [[ -n "$config_dir" ]]; then
    rm -rf "$config_dir"
  fi
  exit "$prior_status"
}
trap cleanup EXIT

cd "$repo_root"

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
printf '%s\n' "$app_bin --http" > "$output_dir/server-identity.txt"

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

# The application is started with a config that builds only what this port
# carries and never pings a provider: the keyless default set resolves to
# freeserp here, `fetch` uses the stdlib extractor, and a zero health interval
# means no background probe reaches any endpoint during the run.
phase='server-startup'
config_dir=$(mktemp -d)
cat > "$config_dir/config.toml" <<'TOML'
[search]
health_interval_seconds = 0

[fetch]
extractor = "stdlib"
TOML
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
server_url="http://127.0.0.1:$port/mcp"
printf '%s\n' "$server_url" > "$output_dir/server-url.txt"
setsid env SEEKWRIGHT_CONFIG="$config_dir/config.toml" "$app_bin" --http --port "$port" \
  > "$output_dir/server.stdout" 2> "$output_dir/server.stderr" &
server_pid=$!
for ((attempt = 0; attempt < 300; attempt++)); do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "error: application exited before becoming ready; see server.stderr" >&2
    exit 1
  fi
  status=$(curl --silent --show-error --max-time 2 -o "$output_dir/readiness-response.json" -w '%{http_code}' \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H 'MCP-Protocol-Version: 2026-07-28' \
    -H 'Mcp-Method: server/discover' \
    --data '{"jsonrpc":"2.0","id":"readiness","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' \
    "$server_url" 2> "$output_dir/readiness.stderr" || true)
  if [[ "$status" == 200 ]]; then
    break
  fi
  if (( attempt == 299 )); then
    echo "error: server/discover readiness failed; HTTP status $status" >&2
    exit 1
  fi
  sleep 0.1
done

printf '%q ' "$runner" server --url "$server_url" --requirements 2026-07-28 --output-dir "$output_dir/results" > "$output_dir/runner-command.txt"
printf '\n' >> "$output_dir/runner-command.txt"
mkdir -p "$output_dir/results"
phase='runner-run'
set +e
timeout --signal=TERM --kill-after=10 900 "$runner" server --url "$server_url" --requirements 2026-07-28 --output-dir "$output_dir/results" \
  > "$output_dir/runner.stdout" 2> "$output_dir/runner.stderr"
runner_exit=$?
set -e
printf '%s\n' "$runner_exit" > "$output_dir/runner.exit-code"

phase='comparison'
set +e
python3 "$conformance_dir/compare_application.py" \
  --manifest "$manifest" --classification "$classification" \
  --list-output "$output_dir/runner-list.stdout" \
  --results "$output_dir/results" --stdout "$output_dir/runner.stdout" \
  --exit-code "$output_dir/runner.exit-code" --report "$output_dir/application-report.json"
gate=$?
set -e
exit "$gate"
