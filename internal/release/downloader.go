package release

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"

	"github.com/mlOS-foundation/system-test/internal/monitor"
)

// DownloadAxon downloads the specified Axon release version
func DownloadAxon(version, outputDir string) error {
	// Use Axon's install script which handles downloading
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("failed to get home directory: %w", err)
	}

	axonBin := filepath.Join(homeDir, ".local", "bin", "axon")
	
	// Check if Axon is already installed
	if _, err := os.Stat(axonBin); os.IsNotExist(err) {
		// Install Axon using the install script
		cmd := exec.Command("bash", "-c", "curl -fsSL https://raw.githubusercontent.com/mlOS-foundation/axon/main/install.sh | bash")
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("failed to install Axon: %w", err)
		}
	}

	// Verify installation
	cmd := exec.Command(axonBin, "version")
	output, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("failed to verify Axon installation: %w", err)
	}

	// Check if version matches (optional - install script installs latest)
	_ = output // Version check can be added later if needed

	return nil
}

// DownloadCore downloads the specified MLOS Core release version
func DownloadCore(version, outputDir string) error {
	platform := getPlatform()
	coreDir := filepath.Join(outputDir, "mlos-core")
	
	if err := os.MkdirAll(coreDir, 0755); err != nil {
		return fmt.Errorf("failed to create core directory: %w", err)
	}

	// Use gh CLI to download release
	archiveName := fmt.Sprintf("mlos-core_%s_%s.tar.gz", version, platform)
	archivePath := filepath.Join(coreDir, archiveName)

	// Download using gh CLI
	cmd := exec.Command("gh", "release", "download", version,
		"--repo", "mlOS-foundation/core",
		"--pattern", archiveName,
		"--dir", coreDir)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to download Core release: %w", err)
	}

	// Extract archive
	extractDir := filepath.Join(coreDir, fmt.Sprintf("mlos-core-%s-%s", version, platform))
	if err := os.MkdirAll(extractDir, 0755); err != nil {
		return fmt.Errorf("failed to create extract directory: %w", err)
	}

	cmd = exec.Command("tar", "-xzf", archivePath, "-C", extractDir)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to extract Core archive: %w", err)
	}

	// Find and copy binary
	binaryName := "mlos_core"
	if runtime.GOOS == "windows" {
		binaryName = "mlos_core.exe"
	}

	// Look for binary in extracted directory
	binaryPath := filepath.Join(extractDir, "build", binaryName)
	if _, err := os.Stat(binaryPath); os.IsNotExist(err) {
		// Try alternative locations
		altPaths := []string{
			filepath.Join(extractDir, binaryName),
			filepath.Join(extractDir, "bin", binaryName),
		}
		found := false
		for _, altPath := range altPaths {
			if _, err := os.Stat(altPath); err == nil {
				binaryPath = altPath
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("Core binary not found in release archive")
		}
	}

	// Copy to build directory
	buildDir := filepath.Join(extractDir, "build")
	if err := os.MkdirAll(buildDir, 0755); err != nil {
		return fmt.Errorf("failed to create build directory: %w", err)
	}

	finalBinaryPath := filepath.Join(buildDir, "mlos-server")
	if binaryPath != finalBinaryPath {
		// Copy binary
		data, err := os.ReadFile(binaryPath)
		if err != nil {
			return fmt.Errorf("failed to read Core binary: %w", err)
		}
		if err := os.WriteFile(finalBinaryPath, data, 0755); err != nil {
			return fmt.Errorf("failed to write Core binary: %w", err)
		}
	}

	// Install to ~/.local/bin
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("failed to get home directory: %w", err)
	}

	localBin := filepath.Join(homeDir, ".local", "bin")
	if err := os.MkdirAll(localBin, 0755); err != nil {
		return fmt.Errorf("failed to create local bin directory: %w", err)
	}

	installPath := filepath.Join(localBin, "mlos-server")
	data, err := os.ReadFile(finalBinaryPath)
	if err != nil {
		return fmt.Errorf("failed to read Core binary for installation: %w", err)
	}
	if err := os.WriteFile(installPath, data, 0755); err != nil {
		return fmt.Errorf("failed to install Core binary: %w", err)
	}

	return nil
}

// StartCore starts the MLOS Core server
func StartCore(version, outputDir string) (*monitor.Process, error) {
	platform := getPlatform()
	coreDir := filepath.Join(outputDir, "mlos-core", fmt.Sprintf("mlos-core-%s-%s", version, platform))
	binaryPath := filepath.Join(coreDir, "build", "mlos-server")

	// Start server with sudo (required for binding to ports)
	cmd := exec.Command("sudo", binaryPath)
	cmd.Dir = coreDir
	
	// Start process
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start Core server: %w", err)
	}

	process := &monitor.Process{
		PID:    cmd.Process.Pid,
		Cmd:    cmd,
		Binary: binaryPath,
	}

	// Wait for server to be ready
	if err := waitForServer(); err != nil {
		monitor.StopProcess(process)
		return nil, fmt.Errorf("server failed to start: %w", err)
	}

	return process, nil
}

func getPlatform() string {
	os := runtime.GOOS
	arch := runtime.GOARCH
	
	// Map Go arch to release arch names
	if arch == "amd64" {
		arch = "x86_64"
	} else if arch == "arm64" {
		arch = "arm64"
	}

	// Map Go OS to release OS names
	if os == "darwin" {
		os = "darwin"
	} else if os == "linux" {
		os = "linux"
	} else if os == "windows" {
		os = "windows"
	}

	return fmt.Sprintf("%s-%s", os, arch)
}

func waitForServer() error {
	// Wait for server to be ready by checking HTTP endpoint
	maxRetries := 30
	for i := 0; i < maxRetries; i++ {
		// Try health endpoint - any response (even 404) means server is up
		cmd := exec.Command("curl", "-s", "-o", "/dev/null", "http://localhost:8080/health")
		if err := cmd.Run(); err == nil {
			// Server responded, it's ready
			return nil
		}
		// Wait a bit before retrying
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("server did not become ready after %d attempts", maxRetries)
}

