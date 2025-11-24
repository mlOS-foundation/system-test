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

	// Skip vision and multimodal models unless testAllModels is true
	repoModel := parts[0]
	if !testAllModels {
		if strings.Contains(repoModel, "resnet") ||
			strings.Contains(repoModel, "vgg") ||
			strings.Contains(repoModel, "clip") {
			return false, nil // Skip
		}
	}

	// Check if model is already installed using our path resolution
	// This will try multiple path formats
	if existingPath, err := GetPath(modelSpec); err == nil {
		fmt.Printf("✅ Model already installed at: %s\n", existingPath)
		return false, nil // Already installed
	}

	// Install using Axon
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return false, fmt.Errorf("failed to get home directory: %w", err)
	}

	axonBin := filepath.Join(homeDir, ".local", "bin", "axon")
	cmd := exec.Command(axonBin, "install", modelSpec)
	
	// Capture output to check for errors, but don't display verbose progress
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

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
			// Always show last few lines of output for debugging
			stdoutStr := stdout.String()
			stderrStr := stderr.String()
			
			// Show last 10 lines of stdout if it's lengthy
			if len(stdoutStr) > 500 {
				lines := strings.Split(stdoutStr, "\n")
				if len(lines) > 10 {
					fmt.Printf("\nAxon stdout (last 10 lines):\n%s\n", strings.Join(lines[len(lines)-10:], "\n"))
				} else {
					fmt.Printf("\nAxon stdout:\n%s\n", stdoutStr)
				}
			} else if len(stdoutStr) > 0 {
				fmt.Printf("\nAxon stdout: %s\n", stdoutStr)
			}
			
			if err != nil {
				// Log captured stderr on error
				if len(stderrStr) > 0 {
					fmt.Printf("Axon stderr: %s\n", stderrStr)
				}
				
				// List cache directory to help debug
				homeDir, _ := os.UserHomeDir()
				cacheDir := filepath.Join(homeDir, ".axon", "cache", "models")
				fmt.Printf("\n📁 Checking axon cache: %s\n", cacheDir)
				
				if entries, readErr := os.ReadDir(cacheDir); readErr == nil {
					fmt.Printf("   Cache contains %d entries:\n", len(entries))
					for i, entry := range entries {
						if i >= 10 {
							fmt.Printf("   ... and %d more\n", len(entries)-10)
							break
						}
						fmt.Printf("   - %s (dir: %v)\n", entry.Name(), entry.IsDir())
					}
				} else {
					fmt.Printf("   ⚠️  Cannot read cache directory: %v\n", readErr)
				}
				
				return false, fmt.Errorf("axon install failed: %w", err)
			}
			
			// Check for errors in output even if exit code is 0
			if strings.Contains(stderrStr, "error") || strings.Contains(stderrStr, "failed") {
				fmt.Printf("\nAxon stderr (contains errors):\n%s\n", stderrStr)
				return false, fmt.Errorf("axon install reported errors: %s", stderrStr)
			}
			
			fmt.Printf("\n✅ Axon install completed (exit code 0)\n")
			
			// Verify model was actually installed
			modelPath, verifyErr := GetPath(modelSpec)
			if verifyErr != nil {
				// Log output to help debug
				fmt.Printf("⚠️  Model path verification failed: %v\n", verifyErr)
				
				// List actual contents of axon cache to help debug
				homeDir, _ := os.UserHomeDir()
				cacheDir := filepath.Join(homeDir, ".axon", "cache", "models")
				fmt.Printf("   Listing axon cache directory: %s\n", cacheDir)
				
				if entries, err := os.ReadDir(cacheDir); err == nil {
					fmt.Printf("   Cache contains %d entries:\n", len(entries))
					for i, entry := range entries {
						if i >= 10 {
							fmt.Printf("   ... and %d more\n", len(entries)-10)
							break
						}
						entryPath := filepath.Join(cacheDir, entry.Name())
						if entry.IsDir() {
							// Check if this directory contains model.onnx
							modelFile := filepath.Join(entryPath, "model.onnx")
							if _, err := os.Stat(modelFile); err == nil {
								fmt.Printf("   ✅ %s/ (contains model.onnx)\n", entry.Name())
							} else {
								// Check subdirectories
								if subEntries, err := os.ReadDir(entryPath); err == nil {
									fmt.Printf("   📁 %s/ (%d subdirs)\n", entry.Name(), len(subEntries))
								}
							}
						} else {
							fmt.Printf("   📄 %s\n", entry.Name())
						}
					}
				} else {
					fmt.Printf("   ⚠️  Cannot read cache directory: %v\n", err)
				}
				
				return false, fmt.Errorf("installation succeeded but model not found at expected path: %w", verifyErr)
			}
			
			// Log successful path for debugging
			fmt.Printf("✅ Model installed at: %s\n", modelPath)
			
			return true, nil
		case <-ticker.C:
			fmt.Print(".")
			// Flush output to ensure dots appear immediately
			os.Stdout.Sync()
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
		// Try alternative path - Axon might use the full model spec as directory name
		// e.g., ~/.axon/cache/models/hf-distilgpt2-latest/model.onnx
		homeDir, _ := os.UserHomeDir()
		altPath := filepath.Join(homeDir, ".axon", "cache", "models", 
			strings.ReplaceAll(strings.ReplaceAll(modelSpec, "/", "-"), "@", "-"), "model.onnx")
		if _, err2 := os.Stat(altPath); err2 == nil {
			return altPath, nil
		}
		
		// Try using axon CLI to get the path
		axonPath, err3 := getPathFromAxon(modelSpec)
		if err3 == nil && axonPath != "" {
			return axonPath, nil
		}
		
		return "", fmt.Errorf("model not found: tried %s, %s (error: %v)", modelPath, altPath, err)
	}

	return modelPath, nil
}

// getPathFromAxon queries Axon CLI for the model path
func getPathFromAxon(modelSpec string) (string, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}

	axonBin := filepath.Join(homeDir, ".local", "bin", "axon")
	cmd := exec.Command(axonBin, "list")
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("failed to run axon list: %w", err)
	}

	// Parse output to find the model path
	// Expected format: hf/distilgpt2@latest -> /path/to/model.onnx
	lines := strings.Split(string(output), "\n")
	for _, line := range lines {
		if strings.Contains(line, modelSpec) {
			// Try to extract path - format varies, try common patterns
			parts := strings.Fields(line)
			for _, part := range parts {
				if strings.HasSuffix(part, ".onnx") && strings.HasPrefix(part, "/") {
					return part, nil
				}
			}
		}
	}

	return "", fmt.Errorf("model %s not found in axon list", modelSpec)
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
