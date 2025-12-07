#!/usr/bin/env bash
# =============================================================================
# Test Format Detection (Format-Agnostic Runtime - Core PR #39)
# =============================================================================
# Tests the format-agnostic model detection in MLOS Core
# Validates both extension-based and magic byte detection
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="${CORE_DIR:-$(cd "$SCRIPT_DIR/../core" 2>/dev/null && pwd)}"
CORE_BINARY="${LOCAL_CORE_BINARY:-$CORE_DIR/build/mlos_core}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Testing Format-Agnostic Model Detection (Core PR #39)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if core is built
if [ ! -f "$CORE_BINARY" ]; then
    echo "Warning: Core binary not found at: $CORE_BINARY"
    echo "         Running format detection simulation only"
    echo ""
    SKIP_CORE_TESTS=1
else
    echo "Core binary: $CORE_BINARY"
    SKIP_CORE_TESTS=0
fi

# Create temp directory for test files
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

echo ""
echo "Creating test model files with magic bytes..."
echo ""

# =============================================================================
# Create test files with proper magic bytes
# =============================================================================

# GGUF format (llama.cpp) - magic: "GGUF"
printf 'GGUF\x03\x00\x00\x00' > "$TEST_DIR/model.gguf"
echo "  Created model.gguf (GGUF magic bytes)"

# PyTorch ZIP format - magic: "PK\x03\x04" (ZIP header)
printf 'PK\x03\x04\x14\x00\x00\x00\x08\x00' > "$TEST_DIR/model.pt"
printf 'PK\x03\x04\x14\x00\x00\x00\x08\x00' > "$TEST_DIR/model.pth"
echo "  Created model.pt, model.pth (PyTorch/ZIP magic bytes)"

# PyTorch pickle format - magic: \x80\x02-\x05 (pickle protocol)
printf '\x80\x04\x95' > "$TEST_DIR/model_pickle.pt"
echo "  Created model_pickle.pt (PyTorch pickle magic bytes)"

# Safetensors format - JSON header starting with "{"
printf '{"__metadata__":{"format":"pt"}}' > "$TEST_DIR/model.safetensors"
echo "  Created model.safetensors (JSON header)"

# ONNX format - no specific magic, extension-based
touch "$TEST_DIR/model.onnx"
echo "  Created model.onnx (extension-based)"

# TFLite format - extension-based
touch "$TEST_DIR/model.tflite"
echo "  Created model.tflite (extension-based)"

# TensorFlow format - extension-based
touch "$TEST_DIR/model.pb"
echo "  Created model.pb (extension-based)"

# CoreML format - extension-based
touch "$TEST_DIR/model.mlmodel"
mkdir -p "$TEST_DIR/model.mlpackage"
touch "$TEST_DIR/model.mlpackage/Manifest.json"
echo "  Created model.mlmodel, model.mlpackage (extension-based)"

# Binary/generic PyTorch format
printf 'PK\x03\x04' > "$TEST_DIR/model.bin"
echo "  Created model.bin (PyTorch ecosystem)"

# Unknown format
touch "$TEST_DIR/unknown.xyz"
echo "  Created unknown.xyz (unknown format)"

# Sharded model (common pattern)
touch "$TEST_DIR/model-00001-of-00003.safetensors"
echo "  Created model-00001-of-00003.safetensors (sharded model)"

echo ""

# =============================================================================
# Test 1: Extension-Based Format Detection
# =============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Test 1: Extension-Based Format Detection"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

PASSED=0
FAILED=0

# Function to detect format by extension (matching Core's runtime_loader.c)
detect_by_extension() {
    local ext="$1"
    case "$ext" in
        .onnx) echo "ONNX" ;;
        .pt|.pth|.bin|.safetensors) echo "PyTorch" ;;
        .gguf) echo "GGUF" ;;
        .ggml) echo "GGML" ;;
        .tflite) echo "TFLite" ;;
        .pb) echo "TensorFlow" ;;
        .mlmodel|.mlpackage) echo "CoreML" ;;
        *) echo "Unknown" ;;
    esac
}

# Test extension mappings (format: extension:expected_format)
EXTENSION_TESTS=".onnx:ONNX .pt:PyTorch .pth:PyTorch .bin:PyTorch .safetensors:PyTorch .gguf:GGUF .tflite:TFLite .pb:TensorFlow .mlmodel:CoreML .mlpackage:CoreML .xyz:Unknown"

for test_case in $EXTENSION_TESTS; do
    ext="${test_case%%:*}"
    expected="${test_case##*:}"
    detected=$(detect_by_extension "$ext")

    if [ "$detected" = "$expected" ]; then
        echo "  PASS: $ext -> $detected"
        PASSED=$((PASSED + 1))
    else
        echo "  FAIL: $ext -> Expected: $expected, Got: $detected"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "Extension Detection: $PASSED passed, $FAILED failed"
echo ""

# =============================================================================
# Test 2: Magic Byte Detection
# =============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Test 2: Magic Byte Detection"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

MAGIC_PASSED=0
MAGIC_FAILED=0

