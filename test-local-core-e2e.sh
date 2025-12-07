#!/bin/bash
# =============================================================================
# Local E2E Test with Local Core Build (from core/build/mlos_core)
# =============================================================================
# Tests the full stack using:
# - Local Axon binary from mlOS-foundation/axon
# - Local Core binary from mlOS-foundation/core/build/mlos_core
# - Tests all models configured in config/models.yaml
# - Includes Core PR #39 format-agnostic runtime plugin tests
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)"
AXON_DIR="${AXON_DIR:-$(cd "$ROOT_DIR/../axon" 2>/dev/null && pwd)}"
CORE_DIR="${CORE_DIR:-$(cd "$ROOT_DIR/../core" 2>/dev/null && pwd)}"

# Configuration
CORE_BINARY="$CORE_DIR/build/mlos_core"
TEST_DIR="$SCRIPT_DIR/local-test-$(date +%s)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Local E2E Test with Local Core"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Axon:     $AXON_DIR/bin/axon"
echo "Core:     $CORE_BINARY"
echo "Test Dir: $TEST_DIR"
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
if [ ! -f "$AXON_DIR/bin/axon" ]; then
    echo "Axon binary not found, building..."
    if [ -d "$AXON_DIR" ]; then
        (cd "$AXON_DIR" && make build)
    else
        echo "Error: Axon directory not found at: $AXON_DIR"
        exit 1
    fi
fi

# Final check
if [ ! -f "$CORE_BINARY" ] || [ ! -f "$AXON_DIR/bin/axon" ]; then
    echo "Error: Failed to build required binaries"
    [ ! -f "$CORE_BINARY" ] && echo "  Missing: $CORE_BINARY"
    [ ! -f "$AXON_DIR/bin/axon" ] && echo "  Missing: $AXON_DIR/bin/axon"
    exit 1
fi

# Check for Docker converter image
if ! docker image inspect axon-converter:local &>/dev/null; then
    echo "Note: Docker image axon-converter:local not found"
    echo "      Will use default converter image"
fi

# Create test directory
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

echo "Test directory: $TEST_DIR"
echo ""

# Copy binaries
cp "$AXON_DIR/bin/axon" ./axon
chmod +x ./axon

mkdir -p build
cp "$CORE_BINARY" ./build/mlos_core
chmod +x ./build/mlos_core

# Set environment
export AXON_CONVERTER_IMAGE="${AXON_CONVERTER_IMAGE:-axon-converter:local}"
export AXON_HOME="$TEST_DIR/.axon"
export PATH="$TEST_DIR:$PATH"

# Use the main test script but with local core
cd "$SCRIPT_DIR"

# Set environment variables for the test script
export USE_LOCAL_CORE=1
export LOCAL_CORE_BINARY="$TEST_DIR/build/mlos_core"
export CORE_VERSION="local-$(date +%s)"

# Run format detection tests first (Core PR #39)
if [ -x "$SCRIPT_DIR/test-format-detection.sh" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Running Format Detection Tests (Core PR #39)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    "$SCRIPT_DIR/test-format-detection.sh" 2>&1 | tee "$TEST_DIR/format-detection.log" || echo "Warning: Format detection tests had issues"
    echo ""
fi

# Run the full E2E test
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Running Full E2E Test Suite"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Run the main test script
./scripts/test-release-e2e.sh.bash "$@" 2>&1 | tee "$TEST_DIR/test.log"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Test Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Test directory: $TEST_DIR"
echo "Test log: $TEST_DIR/test.log"
echo ""
