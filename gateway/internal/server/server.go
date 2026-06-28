package server

import (
	"encoding/json"
	"net/http"
	"time"
)

func New() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", healthz)
	mux.HandleFunc("GET /v1/models", models)
	mux.HandleFunc("POST /v1/responses", responses)
	return mux
}

func healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"status": "ok",
	})
}

func models(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"data": []map[string]any{
			{
				"id":       "relaykit-demo",
				"object":   "model",
				"created":  time.Now().Unix(),
				"owned_by": "relaykit",
			},
		},
	})
}

func responses(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Content-Type") == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"error": map[string]string{
				"message": "Content-Type is required",
				"type":    "invalid_request_error",
			},
		})
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"id":     "resp_relaykit_demo",
		"object": "response",
		"status": "completed",
		"model":  "relaykit-demo",
		"output": []map[string]any{
			{
				"type": "message",
				"role": "assistant",
				"content": []map[string]string{
					{
						"type": "output_text",
						"text": "RelayKit gateway placeholder response.",
					},
				},
			},
		},
	})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

