#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  jq -n --arg code "$1" '{status:"failed",error_code:$code}' >&2
  exit 1
}

[[ "${1:-}" == "--model" && -n "${2:-}" && "${3:-}" == "--query-file" && -n "${4:-}" &&
   "${5:-}" == "--expect" && -n "${6:-}" && "${7:-}" == "--catalog-evidence" && -n "${8:-}" &&
   "${9:-}" == "--catalog-sha256" && -n "${10:-}" && "${11:-}" == "--catalog-setup-id" && -n "${12:-}" &&
   "${13:-}" == "--catalog-session-id" && -n "${14:-}" && "${15:-}" == "--artifact-sha256" && -n "${16:-}" && -z "${17:-}" ]] ||
  fail "invalid_arguments"

model="$2"
query_file="$4"
expect="$6"
catalog_evidence="$8"
catalog_sha256="${10}"
catalog_setup_id="${12}"
catalog_session_id="${14}"
artifact_sha256="${16}"
harness="${RELAYKIT_DESKTOP_QUERY_HARNESS:-${ROOT}/scripts/codex-desktop-manual-proof.sh}"
official_lifecycle="${RELAYKIT_DESKTOP_QUERY_OFFICIAL_LIFECYCLE:-}"
artifact_path="${RELAYKIT_DESKTOP_QUERY_ARTIFACT_PATH:-${ROOT}/dist/RelayKitApp-local.zip}"

