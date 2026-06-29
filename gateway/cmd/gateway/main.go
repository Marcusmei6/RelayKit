package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
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
	if err := runServer(args, stderr); err != nil {
		fmt.Fprintf(stderr, "%v\n", err)
		return 1
	}
	return 0
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

func runServer(args []string, stderr io.Writer) error {
	fs := flag.NewFlagSet("gateway", flag.ContinueOnError)
	fs.SetOutput(stderr)
	listen := fs.String("listen", "127.0.0.1:19777", "loopback listen address")
	configPath := fs.String("config", "../examples/providers.example.json", "provider profile JSON path")
	usageLogPath := fs.String("usage-log", defaultUsageLogPath(), "local usage JSONL path")
	if err := fs.Parse(args); err != nil {
		return err
	}

	handler, err := server.NewWithUsageLog(*configPath, *usageLogPath)
	if err != nil {
		return fmt.Errorf("gateway config failed: %w", err)
	}

	srv := &http.Server{
		Addr:              *listen,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Printf("relaykit gateway listening on http://%s", *listen)
		errCh <- srv.ListenAndServe()
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	select {
	case sig := <-stop:
		log.Printf("shutting down after %s", sig)
	case err := <-errCh:
		if err != nil && err != http.ErrServerClosed {
			return fmt.Errorf("gateway failed: %w", err)
		}
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
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
