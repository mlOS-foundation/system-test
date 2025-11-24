#!/bin/bash
# Test E2E on Linux using Docker (non-interactive)

set -e

echo "🐳 Running E2E test in Linux container..."
echo ""

# Run container without -it for non-interactive execution
# Use --platform linux/amd64 to match GitHub Actions runners
docker run --rm \
    --platform linux/amd64 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$(pwd):/workspace" \
    -w /workspace \
    -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
    ubuntu:22.04 \
    bash -c '
        set -e
        
        echo "📦 Installing dependencies..."
        apt-get update -qq
        apt-get install -y -qq curl git ca-certificates build-essential docker.io wget strace gdb 2>&1 | grep -v "^debconf:" || true
        
        # Install gh CLI
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
        chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        apt-get update -qq
        apt-get install -y -qq gh 2>&1 | grep -v "^debconf:" || true
        
        # Install Go
        echo "📦 Installing Go 1.21..."
        curl -fsSL https://go.dev/dl/go1.21.13.linux-amd64.tar.gz | tar -C /usr/local -xz 2>&1 | head -5 || true
        export PATH=$PATH:/usr/local/go/bin
        export GOPATH=/root/go
        export PATH=$PATH:$GOPATH/bin
        
        # Build test
        echo "🔨 Building e2e-test for Linux..."
        go build -o bin/e2e-test-linux ./cmd/e2e-test
        
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🧪 Running E2E Test on Linux"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        # Run test and capture result
        if ./bin/e2e-test-linux -minimal -core-version 3.0.0-alpha; then
            echo ""
            echo "✅ All tests passed on Linux!"
            exit 0
        else
            exit_code=$?
            echo ""
            echo "❌ Test failed with exit code: $exit_code"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "🔍 Debugging Information"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            
            # Find latest results directory
            latest_dir=$(ls -dt e2e-results-* 2>/dev/null | head -1)
            if [ -n "$latest_dir" ]; then
                echo "📂 Results directory: $latest_dir"
                echo ""
                
                # Find Core binary
                core_binary=$(find "$latest_dir" -name mlos_core -type f 2>/dev/null | head -1)
                if [ -n "$core_binary" ]; then
                    echo "📍 Core binary: $core_binary"
                    
                    # Check if it'\''s executable
                    if [ -x "$core_binary" ]; then
                        echo "   ✅ Binary is executable"
                        
                        # Check dependencies
                        echo ""
                        echo "🔗 Checking Core dependencies:"
                        ldd "$core_binary" || echo "   ⚠️  ldd failed"
                    else
                        echo "   ❌ Binary is NOT executable"
                    fi
                    
                    # Try to run Core manually for 2 seconds
                    echo ""
                    echo "🧪 Testing Core server manually..."
                    core_dir=$(dirname "$core_binary")
                    cd "$core_dir"
                    
                    # Start Core in background with output
                    timeout 3s ./$(basename "$core_binary") --http-port 18080 2>&1 | head -50 &
                    core_pid=$!
                    sleep 2
                    
                    # Test health endpoint
                    echo ""
                    echo "🏥 Testing health endpoint..."
                    curl -v http://127.0.0.1:18080/health 2>&1 | head -20 || echo "   ❌ Health check failed"
                    
                    # Kill Core if still running
                    kill $core_pid 2>/dev/null || true
                    wait $core_pid 2>/dev/null || true
                fi
            fi
            
            exit $exit_code
        fi
    '

echo ""
echo "🏁 Docker test completed"

