# Quick Start Guide

## macOS

```bash
# 1. Install prerequisites
brew install --cask docker
brew install gh  # optional

# 2. Start Docker Desktop
open -a Docker

# 3. Authenticate GitHub CLI (optional)
gh auth login

# 4. Run the script
cd scripts
chmod +x test-release-e2e.sh.bash
./test-release-e2e.sh.bash
```

## Ubuntu

```bash
# 1. Install prerequisites
sudo apt-get update
sudo apt-get install -y curl docker.io

# 2. Start Docker
sudo systemctl start docker
sudo usermod -aG docker $USER
# Log out and back in (or: newgrp docker)

# 3. Install GitHub CLI (optional)
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update
sudo apt-get install -y gh

# 4. Authenticate GitHub CLI (optional)
gh auth login

# 5. Run the script
cd scripts
chmod +x test-release-e2e.sh.bash
./test-release-e2e.sh.bash
```

## Verify Prerequisites

```bash
# Check Docker
docker ps

# Check curl
curl --version

# Check GitHub CLI (optional)
gh --version
```

## Run with All Models

```bash
TEST_ALL_MODELS=1 ./test-release-e2e.sh.bash
```

## View Results

After completion, open the HTML report:
```bash
open release-test-*/release-validation-report.html  # macOS
xdg-open release-test-*/release-validation-report.html  # Ubuntu
```

