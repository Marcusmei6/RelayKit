# RelayKit Beta Feedback

Generate the redacted diagnostics file before reporting:

```bash
./scripts/export-diagnostics.sh
```

Attach only `dist/diagnostics/diagnostics.json`. Do not attach provider config, Keychain exports, Codex auth files, or raw gateway logs.

## Environment

- macOS version:
- Codex Desktop version:
- RelayKit build or zip name:
- Provider type: OpenAI-compatible / Anthropic-compatible / other
- Diagnostics bundle attached: yes / no

## Setup

- App launched: yes / no
- Provider saved: yes / no
- API key state showed saved in Keychain: yes / no
- Test connection result:
- Detect models result:

## Routing

- Models listed in RelayKit: yes / no
- Models listed in isolated Codex Desktop profile: yes / no
- Request routed successfully: yes / no
- Public model id used, if safe to share:
- Error text, with private details removed:

## Tool Calls

- Tool-call display looked correct: yes / no / not tested
- Tool output appeared in the conversation: yes / no / not tested
- Formatting issue observed:

## Usage

- Usage page updated after request: yes / no
- Provider/model grouping looked right: yes / no
- UI felt slow or stuck:

## Screenshots

Attach only redacted screenshots. Hide:

- API keys;
- bearer tokens;
- provider base URLs;
- private model names if sensitive;
- account names;
- local usernames;
- raw request or response bodies.

## Notes

- What was confusing?
- What should be easier before a wider beta?
