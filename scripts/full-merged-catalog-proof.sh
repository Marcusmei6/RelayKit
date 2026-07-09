#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/dist/full-merged-catalog-proof"
TMPROOT="$(mktemp -d /tmp/relaykit-full-catalog-XXXXXX)"
CODEX_HOME_DIR="${TMPROOT}/codex-home"
ISO_HOME="${TMPROOT}/home"
CONFIG_PATH="${TMPROOT}/providers.json"
USAGE_PATH="${TMPROOT}/usage.jsonl"
BUNDLED_RELAY="${ROOT}/dist/RelayKitApp.app/Contents/MacOS/relay"
CODEX_CONFIG_PATH="${HOME}/.codex/config.toml"
CODEX_AUTH_PATH="${HOME}/.codex/auth.json"
FAKE_PID=""
GATEWAY_PID=""
GATEWAY_PORT=""

file_signature() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    /usr/bin/stat -f "%m:%z" "${path}"
  else
    printf 'missing'
  fi
}

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

port_is_free() {
  ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

cleanup() {
  if [[ -n "${GATEWAY_PID}" ]] && kill -0 "${GATEWAY_PID}" 2>/dev/null; then
    kill "${GATEWAY_PID}" >/dev/null 2>&1 || true
    wait "${GATEWAY_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${FAKE_PID}" ]] && kill -0 "${FAKE_PID}" 2>/dev/null; then
    kill "${FAKE_PID}" >/dev/null 2>&1 || true
    wait "${FAKE_PID}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMPROOT}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

secret_value() {
  uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-'
}

mkdir -p "${OUT}" "${CODEX_HOME_DIR}" "${ISO_HOME}"
rm -f "${OUT}/"*

CONFIG_BEFORE="$(file_signature "${CODEX_CONFIG_PATH}")"
AUTH_BEFORE="$(file_signature "${CODEX_AUTH_PATH}")"
port_is_free 18787
port_is_free 19777

"${ROOT}/script/build_and_run.sh" --verify >/dev/null
test -x "${BUNDLED_RELAY}"

OFFICIAL_AUTH_VALUE="$(secret_value)"
PROVIDER_AUTH_VALUE="$(secret_value)"
FAKE_META="${TMPROOT}/fake-upstreams.json"
FAKE_EVENTS="${TMPROOT}/fake-upstream-events.jsonl"

RELAYKIT_FAKE_OFFICIAL_AUTH="${OFFICIAL_AUTH_VALUE}" \
RELAYKIT_FAKE_PROVIDER_AUTH="${PROVIDER_AUTH_VALUE}" \
RELAYKIT_FAKE_META="${FAKE_META}" \
RELAYKIT_FAKE_EVENTS="${FAKE_EVENTS}" \
node <<'NODE' &
const fs = require("fs");
const http = require("http");

const officialAuth = process.env.RELAYKIT_FAKE_OFFICIAL_AUTH;
const providerAuth = process.env.RELAYKIT_FAKE_PROVIDER_AUTH;
const metaPath = process.env.RELAYKIT_FAKE_META;
const eventsPath = process.env.RELAYKIT_FAKE_EVENTS;

function appendEvent(event) {
  fs.appendFileSync(eventsPath, JSON.stringify(event) + "\n");
}

function readJSON(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (chunk) => { body += chunk; });
    req.on("end", () => {
      try { resolve(JSON.parse(body || "{}")); } catch (error) { reject(error); }
    });
    req.on("error", reject);
  });
}

function chatResponse(model, text) {
  return JSON.stringify({
    id: `chatcmpl-${model.replace(/[^a-z0-9]/gi, "-")}`,
    model,
    choices: [{ message: { role: "assistant", content: text }, finish_reason: "stop" }],
    usage: { prompt_tokens: 1, completion_tokens: 1 }
  });
}

const official = http.createServer(async (req, res) => {
  if (req.method !== "POST" || req.url !== "/chat/completions") {
    res.writeHead(404).end();
    return;
  }
  const body = await readJSON(req);
  const ok = req.headers.authorization === `Bearer ${officialAuth}`;
  const providerHeaderPresent = Boolean(req.headers["x-api-key"]);
  appendEvent({ route: "official", model: body.model, official_auth_present: ok, provider_auth_present: providerHeaderPresent });
  if (!ok || providerHeaderPresent) {
    res.writeHead(401, { "Content-Type": "application/json" }).end(JSON.stringify({ error: "bad official auth boundary" }));
    return;
  }
  res.writeHead(200, { "Content-Type": "application/json" }).end(chatResponse(body.model, "OFFICIAL"));
});

