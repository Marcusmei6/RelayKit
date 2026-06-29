package codexconfig

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type ActivationResult struct {
	TargetPath      string
	BackupPath      string
	RollbackCommand string
}

func Activate(targetPath string, content []byte) (ActivationResult, error) {
	if strings.TrimSpace(targetPath) == "" {
		return ActivationResult{}, fmt.Errorf("target path is required")
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
	return out.Close()
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}
