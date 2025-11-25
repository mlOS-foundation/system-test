#!/bin/bash
# Validation script for Ubuntu VM setup
# Checks prerequisites and validates environment for E2E testing

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Validating Ubuntu VM Environment"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Track validation status
ALL_PASSED=true

# Function to check and report
check_item() {
    local name=$1
    local check_cmd=$2
    local fix_hint=$3
    
    echo -n "Checking $name... "
    if eval "$check_cmd" >/dev/null 2>&1; then
        echo -e "${GREEN}✅${NC}"
        return 0
    else
        echo -e "${RED}❌${NC}"
        if [ -n "$fix_hint" ]; then
            echo "   💡 $fix_hint"
        fi
        ALL_PASSED=false
        return 1
    fi
}

# 1. Check Go installation
echo "📦 Development Tools"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check_item "Go 1.22+" "export PATH=\$PATH:/usr/local/go/bin && go version | grep -q 'go1.2[2-9]' || go version | grep -q 'go1.[3-9]'" \
    "Install: curl -fsSL https://go.dev/dl/go1.22.6.linux-amd64.tar.gz | sudo tar -C /usr/local -xz"

GO_VERSION=$(export PATH=$PATH:/usr/local/go/bin && go version 2>/dev/null || echo "not found")
if [[ "$GO_VERSION" != "not found" ]]; then
    echo "   Version: $GO_VERSION"
fi

# 2. Check Docker
echo ""
echo "🐳 Docker"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check_item "Docker CLI" "docker --version" \
    "Install: curl -fsSL https://get.docker.com | sudo sh"

if docker --version >/dev/null 2>&1; then
    DOCKER_VERSION=$(docker --version)
    echo "   $DOCKER_VERSION"
fi

check_item "Docker daemon" "docker ps" \
    "Start: sudo systemctl start docker && sudo usermod -aG docker \$USER"

check_item "Docker socket access" "[ -S /var/run/docker.sock ] && docker ps >/dev/null" \
    "Fix: sudo usermod -aG docker \$USER && newgrp docker"

# 3. Check Axon converter image
echo ""
echo "📦 Axon Converter Image"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if docker images | grep -q "axon-converter"; then
    echo -e "Converter image: ${GREEN}✅${NC}"
    docker images | grep axon-converter | head -2
else
    echo -e "Converter image: ${YELLOW}⚠️  Not loaded${NC}"
    echo "   💡 Will be loaded automatically during test"
fi

# 4. Check GitHub CLI
echo ""
echo "🔐 GitHub CLI"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
check_item "gh CLI" "gh --version" \
    "Install: curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && echo 'deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' | sudo tee /etc/apt/sources.list.d/github-cli.list && sudo apt-get update && sudo apt-get install -y gh"

if gh --version >/dev/null 2>&1; then
    GH_VERSION=$(gh --version | head -1)
    echo "   $GH_VERSION"
    
    # Check authentication
    if gh auth status >/dev/null 2>&1; then
        echo -e "   Authentication: ${GREEN}✅${NC}"
    elif [ -n "$GH_TOKEN" ]; then
        echo -e "   Authentication: ${GREEN}✅${NC} (via GH_TOKEN)"
    else
        echo -e "   Authentication: ${YELLOW}⚠️  Not authenticated${NC}"
        echo "   💡 Set GH_TOKEN or run: gh auth login"
    fi
fi

# 5. Check system-test repository
echo ""
echo "📂 Repository"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ -d "system-test" ]; then
    echo -e "system-test directory: ${GREEN}✅${NC}"
    cd system-test
    
    if [ -d ".git" ]; then
        echo -e "   Git repository: ${GREEN}✅${NC}"
        CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
        echo "   Branch: $CURRENT_BRANCH"
        
        # Check if up to date
        if git fetch --dry-run >/dev/null 2>&1; then
            LOCAL=$(git rev-parse HEAD 2>/dev/null || echo "")
            REMOTE=$(git rev-parse origin/main 2>/dev/null || echo "")
            if [ "$LOCAL" = "$REMOTE" ]; then
                echo -e "   Up to date: ${GREEN}✅${NC}"
            else
                echo -e "   Up to date: ${YELLOW}⚠️  Behind origin/main${NC}"
                echo "   💡 Run: git pull"
            fi
        fi
    else
        echo -e "   Git repository: ${RED}❌${NC}"
        ALL_PASSED=false
    fi
    
    cd ..
else
    echo -e "system-test directory: ${RED}❌${NC}"
    echo "   💡 Clone: git clone https://github.com/mlOS-foundation/system-test.git"
    ALL_PASSED=false
fi

# 6. Check build capability
echo ""
echo "🔨 Build Capability"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ -d "system-test" ]; then
    cd system-test
    export PATH=$PATH:/usr/local/go/bin
    
    if go version >/dev/null 2>&1; then
        echo -n "Testing Go build... "
        if go build -o /tmp/e2e-test-validate ./cmd/e2e-test >/dev/null 2>&1; then
            echo -e "${GREEN}✅${NC}"
            rm -f /tmp/e2e-test-validate
        else
            echo -e "${RED}❌${NC}"
            echo "   💡 Check Go dependencies: go mod download"
            ALL_PASSED=false
        fi
    fi
    cd ..
fi

# 7. Check disk space
echo ""
echo "💾 System Resources"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
AVAILABLE_SPACE=$(df -h . | tail -1 | awk '{print $4}')
echo "   Available disk space: $AVAILABLE_SPACE"

# Check if we have at least 5GB free (rough check)
AVAILABLE_GB=$(df . | tail -1 | awk '{print int($4/1024/1024)}')
if [ "$AVAILABLE_GB" -gt 5 ]; then
    echo -e "   Disk space: ${GREEN}✅${NC} (>5GB free)"
else
    echo -e "   Disk space: ${YELLOW}⚠️  Low (<5GB free)${NC}"
fi

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$ALL_PASSED" = true ]; then
    echo -e "${GREEN}✅ All critical checks passed!${NC}"
    echo ""
    echo "You can now run the E2E test:"
    echo "  cd system-test"
    echo "  export PATH=\$PATH:/usr/local/go/bin"
    echo "  go build -o e2e-test ./cmd/e2e-test"
    echo "  ./e2e-test --axon-version v3.0.0 --core-version 3.0.0-alpha --minimal --verbose"
    exit 0
else
    echo -e "${YELLOW}⚠️  Some checks failed. Please fix the issues above.${NC}"
    exit 1
fi

