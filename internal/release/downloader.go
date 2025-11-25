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
		fmt.Printf("📥 Installing Axon CLI (~50MB)...\n")
		
		// Install Axon using the install script in background
		cmd := exec.Command("bash", "-c", "curl -fsSL https://raw.githubusercontent.com/mlOS-foundation/axon/main/install.sh | bash > /tmp/axon-install.log 2>&1")
		
		// Start the command
		if err := cmd.Start(); err != nil {
			return fmt.Errorf("failed to start Axon install: %w", err)
		}
		
		// Show progress while waiting
		done := make(chan error)
		go func() {
			done <- cmd.Wait()
		}()
		
		ticker := time.NewTicker(2 * time.Second)
		defer ticker.Stop()
		
		for {
			select {
			case err := <-done:
				if err != nil {
					return fmt.Errorf("failed to install Axon: %w", err)
				}
				fmt.Printf("✅ Axon CLI installed\n")
				return nil
			case <-ticker.C:
				fmt.Printf("   ... still installing ...\n")
			}
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
	coreDir := filepath.Join(outputDir, "mlos-core")

	if err := os.MkdirAll(coreDir, 0755); err != nil {
		return fmt.Errorf("failed to create core directory: %w", err)
	}

	// Determine platform-specific pattern
	// Map Go's GOOS/GOARCH to release naming
	osName := runtime.GOOS   // darwin, linux
	archName := runtime.GOARCH // amd64, arm64
	
	// Allow overriding platform for testing (e.g., test Linux Core on Mac via Docker)
	if forcePlatform := os.Getenv("FORCE_CORE_PLATFORM"); forcePlatform != "" {
		parts := strings.Split(forcePlatform, "/")
		if len(parts) == 2 {
			osName = parts[0]
			archName = parts[1]
			fmt.Printf("🐧 Forcing platform: %s/%s (for Docker testing)\n", osName, archName)
		}
	}
	
	// Construct platform-specific pattern: mlos-core_VERSION_OS-ARCH.tar.gz
	pattern := fmt.Sprintf("mlos-core_%s_%s-%s.tar.gz", version, osName, archName)
	archivePath := ""

	fmt.Printf("📥 Downloading MLOS Core for %s/%s...\n", osName, archName)

	// Use gh CLI with platform-specific pattern
	// Download from public core-releases repo (GITHUB_TOKEN can access public repos)
	cmd := exec.Command("gh", "release", "download", version,
		"--repo", "mlOS-foundation/core-releases",
		"--pattern", pattern,
		"--dir", coreDir)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		// If gh fails (e.g., not authenticated), try curl for public repo
		fmt.Printf("gh download failed, trying curl for public release...\n")
		
		// Construct download URL for public repo
		downloadURL := fmt.Sprintf("https://github.com/mlOS-foundation/core-releases/releases/download/%s/%s", 
			version, pattern)
		archivePathFull := filepath.Join(coreDir, pattern)
		
		curlCmd := exec.Command("curl", "-L", "-o", archivePathFull, downloadURL)
		curlCmd.Stdout = os.Stdout
		curlCmd.Stderr = os.Stderr
		
		if curlErr := curlCmd.Run(); curlErr != nil {
			return fmt.Errorf("failed to download Core release for %s/%s (gh: %w, curl: %w)", osName, archName, err, curlErr)
		}
		
		// Verify download succeeded
		if _, statErr := os.Stat(archivePathFull); statErr != nil {
			return fmt.Errorf("Core archive not found after curl download: %s", archivePathFull)
		}
		
		fmt.Printf("✅ Downloaded via curl\n")
	}

	// Find the downloaded file - should match the exact pattern
	archivePath = filepath.Join(coreDir, pattern)
	if _, err := os.Stat(archivePath); os.IsNotExist(err) {
		return fmt.Errorf("Core binary archive not found after download: %s", archivePath)
	}

	// Extract archive (extract to coreDir, then handle nested structure)
	extractCmd := exec.Command("tar", "-xzf", archivePath, "-C", coreDir)
	if err := extractCmd.Run(); err != nil {
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

	// Search for binary (newer releases use mlos_core, older ones may use mlos-server)
	binaryPath := ""

	// Try common locations first - prioritize mlos_core as that's the current name
	commonPaths := []string{
		filepath.Join(extractDir, "mlos_core"),
		filepath.Join(extractDir, "build", "mlos_core"),
		filepath.Join(extractDir, "bin", "mlos_core"),
		filepath.Join(extractDir, "mlos-server"),
		filepath.Join(extractDir, "build", "mlos-server"),
		filepath.Join(extractDir, "bin", "mlos-server"),
	}

	for _, path := range commonPaths {
		if _, err := os.Stat(path); err == nil {
			binaryPath = path
			fmt.Printf("✅ Found Core binary at: %s\n", path)
			break
		}
	}

	// If not found, search recursively
	if binaryPath == "" {
		cmd := exec.Command("find", extractDir, "-type", "f", "(", "-name", "mlos_core", "-o", "-name", "mlos-server", ")")
		output, err := cmd.Output()
		if err == nil {
			lines := strings.Split(strings.TrimSpace(string(output)), "\n")
			if len(lines) > 0 && lines[0] != "" {
				binaryPath = lines[0]
				fmt.Printf("✅ Found Core binary at: %s\n", binaryPath)
			}
		}
	}

	if binaryPath == "" {
		return fmt.Errorf("Core binary (mlos_core or mlos-server) not found in release archive (searched in %s)", extractDir)
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
	
	// Determine target OS (allow override for Docker testing)
	targetOS := runtime.GOOS
	targetArch := runtime.GOARCH
	if forcePlatform := os.Getenv("FORCE_CORE_PLATFORM"); forcePlatform != "" {
		parts := strings.Split(forcePlatform, "/")
		if len(parts) == 2 {
			targetOS = parts[0]
			targetArch = parts[1]
			fmt.Printf("🐧 Using forced platform: %s/%s (for Docker testing)\n", targetOS, targetArch)
		}
	} else {
		fmt.Printf("📦 Detected platform: %s/%s (native execution)\n", targetOS, targetArch)
	}

	// Check if ONNX Runtime is already installed
	libName := "libonnxruntime.1.18.0.dylib"
	if targetOS == "linux" {
		libName = "libonnxruntime.1.18.0.so"
	}
	onnxLibPath := filepath.Join(buildDir, "onnxruntime", "lib", libName)

	if _, err := os.Stat(onnxLibPath); err == nil {
		fmt.Printf("✅ ONNX Runtime already installed: %s\n", libName)
		return nil // Already installed
	}
	
	fmt.Printf("📥 ONNX Runtime not found, downloading for %s/%s...\n", targetOS, targetArch)

	// Determine architecture for ONNX Runtime
	var onnxArch string
	switch targetArch {
	case "amd64":
		onnxArch = "x64"
	case "arm64":
		onnxArch = "arm64"
	default:
		return fmt.Errorf("unsupported architecture for ONNX Runtime: %s", targetArch)
	}

	// Download ONNX Runtime
	var onnxURL string
	if targetOS == "darwin" {
		onnxURL = fmt.Sprintf("https://github.com/microsoft/onnxruntime/releases/download/v1.18.0/onnxruntime-osx-%s-1.18.0.tgz", onnxArch)
	} else if targetOS == "linux" {
		onnxURL = fmt.Sprintf("https://github.com/microsoft/onnxruntime/releases/download/v1.18.0/onnxruntime-linux-%s-1.18.0.tgz", onnxArch)
	} else {
		return fmt.Errorf("unsupported OS for ONNX Runtime: %s", targetOS)
	}

	fmt.Printf("📥 Downloading ONNX Runtime (~8MB)...\n")

	// Download with progress indicator
	onnxArchive := filepath.Join(buildDir, "onnxruntime.tgz")
	cmd := exec.Command("curl", "-L", "-f", "-#", "-o", onnxArchive, onnxURL)
	cmd.Stderr = os.Stderr // Show curl's progress bar
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
	if targetOS == "darwin" {
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
// startCoreInDocker runs Core server in a Linux Docker container
// This is used to test Linux Core behavior on Mac
func startCoreInDocker(extractDir string, port int) (*monitor.Process, error) {
	// Find the Core binary
	binaryPath := ""
	altPaths := []string{
		filepath.Join(extractDir, "mlos_core"),
		filepath.Join(extractDir, "build", "mlos_core"),
		filepath.Join(extractDir, "bin", "mlos_core"),
		filepath.Join(extractDir, "mlos-server"),
		filepath.Join(extractDir, "build", "mlos-server"),
		filepath.Join(extractDir, "bin", "mlos-server"),
	}
	for _, altPath := range altPaths {
		if _, err := os.Stat(altPath); err == nil {
			binaryPath = altPath
			break
		}
	}
	if binaryPath == "" {
		return nil, fmt.Errorf("Core binary not found in %s", extractDir)
	}
	
	// Get absolute paths for Docker volume mounting
	absExtractDir, err := filepath.Abs(extractDir)
	if err != nil {
		return nil, fmt.Errorf("failed to get absolute path: %w", err)
	}
	
	// Run Core in Ubuntu container with port mapping
	// Mount the entire extract directory so ONNX Runtime is accessible
	// Note: On Mac, --network host doesn't work (Docker runs in VM), so use -p instead
	cmd := exec.Command("docker", "run", "--rm",
		"--platform", "linux/amd64",
		"-p", fmt.Sprintf("%d:%d", port, port),
		"-v", fmt.Sprintf("%s:/core", absExtractDir),
		"-w", "/core",
		"ubuntu:22.04",
		"/bin/bash", "-c",
		fmt.Sprintf(`
			# Install minimal dependencies
			echo "📦 Installing dependencies..."
			apt-get update -qq && apt-get install -y -qq curl ca-certificates > /dev/null 2>&1
			
			echo "🔍 Core binary: %s"
			ls -lh %s
			
			# Set LD_LIBRARY_PATH for ONNX Runtime
			export LD_LIBRARY_PATH=/core/build/onnxruntime/lib:$LD_LIBRARY_PATH
			
			# Check dependencies
			echo "🔗 Checking binary dependencies:"
			ldd %s | head -10 || echo "⚠️  ldd failed"
			
			# Run Core server
			chmod +x %s
			echo "🚀 Starting Core server on port %d..."
			%s --http-port %d 2>&1
		`, filepath.Base(binaryPath), filepath.Base(binaryPath), filepath.Base(binaryPath), filepath.Base(binaryPath), port, filepath.Base(binaryPath), port))
	
	// Show output in real-time for debugging
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	
	// Start container
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start Core Docker container: %w", err)
	}
	
	process := &monitor.Process{
		PID:    cmd.Process.Pid,
		Cmd:    cmd,
		Binary: binaryPath,
	}
	
	// Give server a moment to start inside Docker
	// Docker needs more time to pull image, install deps, and start server
	time.Sleep(5 * time.Second)
	
	// Wait for server to be ready (Docker startup takes longer)
	fmt.Printf("⏳ Waiting for Core server to be ready (this may take ~30s for Docker setup)...\n")
	if err := waitForServer(port); err != nil {
		fmt.Printf("\n❌ Server failed to become ready\n")
		if stopErr := monitor.StopProcess(process); stopErr != nil {
			fmt.Printf("WARN: Failed to stop Docker container: %v\n", stopErr)
		}
		return nil, fmt.Errorf("Core server in Docker failed to start: %w", err)
	}
	
	fmt.Printf("✅ Core running in Linux Docker container on port %d\n", port)
	return process, nil
}

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
	
	// Check if we should run Core in Docker (for testing Linux Core on Mac)
	// In CI, this will be false, so Core runs directly on the Linux runner
	if os.Getenv("CORE_IN_DOCKER") == "true" {
		fmt.Printf("🐳 Running Core in Linux Docker container (local testing mode)\n")
		return startCoreInDocker(extractDir, port)
	}
	
	// Direct execution path (used in CI and local native runs)
	// LD_LIBRARY_PATH will be set below for Linux

	binaryPath := filepath.Join(extractDir, "build", "mlos-server")

	// Verify binary exists
	if _, err := os.Stat(binaryPath); os.IsNotExist(err) {
		// Try to find binary in alternative locations - prioritize mlos_core
		altPaths := []string{
			filepath.Join(extractDir, "mlos_core"),
			filepath.Join(extractDir, "bin", "mlos_core"),
			filepath.Join(extractDir, "mlos-server"),
			filepath.Join(extractDir, "bin", "mlos-server"),
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
			cmd := exec.Command("find", extractDir, "-type", "f", "(", "-name", "mlos_core", "-o", "-name", "mlos-server", ")", "-print", "-quit")
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
			return nil, fmt.Errorf("Core binary (mlos_core or mlos-server) not found in %s", extractDir)
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
	
	// Set LD_LIBRARY_PATH for Linux to find ONNX Runtime library
	// This is needed for native Linux execution (CI) and Docker
	if runtime.GOOS == "linux" {
		onnxLibDir := filepath.Join(extractDir, "build", "onnxruntime", "lib")
		// Preserve existing LD_LIBRARY_PATH if set
		existingLibPath := os.Getenv("LD_LIBRARY_PATH")
		if existingLibPath != "" {
			cmd.Env = append(os.Environ(), fmt.Sprintf("LD_LIBRARY_PATH=%s:%s", onnxLibDir, existingLibPath))
		} else {
			cmd.Env = append(os.Environ(), fmt.Sprintf("LD_LIBRARY_PATH=%s", onnxLibDir))
		}
	}

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

func waitForServer(port int) error {
	// Wait for server to be ready by checking HTTP endpoint (use explicit IPv4)
	maxRetries := 30
	url := fmt.Sprintf("http://127.0.0.1:%d/health", port)
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
		// Also try root endpoint as fallback (use explicit IPv4)
		rootURL := fmt.Sprintf("http://127.0.0.1:%d/", port)
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
// Currently unused - using gh CLI directly instead
// Keeping for potential future use
//
//nolint:unused // Kept for potential future use
func downloadViaAPI(version, assetName, outputPath, token string) error {
	// Get release info
	// Use public core-releases repo (GITHUB_TOKEN can access public repos)
	apiURL := fmt.Sprintf("https://api.github.com/repos/mlOS-foundation/core-releases/releases/tags/%s", version)
	req, err := http.NewRequest("GET", apiURL, nil)
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}

	// GitHub Actions tokens (ghs_*) work with "token" prefix
	// Personal tokens work with either "token" or "Bearer"
	// Use "token" for compatibility
	req.Header.Set("Authorization", fmt.Sprintf("token %s", token))
	req.Header.Set("Accept", "application/vnd.github.v3+json")
	req.Header.Set("User-Agent", "mlOS-system-test/1.0")

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
