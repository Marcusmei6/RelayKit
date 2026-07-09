#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROOF_ROOT="${HOME}/Library/Application Support/RelayKit/DesktopProof"
ISO_HOME="${PROOF_ROOT}/home"
CODEX_HOME_DIR="${PROOF_ROOT}/codex-home"
DESKTOP_USER_DATA_DIR="${PROOF_ROOT}/desktop-user-data"
LOG_DIR="${PROOF_ROOT}/logs"
RUN_DIR="${PROOF_ROOT}/run"
USAGE_PATH="${PROOF_ROOT}/usage.jsonl"
PROVIDER_CONFIG="${PROOF_ROOT}/providers.json"
CATALOG_PATH="${PROOF_ROOT}/model-catalog.json"
CODEX_CONFIG="${CODEX_HOME_DIR}/config.toml"
OUT="${ROOT}/dist/codex-desktop-manual-proof"
BUNDLED_RELAY="${ROOT}/dist/RelayKitApp.app/Contents/MacOS/relay"
CODEX_APP_BINARY="/Applications/Codex.app/Contents/MacOS/Codex"
GLOBAL_CODEX_CONFIG="${HOME}/.codex/config.toml"
GLOBAL_CODEX_AUTH="${HOME}/.codex/auth.json"
PROVIDER_PID_FILE="${RUN_DIR}/provider.pid"
GATEWAY_PID_FILE="${RUN_DIR}/gateway.pid"
DESKTOP_PID_FILE="${RUN_DIR}/codex-desktop.pid"
PORT_FILE="${RUN_DIR}/gateway-port"
PROVIDER_PORT_FILE="${RUN_DIR}/provider-port"
PROVIDER_EVENTS="${LOG_DIR}/provider-events.jsonl"
GATEWAY_LOG="${LOG_DIR}/gateway.log"
DESKTOP_LOG="${LOG_DIR}/codex-desktop.log"
PROVIDER_LOG="${LOG_DIR}/provider.log"
PROVIDER_TOKEN_ENV="RELAYKIT_DESKTOP_PROOF_PROVIDER_TOKEN"
PROVIDER_TOKEN_VALUE="relaykit-desktop-proof-token"
STARTED_AT=""

usage() {
  cat >&2 <<'EOF'
usage: ./scripts/codex-desktop-manual-proof.sh [run|--setup-only|status|cleanup|--purge]

run          Start an isolated RelayKit gateway and Codex Desktop, then wait for
             the user to send manual proof requests.
--setup-only Build/setup/verify isolated config and stop helper processes.
status       Print the latest redacted proof evidence if present.
cleanup      Stop isolated gateway/provider/Desktop processes.
--purge      Stop processes and remove the isolated DesktopProof directory.
EOF
}

file_signature() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    /usr/bin/stat -f "%m:%z" "${path}"
  else
    printf 'missing'
  fi
}

