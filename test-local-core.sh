#!/bin/bash
# =============================================================================
# Test with Local Core Binary
# =============================================================================
# Wrapper script to test with local core build instead of downloading release
# Supports Core PR #39 format-agnostic runtime plugin system
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="${CORE_DIR:-$(cd "$SCRIPT_DIR/../core" 2>/dev/null && pwd)}"
CORE_BINARY="$CORE_DIR/build/mlos_core"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Testing with Local Core Build"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Core Binary: $CORE_BINARY"
echo "Core Dir:    $CORE_DIR"
echo ""

# Check if core binary exists
if [ ! -f "$CORE_BINARY" ]; then
    echo "Core binary not found at: $CORE_BINARY"
    echo "Building Core..."
    echo ""

    if [ -d "$CORE_DIR" ]; then
        (cd "$CORE_DIR" && make all)
    else
        echo "Error: Core directory not found at: $CORE_DIR"
        exit 1
    fi
fi

if [ ! -f "$CORE_BINARY" ]; then
    echo "Error: Failed to build Core binary"
    exit 1
fi

echo "Core binary found"
echo ""

# Get Core version from git or binary
CORE_GIT_VERSION=$(cd "$CORE_DIR" && git rev-parse --short HEAD 2>/dev/null || echo 'local')

# Run the test with local core
cd "$SCRIPT_DIR"
export USE_LOCAL_CORE=1
export LOCAL_CORE_BINARY="$CORE_BINARY"
export CORE_VERSION="local-$CORE_GIT_VERSION"

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




