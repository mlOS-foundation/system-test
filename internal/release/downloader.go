package release

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
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

	// Extract archive (extract to coreDir, then handle nested structure)
	cmd = exec.Command("tar", "-xzf", archivePath, "-C", coreDir)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to extract Core archive: %w", err)
	}

	// Handle nested directory structure (archive may extract to a subdirectory)
	extractDir := coreDir
	entries, err := os.ReadDir(coreDir)
	if err == nil {
		// Count subdirectories
		dirCount := 0
		var nestedDir string
		for _, entry := range entries {
			if entry.IsDir() {
				dirCount++
				if dirCount == 1 {
					nestedDir = entry.Name()
				}
			}
		}
		// If there's only one directory, use it as extractDir
		if dirCount == 1 {
			extractDir = filepath.Join(coreDir, nestedDir)
		}
	}

	// Search for binary recursively (can be named mlos_core or mlos-server)
	binaryPath := ""

	// Try common locations first
	commonPaths := []string{
		filepath.Join(extractDir, "mlos_core"),
		filepath.Join(extractDir, "mlos-server"),
		filepath.Join(extractDir, "bin", "mlos_core"),
		filepath.Join(extractDir, "bin", "mlos-server"),
		filepath.Join(extractDir, "build", "mlos-server"),
		filepath.Join(extractDir, "build", "mlos_core"),
	}

	for _, path := range commonPaths {
		if _, err := os.Stat(path); err == nil {
			binaryPath = path
			break
		}
	}

	// If not found, search recursively
	if binaryPath == "" {
		cmd := exec.Command("find", extractDir, "-type", "f", "-name", "mlos_core", "-o", "-name", "mlos-server")
		output, err := cmd.Output()
		if err == nil {
			lines := strings.Split(strings.TrimSpace(string(output)), "\n")
			if len(lines) > 0 && lines[0] != "" {
				binaryPath = lines[0]
			}
		}
	}

	if binaryPath == "" {
		return fmt.Errorf("Core binary not found in release archive (searched in %s)", extractDir)
	}

	// Copy to build directory (normalize name to mlos-server)
	buildDir := filepath.Join(extractDir, "build")
	if err := os.MkdirAll(buildDir, 0755); err != nil {
		return fmt.Errorf("failed to create build directory: %w", err)
	}

	finalBinaryPath := filepath.Join(buildDir, "mlos-server")
	// Always copy (even if same path, to normalize the name)
	data, err := os.ReadFile(binaryPath)
	if err != nil {
		return fmt.Errorf("failed to read Core binary: %w", err)
	}
	if err := os.WriteFile(finalBinaryPath, data, 0755); err != nil {
		return fmt.Errorf("failed to write Core binary: %w", err)
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
	data2, err := os.ReadFile(finalBinaryPath)
	if err != nil {
		return fmt.Errorf("failed to read Core binary for installation: %w", err)
	}
	if err := os.WriteFile(installPath, data2, 0755); err != nil {
		return fmt.Errorf("failed to install Core binary: %w", err)
	}

	return nil
}

// StartCore starts the MLOS Core server on a non-privileged port
func StartCore(version, outputDir string, port int) (*monitor.Process, error) {
	coreDir := filepath.Join(outputDir, "mlos-core")
	
	// Handle nested directory structure (same logic as DownloadCore)
	extractDir := coreDir
	entries, err := os.ReadDir(coreDir)
	if err == nil {
		dirCount := 0
		var nestedDir string
		for _, entry := range entries {
			if entry.IsDir() {
				dirCount++
				if dirCount == 1 {
					nestedDir = entry.Name()
				}
			}
		}
		if dirCount == 1 {
			extractDir = filepath.Join(coreDir, nestedDir)
		}
	}
	
	binaryPath := filepath.Join(extractDir, "build", "mlos-server")
	
	// Verify binary exists
	if _, err := os.Stat(binaryPath); os.IsNotExist(err) {
		// Try to find binary in alternative locations
		altPaths := []string{
			filepath.Join(extractDir, "mlos-server"),
			filepath.Join(extractDir, "mlos_core"),
			filepath.Join(extractDir, "bin", "mlos-server"),
			filepath.Join(extractDir, "bin", "mlos_core"),
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
			// Try recursive search
			cmd := exec.Command("find", extractDir, "-type", "f", "(", "-name", "mlos-server", "-o", "-name", "mlos_core", ")", "-print", "-quit")
			output, err := cmd.Output()
			if err == nil {
				path := strings.TrimSpace(string(output))
				if path != "" {
					binaryPath = path
					found = true
				}
			}
		}
		if !found {
			return nil, fmt.Errorf("Core binary not found in %s (expected at %s)", extractDir, filepath.Join(extractDir, "build", "mlos-server"))
		}
	}

	// Ensure we use absolute path for binary
	absBinaryPath, err := filepath.Abs(binaryPath)
	if err != nil {
		return nil, fmt.Errorf("failed to get absolute path for binary: %w", err)
	}
	
	// Start server on non-privileged port (no sudo needed)
	cmd := exec.Command(absBinaryPath, "--http-port", fmt.Sprintf("%d", port))
	cmd.Dir = extractDir
	
	// Start process
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start Core server: %w", err)
	}

	process := &monitor.Process{
		PID:    cmd.Process.Pid,
		Cmd:    cmd,
		Binary: absBinaryPath,
	}

	// Wait for server to be ready
	if err := waitForServer(port); err != nil {
		monitor.StopProcess(process)
		return nil, fmt.Errorf("server failed to start: %w", err)
	}

	return process, nil
}

func getPlatform() string {
	osName := runtime.GOOS
	arch := runtime.GOARCH
	
	// Map Go arch to release arch names (archives use amd64, not x86_64)
	if arch == "amd64" {
		arch = "amd64" // Keep as amd64 for archive names
	} else if arch == "arm64" {
		arch = "arm64"
	}

	// Map Go OS to release OS names
	if osName == "darwin" {
		osName = "darwin"
	} else if osName == "linux" {
		osName = "linux"
	} else if osName == "windows" {
		osName = "windows"
	}

	return fmt.Sprintf("%s-%s", osName, arch)
}

func waitForServer(port int) error {
	// Wait for server to be ready by checking HTTP endpoint
	maxRetries := 30
	url := fmt.Sprintf("http://localhost:%d/health", port)
	for i := 0; i < maxRetries; i++ {
		// Try health endpoint - any response (even 404) means server is up
		cmd := exec.Command("curl", "-s", "-o", "/dev/null", url)
		if err := cmd.Run(); err == nil {
			// Server responded, it's ready
			return nil
		}
		// Wait a bit before retrying
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("server did not become ready after %d attempts", maxRetries)
}