port_is_free() {
  ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

free_port() {
  python3 - <<'PY'
import socket
for _ in range(100):
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    if port not in (18787, 19777):
        print(port)
        break
else:
    raise SystemExit("could not allocate a safe loopback port")
PY
}

kill_pid_file() {
  local path="$1"
  [[ -f "${path}" ]] || return 0
  local pid
  pid="$(cat "${path}" 2>/dev/null || true)"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  fi
  rm -f "${path}" >/dev/null 2>&1 || true
}

cleanup_processes() {
  kill_pid_file "${GATEWAY_PID_FILE}"
  kill_pid_file "${PROVIDER_PID_FILE}"
  kill_pid_file "${DESKTOP_PID_FILE}"
  pkill -f "${BUNDLED_RELAY} -listen 127.0.0.1:$(cat "${PORT_FILE}" 2>/dev/null || printf impossible)" >/dev/null 2>&1 || true
}

ensure_dirs() {
  mkdir -p "${ISO_HOME}" "${CODEX_HOME_DIR}" "${DESKTOP_USER_DATA_DIR}" "${LOG_DIR}" "${RUN_DIR}" "${OUT}"
  chmod 700 "${PROOF_ROOT}" "${ISO_HOME}" "${CODEX_HOME_DIR}" "${DESKTOP_USER_DATA_DIR}" "${LOG_DIR}" "${RUN_DIR}"
}

start_provider() {
  local provider_port="$1"
  rm -f "${PROVIDER_EVENTS}"
  RELAYKIT_PROVIDER_EVENTS="${PROVIDER_EVENTS}" \
  RELAYKIT_PROVIDER_TOKEN="${PROVIDER_TOKEN_VALUE}" \
  node - "${provider_port}" >"${PROVIDER_LOG}" 2>&1 <<'NODE' &
const fs = require("fs");
const http = require("http");

const port = Number(process.argv[2]);
const events = process.env.RELAYKIT_PROVIDER_EVENTS;
const token = process.env.RELAYKIT_PROVIDER_TOKEN;

function append(event) {
  fs.appendFileSync(events, JSON.stringify({...event, timestamp: new Date().toISOString()}) + "\n");
}

function readJSON(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", chunk => { body += chunk; });
    req.on("end", () => {
      try { resolve(JSON.parse(body || "{}")); } catch (error) { reject(error); }
    });
    req.on("error", reject);
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/healthz") {
    res.writeHead(200, {"Content-Type": "application/json"}).end(JSON.stringify({status: "ok"}));
    return;
  }
  if (req.method === "GET" && req.url === "/v1/models") {
    res.writeHead(200, {"Content-Type": "application/json"}).end(JSON.stringify({
      object: "list",
      data: [{id: "provider-upstream", object: "model", owned_by: "demo"}]
    }));
    return;
  }
  if (req.method !== "POST" || req.url !== "/chat/completions") {
    res.writeHead(404).end();
    return;
  }
  const body = await readJSON(req);
  const authorized = req.headers["x-api-key"] === token;
  append({route: "provider", model: body.model, provider_auth_present: authorized, official_auth_present: Boolean(req.headers.authorization)});
  if (!authorized) {
    res.writeHead(401, {"Content-Type": "application/json"}).end(JSON.stringify({error: "provider auth missing"}));
    return;
  }
  res.writeHead(200, {"Content-Type": "application/json"}).end(JSON.stringify({
    id: "chatcmpl-relaykit-desktop-proof",
    model: body.model,
    choices: [{message: {role: "assistant", content: "RelayKit demo provider response."}, finish_reason: "stop"}],
    usage: {prompt_tokens: 8, completion_tokens: 5, total_tokens: 13}
  }));
});

server.listen(port, "127.0.0.1");
process.on("SIGTERM", () => server.close(() => process.exit(0)));
setInterval(() => {}, 1000);
NODE
  echo "$!" >"${PROVIDER_PID_FILE}"
  for _ in {1..40}; do
    curl -fsS "http://127.0.0.1:${provider_port}/healthz" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "provider fixture did not start" >&2
  exit 1
}

write_provider_config() {
  local provider_port="$1"
  cat >"${PROVIDER_CONFIG}" <<JSON
{
  "official_passthrough": {
    "base_url": "https://api.openai.example/v1",
    "credential_ref": { "kind": "codex_home", "value": "${CODEX_HOME_DIR}" },
    "codex_binary": "codex",
    "models": [
      { "id": "gpt-5.5", "display_name": "GPT-5.5" }
    ]
  },
  "providers": [
    {
      "id": "desktop-proof-demo",
      "name": "Desktop Proof Demo",
      "base_url": "http://127.0.0.1:${provider_port}",
      "api_format": "openai_chat",
      "credential_ref": { "kind": "env", "value": "${PROVIDER_TOKEN_ENV}", "header": "x-api-key" },
      "routing": { "source": "desktop-proof-demo", "model_prefix": "desktop-proof-demo/", "status": "enabled", "visible": true },
      "models": [
        { "id": "desktop-proof-demo/claude-haiku-4-5", "display_name": "Desktop Proof Demo Haiku 4.5", "upstream_model": "provider-upstream" }
      ]
    }
  ]
}
JSON
}

