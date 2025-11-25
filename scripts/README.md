# MLOS Release E2E Test Script

This script validates Axon and MLOS Core releases with end-to-end inference tests.

## Prerequisites

### Required:
- **Bash** (version 3.2+)
- **curl** - for downloading releases
- **Docker** - for Axon's ONNX conversion (Docker daemon must be running)

### Optional (but recommended):
- **GitHub CLI (`gh`)** - for faster artifact downloads (has curl fallback)
- **sudo** - not required (script uses non-privileged port 18080)

## Installation

### macOS

```bash
# Install Homebrew (if not already installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install Docker Desktop
brew install --cask docker

# Install GitHub CLI (optional)
brew install gh

# Start Docker Desktop (required)
open -a Docker
```

### Ubuntu/Debian

```bash
# Update package list
sudo apt-get update

# Install curl
sudo apt-get install -y curl

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER

# Install GitHub CLI (optional)
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update
sudo apt-get install -y gh

# Start Docker service
sudo systemctl start docker
sudo systemctl enable docker

# Log out and back in (or run: newgrp docker) to apply docker group changes
```

## GitHub CLI Authentication (Optional)

If using `gh` CLI, authenticate for faster downloads:

```bash
gh auth login
# Follow the prompts to authenticate
```

Or set a token:
```bash
export GH_TOKEN="your_github_token"
```

**Note:** The script has curl fallbacks, so `gh` authentication is optional for public repos.

## Usage

### Basic Usage

```bash
cd /path/to/system-test/scripts
chmod +x test-release-e2e.sh.bash
./test-release-e2e.sh.bash
```

### Test All Models

To test all models (including vision and multimodal):

```bash
TEST_ALL_MODELS=1 ./test-release-e2e.sh.bash
```

### Custom Versions

You can modify the versions in the script or set environment variables:

```bash
# Edit the script to change:
# AXON_RELEASE_VERSION="v3.0.0"
# CORE_RELEASE_VERSION="3.0.0-alpha"
```

## What the Script Does

1. **Environment Setup**: Checks prerequisites (Docker, curl, gh)
2. **Download Releases**: Downloads Axon and MLOS Core binaries
3. **Install Models**: Installs test models using Axon (converts to ONNX)
4. **Start Core**: Starts MLOS Core server on port 18080
5. **Register Models**: Registers models with Core using `axon register`
6. **Run Inference**: Tests inference for each model
7. **Generate Report**: Creates HTML report with metrics and charts

## Output

The script creates a test directory with:
- `release-validation-report.html` - Visual HTML report
- `metrics.json` - Raw metrics data
- `test.log` - Detailed execution log
- `mlos-core-logs/` - Core server logs (stdout/stderr)

## Troubleshooting

### Docker Issues

**Problem:** "Docker daemon is not running"
```bash
# macOS: Start Docker Desktop
open -a Docker

# Ubuntu: Start Docker service
sudo systemctl start docker
```

**Problem:** "Permission denied" for Docker
```bash
# Ubuntu: Add user to docker group
sudo usermod -aG docker $USER
# Log out and back in
```

### Model Installation Fails

**Problem:** "Model installation failed - file not found"
- Check Docker is running: `docker ps`
- Check converter image is loaded: `docker images | grep axon-converter`
- Check Axon cache: `ls -la ~/.axon/cache/models/`

### Core Server Issues

**Problem:** "MLOS Core process died"
- Check Core logs: `cat release-test-*/mlos-core-logs/core-stderr.log`
- Check port 18080 is available: `lsof -i :18080`
- On Linux, ensure `LD_LIBRARY_PATH` is set (script handles this)

### Port Already in Use

**Problem:** "Address already in use"
```bash
# Find and kill process using port 18080
lsof -ti :18080 | xargs kill -9
```

## Platform-Specific Notes

### macOS
- Uses `mlos_core` binary from `darwin-amd64` or `darwin-arm64` release
- Docker Desktop must be running
- No `LD_LIBRARY_PATH` needed (uses `.dylib` libraries)

### Ubuntu/Linux
- Uses `mlos_core` binary from `linux-amd64` release
- Sets `LD_LIBRARY_PATH` for ONNX Runtime library
- May need `sudo` for some operations (but script avoids this)

## Example Output

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🚀 MLOS Release E2E Validation
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2025-11-25 23:26:01] ✅ GitHub CLI found: gh version 2.x.x
[2025-11-25 23:26:01] ✅ curl found
[2025-11-25 23:26:01] ✅ Docker available for ONNX conversion
...
[2025-11-25 23:30:00] ✅ Test completed successfully
[2025-11-25 23:30:00] 📄 Report: release-test-1234567890/release-validation-report.html
```

## Support

For issues or questions:
1. Check the log file: `release-test-*/test.log`
2. Check Core logs: `release-test-*/mlos-core-logs/*.log`
3. Verify prerequisites are installed and running

