package server

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestOfficialStructuralTraceDefaultOff(t *testing.T) {
	dir := t.TempDir()
	tracePath := filepath.Join(dir, "official-trace.jsonl")
	t.Setenv("RELAYKIT_OFFICIAL_STRUCTURAL_TRACE_PATH", "")

	h, err := New(officialStructuralTraceConfig(t, dir))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	_ = officialStructuralTraceWebSocketResponse(t, h)
	if _, err := os.Stat(tracePath); !os.IsNotExist(err) {
		t.Fatalf("default-off trace file stat err = %v, want not exist", err)
	}
}

func TestOfficialStructuralTraceRedactsValues(t *testing.T) {
	dir := t.TempDir()
	traceDir := filepath.Join(dir, "trace")
	if err := os.Mkdir(traceDir, 0700); err != nil {
		t.Fatal(err)
	}
	tracePath := filepath.Join(traceDir, "official-trace.jsonl")
	t.Setenv("RELAYKIT_OFFICIAL_STRUCTURAL_TRACE_PATH", tracePath)

	h, err := New(officialStructuralTraceConfig(t, dir))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	_ = officialStructuralTraceWebSocketResponse(t, h)

	raw, err := os.ReadFile(tracePath)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(tracePath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("trace mode = %o, want 600", info.Mode().Perm())
	}
	for _, value := range []string{
		"RELAYKIT_FAKE_SENTINEL_MODEL",
		"RELAYKIT_FAKE_SENTINEL_COMMAND",
		"RELAYKIT_FAKE_SENTINEL_CALL",
		"RELAYKIT_FAKE_SENTINEL_OUTPUT",
		"RELAYKIT_FAKE_SENTINEL_TOP_LEVEL",
		"RELAYKIT_FAKE_SENTINEL_FIELD_NAME",
	} {
		if strings.Contains(string(raw), value) {
			t.Fatalf("trace leaked raw value %q: %s", value, raw)
		}
	}

	var event struct {
		Input struct {
			Type  string `json:"type"`
			Items []struct {
				Index int    `json:"index"`
				Type  string `json:"type"`
			} `json:"items"`
		} `json:"input"`
		CustomToolCalls []struct {
			CallID struct {
				Length int    `json:"length"`
				SHA256 string `json:"sha256"`
				Match  bool   `json:"match"`
			} `json:"call_id"`
		} `json:"custom_tool_calls"`
		CustomToolOutputs []struct {
			OutputVariant string `json:"output_variant"`
		} `json:"custom_tool_outputs"`
		Rejection struct {
			Field   string `json:"field"`
			Variant string `json:"variant"`
		} `json:"rejection"`
	}
	if err := json.Unmarshal(raw, &event); err != nil {
		t.Fatalf("decode trace: %v; raw=%s", err, raw)
	}
	if event.Input.Type != "array" || len(event.Input.Items) != 4 || event.Input.Items[2].Type != "custom_tool_call" || event.Input.Items[3].Type != "custom_tool_call_output" {
		t.Fatalf("input structure = %#v", event.Input)
	}
	if len(event.CustomToolCalls) != 1 || len(event.CustomToolOutputs) != 1 || event.CustomToolOutputs[0].OutputVariant != "string" {
		t.Fatalf("custom tool structure = calls=%#v outputs=%#v", event.CustomToolCalls, event.CustomToolOutputs)
	}
	wantHash := sha256.Sum256([]byte("RELAYKIT_FAKE_SENTINEL_CALL"))
	if got := event.CustomToolCalls[0].CallID; got.Length != len("RELAYKIT_FAKE_SENTINEL_CALL") || got.SHA256 != hex.EncodeToString(wantHash[:]) || !got.Match {
		t.Fatalf("call id structure = %#v", got)
	}
	if event.Rejection.Field != "call_input" || event.Rejection.Variant != "mismatch" {
		t.Fatalf("rejection = %#v", event.Rejection)
	}
}

