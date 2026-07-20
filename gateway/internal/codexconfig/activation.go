package codexconfig

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/pelletier/go-toml"
)

const (
	managedOpenAIBaseURL = "http://127.0.0.1:19777/v1"
	stateVersion         = 1
)

type ActivationResult struct {
	TargetPath      string
	BackupPath      string
	RollbackCommand string
}

type EnableOptions struct {
	TargetPath  string
	CatalogPath string
	StatePath   string
}

type EnableResult struct {
	TargetPath string
	BackupPath string
	StatePath  string
}

type DisableResult struct {
	TargetPath string
	StatePath  string
	Removed    []string
	Restored   []string
	Preserved  []string
}

type Status string

const (
	StatusDisabled Status = "disabled"
	StatusEnabled  Status = "enabled"
	StatusDrifted  Status = "drifted"
)

type managedValues struct {
	OpenAIBaseURL    string `json:"openai_base_url"`
	ModelCatalogJSON string `json:"model_catalog_json"`
}

type originalValue struct {
	Present bool   `json:"present"`
	Value   string `json:"value,omitempty"`
}

type originalValues struct {
	OpenAIBaseURL    originalValue `json:"openai_base_url"`
	ModelCatalogJSON originalValue `json:"model_catalog_json"`
}

type managedState struct {
	Version  int            `json:"version"`
	Target   string         `json:"target"`
	Backup   string         `json:"backup,omitempty"`
	Managed  managedValues  `json:"managed"`
	Original originalValues `json:"original"`
}

func Activate(targetPath string, content []byte) (ActivationResult, error) {
	if strings.TrimSpace(targetPath) == "" {
		return ActivationResult{}, fmt.Errorf("target path is required")
	}
	if IsAuthJSONPath(targetPath) {
		return ActivationResult{}, fmt.Errorf("auth.json paths are not allowed")
	}
	if err := rejectSymlinkPath(targetPath, "target path"); err != nil {
		return ActivationResult{}, err
	}
	if len(content) == 0 {
		return ActivationResult{}, fmt.Errorf("config content is required")
	}

	result := ActivationResult{TargetPath: targetPath}
	mode := os.FileMode(0600)
	if info, err := os.Stat(targetPath); err == nil {
		mode = info.Mode().Perm()
		backupPath := targetPath + ".bak." + time.Now().UTC().Format("20060102T150405.000000000Z")
		if err := copyFile(targetPath, backupPath, mode); err != nil {
			return ActivationResult{}, err
		}
		result.BackupPath = backupPath
		result.RollbackCommand = "cp " + shellQuote(backupPath) + " " + shellQuote(targetPath)
	} else if !os.IsNotExist(err) {
		return ActivationResult{}, err
	}

	if err := writeFileAtomic(targetPath, content, mode); err != nil {
		return ActivationResult{}, err
	}
	return result, nil
}

func Restore(targetPath, backupPath string) error {
	if strings.TrimSpace(targetPath) == "" {
		return fmt.Errorf("target path is required")
	}
	if strings.TrimSpace(backupPath) == "" {
		return fmt.Errorf("backup path is required")
	}
	if IsAuthJSONPath(targetPath) || IsAuthJSONPath(backupPath) {
		return fmt.Errorf("auth.json paths are not allowed")
	}
	if err := rejectSymlinkPath(targetPath, "target path"); err != nil {
		return err
	}
	if err := rejectSymlinkPath(backupPath, "backup path"); err != nil {
		return err
	}
	info, err := os.Stat(backupPath)
	if err != nil {
		return err
	}
	body, err := os.ReadFile(backupPath)
	if err != nil {
		return err
	}
	return writeFileAtomic(targetPath, body, info.Mode().Perm())
}

