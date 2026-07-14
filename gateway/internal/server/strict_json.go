package server

import (
	"bytes"
	"encoding/json"
	"fmt"
)

func strictJSONObject(body []byte) (map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(body))
	first, err := decoder.Token()
	if err != nil {
		return nil, fmt.Errorf("invalid JSON object")
	}
	delim, ok := first.(json.Delim)
	if !ok || delim != '{' {
		return nil, fmt.Errorf("JSON value must be an object")
	}

	object := make(map[string]json.RawMessage)
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			return nil, fmt.Errorf("invalid JSON object")
		}
		key, ok := keyToken.(string)
		if !ok {
			return nil, fmt.Errorf("invalid JSON object")
		}
		if _, exists := object[key]; exists {
			return nil, fmt.Errorf("duplicate JSON object field")
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return nil, fmt.Errorf("invalid JSON object")
		}
		object[key] = value
	}
	if _, err := decoder.Token(); err != nil {
		return nil, fmt.Errorf("invalid JSON object")
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return nil, fmt.Errorf("invalid JSON object")
	}
	return object, nil
}