write_catalog() {
  local bundled_models="${RUN_DIR}/codex-bundled-models.json"
  codex debug models --bundled >"${bundled_models}"
  node - "${CATALOG_PATH}" "${bundled_models}" <<'NODE'
const fs = require("fs");
const out = process.argv[2];
const bundled = process.argv[3];
const parsed = JSON.parse(fs.readFileSync(bundled, "utf8"));
const official = parsed.models || [];
const template = official.find(model => model.slug === "gpt-5.5") || official[0];
if (!template) throw new Error("no bundled model template found");
const demo = {
  ...template,
  slug: "desktop-proof-demo/claude-haiku-4-5",
  display_name: "Desktop Proof Demo Haiku 4.5",
  description: "RelayKit public-safe desktop proof demo route.",
  source: "desktop-proof-demo",
  owned_by: "demo",
  visibility: "list",
  priority: 100,
  upstream_model: "provider-upstream",
  protocol: "responses",
  transport: "local_relaykit",
  status: "ready",
  object: "model",
  supported_in_api: true,
  upgrade: null,
  availability_nux: null,
  additional_speed_tiers: [],
  service_tiers: []
};
fs.writeFileSync(out, JSON.stringify({models: [...official, demo]}, null, 2) + "\n");
NODE
  cp "${CATALOG_PATH}" "${OUT}/model-catalog.json"
}

write_codex_config() {
  local gateway_port="$1"
  cat >"${CODEX_CONFIG}" <<TOML
model = "gpt-5.5"
model_provider = "openai"
openai_base_url = "http://127.0.0.1:${gateway_port}/v1"
model_catalog_json = "${CATALOG_PATH}"
TOML
  cp "${CODEX_CONFIG}" "${OUT}/codex-config.toml"
}

start_gateway() {
  local gateway_port="$1"
  rm -f "${USAGE_PATH}" "${GATEWAY_LOG}"
  env "${PROVIDER_TOKEN_ENV}=${PROVIDER_TOKEN_VALUE}" \
  "${BUNDLED_RELAY}" -listen "127.0.0.1:${gateway_port}" -config "${PROVIDER_CONFIG}" -usage-log "${USAGE_PATH}" >"${GATEWAY_LOG}" 2>&1 &
  echo "$!" >"${GATEWAY_PID_FILE}"
  for _ in {1..60}; do
    curl -fsS "http://127.0.0.1:${gateway_port}/healthz" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  echo "RelayKit gateway did not start" >&2
  cat "${GATEWAY_LOG}" >&2 || true
  exit 1
}

