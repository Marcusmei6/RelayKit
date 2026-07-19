package server

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"syscall"
)

const officialStructuralTracePathEnv = "RELAYKIT_OFFICIAL_STRUCTURAL_TRACE_PATH"

type officialStructuralTrace struct {
	mu   sync.Mutex
	file *os.File
}

type officialStructuralTraceEvent struct {
	RequestFields     []officialStructuralTraceField    `json:"request_fields"`
	Input             officialStructuralTraceInput      `json:"input"`
	CustomToolCalls   []officialStructuralTraceToolItem `json:"custom_tool_calls"`
	CustomToolOutputs []officialStructuralTraceToolItem `json:"custom_tool_outputs"`
	Rejection         officialStructuralTraceRejection  `json:"rejection"`
}

type officialStructuralTraceInput struct {
	Type  string                             `json:"type"`
	Items []officialStructuralTraceInputItem `json:"items,omitempty"`
}

type officialStructuralTraceInputItem struct {
	Index   int                                  `json:"index"`
	Type    string                               `json:"type"`
	Fields  []officialStructuralTraceField       `json:"fields"`
	Content []officialStructuralTraceContentItem `json:"content,omitempty"`
}

type officialStructuralTraceContentItem struct {
	Index  int                            `json:"index"`
	Type   string                         `json:"type"`
	Fields []officialStructuralTraceField `json:"fields"`
}

type officialStructuralTraceField struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

type officialStructuralTraceToolItem struct {
	Index         int                                  `json:"index"`
	Type          string                               `json:"type"`
	Fields        []officialStructuralTraceField       `json:"fields"`
	CallID        officialStructuralTraceCallID        `json:"call_id"`
	OutputVariant string                               `json:"output_variant,omitempty"`
	OutputItems   []officialStructuralTraceContentItem `json:"output_items,omitempty"`
}

type officialStructuralTraceCallID struct {
	Type   string `json:"type"`
	Length int    `json:"length"`
	SHA256 string `json:"sha256,omitempty"`
	Match  bool   `json:"match"`
}

type officialStructuralTraceRejection struct {
	Field   string `json:"field"`
	Variant string `json:"variant"`
}

type officialStructuralRejectionError struct {
	field   string
	variant string
	message string
}

func (e *officialStructuralRejectionError) Error() string {
	return e.message
}

func newOfficialStructuralRejectionError(field, variant, message string) error {
	return &officialStructuralRejectionError{field: field, variant: variant, message: message}
}

func newOfficialStructuralTraceFromEnv() (*officialStructuralTrace, error) {
	path := os.Getenv(officialStructuralTracePathEnv)
	if path == "" {
		return nil, nil
	}
	if !filepath.IsAbs(path) {
		return nil, fmt.Errorf("official structural trace path must be absolute")
	}
	if err := validateOfficialStructuralTraceDirectory(filepath.Dir(path)); err != nil {
		return nil, err
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSymlink != 0 {
			return nil, fmt.Errorf("official structural trace path must not be a symlink")
		}
		return nil, fmt.Errorf("official structural trace path must not exist")
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("inspect official structural trace path: %w", err)
	}

	fd, err := syscall.Open(path, syscall.O_WRONLY|syscall.O_CREAT|syscall.O_EXCL|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, fmt.Errorf("create official structural trace: %w", err)
	}
	if err := syscall.Fchmod(fd, 0600); err != nil {
		_ = syscall.Close(fd)
		return nil, fmt.Errorf("set official structural trace permissions: %w", err)
	}
	syscall.CloseOnExec(fd)
	file := os.NewFile(uintptr(fd), path)
	if file == nil {
		_ = syscall.Close(fd)
		return nil, fmt.Errorf("create official structural trace file")
	}
	return &officialStructuralTrace{file: file}, nil
}

func validateOfficialStructuralTraceDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("inspect official structural trace directory: %w", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0700 {
		return fmt.Errorf("official structural trace directory must be a non-symlink owner-only 0700 directory")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) {
		return fmt.Errorf("official structural trace directory must be owned by the current user")
	}
	return nil
}