// Enable merges RelayKit's two root Codex settings into an explicit config.
// It never reads auth.json or changes model selection/provider settings.
func Enable(options EnableOptions) (EnableResult, error) {
	targetPath, err := absolutePath(options.TargetPath, "target path")
	if err != nil {
		return EnableResult{}, err
	}
	statePath, err := absolutePath(options.StatePath, "state path")
	if err != nil {
		return EnableResult{}, err
	}
	if IsAuthJSONPath(targetPath) || IsAuthJSONPath(statePath) {
		return EnableResult{}, fmt.Errorf("auth.json paths are not allowed")
	}
	if err := rejectSymlinkPath(targetPath, "target path"); err != nil {
		return EnableResult{}, err
	}
	if err := rejectSymlinkPath(statePath, "state path"); err != nil {
		return EnableResult{}, err
	}
	catalogPath := strings.TrimSpace(options.CatalogPath)
	if !filepath.IsAbs(catalogPath) {
		return EnableResult{}, fmt.Errorf("catalog path must be absolute")
	}
	catalogPath = filepath.Clean(catalogPath)
	if targetPath == statePath {
		return EnableResult{}, fmt.Errorf("state path must differ from target path")
	}

	original, err := os.ReadFile(targetPath)
	targetExisted := err == nil
	if os.IsNotExist(err) {
		original = []byte{}
	} else if err != nil {
		return EnableResult{}, err
	}
	originalMode := os.FileMode(0600)
	if targetExisted {
		info, err := os.Stat(targetPath)
		if err != nil {
			return EnableResult{}, err
		}
		originalMode = info.Mode().Perm()
	}

	tree, err := toml.LoadBytes(original)
	if err != nil {
		return EnableResult{}, fmt.Errorf("invalid target TOML")
	}
	originalValues, err := originalValuesForEnable(tree, targetPath, statePath)
	if err != nil {
		return EnableResult{}, err
	}
	tree.Set("openai_base_url", managedOpenAIBaseURL)
	tree.Set("model_catalog_json", catalogPath)
	merged, err := tree.ToTomlString()
	if err != nil {
		return EnableResult{}, fmt.Errorf("encode target TOML failed")
	}

	result := EnableResult{TargetPath: targetPath, StatePath: statePath}
	if targetExisted {
		backupPath := targetPath + ".bak." + time.Now().UTC().Format("20060102T150405.000000000Z")
		if err := copyFile(targetPath, backupPath, 0600); err != nil {
			return EnableResult{}, err
		}
		result.BackupPath = backupPath
	}

	if err := os.MkdirAll(filepath.Dir(targetPath), 0700); err != nil {
		return EnableResult{}, err
	}
	if err := os.MkdirAll(filepath.Dir(statePath), 0700); err != nil {
		return EnableResult{}, err
	}
	if err := writeFileAtomic(targetPath, []byte(merged), 0600); err != nil {
		return EnableResult{}, err
	}
	stateBody, err := json.Marshal(managedState{
		Version: stateVersion,
		Target:  targetPath,
		Backup:  result.BackupPath,
		Managed: managedValues{
			OpenAIBaseURL:    managedOpenAIBaseURL,
			ModelCatalogJSON: catalogPath,
		},
		Original: originalValues,
	})
	if err != nil {
		return EnableResult{}, fmt.Errorf("encode RelayKit state failed")
	}
	if err := writeFileAtomic(statePath, append(stateBody, '\n'), 0600); err != nil {
		if rollbackErr := restoreEnableTarget(targetPath, original, originalMode, targetExisted); rollbackErr != nil {
			return EnableResult{}, fmt.Errorf("write RelayKit state failed and target rollback failed")
		}
		return EnableResult{}, fmt.Errorf("write RelayKit state failed")
	}
	return result, nil
}

// IntegrationStatus validates managed state against the current TOML.
func IntegrationStatus(targetPath, statePath string) (Status, error) {
	targetPath, err := absolutePath(targetPath, "target path")
	if err != nil {
		return StatusDisabled, err
	}
	statePath, err = absolutePath(statePath, "state path")
	if err != nil {
		return StatusDisabled, err
	}
	if IsAuthJSONPath(targetPath) || IsAuthJSONPath(statePath) {
		return StatusDisabled, fmt.Errorf("auth.json paths are not allowed")
	}
	if err := rejectSymlinkPath(targetPath, "target path"); err != nil {
		return StatusDisabled, err
	}
	if err := rejectSymlinkPath(statePath, "state path"); err != nil {
		return StatusDisabled, err
	}
	if _, err := os.Stat(statePath); os.IsNotExist(err) {
		return StatusDisabled, nil
	} else if err != nil {
		return StatusDisabled, err
	}
	state, err := readManagedState(statePath)
	if err != nil || state.Target != targetPath {
		return StatusDrifted, nil
	}
	content, err := os.ReadFile(targetPath)
	if os.IsNotExist(err) {
		return StatusDrifted, nil
	}
	if err != nil {
		return StatusDisabled, err
	}
	tree, err := toml.LoadBytes(content)
	if err != nil {
		return StatusDrifted, nil
	}
	baseURL, baseOK := tree.Get("openai_base_url").(string)
	catalog, catalogOK := tree.Get("model_catalog_json").(string)
	if baseOK && catalogOK && baseURL == state.Managed.OpenAIBaseURL && catalog == state.Managed.ModelCatalogJSON {
		return StatusEnabled, nil
	}
	return StatusDrifted, nil
}