write_app_server_evidence() {
  HOME="${ISO_HOME}" CODEX_HOME="${CODEX_HOME_DIR}" node - "${OUT}/app-server.json" <<'NODE'
const {spawn} = require("child_process");
const fs = require("fs");
const out = process.argv[2];
const child = spawn("codex", ["app-server", "--listen", "stdio://"], {stdio: ["pipe", "pipe", "pipe"], env: process.env});
let buffer = "";
const messages = [];
let wrote = false;
child.stdout.on("data", data => {
  buffer += data.toString();
  let idx;
  while ((idx = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, idx).trim();
    buffer = buffer.slice(idx + 1);
    if (!line) continue;
    try { messages.push(JSON.parse(line)); } catch {}
  }
});
child.stderr.resume();
function send(msg) { child.stdin.write(JSON.stringify(msg) + "\n"); }
function finish() {
  if (wrote) return;
  wrote = true;
  const config = messages.find(m => m.id === 2)?.result?.config;
  const models = messages.find(m => m.id === 3)?.result?.data || [];
  fs.writeFileSync(out, JSON.stringify({
    config: {model: config?.model, model_provider: config?.model_provider},
    official: models.filter(model => model.model === "gpt-5.5").map(model => ({model: model.model, displayName: model.displayName, hidden: model.hidden})),
    provider: models.filter(model => model.model && model.model.startsWith("desktop-proof-demo/")).map(model => ({model: model.model, displayName: model.displayName, hidden: model.hidden}))
  }, null, 2) + "\n");
  child.kill("SIGTERM");
  setTimeout(() => process.exit(0), 100);
}
send({id: 1, method: "initialize", params: {clientInfo: {name: "relaykit-desktop-proof", title: null, version: "1.0.0"}, capabilities: {experimentalApi: true, requestAttestation: false}}});
send({id: 2, method: "config/read", params: {}});
send({id: 3, method: "model/list", params: {includeHidden: false}});
const timer = setInterval(() => {
  if (messages.some(m => m.id === 2) && messages.some(m => m.id === 3)) {
    clearInterval(timer);
    finish();
  }
}, 100);
setTimeout(finish, 20000);
NODE
}

summarize_usage() {
  if [[ -f "${USAGE_PATH}" ]]; then
    "${BUNDLED_RELAY}" summarize-usage -path "${USAGE_PATH}" >"${OUT}/usage-summary.json"
    jq -s '.' "${USAGE_PATH}" >"${OUT}/usage-events.json"
  else
    printf '[]\n' >"${OUT}/usage-summary.json"
    printf '[]\n' >"${OUT}/usage-events.json"
  fi
}

