package model

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Install installs a model using Axon with progress indicator
func Install(modelSpec string, testAllModels bool) (bool, error) {
	// Parse model spec: "repo/model@version"
	parts := strings.Split(modelSpec, "@")
	if len(parts) != 2 {
		return false, fmt.Errorf("invalid model spec format: %s", modelSpec)
	}

	repoModel := parts[0]
	version := parts[1]

	// Check if model is already installed
	modelPath := GetModelPath(repoModel, version)
	if _, err := os.Stat(modelPath); err == nil {
		return false, nil // Already installed
	}

	// Skip vision and multimodal models unless testAllModels is true
	if !testAllModels {
		if strings.Contains(repoModel, "resnet") ||
			strings.Contains(repoModel, "vgg") ||
			strings.Contains(repoModel, "clip") {
			return false, nil // Skip
		}
	}

	// Install using Axon
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return false, fmt.Errorf("failed to get home directory: %w", err)
	}

	axonBin := filepath.Join(homeDir, ".local", "bin", "axon")
	cmd := exec.Command(axonBin, "install", modelSpec)
	// Suppress verbose download progress
	cmd.Stdout = nil
	cmd.Stderr = nil // Suppress stderr too to avoid verbose progress

	// Run with progress indicator
	if err := cmd.Start(); err != nil {
		return false, fmt.Errorf("failed to start axon install: %w", err)
	}

	// Show progress dots while installing
	done := make(chan error)
	go func() {
		done <- cmd.Wait()
	}()

	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case err := <-done:
			if err != nil {
				return false, fmt.Errorf("axon install failed: %w", err)
			}
			return true, nil
		case <-ticker.C:
			fmt.Print(".")
		}
	}
}

// GetPath returns the path to an installed model
func GetPath(modelSpec string) (string, error) {
	parts := strings.Split(modelSpec, "@")
	if len(parts) != 2 {
		return "", fmt.Errorf("invalid model spec format: %s", modelSpec)
	}

	repoModel := parts[0]
	version := parts[1]

	modelPath := GetModelPath(repoModel, version)
	if _, err := os.Stat(modelPath); err != nil {
		return "", fmt.Errorf("model not found: %s", modelPath)
	}

	return modelPath, nil
}

// GetModelPath returns the expected path for a model
// Matches bash script: ~/.axon/cache/models/${model_id%@*}/${model_id##*@}/model.onnx
// For "hf/distilgpt2@latest": ~/.axon/cache/models/hf/distilgpt2/latest/model.onnx
func GetModelPath(repoModel, version string) string {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		// Fallback to current directory if home directory cannot be determined
		homeDir = "."
	}
	// Format: ~/.axon/cache/models/{repoModel}/{version}/model.onnx
	// Example: hf/distilgpt2 + latest -> ~/.axon/cache/models/hf/distilgpt2/latest/model.onnx
	return filepath.Join(homeDir, ".axon", "cache", "models", repoModel, version, "model.onnx")
}

// Register registers a model with MLOS Core
func Register(modelID, modelPath string, port int) error {
	// Register via HTTP API
	jsonPayload := fmt.Sprintf(`{"model_id":%q,"path":%q}`, modelID, modelPath)
	url := fmt.Sprintf("http://localhost:%d/models/register", port)

	cmd := exec.Command("curl", "-X", "POST",
		url,
		"-H", "Content-Type: application/json",
		"-d", jsonPayload)

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("registration failed: %w, output: %s", err, string(output))
	}

	// Check for error in response
	if strings.Contains(string(output), "error") {
		return fmt.Errorf("registration failed: %s", string(output))
	}

	return nil
}