func TestOfficialStructuralTraceCapturesSafeTopLevelFields(t *testing.T) {
	dir := t.TempDir()
	traceDir := filepath.Join(dir, "trace")
	if err := os.Mkdir(traceDir, 0700); err != nil {
		t.Fatal(err)
	}
	tracePath := filepath.Join(traceDir, "official-trace.jsonl")
	t.Setenv("RELAYKIT_OFFICIAL_STRUCTURAL_TRACE_PATH", tracePath)
	h, err := New(officialStructuralTraceConfig(t, dir))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	_ = officialStructuralTraceWebSocketResponseForRequest(t, h, officialStructuralTraceRequest(officialStructuralTraceInvalidInput("RELAYKIT_FAKE_SENTINEL_COMMAND")))

	var event struct {
		RequestFields []officialStructuralTraceField `json:"request_fields"`
	}
	if err := json.Unmarshal(readOfficialStructuralTrace(t, tracePath), &event); err != nil {
		t.Fatal(err)
	}
	for name, wantType := range map[string]string{
		"input":  "array",
		"model":  "string",
		"store":  "boolean",
		"stream": "boolean",
		"tools":  "array",
	} {
		if got := officialStructuralTraceFieldType(event.RequestFields, name); got != wantType {
			t.Fatalf("top-level field %q type = %q, want %q; fields=%#v", name, got, wantType, event.RequestFields)
		}
	}
	if got := officialStructuralTraceFieldType(event.RequestFields, "RELAYKIT_FAKE_SENTINEL_TOP_LEVEL"); got != "" {
		t.Fatalf("unknown top-level field leaked as %q", got)
	}
}

func TestOfficialStructuralTraceCapturesOutputStructure(t *testing.T) {
	tests := []struct {
		name         string
		output       any
		wantVariant  string
		wantItemType string
	}{
		{
			name:        "string",
			output:      "RELAYKIT_FAKE_SENTINEL_OUTPUT",
			wantVariant: "string",
		},
		{
			name: "object",
			output: map[string]any{
				"type": "input_text",
				"text": "RELAYKIT_FAKE_SENTINEL_OUTPUT",
			},
			wantVariant: "object",
		},
		{
			name: "structured content array",
			output: []map[string]any{{
				"type":                              "input_text",
				"text":                              "RELAYKIT_FAKE_SENTINEL_OUTPUT",
				"RELAYKIT_FAKE_SENTINEL_FIELD_NAME": "RELAYKIT_FAKE_SENTINEL_VALUE",
			}},
			wantVariant:  "structured_content_array",
			wantItemType: "input_text",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			traceDir := filepath.Join(dir, "trace")
			if err := os.Mkdir(traceDir, 0700); err != nil {
				t.Fatal(err)
			}
			tracePath := filepath.Join(traceDir, "official-trace.jsonl")
			t.Setenv("RELAYKIT_OFFICIAL_STRUCTURAL_TRACE_PATH", tracePath)
			h, err := New(officialStructuralTraceConfig(t, dir))
			if err != nil {
				t.Fatalf("New err = %v", err)
			}
			input := officialStructuralTraceInvalidInput("RELAYKIT_FAKE_SENTINEL_COMMAND")
			input[3].(map[string]any)["output"] = tc.output
			_ = officialStructuralTraceWebSocketResponseForRequest(t, h, officialStructuralTraceRequest(input))

			var event struct {
				CustomToolOutputs []struct {
					OutputVariant string                               `json:"output_variant"`
					OutputItems   []officialStructuralTraceContentItem `json:"output_items"`
				} `json:"custom_tool_outputs"`
			}
			raw := readOfficialStructuralTrace(t, tracePath)
			if err := json.Unmarshal(raw, &event); err != nil {
				t.Fatal(err)
			}
			if len(event.CustomToolOutputs) != 1 || event.CustomToolOutputs[0].OutputVariant != tc.wantVariant {
				t.Fatalf("output structure = %#v", event.CustomToolOutputs)
			}
			if tc.wantItemType != "" {
				items := event.CustomToolOutputs[0].OutputItems
				if len(items) != 1 || items[0].Index != 0 || items[0].Type != tc.wantItemType || officialStructuralTraceFieldType(items[0].Fields, "text") != "string" || officialStructuralTraceFieldType(items[0].Fields, "RELAYKIT_FAKE_SENTINEL_FIELD_NAME") != "" {
					t.Fatalf("output items = %#v", items)
				}
			}
			if strings.Contains(string(raw), "RELAYKIT_FAKE_SENTINEL_VALUE") || strings.Contains(string(raw), "RELAYKIT_FAKE_SENTINEL_FIELD_NAME") {
				t.Fatalf("output trace leaked raw value or field name: %s", raw)
			}
		})
	}
}

