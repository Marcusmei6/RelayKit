package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"syscall"
	"time"

	"relaykit/gateway/internal/codexconfig"
	"relaykit/gateway/internal/server"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) > 0 && args[0] == "activate-codex-config" {
		return activateCodexConfig(args[1:], stdout, stderr)
	}
	if len(args) > 0 && args[0] == "summarize-usage" {
		return summarizeUsage(args[1:], stdout, stderr)
	}
	if err := runServer(args, os.Stdin, stderr); err != nil {
		fmt.Fprintf(stderr, "%v\n", err)
		return 1
	}
	return 0
}

type usageLogEvent struct {
	Timestamp    string `json:"timestamp"`
	ProviderID   string `json:"provider_id"`
	Model        string `json:"model"`
	InputTokens  int64  `json:"input_tokens"`
	OutputTokens int64  `json:"output_tokens"`
	TotalTokens  int64  `json:"total_tokens"`
	DurationMS   int64  `json:"duration_ms"`
}

type usageSummary struct {
	Day          string `json:"day"`
	ProviderID   string `json:"provider_id"`
	Model        string `json:"model"`
	Requests     int64  `json:"requests"`
	InputTokens  int64  `json:"input_tokens"`
	OutputTokens int64  `json:"output_tokens"`
	TotalTokens  int64  `json:"total_tokens"`
	DurationMS   int64  `json:"duration_ms"`
}

func summarizeUsage(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("summarize-usage", flag.ContinueOnError)
	fs.SetOutput(stderr)
	path := fs.String("path", defaultUsageLogPath(), "usage JSONL path")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	summaries, err := readUsageSummaries(*path)
	if err != nil {
		fmt.Fprintf(stderr, "summarize usage failed: %v\n", err)
		return 1
	}
	if err := json.NewEncoder(stdout).Encode(summaries); err != nil {
		fmt.Fprintf(stderr, "write summary failed: %v\n", err)
		return 1
	}
	return 0
}

func readUsageSummaries(path string) ([]usageSummary, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return []usageSummary{}, nil
		}
		return nil, err
	}
	defer f.Close()

	byKey := map[string]*usageSummary{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		var event usageLogEvent
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
			return nil, err
		}
		day := event.Timestamp
		if len(day) >= len("2006-01-02") {
			day = day[:len("2006-01-02")]
		}
		key := day + "\x00" + event.ProviderID + "\x00" + event.Model
		summary := byKey[key]
		if summary == nil {
			summary = &usageSummary{Day: day, ProviderID: event.ProviderID, Model: event.Model}
			byKey[key] = summary
		}
		summary.Requests++
		summary.InputTokens += event.InputTokens
		summary.OutputTokens += event.OutputTokens
		summary.TotalTokens += event.TotalTokens
		summary.DurationMS += event.DurationMS
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}

	out := make([]usageSummary, 0, len(byKey))
	for _, summary := range byKey {
		out = append(out, *summary)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Day != out[j].Day {
			return out[i].Day < out[j].Day
		}
		if out[i].ProviderID != out[j].ProviderID {
			return out[i].ProviderID < out[j].ProviderID
		}
		return out[i].Model < out[j].Model
	})
	return out, nil
}

