#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --repo owner/repo --sha <40-char-sha> --output /absolute/path/evidence.json" >&2
}

fail() {
  echo "$1" >&2
  exit 1
}

repo=""
sha=""
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --sha) sha="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "repo must be an explicit owner/repo"
[[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || fail "sha must be a lowercase 40-character commit SHA"
[[ "${output}" = /* ]] || fail "output must be an absolute path"
[[ -d "$(dirname "${output}")" ]] || fail "output parent directory does not exist"
[[ ! -e "${output}" ]] || fail "output already exists"
command -v gh >/dev/null 2>&1 || fail "missing gh CLI"
command -v jq >/dev/null 2>&1 || fail "missing jq"

raw="$(mktemp "${TMPDIR:-/tmp}/relaykit-check-runs.XXXXXX")"
rendered="$(mktemp "$(dirname "${output}")/.relaykit-required-checks.XXXXXX")"
cleanup() { rm -f "${raw}" "${rendered}"; }
trap cleanup EXIT

if ! gh api --paginate --slurp "repos/${repo}/commits/${sha}/check-runs?per_page=100" >"${raw}"; then
  fail "GitHub check-runs query failed"
fi

required='[
  "Fast Public Boundary",
  "Fast Shell Contracts",
  "Fast Go Quality",
  "macOS App",
  "macOS Runtime Safety",
  "Protocol Contract"
]'

if ! jq -e \
  --arg repo "${repo}" \
  --arg sha "${sha}" \
  --argjson required "${required}" '
    if type != "array" then error("malformed paginated response") else . end
    | [
        .[] |
        if (.check_runs | type) == "array" then .check_runs[]
        else error("malformed check-runs page")
        end
      ] as $all
    | ("https://github.com/" + $repo + "/actions/runs/") as $run_prefix
    | [
        $required[] as $required_name
        | [$all[] | select(.name == $required_name)] as $matches
        | if ($matches | length) != 1 then
            error("required check missing or duplicated")
          else
            $matches[0]
          end
        | if
            (.id | type) != "number" or
            .head_sha != $sha or
            .status != "completed" or
            .conclusion != "success" or
            .app.slug != "github-actions" or
            (.details_url | type) != "string" or
            (.details_url | startswith($run_prefix) | not) or
            (.details_url | ltrimstr($run_prefix) | test("^[0-9]+(/job/[0-9]+)?$") | not)
          then error("required check is not a successful same-SHA Actions result")
          else
            {
              id: .id,
              name: .name,
              details_url: .details_url,
              conclusion: .conclusion,
              app_slug: .app.slug
            }
          end
      ] as $checks
    | {
        schema_version: 1,
        source_commit_sha: $sha,
        checks: $checks,
        actions_runs: (
          [
            $checks[].details_url
            | ltrimstr($run_prefix)
            | split("/")[0]
            | select(test("^[0-9]+$"))
            | {
                id: tonumber,
                url: ($run_prefix + .)
              }
          ]
          | unique_by(.id)
        )
      }
  ' "${raw}" >"${rendered}"; then
  fail "GitHub required checks validation failed"
fi

mv "${rendered}" "${output}"
printf '%s\n' "GitHub required checks evidence written: ${output}"