func (t *officialStructuralTrace) recordRejectedOfficialRequest(request map[string]json.RawMessage, input json.RawMessage, rejection officialStructuralTraceRejection) {
	if t == nil {
		return
	}
	event := officialStructuralTraceForRejectedRequest(request, input, rejection)
	encoded, err := json.Marshal(event)
	if err != nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	_, _ = t.file.Write(append(encoded, '\n'))
}

func officialStructuralTraceForRejectedRequest(request map[string]json.RawMessage, input json.RawMessage, rejection officialStructuralTraceRejection) officialStructuralTraceEvent {
	event := officialStructuralTraceEvent{
		RequestFields: officialStructuralTraceRequestFields(request),
		Input:         officialStructuralTraceInput{Type: officialStructuralJSONType(input)},
		Rejection:     rejection,
	}
	var items []json.RawMessage
	if json.Unmarshal(input, &items) != nil {
		return event
	}
	event.Input.Items = make([]officialStructuralTraceInputItem, 0, len(items))
	callValues := make([]string, 0)
	outputValues := make([]string, 0)
	for index, rawItem := range items {
		object, ok := officialStructuralJSONObject(rawItem)
		if !ok {
			event.Input.Items = append(event.Input.Items, officialStructuralTraceInputItem{
				Index:  index,
				Type:   "non_object",
				Fields: nil,
			})
			continue
		}
		itemType := officialStructuralTypeValue(object["type"])
		item := officialStructuralTraceInputItem{
			Index:   index,
			Type:    itemType,
			Fields:  officialStructuralTraceFields(object),
			Content: officialStructuralTraceContent(object["content"]),
		}
		event.Input.Items = append(event.Input.Items, item)
		switch itemType {
		case "custom_tool_call":
			callID, value := officialStructuralTraceCallIDFor(object["call_id"])
			event.CustomToolCalls = append(event.CustomToolCalls, officialStructuralTraceToolItem{
				Index:  index,
				Type:   itemType,
				Fields: officialStructuralTraceFields(object),
				CallID: callID,
			})
			callValues = append(callValues, value)
		case "custom_tool_call_output":
			callID, value := officialStructuralTraceCallIDFor(object["call_id"])
			event.CustomToolOutputs = append(event.CustomToolOutputs, officialStructuralTraceToolItem{
				Index:         index,
				Type:          itemType,
				Fields:        officialStructuralTraceFields(object),
				CallID:        callID,
				OutputVariant: officialStructuralOutputVariant(object),
				OutputItems:   officialStructuralTraceOutputItems(object["output"]),
			})
			outputValues = append(outputValues, value)
		}
	}
	for index := range event.CustomToolCalls {
		event.CustomToolCalls[index].CallID.Match = officialStructuralCallIDMatches(callValues[index], outputValues)
	}
	for index := range event.CustomToolOutputs {
		event.CustomToolOutputs[index].CallID.Match = officialStructuralCallIDMatches(outputValues[index], callValues)
	}
	return event
}

func officialStructuralTraceRequestFields(request map[string]json.RawMessage) []officialStructuralTraceField {
	fields := make([]officialStructuralTraceField, 0, len(request))
	for name, value := range request {
		if !officialStructuralSafeRequestField(name) {
			continue
		}
		fields = append(fields, officialStructuralTraceField{Name: name, Type: officialStructuralJSONType(value)})
	}
	sort.Slice(fields, func(i, j int) bool {
		return fields[i].Name < fields[j].Name
	})
	return fields
}

func officialStructuralSafeRequestField(name string) bool {
	switch name {
	case "background", "conversation", "include", "input", "instructions", "max_output_tokens", "max_tool_calls", "metadata", "model", "parallel_tool_calls", "previous_response_id", "reasoning", "service_tier", "store", "stream", "temperature", "text", "tool_choice", "tools", "top_p", "truncation", "user":
		return true
	default:
		return false
	}
}

func officialStructuralJSONObject(raw json.RawMessage) (map[string]json.RawMessage, bool) {
	var object map[string]json.RawMessage
	if json.Unmarshal(raw, &object) != nil || object == nil {
		return nil, false
	}
	return object, true
}