func TestOfficialStructuralTraceClassifiesParserRejection(t *testing.T) {
	command := "RELAYKIT_FAKE_SENTINEL_COMMAND"
	validInput, err := codeModeExecProgram(command)
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name        string
		callInput   string
		output      any
		content     any
		malformed   bool
		wantField   string
		wantVariant string
	}{
		{
			name:        "call input mismatch",
			callInput:   "RELAYKIT_FAKE_SENTINEL_MISMATCH",
			output:      "done",
			wantField:   "call_input",
			wantVariant: "mismatch",
		},
		{
			name:        "ambiguous output",
			callInput:   validInput,
			output:      "done",
			content:     "also done",
			wantField:   "tool_output",
			wantVariant: "ambiguous",
		},
		{
			name:        "unsupported output",
			callInput:   validInput,
			output:      true,
			wantField:   "tool_output",
			wantVariant: "unsupported",
		},
		{
			name:        "malformed output",
			callInput:   validInput,
			output:      "done",
			malformed:   true,
			wantField:   "tool_output",
			wantVariant: "malformed",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			traceDir := filepath.Join(dir, "trace")
			if err := os.Mkdir(traceDir, 0700); err != nil {
				t.Fatal(err)
			}
			tracePath := filepath.Join(traceDir, "official-trace.jsonl")
			t.Setenv("RELAYKIT_OFFICIAL_STRUCTURAL_TRACE_PATH", tracePath)
			h, err := New(officialStructuralTraceConfig(t, dir))
			if err != nil {
				t.Fatalf("New err = %v", err)
			}
			input := officialStructuralTraceInvalidInput(command)
			call := input[2].(map[string]any)
			call["input"] = tc.callInput
			output := input[3].(map[string]any)
			output["output"] = tc.output
			if tc.content != nil {
				output["content"] = tc.content
			}
			if tc.malformed {
				output["call_id"] = ""
			}
			_ = officialStructuralTraceWebSocketResponseForRequest(t, h, officialStructuralTraceRequest(input))

			var event struct {
				Rejection officialStructuralTraceRejection `json:"rejection"`
			}
			if err := json.Unmarshal(readOfficialStructuralTrace(t, tracePath), &event); err != nil {
				t.Fatal(err)
			}
			if event.Rejection.Field != tc.wantField || event.Rejection.Variant != tc.wantVariant {
				t.Fatalf("rejection = %#v, want %s/%s", event.Rejection, tc.wantField, tc.wantVariant)
			}
		})
	}
}

func TestOfficialStructuralTraceDoesNotMatchMissingOrNonStringCallIDs(t *testing.T) {
	for name, input := range map[string][]map[string]any{
		"missing": {
			{"type": "custom_tool_call", "name": "exec", "input": "ignored"},
			{"type": "custom_tool_call_output", "output": "ignored"},
		},
		"non-string": {
			{"type": "custom_tool_call", "call_id": true, "name": "exec", "input": "ignored"},
			{"type": "custom_tool_call_output", "call_id": true, "output": "ignored"},
		},
	} {
		t.Run(name, func(t *testing.T) {
			raw, err := json.Marshal(input)
			if err != nil {
				t.Fatal(err)
			}
			event := officialStructuralTraceForRejectedRequest(nil, raw, officialStructuralTraceRejection{Field: "test", Variant: "test"})
			if len(event.CustomToolCalls) != 1 || len(event.CustomToolOutputs) != 1 {
				t.Fatalf("custom tool structure = %#v/%#v", event.CustomToolCalls, event.CustomToolOutputs)
			}
			if event.CustomToolCalls[0].CallID.Match || event.CustomToolOutputs[0].CallID.Match {
				t.Fatalf("missing or non-string call IDs must not match: %#v/%#v", event.CustomToolCalls[0].CallID, event.CustomToolOutputs[0].CallID)
			}
		})
	}
}

