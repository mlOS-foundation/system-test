#!/bin/bash
# Interactive Linux debugging session with Core server logs

set -e

echo "🐳 Starting interactive Linux debug environment..."

docker run --rm -it \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$(pwd):/workspace" \
    -w /workspace \
    -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
    ubuntu:22.04 \
    bash -c '
        echo "📦 Installing dependencies..."
        apt-get update -qq
        apt-get install -y -qq curl git ca-certificates build-essential docker.io wget > /dev/null 2>&1
        
        # Install gh CLI
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
        chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        apt-get update -qq
        apt-get install -y -qq gh > /dev/null 2>&1
        
        # Install Go
        echo "📦 Installing Go 1.21..."
        curl -fsSL https://go.dev/dl/go1.21.13.linux-amd64.tar.gz | tar -C /usr/local -xz
        export PATH=$PATH:/usr/local/go/bin
        export GOPATH=/root/go
        export PATH=$PATH:$GOPATH/bin
        
        # Build test
        echo "🔨 Building e2e-test for Linux..."
        go build -o bin/e2e-test-linux ./cmd/e2e-test
        
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🔍 Linux Debug Environment Ready"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Available commands:"
        echo "  ./bin/e2e-test-linux -minimal -core-version 3.0.0-alpha"
        echo ""
        echo "To debug Core server:"
        echo "  1. Find Core binary: find e2e-results-*/mlos-core -name mlos_core"
        echo "  2. Run with strace: strace -f ./path/to/mlos_core --http-port 18080"
        echo "  3. Check logs: tail -f e2e-results-*/mlos-core/*.log"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        # Run test automatically
        echo "🧪 Running E2E test..."
        ./bin/e2e-test-linux -minimal -core-version 3.0.0-alpha || {
            echo ""
            echo "❌ Test failed - entering debug shell..."
            echo ""
            echo "Core binary location:"
            find e2e-results-* -name mlos_core 2>/dev/null | head -1
            echo ""
            echo "To debug manually, run:"
            echo "  cd \$(ls -dt e2e-results-* | head -1)"
            echo "  strace -f ./mlos-core/*/mlos_core --http-port 18080"
            echo ""
            /bin/bash
        }
    '