func activateCodexConfig(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("activate-codex-config", flag.ContinueOnError)
	fs.SetOutput(stderr)
	target := fs.String("target", "", "destination Codex config path")
	source := fs.String("source", "", "source config TOML path")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *target == "" {
		fmt.Fprintln(stderr, "target is required")
		return 2
	}
	if *source == "" {
		fmt.Fprintln(stderr, "source is required")
		return 2
	}
	content, err := os.ReadFile(*source)
	if err != nil {
		fmt.Fprintf(stderr, "read source failed: %v\n", err)
		return 1
	}
	result, err := codexconfig.Activate(*target, content)
	if err != nil {
		fmt.Fprintf(stderr, "activate failed: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "activated: %s\n", result.TargetPath)
	if result.BackupPath != "" {
		fmt.Fprintf(stdout, "backup: %s\nrollback: %s\n", result.BackupPath, result.RollbackCommand)
	}
	return 0
}

const maximumCredentialHandoffBytes = 1 << 20

func parseParentPID(value string) (int, error) {
	pid, err := strconv.Atoi(value)
	if err != nil || pid <= 0 {
		return 0, fmt.Errorf("parent PID must be a positive integer")
	}
	return pid, nil
}

func parentProcessAlive(pid int) bool {
	process, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	err = process.Signal(syscall.Signal(0))
	return err == nil || errors.Is(err, syscall.EPERM)
}

type credentialHandoff struct {
	Version     int               `json:"version"`
	Credentials map[string]string `json:"credentials"`
}

func readCredentialHandoff(reader io.Reader) (map[string]string, error) {
	body, err := io.ReadAll(io.LimitReader(reader, maximumCredentialHandoffBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read credential handoff failed")
	}
	if len(body) > maximumCredentialHandoffBytes {
		return nil, fmt.Errorf("credential handoff exceeds size limit")
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	var payload credentialHandoff
	if err := decoder.Decode(&payload); err != nil {
		return nil, fmt.Errorf("invalid credential handoff")
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return nil, fmt.Errorf("invalid credential handoff")
	}
	if payload.Version != 1 || payload.Credentials == nil {
		return nil, fmt.Errorf("unsupported credential handoff")
	}
	credentials := make(map[string]string, len(payload.Credentials))
	for reference, value := range payload.Credentials {
		if reference == "" || value == "" {
			return nil, fmt.Errorf("invalid credential handoff entry")
		}
		credentials[reference] = value
	}
	return credentials, nil
}

func runServer(args []string, stdin io.Reader, stderr io.Writer) error {
	fs := flag.NewFlagSet("gateway", flag.ContinueOnError)
	fs.SetOutput(stderr)
	listen := fs.String("listen", "127.0.0.1:19777", "loopback listen address")
	configPath := fs.String("config", "../examples/providers.example.json", "provider profile JSON path")
	usageLogPath := fs.String("usage-log", defaultUsageLogPath(), "local usage JSONL path")
	credentialStdin := fs.Bool("credential-stdin", false, "read App-provided credentials from standard input")
	parentPIDValue := fs.String("parent-pid", "", "optional positive parent process ID")
	if err := fs.Parse(args); err != nil {
		return err
	}
	parentPID := 0
	if *parentPIDValue != "" {
		var err error
		parentPID, err = parseParentPID(*parentPIDValue)
		if err != nil {
			return err
		}
		if !parentProcessAlive(parentPID) {
			return fmt.Errorf("parent process is not running")
		}
	}

	var handler http.Handler
	var err error
	if *credentialStdin {
		credentials, readErr := readCredentialHandoff(stdin)
		if readErr != nil {
			return readErr
		}
		handler, err = server.NewWithUsageLogAndCredentials(*configPath, *usageLogPath, credentials)
	} else {
		handler, err = server.NewWithUsageLog(*configPath, *usageLogPath)
	}
	if err != nil {
		return fmt.Errorf("gateway config failed: %w", err)
	}

	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		return fmt.Errorf("gateway listen failed: %w", err)
	}
	rootCtx, cancelRoot := context.WithCancel(context.Background())
	srv := &http.Server{
		Addr:              *listen,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		BaseContext: func(net.Listener) context.Context {
			return rootCtx
		},
	}

	errCh := make(chan error, 1)
	go func() {
		log.Printf("relaykit gateway listening on http://%s", *listen)
		errCh <- srv.Serve(listener)
	}()
	parentLost := make(chan struct{})
	parentMonitorDone := make(chan struct{})
	if parentPID > 0 {
		go func() {
			defer close(parentMonitorDone)
			ticker := time.NewTicker(250 * time.Millisecond)
			defer ticker.Stop()
			for {
				select {
				case <-rootCtx.Done():
					return
				case <-ticker.C:
					if !parentProcessAlive(parentPID) {
						cancelRoot()
						close(parentLost)
						_ = listener.Close()
						return
					}
				}
			}
		}()
	} else {
		close(parentMonitorDone)
	}
	defer func() {
		cancelRoot()
		<-parentMonitorDone
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(stop)

	select {
	case sig := <-stop:
		log.Printf("shutting down after %s", sig)
	case <-parentLost:
		log.Printf("shutting down after parent process exited")
	case err := <-errCh:
		if rootCtx.Err() != nil {
			break
		}
		if err != nil && err != http.ErrServerClosed {
			return fmt.Errorf("gateway failed: %w", err)
		}
		return nil
	}
	cancelRoot()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil && !errors.Is(err, net.ErrClosed) {
		_ = srv.Close()
		return fmt.Errorf("shutdown failed: %w", err)
	}
	return nil
}

func defaultUsageLogPath() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "RelayKit", "usage.jsonl")
}