func TestOfficialStructuralTraceRejectsUnsafePath(t *testing.T) {
	dir := t.TempDir()
	traceDir := filepath.Join(dir, "trace")
	if err := os.Mkdir(traceDir, 0700); err != nil {
		t.Fatal(err)
	}
	existing := filepath.Join(traceDir, "existing.jsonl")
	if err := os.WriteFile(existing, []byte("existing"), 0600); err != nil {
		t.Fatal(err)
	}
	insecureDir := filepath.Join(dir, "insecure")
	if err := os.Mkdir(insecureDir, 0755); err != nil {
		t.Fatal(err)
	}
	symlink := filepath.Join(traceDir, "symlink.jsonl")
	if err := os.Symlink(existing, symlink); err != nil {
		t.Fatal(err)
	}

	for name, path := range map[string]string{
		"relative":       "official-trace.jsonl",
		"existing":       existing,
		"insecure dir":   filepath.Join(insecureDir, "official-trace.jsonl"),
		"symlink target": symlink,
	} {
		t.Run(name, func(t *testing.T) {
			t.Setenv("RELAYKIT_OFFICIAL_STRUCTURAL_TRACE_PATH", path)
			if _, err := New(officialStructuralTraceConfig(t, dir)); err == nil {
				t.Fatal("New succeeded for unsafe trace path")
			}
		})
	}
}

func TestOfficialStructuralTraceCapturesProductionRejection(t *testing.T) {
	dir := t.TempDir()
	traceDir := filepath.Join(dir, "trace")
	if err := os.Mkdir(traceDir, 0700); err != nil {
		t.Fatal(err)
	}
	tracePath := filepath.Join(traceDir, "official-trace.jsonl")
	t.Setenv("RELAYKIT_OFFICIAL_STRUCTURAL_TRACE_PATH", tracePath)

	h, err := New(officialStructuralTraceConfig(t, dir))
	if err != nil {
		t.Fatalf("New err = %v", err)
	}
	response := officialStructuralTraceWebSocketResponse(t, h)
	if !strings.Contains(response, `"type":"invalid_request_error"`) {
		t.Fatalf("websocket response = %s", response)
	}
	raw, err := os.ReadFile(tracePath)
	if err != nil {
		t.Fatal(err)
	}
	if lines := strings.Count(string(raw), "\n"); lines != 1 {
		t.Fatalf("trace line count = %d, want 1; raw=%s", lines, raw)
	}
}

