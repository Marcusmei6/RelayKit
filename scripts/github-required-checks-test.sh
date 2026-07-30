#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-required-checks-test.XXXXXX")"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

fail() {
  echo "github required checks test failed: $1" >&2
  exit 1
}

MOCK_BIN="${TMP_DIR}/bin"
mkdir -p "${MOCK_BIN}"
cat >"${MOCK_BIN}/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

[[ "$*" == "api --paginate --slurp repos/example/relaykit/commits/${RELAYKIT_TEST_SHA}/check-runs?per_page=100" ]] ||
  { echo "unexpected gh invocation" >&2; exit 64; }

if [[ "${RELAYKIT_TEST_SCENARIO}" == "query-error" ]]; then
  exit 73
fi
if [[ "${RELAYKIT_TEST_SCENARIO}" == "malformed" ]]; then
  printf '%s\n' '{"not-json"'
  exit 0
fi

jq -n \
  --arg sha "${RELAYKIT_TEST_SHA}" \
  --arg scenario "${RELAYKIT_TEST_SCENARIO}" '
  def check($id; $name):
    {
      id: $id,
      name: $name,
      head_sha: $sha,
      status: "completed",
      conclusion: "success",
      app: {slug: "github-actions"},
      details_url: ("https://github.com/example/relaykit/actions/runs/" + (($id + 1000) | tostring) + "/job/" + ($id | tostring))
    };
  [
    check(101; "Fast Public Boundary"),
    check(102; "Fast Shell Contracts"),
    check(103; "Fast Go Quality"),
    check(104; "macOS App"),
    check(105; "macOS Runtime Safety"),
    check(106; "Protocol Contract")
  ]
  | if $scenario == "missing" then .[0:5]
    elif $scenario == "duplicate" then . + [.[0] | .id = 107]
    elif $scenario == "failure" then map(if .name == "macOS App" then .conclusion = "failure" else . end)
    elif $scenario == "wrong-sha" then map(if .name == "Protocol Contract" then .head_sha = ("0" * 40) else . end)
    elif $scenario == "foreign-app" then map(if .name == "Fast Go Quality" then .app.slug = "example-ci" else . end)
    else .
    end
  | [{total_count: length, check_runs: .}]
'
SH
chmod +x "${MOCK_BIN}/gh"

SHA="1234567890abcdef1234567890abcdef12345678"
OUTPUT="${TMP_DIR}/evidence.json"
RUN_ENV=(
  env
  "PATH=${MOCK_BIN}:${PATH}"
  "RELAYKIT_TEST_SHA=${SHA}"
)

RELAYKIT_TEST_SCENARIO=success "${RUN_ENV[@]}" \
  "${ROOT_DIR}/scripts/github-required-checks.sh" \
  --repo example/relaykit --sha "${SHA}" --output "${OUTPUT}"

jq -e --arg sha "${SHA}" '
  .schema_version == 1 and
  .source_commit_sha == $sha and
  (.checks | length == 6) and
  ([.checks[].name] == [
    "Fast Public Boundary",
    "Fast Shell Contracts",
    "Fast Go Quality",
    "macOS App",
    "macOS Runtime Safety",
    "Protocol Contract"
  ]) and
  ([.checks[] | keys] | all(. == ["app_slug", "conclusion", "details_url", "id", "name"])) and
  ([.checks[].app_slug] | all(. == "github-actions")) and
  ([.checks[].conclusion] | all(. == "success")) and
  (.actions_runs | length == 6) and
  ([.actions_runs[] | keys] | all(. == ["id", "url"])) and
  ([.actions_runs[].id] | unique | length == 6)
' "${OUTPUT}" >/dev/null || fail "success evidence schema is invalid"

for scenario in missing duplicate failure wrong-sha foreign-app malformed query-error; do
  scenario_output="${TMP_DIR}/${scenario}.json"
  if RELAYKIT_TEST_SCENARIO="${scenario}" "${RUN_ENV[@]}" \
    "${ROOT_DIR}/scripts/github-required-checks.sh" \
    --repo example/relaykit --sha "${SHA}" --output "${scenario_output}" >/dev/null 2>&1; then
    fail "${scenario} response unexpectedly succeeded"
  fi
  [[ ! -e "${scenario_output}" ]] || fail "${scenario} response left evidence behind"
done

printf '%s\n' "github required checks tests passed"
