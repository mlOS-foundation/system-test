package release

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
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

	archiveName := fmt.Sprintf("mlos-core_%s_%s.tar.gz", version, platform)
	archivePath := filepath.Join(coreDir, archiveName)

	// Get GITHUB_TOKEN from environment (set by GitHub Actions)
	githubToken := os.Getenv("GITHUB_TOKEN")
	if githubToken == "" {
		// Try alternative env var names
		githubToken = os.Getenv("GH_TOKEN")
	}

	// Try GitHub API first (more reliable with GITHUB_TOKEN)
	if githubToken != "" {
		if err := downloadViaAPI(version, archiveName, archivePath, githubToken); err == nil {
			// Success, proceed to extraction
		} else {
			fmt.Printf("GitHub API download failed: %v, trying gh CLI fallback...\n", err)
			// Fall through to gh CLI as fallback
		}
	}

	// Fallback to gh CLI if API failed or no token
	if _, err := os.Stat(archivePath); os.IsNotExist(err) {
		cmd := exec.Command("gh", "release", "download", version,
			"--repo", "mlOS-foundation/core",
			"--pattern", archiveName,
			"--dir", coreDir)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr

		if err := cmd.Run(); err != nil {
			// Try pattern matching
			fmt.Printf("Pattern download failed, trying alternative approach...\n")
			cmd = exec.Command("gh", "release", "download", version,
				"--repo", "mlOS-foundation/core",
				"--pattern", "*.tar.gz",
				"--dir", coreDir)
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
			if err := cmd.Run(); err != nil {
				return fmt.Errorf("failed to download Core release: %w", err)
			}
			// Find the downloaded file
			matches, err := filepath.Glob(filepath.Join(coreDir, archiveName))
			if err != nil || len(matches) == 0 {
				// Try with underscore instead of hyphen in platform
				altArchiveName := strings.Replace(archiveName, "_", "-", 1)
				matches, err = filepath.Glob(filepath.Join(coreDir, altArchiveName))
			}
			if err != nil || len(matches) == 0 {
				return fmt.Errorf("Core binary archive not found after download (expected: %s)", archiveName)
			}
			archivePath = matches[0]
		}
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

// SetupONNXRuntime downloads and sets up ONNX Runtime if needed
func SetupONNXRuntime(extractDir string) error {
	buildDir := filepath.Join(extractDir, "build")

	// Check if ONNX Runtime is already installed
	libName := "libonnxruntime.1.18.0.dylib"
	if runtime.GOOS == "linux" {
		libName = "libonnxruntime.1.18.0.so"
	}
	onnxLibPath := filepath.Join(buildDir, "onnxruntime", "lib", libName)

	if _, err := os.Stat(onnxLibPath); err == nil {
		return nil // Already installed
	}

	// Determine architecture for ONNX Runtime
	var onnxArch string
	switch runtime.GOARCH {
	case "amd64":
		onnxArch = "x64"
	case "arm64":
		onnxArch = "arm64"
	default:
		return fmt.Errorf("unsupported architecture for ONNX Runtime: %s", runtime.GOARCH)
	}

	// Download ONNX Runtime
	var onnxURL string
	if runtime.GOOS == "darwin" {
		onnxURL = fmt.Sprintf("https://github.com/microsoft/onnxruntime/releases/download/v1.18.0/onnxruntime-osx-%s-1.18.0.tgz", onnxArch)
	} else if runtime.GOOS == "linux" {
		onnxURL = fmt.Sprintf("https://github.com/microsoft/onnxruntime/releases/download/v1.18.0/onnxruntime-linux-%s-1.18.0.tgz", onnxArch)
	} else {
		return fmt.Errorf("unsupported OS for ONNX Runtime: %s", runtime.GOOS)
	}

	fmt.Printf("ONNX Runtime not found, downloading...\n")
	fmt.Printf("Downloading ONNX Runtime from: %s\n", onnxURL)

	// Download
	onnxArchive := filepath.Join(buildDir, "onnxruntime.tgz")
	cmd := exec.Command("curl", "-L", "-f", "-o", onnxArchive, onnxURL)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to download ONNX Runtime: %w", err)
	}

	// Extract
	if err := os.MkdirAll(buildDir, 0755); err != nil {
		return fmt.Errorf("failed to create build directory: %w", err)
	}

	cmd = exec.Command("tar", "-xzf", onnxArchive, "-C", buildDir)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to extract ONNX Runtime: %w", err)
	}

	// Rename to expected directory structure
	// Archive extracts to: onnxruntime-osx-arm64-1.18.0 or onnxruntime-linux-x64-1.18.0
	var extractedDirName string
	if runtime.GOOS == "darwin" {
		extractedDirName = fmt.Sprintf("onnxruntime-osx-%s-1.18.0", onnxArch)
	} else {
		extractedDirName = fmt.Sprintf("onnxruntime-linux-%s-1.18.0", onnxArch)
	}
	extractedDir := filepath.Join(buildDir, extractedDirName)
	expectedDir := filepath.Join(buildDir, "onnxruntime")

	if _, err := os.Stat(extractedDir); err == nil {
		if err := os.Rename(extractedDir, expectedDir); err != nil {
			return fmt.Errorf("failed to rename ONNX Runtime directory: %w", err)
		}
	} else {
		// Directory might already be named correctly, or extraction failed
		return fmt.Errorf("ONNX Runtime extraction directory not found: %s", extractedDir)
	}

	// Clean up archive
	_ = os.Remove(onnxArchive) // Ignore cleanup errors

	fmt.Printf("✅ ONNX Runtime installed\n")
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

	// Setup ONNX Runtime if needed
	if err := SetupONNXRuntime(extractDir); err != nil {
		return nil, fmt.Errorf("failed to setup ONNX Runtime: %w", err)
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

	// Capture output for debugging
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	// Start process
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start Core server: %w", err)
	}

	process := &monitor.Process{
		PID:    cmd.Process.Pid,
		Cmd:    cmd,
		Binary: absBinaryPath,
	}

	// Give server a moment to start
	time.Sleep(1 * time.Second)

	// Check if process is still running
	if cmd.ProcessState != nil && cmd.ProcessState.Exited() {
		output := stdout.String()
		errOutput := stderr.String()
		return nil, fmt.Errorf("server process exited immediately. stdout: %s, stderr: %s", output, errOutput)
	}

	// Wait for server to be ready
	if err := waitForServer(port); err != nil {
		// Log server output for debugging
		output := stdout.String()
		if output != "" {
			fmt.Printf("Server stdout: %s\n", output)
		}
		errOutput := stderr.String()
		if errOutput != "" {
			fmt.Printf("Server stderr: %s\n", errOutput)
		}
		if stopErr := monitor.StopProcess(process); stopErr != nil {
			fmt.Printf("WARN: Failed to stop process: %v\n", stopErr)
		}
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
		// Try health endpoint - check for any HTTP response (even 404 means server is up)
		cmd := exec.Command("curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", url)
		output, err := cmd.Output()
		if err == nil {
			statusCode := strings.TrimSpace(string(output))
			// Any HTTP status code (200, 404, etc.) means server is responding
			if statusCode != "" && statusCode != "000" {
				return nil
			}
		}
		// Also try root endpoint as fallback
		rootURL := fmt.Sprintf("http://localhost:%d/", port)
		cmd2 := exec.Command("curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", rootURL)
		output2, err2 := cmd2.Output()
		if err2 == nil {
			statusCode := strings.TrimSpace(string(output2))
			if statusCode != "" && statusCode != "000" {
				return nil
			}
		}
		// Wait a bit before retrying
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("server did not become ready after %d attempts (checked %s)", maxRetries, url)
}