// Disable removes only values still equal to the values recorded by Enable.
// Later user changes are retained and reported by field name only.
func Disable(targetPath, statePath string) (DisableResult, error) {
	targetPath, err := absolutePath(targetPath, "target path")
	if err != nil {
		return DisableResult{}, err
	}
	statePath, err = absolutePath(statePath, "state path")
	if err != nil {
		return DisableResult{}, err
	}
	if IsAuthJSONPath(targetPath) || IsAuthJSONPath(statePath) {
		return DisableResult{}, fmt.Errorf("auth.json paths are not allowed")
	}
	if err := rejectSymlinkPath(targetPath, "target path"); err != nil {
		return DisableResult{}, err
	}
	if err := rejectSymlinkPath(statePath, "state path"); err != nil {
		return DisableResult{}, err
	}
	if targetPath == statePath {
		return DisableResult{}, fmt.Errorf("state path must differ from target path")
	}
	state, err := readManagedState(statePath)
	if err != nil {
		return DisableResult{}, err
	}
	if state.Target != targetPath {
		return DisableResult{}, fmt.Errorf("RelayKit state target does not match target path")
	}

	content, err := os.ReadFile(targetPath)
	if err != nil {
		return DisableResult{}, err
	}
	tree, err := toml.LoadBytes(content)
	if err != nil {
		return DisableResult{}, fmt.Errorf("invalid target TOML")
	}

	result := DisableResult{TargetPath: targetPath, StatePath: statePath}
	for _, field := range []struct {
		name     string
		managed  string
		original originalValue
	}{
		{name: "openai_base_url", managed: state.Managed.OpenAIBaseURL, original: state.Original.OpenAIBaseURL},
		{name: "model_catalog_json", managed: state.Managed.ModelCatalogJSON, original: state.Original.ModelCatalogJSON},
	} {
		if current, ok := tree.Get(field.name).(string); ok && current == field.managed {
			if field.original.Present {
				tree.Set(field.name, field.original.Value)
				result.Restored = append(result.Restored, field.name)
			} else {
				if err := tree.Delete(field.name); err != nil {
					return DisableResult{}, fmt.Errorf("remove managed setting failed")
				}
				result.Removed = append(result.Removed, field.name)
			}
		} else {
			result.Preserved = append(result.Preserved, field.name)
		}
	}
	if len(result.Removed) > 0 || len(result.Restored) > 0 {
		updated, err := tree.ToTomlString()
		if err != nil {
			return DisableResult{}, fmt.Errorf("encode target TOML failed")
		}
		if err := writeFileAtomic(targetPath, []byte(updated), 0600); err != nil {
			return DisableResult{}, err
		}
	}
	if err := os.Remove(statePath); err != nil && !os.IsNotExist(err) {
		return DisableResult{}, fmt.Errorf("remove RelayKit state failed")
	}
	return result, nil
}

func originalValuesForEnable(tree *toml.Tree, targetPath, statePath string) (originalValues, error) {
	if _, err := os.Stat(statePath); err == nil {
		state, err := readManagedState(statePath)
		if err != nil {
			return originalValues{}, err
		}
		if state.Target != targetPath {
			return originalValues{}, fmt.Errorf("RelayKit state target does not match target path")
		}
		return state.Original, nil
	} else if !os.IsNotExist(err) {
		return originalValues{}, err
	}

	read := func(name string) (originalValue, error) {
		value := tree.Get(name)
		if value == nil {
			return originalValue{}, nil
		}
		text, ok := value.(string)
		if !ok {
			return originalValue{}, fmt.Errorf("existing %s must be a string", name)
		}
		return originalValue{Present: true, Value: text}, nil
	}
	baseURL, err := read("openai_base_url")
	if err != nil {
		return originalValues{}, err
	}
	catalog, err := read("model_catalog_json")
	if err != nil {
		return originalValues{}, err
	}
	return originalValues{OpenAIBaseURL: baseURL, ModelCatalogJSON: catalog}, nil
}

func absolutePath(path, name string) (string, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return "", fmt.Errorf("%s is required", name)
	}
	return filepath.Abs(path)
}

// IsAuthJSONPath identifies the Codex auth file by name without reading it.
func IsAuthJSONPath(path string) bool {
	return strings.EqualFold(filepath.Base(path), "auth.json")
}

func rejectSymlinkPath(path, name string) error {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("%s must not be a symbolic link", name)
	}
	return nil
}

func readManagedState(path string) (managedState, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return managedState{}, err
	}
	var state managedState
	if err := json.Unmarshal(body, &state); err != nil {
		return managedState{}, fmt.Errorf("invalid RelayKit state")
	}
	if state.Version != stateVersion || state.Target == "" || state.Managed.OpenAIBaseURL != managedOpenAIBaseURL || !filepath.IsAbs(state.Managed.ModelCatalogJSON) {
		return managedState{}, fmt.Errorf("invalid RelayKit state")
	}
	return state, nil
}

func restoreOriginalTarget(path string, content []byte, mode os.FileMode) error {
	return writeFileAtomic(path, content, mode)
}

func restoreEnableTarget(path string, content []byte, mode os.FileMode, existed bool) error {
	if existed {
		return restoreOriginalTarget(path, content, mode)
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func writeFileAtomic(path string, content []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".relaykit-config-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)

	if _, err := tmp.Write(content); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}

func copyFile(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Chmod(mode); err != nil {
		out.Close()
		return err
	}
	if err := out.Sync(); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}