const provider = http.createServer(async (req, res) => {
  if (req.method !== "POST" || req.url !== "/chat/completions") {
    res.writeHead(404).end();
    return;
  }
  const body = await readJSON(req);
  const providerOK = req.headers["x-api-key"] === providerAuth;
  const officialHeaderPresent = Boolean(req.headers.authorization);
  appendEvent({ route: "provider", model: body.model, provider_auth_present: providerOK, official_auth_present: officialHeaderPresent });
  if (!providerOK || officialHeaderPresent) {
    res.writeHead(401, { "Content-Type": "application/json" }).end(JSON.stringify({ error: "bad provider auth boundary" }));
    return;
  }
  res.writeHead(200, { "Content-Type": "application/json" }).end(chatResponse(body.model, "PROVIDER"));
});

let ready = 0;
function maybeReady() {
  ready += 1;
  if (ready === 2) {
    fs.writeFileSync(metaPath, JSON.stringify({
      official_port: official.address().port,
      provider_port: provider.address().port
    }) + "\n");
  }
}
official.listen(0, "127.0.0.1", maybeReady);
provider.listen(0, "127.0.0.1", maybeReady);
process.on("SIGTERM", () => {
  official.close();
  provider.close();
  process.exit(0);
});
setInterval(() => {}, 1000);
NODE
FAKE_PID="$!"
for _ in {1..40}; do
  [[ -s "${FAKE_META}" ]] && break
  sleep 0.1
done
test -s "${FAKE_META}"
OFFICIAL_PORT="$(jq -r '.official_port' "${FAKE_META}")"
PROVIDER_PORT="$(jq -r '.provider_port' "${FAKE_META}")"

cat >"${CONFIG_PATH}" <<JSON
{
  "official_passthrough": {
    "base_url": "http://127.0.0.1:${OFFICIAL_PORT}",
    "credential_ref": { "kind": "env", "value": "RELAYKIT_FAKE_OFFICIAL_AUTH" },
    "models": [
      { "id": "gpt-5.5", "display_name": "GPT-5.5" }
    ]
  },
  "providers": [
    {
      "id": "demo",
      "name": "Demo Relay",
      "base_url": "http://127.0.0.1:${PROVIDER_PORT}",
      "api_format": "openai_chat",
      "credential_ref": { "kind": "env", "value": "RELAYKIT_FAKE_PROVIDER_AUTH", "header": "x-api-key" },
      "routing": { "source": "demo", "model_prefix": "demo/", "status": "enabled", "visible": true },
      "models": [
        { "id": "demo/claude-haiku-4-5", "display_name": "Demo Claude Haiku 4.5", "upstream_model": "provider-upstream" }
      ]
    }
  ]
}
JSON

GATEWAY_PORT="$(free_port)"
if [[ "${GATEWAY_PORT}" == "18787" || "${GATEWAY_PORT}" == "19777" ]]; then
  GATEWAY_PORT="$(free_port)"
fi
port_is_free "${GATEWAY_PORT}"
RELAYKIT_FAKE_OFFICIAL_AUTH="${OFFICIAL_AUTH_VALUE}" \
RELAYKIT_FAKE_PROVIDER_AUTH="${PROVIDER_AUTH_VALUE}" \
"${BUNDLED_RELAY}" -listen "127.0.0.1:${GATEWAY_PORT}" -config "${CONFIG_PATH}" -usage-log "${USAGE_PATH}" >"${TMPROOT}/gateway.log" 2>&1 &
GATEWAY_PID="$!"
for _ in {1..40}; do
  curl -fsS "http://127.0.0.1:${GATEWAY_PORT}/healthz" >/dev/null 2>&1 && break
  sleep 0.25
done
curl -fsS "http://127.0.0.1:${GATEWAY_PORT}/healthz" | jq -e '.service == "relaykit" and .status == "ok"' >/dev/null
curl -fsS "http://127.0.0.1:${GATEWAY_PORT}/v1/models" >"${OUT}/gateway-models.json"
jq -e '([.data[].id] | index("gpt-5.5") and index("demo/claude-haiku-4-5"))' "${OUT}/gateway-models.json" >/dev/null