func officialStructuralTraceFields(object map[string]json.RawMessage) []officialStructuralTraceField {
	fields := make([]officialStructuralTraceField, 0, len(object))
	for name, value := range object {
		fields = append(fields, officialStructuralTraceField{
			Name: officialStructuralFieldName(name),
			Type: officialStructuralJSONType(value),
		})
	}
	sort.Slice(fields, func(i, j int) bool {
		if fields[i].Name == fields[j].Name {
			return fields[i].Type < fields[j].Type
		}
		return fields[i].Name < fields[j].Name
	})
	return fields
}

func officialStructuralTraceContent(raw json.RawMessage) []officialStructuralTraceContentItem {
	var items []json.RawMessage
	if json.Unmarshal(raw, &items) != nil {
		return nil
	}
	content := make([]officialStructuralTraceContentItem, 0, len(items))
	for index, rawItem := range items {
		object, ok := officialStructuralJSONObject(rawItem)
		if !ok {
			content = append(content, officialStructuralTraceContentItem{Index: index, Type: "non_object"})
			continue
		}
		content = append(content, officialStructuralTraceContentItem{
			Index:  index,
			Type:   officialStructuralTypeValue(object["type"]),
			Fields: officialStructuralTraceFields(object),
		})
	}
	return content
}

func officialStructuralTraceOutputItems(raw json.RawMessage) []officialStructuralTraceContentItem {
	if officialStructuralJSONType(raw) != "array" {
		return nil
	}
	return officialStructuralTraceContent(raw)
}

func officialStructuralTraceCallIDFor(raw json.RawMessage) (officialStructuralTraceCallID, string) {
	callID := officialStructuralTraceCallID{Type: officialStructuralJSONType(raw)}
	var value string
	if callID.Type != "string" || json.Unmarshal(raw, &value) != nil {
		return callID, ""
	}
	sum := sha256.Sum256([]byte(value))
	callID.Length = len(value)
	callID.SHA256 = hex.EncodeToString(sum[:])
	return callID, value
}

func officialStructuralCallIDMatches(value string, candidates []string) bool {
	if value == "" {
		return false
	}
	for _, candidate := range candidates {
		if candidate != "" && candidate == value {
			return true
		}
	}
	return false
}

func officialStructuralOutputVariant(object map[string]json.RawMessage) string {
	hasOutput := rawJSONPresent(object["output"])
	hasContent := rawJSONPresent(object["content"])
	switch {
	case hasOutput && hasContent:
		return "ambiguous"
	case hasOutput:
		switch officialStructuralJSONType(object["output"]) {
		case "string":
			return "string"
		case "object":
			return "object"
		case "array":
			return "structured_content_array"
		default:
			return "other"
		}
	case hasContent:
		return "content"
	default:
		return "missing"
	}
}

func officialStructuralRejectionForError(err error) officialStructuralTraceRejection {
	var rejection *officialStructuralRejectionError
	if errors.As(err, &rejection) {
		return officialStructuralTraceRejection{Field: rejection.field, Variant: rejection.variant}
	}
	return officialStructuralTraceRejection{Field: "explicit_shell_roundtrip", Variant: "rejected"}
}

func officialStructuralTypeValue(raw json.RawMessage) string {
	var value string
	if officialStructuralJSONType(raw) != "string" || json.Unmarshal(raw, &value) != nil {
		return "non_string"
	}
	if officialStructuralSafeType(value) {
		return value
	}
	return "other"
}

func officialStructuralSafeType(value string) bool {
	switch value {
	case "additional_tools", "custom", "custom_tool_call", "custom_tool_call_output", "function", "function_call", "function_call_output", "input_text", "message", "text":
		return true
	default:
		return false
	}
}

func officialStructuralFieldName(name string) string {
	switch name {
	case "arguments", "call_id", "content", "input", "name", "output", "role", "text", "tools", "type":
		return name
	default:
		return "other"
	}
}

func officialStructuralJSONType(raw json.RawMessage) string {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 {
		return "missing"
	}
	switch raw[0] {
	case '{':
		return "object"
	case '[':
		return "array"
	case '"':
		return "string"
	case 't', 'f':
		return "boolean"
	case 'n':
		return "null"
	default:
		return "number"
	}
}