// downloadViaAPI downloads a release asset using GitHub API
func downloadViaAPI(version, assetName, outputPath, token string) error {
	// Get release info
	apiURL := fmt.Sprintf("https://api.github.com/repos/mlOS-foundation/core/releases/tags/%s", version)
	req, err := http.NewRequest("GET", apiURL, nil)
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Authorization", fmt.Sprintf("token %s", token))
	req.Header.Set("Accept", "application/vnd.github.v3+json")

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("failed to fetch release info: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("failed to get release info: status %d, body: %s", resp.StatusCode, string(body))
	}

	var release struct {
		Assets []struct {
			Name               string `json:"name"`
			BrowserDownloadURL string `json:"browser_download_url"`
		} `json:"assets"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&release); err != nil {
		return fmt.Errorf("failed to decode release info: %w", err)
	}

	// Find matching asset
	var downloadURL string
	for _, asset := range release.Assets {
		if asset.Name == assetName {
			downloadURL = asset.BrowserDownloadURL
			break
		}
	}

	// Try variations if exact match not found
	if downloadURL == "" {
		// Try with underscore/hyphen variations
		variations := []string{
			strings.Replace(assetName, "_", "-", 1),
			strings.Replace(assetName, "-", "_", 1),
		}
		for _, asset := range release.Assets {
			for _, variant := range variations {
				if strings.Contains(asset.Name, variant) || strings.Contains(asset.Name, strings.TrimSuffix(assetName, ".tar.gz")) {
					downloadURL = asset.BrowserDownloadURL
					break
				}
			}
			if downloadURL != "" {
				break
			}
		}
	}

	if downloadURL == "" {
		return fmt.Errorf("asset %s not found in release", assetName)
	}

	// Download the asset
	fmt.Printf("Downloading %s from GitHub API...\n", assetName)
	req, err = http.NewRequest("GET", downloadURL, nil)
	if err != nil {
		return fmt.Errorf("failed to create download request: %w", err)
	}

	req.Header.Set("Authorization", fmt.Sprintf("token %s", token))
	req.Header.Set("Accept", "application/octet-stream")

	resp, err = client.Do(req)
	if err != nil {
		return fmt.Errorf("failed to download asset: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("failed to download asset: status %d, body: %s", resp.StatusCode, string(body))
	}

	// Save to file
	outFile, err := os.Create(outputPath)
	if err != nil {
		return fmt.Errorf("failed to create output file: %w", err)
	}
	defer outFile.Close()

	if _, err := io.Copy(outFile, resp.Body); err != nil {
		return fmt.Errorf("failed to write file: %w", err)
	}

	fmt.Printf("✅ Downloaded %s\n", assetName)
	return nil
}
