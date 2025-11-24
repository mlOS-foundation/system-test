#!/bin/bash
# Test E2E on Linux using Docker to reproduce CI issues

set -e

echo "🐳 Building Linux test environment..."
docker build -f Dockerfile.test -t mlos-test-linux .

echo ""
echo "🚀 Running E2E test in Linux container..."
echo ""

# Run container with Docker socket mounted (for Axon converter)
# and bind mount the repo
docker run --rm -it \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$(pwd):/workspace" \
    -w /workspace \
    -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
    mlos-test-linux \
    bash -c '
        echo "📦 Installing Go 1.21..."
        curl -fsSL https://go.dev/dl/go1.21.13.linux-amd64.tar.gz | tar -C /usr/local -xz
        export PATH=$PATH:/usr/local/go/bin
        export GOPATH=/root/go
        export PATH=$PATH:$GOPATH/bin
        
        echo ""
        echo "🔨 Building e2e-test for Linux..."
        go build -o bin/e2e-test-linux ./cmd/e2e-test
        
        echo ""
        echo "🧪 Running E2E test..."
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        ./bin/e2e-test-linux -minimal -core-version 3.0.0-alpha -v || {
            echo ""
            echo "❌ Test failed - checking Core server logs..."
            echo ""
            if [ -d e2e-results-* ]; then
                latest_dir=$(ls -dt e2e-results-* | head -1)
                echo "📋 Checking $latest_dir for logs..."
                find "$latest_dir" -name "*.log" -o -name "core-*.txt" | while read f; do
                    echo ""
                    echo "=== $f ==="
                    cat "$f"
                done
            fi
            exit 1
        }
    '

echo ""
echo "✅ Docker test completed"

