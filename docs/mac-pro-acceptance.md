# Mac Pro Direct Replacement Acceptance

## Current Blocker

Mac Pro `NL77R52RMY` at `192.168.50.97` is reachable by network, but SSH is not usable:

- ICMP ping responds.
- TCP port `22` accepts connections.
- SSH times out before the server banner with `Connection timed out during banner exchange`.
- Raw `nc` to port `22` receives no `SSH-2.0` banner.
- Screen Sharing `5900` and Remote Management `3283` are closed.

This pauses RelayKit acceptance. It does not prove a RelayKit product failure, and Mac mini `127.0.0.1:18787` must not be used as acceptance evidence.

## Mac Pro Recovery

Someone with physical or GUI access to the Mac Pro should do one of:

1. Toggle System Settings -> General -> Sharing -> Remote Login off, then on.
2. Run in Mac Pro Terminal:

   ```bash
   sudo launchctl kickstart -k system/com.openssh.sshd
   ```

3. Reboot the Mac Pro if Remote Login or `sshd` restart does not recover SSH.

## Post-Recovery Check

From the Mac mini:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 -o ControlMaster=no -o ControlPath=none bytedance@192.168.50.97 'hostname; date'
```

Or run the resume helper:

```bash
./scripts/mac-pro-acceptance-resume.sh
```

If SSH is still wedged, the helper exits with a clear SSH banner blocker message and does not touch RelayKit state.

## Acceptance Commands

After SSH works, the resume helper checks the Mac Pro runtime only:

```bash
./scripts/mac-pro-acceptance-resume.sh
```

Manual equivalent:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 -o ControlMaster=no -o ControlPath=none bytedance@192.168.50.97 '
  cd /Users/bytedance/workplace/RelayKit-acceptance &&
  lsof -nP -iTCP:18787 -sTCP:LISTEN &&
  awk "/^[[:space:]]*model_provider[[:space:]]*=/{print}" ~/.codex/config.toml &&
  RELAYKIT_ACCEPTANCE_URL=http://127.0.0.1:18787 ./scripts/direct-replacement-check.sh
'
```

For the final private-model proof, run from the Mac Pro only and keep model IDs out of reports:

```bash
cd /Users/bytedance/workplace/RelayKit-acceptance
# Read the current model from ~/.codex/config.toml locally, then call RelayKit:
# curl -fsS http://127.0.0.1:18787/v1/responses ...
```

For real Codex proof, use the explicit Codex path if shell `PATH` does not find it:

```bash
/Users/bytedance/.local/share/fnm/node-versions/v22.22.2/installation/bin/codex exec --skip-git-repo-check --ignore-rules --ephemeral \
  --output-last-message /tmp/relaykit-real-codex-last.txt \
  "Reply exactly OK. Do not run tools." </dev/null
```

## Acceptance Criteria

- SSH to Mac Pro works from Mac mini.
- Mac Pro `127.0.0.1:18787` listener command is RelayKit `relay`, not `agent-local-gateway` or a bridge.
- Mac Pro `~/.codex/config.toml` has `model_provider = "gateway"`.
- `/v1/models` includes OpenAI-compatible `data` and Codex-compatible `models`.
- Catalog evidence is not all hidden: visible `data`/`models` count is greater than zero and `model_health.healthy` is greater than zero.
- Current o47 path returns successful `/v1/responses` text through RelayKit.
- Real Codex exec through the Mac Pro config returns `OK`.
- No private model IDs, provider config contents, key material, cookies, JWTs, or raw private logs are printed or committed.