CATALOG_PATH="${CODEX_HOME_DIR}/relaykit-merged-catalog.json"
codex debug models --bundled | node -e '
const fs = require("fs");
const out = process.argv[1];
const parsed = JSON.parse(fs.readFileSync(0, "utf8"));
const official = parsed.models || [];
const template = official.find((model) => model.slug === "gpt-5.5") || official[0];
if (!template) throw new Error("no bundled model template found");
const demo = {
  ...template,
  slug: "demo/claude-haiku-4-5",
  display_name: "Demo Claude Haiku 4.5",
  description: "RelayKit Demo Claude Haiku 4.5 route.",
  source: "demo",
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
fs.writeFileSync(out, JSON.stringify({ models: [...official, demo] }, null, 2) + "\n");
' "${CATALOG_PATH}"
cp "${CATALOG_PATH}" "${OUT}/model-catalog.json"

cat >"${CODEX_HOME_DIR}/config.toml" <<TOML
model = "gpt-5.5"
model_provider = "openai"
openai_base_url = "http://127.0.0.1:${GATEWAY_PORT}/v1"
model_catalog_json = "${CATALOG_PATH}"
TOML
cp "${CODEX_HOME_DIR}/config.toml" "${OUT}/codex-config.toml"
HOME="${ISO_HOME}" CODEX_HOME="${CODEX_HOME_DIR}" codex debug models >"${OUT}/codex-debug-models.json"
jq -e '([.models[].slug] | index("gpt-5.5") and index("demo/claude-haiku-4-5"))' "${OUT}/codex-debug-models.json" >/dev/null

HOME="${ISO_HOME}" CODEX_HOME="${CODEX_HOME_DIR}" node - "${OUT}/app-server.json" <<'NODE'
const { spawn } = require("child_process");
const fs = require("fs");
const out = process.argv[2];
const child = spawn("codex", ["app-server", "--listen", "stdio://"], { stdio: ["pipe", "pipe", "pipe"], env: process.env });
let buffer = "";
const messages = [];
let wrote = false;
child.stdout.on("data", (data) => {
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
const send = (msg) => child.stdin.write(JSON.stringify(msg) + "\n");
function finish() {
  if (wrote) return;
  wrote = true;
  const config = messages.find((m) => m.id === 2)?.result?.config;
  const models = messages.find((m) => m.id === 3)?.result?.data || [];
  fs.writeFileSync(out, JSON.stringify({
    config: { model: config?.model, model_provider: config?.model_provider },
    official: models.filter((model) => model.model === "gpt-5.5").map((model) => ({ model: model.model, displayName: model.displayName, hidden: model.hidden })),
    provider: models.filter((model) => model.model && model.model.startsWith("demo/")).map((model) => ({ model: model.model, displayName: model.displayName, hidden: model.hidden }))
  }, null, 2) + "\n");
  child.kill("SIGTERM");
  setTimeout(() => process.exit(0), 100);
}
send({ id: 1, method: "initialize", params: { clientInfo: { name: "relaykit-full-merged-proof", title: null, version: "1.0.0" }, capabilities: { experimentalApi: true, requestAttestation: false } } });
send({ id: 2, method: "config/read", params: {} });
send({ id: 3, method: "model/list", params: { includeHidden: false } });
const interval = setInterval(() => {
  if (messages.some((m) => m.id === 2) && messages.some((m) => m.id === 3)) {
    clearInterval(interval);
    finish();
  }
}, 100);
setTimeout(finish, 20000);
NODE
jq -e '.config.model == "gpt-5.5" and ([.official[].model] | index("gpt-5.5")) and ([.provider[].model] | index("demo/claude-haiku-4-5"))' "${OUT}/app-server.json" >/dev/null

curl -fsS -H "Content-Type: application/json" \
  -d '{"model":"gpt-5.5","input":"reply OK"}' \
  "http://127.0.0.1:${GATEWAY_PORT}/v1/responses" >"${OUT}/official-response.json"
curl -fsS -H "Content-Type: application/json" \
  -d '{"model":"demo/claude-haiku-4-5","input":"reply OK"}' \
  "http://127.0.0.1:${GATEWAY_PORT}/v1/responses" >"${OUT}/provider-response.json"
UNKNOWN_STATUS="$(curl -sS -o "${OUT}/unknown-model.json" -w '%{http_code}' -H "Content-Type: application/json" \
  -d '{"model":"missing-model","input":"reply OK"}' \
  "http://127.0.0.1:${GATEWAY_PORT}/v1/responses")"
[[ "${UNKNOWN_STATUS}" == "400" ]]
grep -q 'unknown model' "${OUT}/unknown-model.json"

"${BUNDLED_RELAY}" summarize-usage -path "${USAGE_PATH}" >"${OUT}/usage-summary.json"
jq -s '.' "${FAKE_EVENTS}" >"${OUT}/upstream-events.json"
jq -e '
  (map(select(.route == "official" and .official_auth_present == true and .provider_auth_present == false)) | length) == 1 and
  (map(select(.route == "provider" and .provider_auth_present == true and .official_auth_present == false)) | length) == 1
' "${OUT}/upstream-events.json" >/dev/null

if grep -R "${OFFICIAL_AUTH_VALUE}" "${OUT}" "${CONFIG_PATH}" "${USAGE_PATH}" "${TMPROOT}/gateway.log" >/dev/null 2>&1; then
  echo "official auth value leaked to proof files" >&2
  exit 1
fi

cleanup
trap - EXIT
GATEWAY_PID=""
FAKE_PID=""
GATEWAY_RELEASED=false
port_is_free "${GATEWAY_PORT}" && GATEWAY_RELEASED=true
SHARED_18787_FREE=false
SHARED_19777_FREE=false
port_is_free 18787 && SHARED_18787_FREE=true
port_is_free 19777 && SHARED_19777_FREE=true
CONFIG_AFTER="$(file_signature "${CODEX_CONFIG_PATH}")"
AUTH_AFTER="$(file_signature "${CODEX_AUTH_PATH}")"

jq -n \
  --arg config_before "${CONFIG_BEFORE}" \
  --arg config_after "${CONFIG_AFTER}" \
  --arg auth_before "${AUTH_BEFORE}" \
  --arg auth_after "${AUTH_AFTER}" \
  --argjson gateway_released "${GATEWAY_RELEASED}" \
  --argjson port18787 "${SHARED_18787_FREE}" \
  --argjson port19777 "${SHARED_19777_FREE}" \
  --slurpfile gateway "${OUT}/gateway-models.json" \
  --slurpfile app_server "${OUT}/app-server.json" \
  --slurpfile events "${OUT}/upstream-events.json" \
  '{
    full_merged_gateway_models: (([$gateway[0].data[]?.id] | index("gpt-5.5")) and ([$gateway[0].data[]?.id] | index("demo/claude-haiku-4-5"))),
    isolated_app_server_lists_official_and_provider: (([$app_server[0].official[]?.model] | index("gpt-5.5")) and ([$app_server[0].provider[]?.model] | index("demo/claude-haiku-4-5"))),
    official_request_hit_fake_official: (($events[0] | map(select(.route == "official" and .official_auth_present == true and .provider_auth_present == false)) | length) == 1),
    provider_request_hit_fake_provider: (($events[0] | map(select(.route == "provider" and .provider_auth_present == true and .official_auth_present == false)) | length) == 1),
    unknown_model_rejected: true,
    official_auth_not_in_provider_config_or_logs_or_evidence: true,
    global_config_signature_before: $config_before,
    global_config_signature_after: $config_after,
    global_auth_signature_before: $auth_before,
    global_auth_signature_after: $auth_after,
    global_config_unchanged: ($config_before == $config_after),
    global_auth_unchanged: ($auth_before == $auth_after),
    gateway_port_released: $gateway_released,
    shared_18787_free_after: $port18787,
    shared_19777_free_after: $port19777
  }' >"${OUT}/evidence.json"

if grep -R "${OFFICIAL_AUTH_VALUE}" "${OUT}" >/dev/null 2>&1; then
  echo "official auth value leaked to proof evidence" >&2
  exit 1
fi
jq -e '
  .full_merged_gateway_models == true and
  .isolated_app_server_lists_official_and_provider == true and
  .official_request_hit_fake_official == true and
  .provider_request_hit_fake_provider == true and
  .unknown_model_rejected == true and
  .official_auth_not_in_provider_config_or_logs_or_evidence == true and
  .global_config_unchanged == true and
  .global_auth_unchanged == true and
  .gateway_port_released == true and
  .shared_18787_free_after == true and
  .shared_19777_free_after == true
' "${OUT}/evidence.json" >/dev/null

printf 'RelayKit full merged catalog proof passed: %s\n' "${OUT}"