func TestOfficialStructuralTraceDoesNotChangeResponse(t *testing.T) {
	dir := t.TempDir()
	configPath := officialStructuralTraceConfig(t, dir)
	t.Setenv("RELAYKIT_OFFICIAL_STRUCTURAL_TRACE_PATH", "")
	withoutTrace, err := New(configPath)
	if err != nil {
		t.Fatalf("New without trace err = %v", err)
	}
	withoutTraceResponse := officialStructuralTraceWebSocketResponse(t, withoutTrace)

	traceDir := filepath.Join(dir, "trace")
	if err := os.Mkdir(traceDir, 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELAYKIT_OFFICIAL_STRUCTURAL_TRACE_PATH", filepath.Join(traceDir, "official-trace.jsonl"))
	withTrace, err := New(configPath)
	if err != nil {
		t.Fatalf("New with trace err = %v", err)
	}
	withTraceResponse := officialStructuralTraceWebSocketResponse(t, withTrace)

	if normalizeOfficialStructuralTraceResponse(t, withoutTraceResponse) != normalizeOfficialStructuralTraceResponse(t, withTraceResponse) {
		t.Fatalf("trace changed websocket response:\nwithout=%s\nwith=%s", withoutTraceResponse, withTraceResponse)
	}
}

func officialStructuralTraceConfig(t *testing.T, dir string) string {
	t.Helper()
	codexHome := filepath.Join(dir, "codex-home")
	if err := os.MkdirAll(codexHome, 0700); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(dir, "providers.json")
	configBody, err := json.Marshal(map[string]any{
		"official_passthrough": map[string]any{
			"base_url":       "https://example.test/v1",
			"credential_ref": map[string]string{"kind": "codex_home", "value": codexHome},
			"models":         []map[string]string{{"id": "RELAYKIT_FAKE_SENTINEL_MODEL"}},
		},
		"providers": []any{},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, configBody, 0600); err != nil {
		t.Fatal(err)
	}
	return configPath
}

func officialStructuralTraceWebSocketResponse(t *testing.T, h http.Handler) string {
	t.Helper()
	return officialStructuralTraceWebSocketResponseForRequest(t, h, officialStructuralTraceRequest(officialStructuralTraceInvalidInput("RELAYKIT_FAKE_SENTINEL_COMMAND")))
}

func officialStructuralTraceWebSocketResponseForRequest(t *testing.T, h http.Handler, request map[string]any) string {
	t.Helper()
	srv := httptest.NewServer(h)
	defer srv.Close()
	conn, reader := openTestWebSocket(t, srv.URL, "/v1/responses")
	defer conn.Close()
	payload, err := json.Marshal(map[string]any{"type": "response.create", "response": request})
	if err != nil {
		t.Fatal(err)
	}
	writeTestWebSocketText(t, conn, string(payload))
	return readTestWebSocketUntil(t, reader, "response.failed")
}

func officialStructuralTraceRequest(input []any) map[string]any {
	return map[string]any{
		"model":                            "RELAYKIT_FAKE_SENTINEL_MODEL",
		"input":                            input,
		"tools":                            []any{},
		"stream":                           false,
		"store":                            true,
		"RELAYKIT_FAKE_SENTINEL_TOP_LEVEL": "RELAYKIT_FAKE_SENTINEL_VALUE",
	}
}

func officialStructuralTraceInvalidInput(command string) []any {
	return []any{
		map[string]any{"type": "additional_tools", "role": "developer", "tools": []map[string]any{{"type": "custom", "name": "exec"}}},
		map[string]any{"type": "message", "role": "user", "content": []map[string]any{{"type": "input_text", "text": `RELAYKIT_EXEC_COMMAND_V1 {"cmd":"` + command + `"}`}}},
		map[string]any{"type": "custom_tool_call", "call_id": "RELAYKIT_FAKE_SENTINEL_CALL", "name": "exec", "input": "RELAYKIT_FAKE_SENTINEL_COMMAND"},
		map[string]any{"type": "custom_tool_call_output", "call_id": "RELAYKIT_FAKE_SENTINEL_CALL", "output": "RELAYKIT_FAKE_SENTINEL_OUTPUT"},
	}
}

func readOfficialStructuralTrace(t *testing.T, path string) []byte {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func officialStructuralTraceFieldType(fields []officialStructuralTraceField, name string) string {
	for _, field := range fields {
		if field.Name == name {
			return field.Type
		}
	}
	return ""
}

func normalizeOfficialStructuralTraceResponse(t *testing.T, raw string) string {
	t.Helper()
	var event map[string]any
	if err := json.Unmarshal([]byte(raw), &event); err != nil {
		t.Fatalf("decode websocket response: %v; raw=%s", err, raw)
	}
	if response, ok := event["response"].(map[string]any); ok {
		delete(response, "id")
	}
	encoded, err := json.Marshal(event)
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}