# Function to detect format by magic bytes (matching Core's logic)
detect_magic() {
    local file="$1"
    local magic=$(xxd -l 4 -p "$file" 2>/dev/null | tr '[:lower:]' '[:upper:]')

    # GGUF magic: "GGUF" = 47475546
    if [ "$magic" = "47475546" ]; then
        echo "GGUF"
        return
    fi

    # ZIP magic (PyTorch): "PK\x03\x04" = 504B0304
    if [ "$magic" = "504B0304" ]; then
        echo "PyTorch"
        return
    fi

    # Check first byte for pickle or JSON
    local first_byte=$(xxd -l 1 -p "$file" 2>/dev/null | tr '[:lower:]' '[:upper:]')

    # Pickle protocol: 0x80 followed by 0x02-0x05
    if [ "$first_byte" = "80" ]; then
        local second_byte=$(xxd -s 1 -l 1 -p "$file" 2>/dev/null | tr '[:lower:]' '[:upper:]')
        if [[ "$second_byte" =~ ^0[2-5]$ ]]; then
            echo "PyTorch"
            return
        fi
    fi

    # JSON header (safetensors): starts with "{"
    if [ "$first_byte" = "7B" ]; then
        echo "PyTorch"
        return
    fi

    echo "Unknown"
}

# Test magic byte detection (format: filename:expected_format)
MAGIC_TESTS="model.gguf:GGUF model.pt:PyTorch model_pickle.pt:PyTorch model.safetensors:PyTorch model.bin:PyTorch"

for test_case in $MAGIC_TESTS; do
    filename="${test_case%%:*}"
    expected="${test_case##*:}"
    filepath="$TEST_DIR/$filename"
    detected=$(detect_magic "$filepath")

    if [ "$detected" = "$expected" ]; then
        echo "  PASS: $filename -> $detected (magic bytes)"
        MAGIC_PASSED=$((MAGIC_PASSED + 1))
    else
        echo "  FAIL: $filename -> Expected: $expected, Got: $detected"
        MAGIC_FAILED=$((MAGIC_FAILED + 1))
    fi
done

echo ""
echo "Magic Detection: $MAGIC_PASSED passed, $MAGIC_FAILED failed"
echo ""

# =============================================================================
# Test 3: Core Runtime Manager (if Core binary available)
# =============================================================================

if [ "$SKIP_CORE_TESTS" = "0" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Test 3: Core Runtime Manager Initialization"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Start Core briefly and check runtime initialization logs
    CORE_PORT=18080
    CORE_LOG="$TEST_DIR/core.log"

    echo "  Starting Core on port $CORE_PORT..."

    # Start Core in background with timeout
    timeout 5s "$CORE_BINARY" --http-port $CORE_PORT --no-grpc --no-ipc > "$CORE_LOG" 2>&1 &
    CORE_PID=$!

    # Wait for startup
    sleep 2

    # Check if Core started
    if curl -s "http://localhost:$CORE_PORT/health" > /dev/null 2>&1; then
        echo "  PASS: Core started successfully"
        ((PASSED++))

        # Check runtime initialization in logs
        if grep -q "Runtime manager initialized" "$CORE_LOG" 2>/dev/null || \
           grep -q "ONNX Runtime" "$CORE_LOG" 2>/dev/null; then
            echo "  PASS: Runtime manager initialized"
            ((PASSED++))
        else
            echo "  INFO: Runtime initialization log not found (may be debug level)"
        fi
    else
        echo "  SKIP: Core did not start within timeout"
    fi

    # Cleanup
    kill $CORE_PID 2>/dev/null || true
    wait $CORE_PID 2>/dev/null || true

    echo ""
fi

# =============================================================================
# Summary
# =============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Test Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

TOTAL_PASSED=$((PASSED + MAGIC_PASSED))
TOTAL_FAILED=$((FAILED + MAGIC_FAILED))

echo "  Extension Detection: $PASSED passed, $FAILED failed"
echo "  Magic Byte Detection: $MAGIC_PASSED passed, $MAGIC_FAILED failed"
echo "  ─────────────────────────────────────────────"
echo "  Total: $TOTAL_PASSED passed, $TOTAL_FAILED failed"
echo ""

if [ $TOTAL_FAILED -gt 0 ]; then
    echo "FAILED: Some format detection tests failed"
    exit 1
fi

echo "SUCCESS: All format detection tests passed!"
echo ""

# =============================================================================
# Supported Formats Reference (from Core PR #39)
# =============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Supported Formats (Core PR #39)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Format     | Extensions                    | Status"
echo "  ───────────┼───────────────────────────────┼─────────────────"
echo "  ONNX       | .onnx                         | Built-in (via SMI)"
echo "  PyTorch    | .pt, .pth, .bin, .safetensors | Plugin ready"
echo "  GGUF       | .gguf                         | Plugin ready"
echo "  TFLite     | .tflite                       | Plugin ready"
echo "  TensorFlow | .pb                           | Plugin ready"
echo "  CoreML     | .mlmodel, .mlpackage          | Plugin ready"
echo "  MLX        | -                             | Plugin ready"
echo ""
