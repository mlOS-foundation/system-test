#!/bin/bash
# =============================================================================
# Test with Local Axon and Core Binaries
# =============================================================================
# Wrapper script to test with local Axon and Core builds
# Supports Core PR #39 format-agnostic runtime plugin system
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="${CORE_DIR:-$(cd "$SCRIPT_DIR/../core" 2>/dev/null && pwd)}"
AXON_DIR="${AXON_DIR:-$(cd "$SCRIPT_DIR/../axon" 2>/dev/null && pwd)}"
CORE_BINARY="$CORE_DIR/build/mlos_core"
AXON_BINARY="$AXON_DIR/bin/axon"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Testing with Local Axon and Core Builds"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Core Binary: $CORE_BINARY"
echo "Axon Binary: $AXON_BINARY"
echo ""

# Build Core if needed
if [ ! -f "$CORE_BINARY" ]; then
    echo "Core binary not found, building..."
    if [ -d "$CORE_DIR" ]; then
        (cd "$CORE_DIR" && make all)
    else
        echo "Error: Core directory not found at: $CORE_DIR"
        exit 1
    fi
fi

# Build Axon if needed
if [ ! -f "$AXON_BINARY" ]; then
    echo "Axon binary not found, building..."
    if [ -d "$AXON_DIR" ]; then
        (cd "$AXON_DIR" && make build)
    else
        echo "Error: Axon directory not found at: $AXON_DIR"
        exit 1
    fi
fi

# Final check
if [ ! -f "$CORE_BINARY" ] || [ ! -f "$AXON_BINARY" ]; then
    echo "Error: Failed to build required binaries"
    [ ! -f "$CORE_BINARY" ] && echo "  Missing: $CORE_BINARY"
    [ ! -f "$AXON_BINARY" ] && echo "  Missing: $AXON_BINARY"
    exit 1
fi

echo "Both binaries found"
echo ""

# Get versions from git
CORE_GIT_VERSION=$(cd "$CORE_DIR" && git rev-parse --short HEAD 2>/dev/null || echo 'local')
AXON_GIT_VERSION=$(cd "$AXON_DIR" && git rev-parse --short HEAD 2>/dev/null || echo 'local')

# Run the test with local core and local axon
cd "$SCRIPT_DIR"
export USE_LOCAL_CORE=1
export LOCAL_CORE_BINARY="$CORE_BINARY"
export USE_LOCAL_AXON=1
export LOCAL_AXON_BINARY="$AXON_BINARY"
export CORE_VERSION="local-$CORE_GIT_VERSION"
export AXON_VERSION="local-$AXON_GIT_VERSION"
export PATH="$AXON_DIR/bin:$PATH"

# Run format detection tests first (Core PR #39)
if [ -x "$SCRIPT_DIR/test-format-detection.sh" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Running Format Detection Tests (Core PR #39)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    "$SCRIPT_DIR/test-format-detection.sh" || echo "Warning: Format detection tests had issues"
    echo ""
fi

# Run the main E2E test
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Running E2E Release Tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
./scripts/test-release-e2e.sh.bash "$@"