write_evidence() {
  local manual_status="$1"
  local route_status="$2"
  local config_before="$3"
  local auth_before="$4"
  local gateway_port
  local provider_port
  gateway_port="$(cat "${PORT_FILE}" 2>/dev/null || true)"
  provider_port="$(cat "${PROVIDER_PORT_FILE}" 2>/dev/null || true)"
  summarize_usage
  if [[ -n "${gateway_port}" ]] && curl -fsS "http://127.0.0.1:${gateway_port}/v1/models" >"${OUT}/gateway-models.tmp" 2>/dev/null; then
    mv "${OUT}/gateway-models.tmp" "${OUT}/gateway-models.json"
  else
    rm -f "${OUT}/gateway-models.tmp"
    [[ -f "${OUT}/gateway-models.json" ]] || printf '{"data":[]}\n' >"${OUT}/gateway-models.json"
  fi
  local config_after auth_after port18787 port19777 gateway_released
  config_after="$(file_signature "${GLOBAL_CODEX_CONFIG}")"
  auth_after="$(file_signature "${GLOBAL_CODEX_AUTH}")"
  port18787=false
  port19777=false
  gateway_released=false
  port_is_free 18787 && port18787=true
  port_is_free 19777 && port19777=true
  [[ -n "${gateway_port}" ]] && port_is_free "${gateway_port}" && gateway_released=true
  jq -n \
    --arg proof_root "${PROOF_ROOT}" \
    --arg manual_status "${manual_status}" \
    --arg route_status "${route_status}" \
    --arg config_before "${config_before}" \
    --arg config_after "${config_after}" \
    --arg auth_before "${auth_before}" \
    --arg auth_after "${auth_after}" \
    --arg gateway_port "${gateway_port}" \
    --arg provider_port "${provider_port}" \
    --arg started_at "${STARTED_AT}" \
    --argjson port18787 "${port18787}" \
    --argjson port19777 "${port19777}" \
    --argjson gateway_released "${gateway_released}" \
    --slurpfile gateway "${OUT}/gateway-models.json" \
    --slurpfile app_server "${OUT}/app-server.json" \
    --slurpfile usage "${OUT}/usage-events.json" \
    '{
      proof_root: $proof_root,
      manual_status: $manual_status,
      route_proof_status: $route_status,
      started_at: $started_at,
      gateway_port: $gateway_port,
      provider_port: $provider_port,
      gateway_health_ok: (($gateway[0].data // []) | length > 0),
      gateway_models_include_demo: (([$gateway[0].data[]?.id] | index("gpt-5.5")) and ([$gateway[0].data[]?.id] | index("desktop-proof-demo/claude-haiku-4-5"))),
      gateway_model_health: {healthy: (($gateway[0].data // []) | length)},
      generated_config_model: "gpt-5.5",
      app_server_demo_models: ($app_server[0].provider // []),
      app_server_official_models: ($app_server[0].official // []),
      isolated_app_server_lists_official_and_provider: (([$app_server[0].official[]?.model] | index("gpt-5.5")) and ([$app_server[0].provider[]?.model] | index("desktop-proof-demo/claude-haiku-4-5"))),
      usage_event_count: ($usage[0] | length),
      usage_models: ($usage[0] | map(.model) | unique | sort),
      fresh_current_run_usage_event: (($usage[0] | length) > 0),
      desktop_gui_route_proof: (if $route_status == "manual_route_proof_passed" then "manual_user_assisted" else "not_complete" end),
      desktop_gui_tool_ui_review: "user_required",
      mock_ok_used: false,
      old_usage_evidence_used: false,
      global_config_signature_before: $config_before,
      global_config_signature_after: $config_after,
      global_auth_signature_before: $auth_before,
      global_auth_signature_after: $auth_after,
      global_config_unchanged: ($config_before == $config_after),
      global_auth_unchanged: ($auth_before == $auth_after),
      shared_18787_free_after: $port18787,
      shared_19777_free_after: $port19777,
      gateway_port_released: $gateway_released
    }' >"${OUT}/evidence.json"
  cp "${OUT}/usage-events.json" "${OUT}/usage-proof.json"
}

setup_preflight() {
  ensure_dirs
  STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  rm -rf "${OUT}"
  mkdir -p "${OUT}"
  cleanup_processes
  "${ROOT}/script/build_app_bundle.sh" --verify >/dev/null
  test -x "${BUNDLED_RELAY}"

  local provider_port gateway_port
  provider_port="$(free_port)"
  gateway_port="$(free_port)"
  while [[ "${provider_port}" == "${gateway_port}" ]]; do
    gateway_port="$(free_port)"
  done
  echo "${provider_port}" >"${PROVIDER_PORT_FILE}"
  echo "${gateway_port}" >"${PORT_FILE}"

  start_provider "${provider_port}"
  write_provider_config "${provider_port}"
  write_catalog
  write_codex_config "${gateway_port}"
  start_gateway "${gateway_port}"

  curl -fsS "http://127.0.0.1:${gateway_port}/v1/models" >"${OUT}/gateway-models.json"
  jq -e '([.data[].id] | index("gpt-5.5") and index("desktop-proof-demo/claude-haiku-4-5"))' "${OUT}/gateway-models.json" >/dev/null
  HOME="${ISO_HOME}" CODEX_HOME="${CODEX_HOME_DIR}" codex debug models >"${OUT}/codex-debug-models.json"
  jq -e '([.models[].slug] | index("gpt-5.5") and index("desktop-proof-demo/claude-haiku-4-5"))' "${OUT}/codex-debug-models.json" >/dev/null
  write_app_server_evidence
  jq -e '.config.model == "gpt-5.5" and ([.official[].model] | index("gpt-5.5")) and ([.provider[].model] | index("desktop-proof-demo/claude-haiku-4-5"))' "${OUT}/app-server.json" >/dev/null
}

launch_desktop() {
  if [[ ! -x "${CODEX_APP_BINARY}" ]]; then
    echo "Codex Desktop binary not found at ${CODEX_APP_BINARY}" >&2
    exit 1
  fi
  HOME="${ISO_HOME}" CODEX_HOME="${CODEX_HOME_DIR}" "${CODEX_APP_BINARY}" --user-data-dir "${DESKTOP_USER_DATA_DIR}" >"${DESKTOP_LOG}" 2>&1 &
  echo "$!" >"${DESKTOP_PID_FILE}"
}

verify_manual_usage() {
  local event_count official_count provider_count
  summarize_usage
  event_count="$(jq 'length' "${OUT}/usage-events.json")"
  official_count="$(jq '[.[] | select(.model == "gpt-5.5" and (.status // "") == "completed")] | length' "${OUT}/usage-events.json")"
  provider_count="$(jq '[.[] | select(.model == "desktop-proof-demo/claude-haiku-4-5" and (.status // "") == "completed")] | length' "${OUT}/usage-events.json")"
  if [[ "${event_count}" -gt 0 && "${official_count}" -gt 0 && "${provider_count}" -gt 0 ]]; then
    return 0
  fi
  return 1
}

case "${MODE}" in
  run)
    trap cleanup_processes EXIT
    CONFIG_BEFORE="$(file_signature "${GLOBAL_CODEX_CONFIG}")"
    AUTH_BEFORE="$(file_signature "${GLOBAL_CODEX_AUTH}")"
    setup_preflight
    write_evidence "awaiting_user_login" "not_started_manual_user_step" "${CONFIG_BEFORE}" "${AUTH_BEFORE}"
    launch_desktop
    cat <<EOF
RelayKit isolated Desktop proof is ready.

Keep this terminal open. In the isolated Codex Desktop window:
1. Sign in if Codex asks.
2. Confirm the model picker lists:
   - gpt-5.5
   - desktop-proof-demo/claude-haiku-4-5
3. Send a simple request with each model.
4. Send one tool/command request and visually confirm Codex Desktop does not show raw XML/function_call text.

Gateway: http://127.0.0.1:$(cat "${PORT_FILE}")/v1
Isolated CODEX_HOME: ${CODEX_HOME_DIR}
Evidence: ${OUT}/evidence.json

Press Enter here after the requests finish.
EOF
    read -r _
    if verify_manual_usage; then
      write_evidence "manual_route_proof_passed" "manual_route_proof_passed" "${CONFIG_BEFORE}" "${AUTH_BEFORE}"
      echo "RelayKit manual Desktop proof passed: ${OUT}/evidence.json"
    else
      write_evidence "manual_route_proof_missing" "manual_route_proof_missing" "${CONFIG_BEFORE}" "${AUTH_BEFORE}"
      echo "RelayKit manual Desktop proof did not find both completed usage events: ${OUT}/evidence.json" >&2
      exit 1
    fi
    ;;
  --setup-only|setup)
    trap cleanup_processes EXIT
    CONFIG_BEFORE="$(file_signature "${GLOBAL_CODEX_CONFIG}")"
    AUTH_BEFORE="$(file_signature "${GLOBAL_CODEX_AUTH}")"
    setup_preflight
    write_evidence "setup_preflight_passed" "not_started_manual_user_step" "${CONFIG_BEFORE}" "${AUTH_BEFORE}"
    cleanup_processes
    write_evidence "setup_preflight_passed" "not_started_manual_user_step" "${CONFIG_BEFORE}" "${AUTH_BEFORE}"
    echo "RelayKit manual Desktop proof setup passed: ${OUT}/evidence.json"
    ;;
  status)
    if [[ -f "${OUT}/evidence.json" ]]; then
      jq '.' "${OUT}/evidence.json"
    else
      echo "No manual Desktop proof evidence found at ${OUT}/evidence.json" >&2
      exit 1
    fi
    ;;
  cleanup)
    cleanup_processes
    echo "RelayKit manual Desktop proof processes stopped"
    ;;
  --purge|purge)
    cleanup_processes
    rm -rf "${PROOF_ROOT}" "${OUT}"
    echo "RelayKit manual Desktop proof state removed"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
