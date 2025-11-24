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

	// Check if Docker is available (Axon needs it for ONNX conversion)
	dockerCmd := exec.Command("docker", "--version")
	if dockerOut, dockerErr := dockerCmd.CombinedOutput(); dockerErr != nil {
		fmt.Printf("⚠️  Docker CLI not available: %v\n", dockerErr)
		fmt.Printf("   Axon may fallback to native format (non-ONNX)\n")
	} else {
		fmt.Printf("   Docker CLI: %s\n", strings.TrimSpace(string(dockerOut)))
	}
	
	// Check if Docker daemon is actually running (can we run containers?)
	dockerPsCmd := exec.Command("docker", "ps")
	if dockerPsOut, dockerPsErr := dockerPsCmd.CombinedOutput(); dockerPsErr != nil {
		fmt.Printf("⚠️  Docker daemon not accessible: %v\n", dockerPsErr)
		fmt.Printf("   Output: %s\n", strings.TrimSpace(string(dockerPsOut)))
		fmt.Printf("   Axon WILL fallback to native Python (which will fail without torch)\n")
	} else {
		fmt.Printf("   Docker daemon: Running ✓\n")
	}

	axonBin := filepath.Join(homeDir, ".local", "bin", "axon")
	
	// Pre-pull Axon converter image to ensure Docker conversion works
	fmt.Printf("   Pre-pulling Axon converter image...\n")
	converterImage := "ghcr.io/mlos-foundation/axon-converter:latest"
	pullCmd := exec.Command("docker", "pull", converterImage)
	pullOutput, pullErr := pullCmd.CombinedOutput()
	if pullErr != nil {
		fmt.Printf("⚠️  Failed to pull converter image: %v\n", pullErr)
		fmt.Printf("   Output: %s\n", strings.TrimSpace(string(pullOutput)))
		fmt.Printf("   Axon may still try to pull it automatically\n")
	} else {
		fmt.Printf("✅ Converter image ready: %s\n", converterImage)
	}
	
	// Try to force ONNX format if Axon supports it
	// Note: Check Axon CLI help to see if --format flag exists
	cmd := exec.Command(axonBin, "install", modelSpec, "--format", "onnx")
	
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
				
				// If it failed due to unknown flag, try without --format
				retrySuccess := false
				if strings.Contains(stderrStr, "unknown flag") || strings.Contains(stderrStr, "--format") {
					fmt.Printf("⚠️  --format flag not supported, retrying without it...\n")
					cmd2 := exec.Command(axonBin, "install", modelSpec)
					stdout.Reset()
					stderr.Reset()
					cmd2.Stdout = &stdout
					cmd2.Stderr = &stderr
					if err2 := cmd2.Run(); err2 == nil {
						fmt.Printf("✅ Succeeded without --format flag\n")
						retrySuccess = true
					}
				}
				
				if !retrySuccess {
					// List cache directory to help debug
					listCacheDir := func() {
						homeDirDebug, _ := os.UserHomeDir()
						cacheDirDebug := filepath.Join(homeDirDebug, ".axon", "cache", "models")
						fmt.Printf("\n📁 Checking axon cache: %s\n", cacheDirDebug)
						
						if entries, readErr := os.ReadDir(cacheDirDebug); readErr == nil {
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
					}
					listCacheDir()
					return false, fmt.Errorf("axon install failed: %w", err)
				}
			}
			
			// Check for errors in output even if exit code is 0
			if strings.Contains(stderrStr, "error") || strings.Contains(stderrStr, "failed") {
				fmt.Printf("\nAxon stderr (contains errors):\n%s\n", stderrStr)
				return false, fmt.Errorf("axon install reported errors: %s", stderrStr)
			}
			
			// Check for Docker/ONNX conversion issues
			outputStr := stdoutStr + "\n" + stderrStr
			if strings.Contains(outputStr, "ONNX conversion failed") {
				fmt.Printf("❌ ONNX conversion failed during installation\n")
				if strings.Contains(outputStr, "ModuleNotFoundError") {
					fmt.Printf("   Docker converter image may be broken or not pulled\n")
				}
				if strings.Contains(outputStr, "execution_format: pytorch") {
					fmt.Printf("   ⚠️  Axon fell back to PyTorch format (MLOS Core won't support this)\n")
				}
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
				
				// Walk the directory tree to find actual files
				var foundFiles []string
				walkErr := filepath.Walk(cacheDir, func(path string, info os.FileInfo, err error) error {
					if err != nil {
						return nil // Skip errors
					}
					if !info.IsDir() {
						relPath, _ := filepath.Rel(cacheDir, path)
						foundFiles = append(foundFiles, relPath)
					}
					return nil
				})
				if walkErr != nil {
					fmt.Printf("   ⚠️  Error walking cache directory: %v\n", walkErr)
				}
				
				if len(foundFiles) > 0 {
					fmt.Printf("   Found %d files in cache:\n", len(foundFiles))
					for i, file := range foundFiles {
						if i >= 15 {
							fmt.Printf("   ... and %d more files\n", len(foundFiles)-15)
							break
						}
						fmt.Printf("   - %s\n", file)
					}
					
					// Check specifically for the expected model path
					expectedPath := filepath.Join(cacheDir, "hf", "distilgpt2", "latest", "model.onnx")
					if _, err := os.Stat(expectedPath); os.IsNotExist(err) {
						fmt.Printf("   ❌ Expected file missing: hf/distilgpt2/latest/model.onnx\n")
						
						// Look for any .onnx files
						onnxFiles := []string{}
						for _, f := range foundFiles {
							if strings.HasSuffix(f, ".onnx") {
								onnxFiles = append(onnxFiles, f)
							}
						}
						if len(onnxFiles) > 0 {
							fmt.Printf("   Found .onnx files: %v\n", onnxFiles)
						} else {
							fmt.Printf("   ⚠️  No .onnx files found in cache\n")
							fmt.Printf("   Model may be in PyTorch format (check for .pt or .bin files)\n")
						}
					}
				} else {
					fmt.Printf("   ⚠️  No files found in cache directory\n")
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

	// MLOS Core requires ONNX format - no fallback to PyTorch
	modelPath := GetModelPath(repoModel, version)
	if _, err := os.Stat(modelPath); err == nil {
		return modelPath, nil
	}
	
	// Try alternative path format
	homeDir, _ := os.UserHomeDir()
	altPath := filepath.Join(homeDir, ".axon", "cache", "models", 
		strings.ReplaceAll(strings.ReplaceAll(modelSpec, "/", "-"), "@", "-"), "model.onnx")
	if _, err2 := os.Stat(altPath); err2 == nil {
		return altPath, nil
	}
	
	// ONNX file not found - this is a hard error
	// Check what files actually exist to help debug
	baseDir := filepath.Join(homeDir, ".axon", "cache", "models", repoModel, version)
	if entries, readErr := os.ReadDir(baseDir); readErr == nil && len(entries) > 0 {
		fmt.Printf("❌ ONNX model not found, but found these files:\n")
		for i, entry := range entries {
			if i >= 10 {
				fmt.Printf("   ... and %d more\n", len(entries)-10)
				break
			}
			fmt.Printf("   - %s\n", entry.Name())
		}
		if hasAnyFile(baseDir, "pytorch_model.bin", "model.safetensors", "model.pt") {
			fmt.Printf("❌ PyTorch format found - Docker ONNX conversion FAILED\n")
			fmt.Printf("   MLOS Core requires ONNX format\n")
			fmt.Printf("   Check Docker logs during 'axon install' for conversion errors\n")
		}
	}
	
	return "", fmt.Errorf("ONNX model not found (MLOS Core requires ONNX format): tried %s, %s", modelPath, altPath)
}

// hasAnyFile checks if any of the given files exist in the directory
func hasAnyFile(dir string, filenames ...string) bool {
	for _, filename := range filenames {
		if _, err := os.Stat(filepath.Join(dir, filename)); err == nil {
			return true
		}
	}
	return false
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