[[ "${query_file}" = /* && -f "${query_file}" && ! -L "${query_file}" && "$(stat -f '%Lp' "${query_file}")" == "600" ]] ||
  fail "query_file_invalid"
[[ "${expect}" == "plain" || "${expect}" == "markdown" || "${expect}" == "tool" ]] || fail "expect_invalid"
[[ "${catalog_evidence}" = /* && -f "${catalog_evidence}" && ! -L "${catalog_evidence}" ]] || fail "catalog_evidence_unavailable"
[[ "${catalog_sha256}" =~ ^[0-9a-f]{64}$ && "${artifact_sha256}" =~ ^[0-9a-f]{64}$ ]] || fail "evidence_hash_invalid"
[[ "${catalog_setup_id}" =~ ^[A-Za-z0-9._:-]{1,128}$ && "${catalog_session_id}" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || fail "catalog_lineage_invalid"
[[ "$(shasum -a 256 "${catalog_evidence}" | awk '{print $1}')" == "${catalog_sha256}" ]] || fail "catalog_evidence_stale"
[[ -f "${artifact_path}" && ! -L "${artifact_path}" && "$(shasum -a 256 "${artifact_path}" | awk '{print $1}')" == "${artifact_sha256}" ]] || fail "artifact_evidence_stale"
jq -e \
  --arg setup_id "${catalog_setup_id}" \
  --arg session_id "${catalog_session_id}" \
  --arg artifact_sha256 "${artifact_sha256}" \
  '.relaykit_lineage == {setup_id:$setup_id,session_id:$session_id,artifact_sha256:$artifact_sha256}' \
  "${catalog_evidence}" >/dev/null 2>&1 || fail "catalog_lineage_stale"
[[ -x "${harness}" ]] || fail "harness_unavailable"
if [[ -z "${official_lifecycle}" && "${harness}" == "${ROOT}/scripts/codex-desktop-manual-proof.sh" ]]; then
  official_lifecycle="${ROOT}/scripts/codex-desktop-query-official-once.sh"
fi

resolved_model="$(jq -ce --arg requested "${model}" '
  [(.official[]? | . + {source_type:"official"}), (.provider[]? | . + {source_type:"provider"})]
  | map(select(.model == $requested or .displayName == $requested))
  | select(length == 1)
  | .[0]
' "${catalog_evidence}" 2>/dev/null)" || fail "model_not_unique_or_missing"
model_id="$(jq -er '.model' <<<"${resolved_model}")"
model_label="$(jq -er '.displayName' <<<"${resolved_model}")"
model_source="$(jq -er '.source_type' <<<"${resolved_model}")"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/relaykit-desktop-query-backend.XXXXXX")"
chmod 700 "${tmp}"
trap 'rm -rf "${tmp}"' EXIT
staged_query="${tmp}/query.txt"
scenario="${tmp}/scenario.json"
marker="RELAYKIT_DESKTOP_QUERY_$(date -u +%Y%m%dT%H%M%SZ)_$$"

cp "${query_file}" "${staged_query}"
printf '\n\nFor automation verification, end the response with a separate final line containing exactly: %s\n' "${marker}" >>"${staged_query}"
chmod 600 "${staged_query}"
[[ "$(stat -f '%z' "${staged_query}")" -le 65536 ]] || fail "query_file_size"

jq -n \
  --arg model_id "${model_id}" \
  --arg model_label "${model_label}" \
  --arg query_file "${staged_query}" \
  --arg marker "${marker}" \
  '{
    version: 1,
    stage_timeout_seconds: 420,
    stages: [{
      id: "desktop-query",
      model_id: $model_id,
      model_label: $model_label,
      query_file: $query_file,
      response_marker: $marker,
      evidence_role: "desktop-query-response",
      expect: $expect
    }]
  }' --arg expect "${expect}" >"${scenario}"
chmod 600 "${scenario}"

harness_stdout="${tmp}/harness.stdout"
harness_stderr="${tmp}/harness.stderr"
filtered_stderr="${tmp}/harness.filtered.stderr"
harness_status=0
set +e
if [[ "${model_source}" == "official" && -n "${official_lifecycle}" ]]; then
  if [[ ! -x "${official_lifecycle}" ]]; then
    jq -nc '{status:"failed",error_code:"official_lifecycle_unavailable"}' >"${harness_stderr}"
    harness_status=1
  else
    "${official_lifecycle}" \
      --model "${model_id}" \
      --query-file "${staged_query}" \
      --expect "${expect}" \
      --catalog-evidence "${catalog_evidence}" \
      --catalog-sha256 "${catalog_sha256}" \
      --artifact-sha256 "${artifact_sha256}" \
      >"${harness_stdout}" 2>"${harness_stderr}"
    harness_status=$?
  fi
elif [[ "${harness}" == "${ROOT}/scripts/codex-desktop-manual-proof.sh" ]]; then
  if [[ "${model_source}" == "provider" ]]; then
    provider_config="${RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG:-}"
    [[ -f "${provider_config}" ]] || fail "provider_precondition_unavailable"
    RELAYKIT_DESKTOP_PROOF_REAL_PROVIDER_CONFIG="${provider_config}" \
    RELAYKIT_DESKTOP_PROOF_PUBLIC_MODEL_ID="${model_id}" \
    RELAYKIT_DESKTOP_PROOF_REUSE_CURRENT_ZIP="${RELAYKIT_DESKTOP_PROOF_REUSE_CURRENT_ZIP:-1}" \
    RELAYKIT_DESKTOP_PROOF_REUSE_EXTRACTED_APP="${RELAYKIT_DESKTOP_PROOF_REUSE_EXTRACTED_APP:-1}" \
    RELAYKIT_DESKTOP_PROOF_INPUT_MODE=automated_ax \
      "${harness}" run-auto --scenario "${scenario}" </dev/null >"${harness_stdout}" 2>"${harness_stderr}"
  else
    RELAYKIT_DESKTOP_PROOF_REUSE_CURRENT_ZIP="${RELAYKIT_DESKTOP_PROOF_REUSE_CURRENT_ZIP:-1}" \
    RELAYKIT_DESKTOP_PROOF_REUSE_EXTRACTED_APP="${RELAYKIT_DESKTOP_PROOF_REUSE_EXTRACTED_APP:-1}" \
    RELAYKIT_DESKTOP_PROOF_INPUT_MODE=automated_ax \
      "${harness}" run-auto --scenario "${scenario}" </dev/null >"${harness_stdout}" 2>"${harness_stderr}"
  fi
  harness_status=$?
else
  "${harness}" run-auto --scenario "${scenario}" </dev/null >"${harness_stdout}" 2>"${harness_stderr}"
  harness_status=$?
fi
set -e

grep -Ev 'Terminated: 15.*sandbox-exec' "${harness_stderr}" >"${filtered_stderr}" || true
if [[ "${harness_status}" -ne 0 ]]; then
  failure_meta="$(python3 - "${filtered_stderr}" "${harness_stdout}" <<'PY'
import json
import sys

found = []
decoder = json.JSONDecoder()
for path in sys.argv[1:]:
    try:
        text = open(path, errors="replace").read()
    except OSError:
        continue
    for index, char in enumerate(text):
        if char != "{":
            continue
        try:
            value, _ = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and isinstance(value.get("error_code"), str):
            found.append(value)
value = found[-1] if found else {}
print(json.dumps({
    "error_code": value.get("error_code", "harness_failed"),
    "evidence_path": value.get("evidence"),
    "submission_state": value.get("submission_state"),
}, sort_keys=True))
PY
)"
  error_code="$(jq -r '.error_code' <<<"${failure_meta}")"
  evidence_path="$(jq -r '.evidence_path // empty' <<<"${failure_meta}")"
  submission_state="$(jq -r '.submission_state // empty' <<<"${failure_meta}")"
  if [[ -z "${submission_state}" ]]; then
    case "${error_code}" in
      provider_input_missing_or_invalid|input_mode_invalid|scenario_invalid|scenario_argument_invalid|global_state_capture_failed|preflight_failed|preflight_evidence_failed|ax_driver_build_failed|desktop_catalog_labels_invalid|desktop_launch_failed|desktop_activation_failed|desktop_window_identity_invalid|desktop_initial_capture_failed|desktop_pid_invalid)
        submission_state="not_submitted"
        ;;
      *)
        submission_state="unknown_after_submit_attempt"
        ;;
    esac
  fi
  jq -nc \
    --arg error_code "${error_code}" \
    --arg model "${model_id}" \
    --arg expect "${expect}" \
    --arg submission_state "${submission_state}" \
    --arg evidence_path "${evidence_path}" \
    --arg artifact_sha256 "${artifact_sha256}" \
    --arg catalog_sha256 "${catalog_sha256}" \
    '{status:"failed",error_code:$error_code,model:$model,expect:$expect,submission_state:$submission_state,evidence_path:(if $evidence_path == "" then null else $evidence_path end),artifact_sha256:$artifact_sha256,catalog_sha256:$catalog_sha256}' >&2
  exit "${harness_status}"
fi

jq -e -s 'length == 1 and (.[0] | type == "object")' "${harness_stdout}" >/dev/null ||
  fail "harness_result_invalid"
[[ -s "${filtered_stderr}" ]] && cat "${filtered_stderr}" >&2
jq -c \
  --arg model "${model_id}" \
  --arg expect "${expect}" \
  --arg catalog_sha256 "${catalog_sha256}" \
  --arg artifact_sha256 "${artifact_sha256}" \
  '{
    status: .status,
    model: $model,
    expect: $expect,
    submission_state: (.submission_state // .stages[0].submission_state // "unknown"),
    evidence_path: .evidence,
    artifact_sha256: $artifact_sha256,
    catalog_sha256: $catalog_sha256
  }' "${harness_stdout}"
