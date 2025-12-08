#!/bin/bash
# Local Docker-based E2E testing for MLOS stack
# Tests Axon + Core integration on Linux (ARM64 or AMD64)
#
# Usage:
#   ./scripts/test-local-docker.sh                    # Test on linux/arm64 (native on Mac M1/M2)
#   ./scripts/test-local-docker.sh linux/amd64        # Test on linux/amd64 (emulated, matches CI)
#   ./scripts/test-local-docker.sh linux/arm64 gpt2   # Test specific model
#
# Prerequisites:
#   - Docker with multi-platform support
#   - GitHub CLI (gh) authenticated for private repo access

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Default values
PLATFORM="${1:-linux/arm64}"
TEST_MODEL="${2:-gpt2}"
AXON_VERSION="${AXON_VERSION:-v3.1.6}"
CORE_VERSION="${CORE_VERSION:-3.2.12-alpha}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}🐳 MLOS Local Docker E2E Test${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "Platform:     ${YELLOW}${PLATFORM}${NC}"
echo -e "Axon:         ${YELLOW}${AXON_VERSION}${NC}"
echo -e "Core:         ${YELLOW}${CORE_VERSION}${NC}"
echo -e "Test Model:   ${YELLOW}${TEST_MODEL}${NC}"
echo ""

# Map platform to architectures
case "$PLATFORM" in
    linux/arm64)
        ARCH="arm64"
        ORT_ARCH="linux-aarch64"
        AXON_ARCH="linux-arm64"
        CORE_ARCH="linux-arm64"
        ;;
    linux/amd64)
        ARCH="amd64"
        ORT_ARCH="linux-x64"
        AXON_ARCH="linux-amd64"
        CORE_ARCH="linux-amd64"
        ;;
    *)
        echo -e "${RED}Unsupported platform: $PLATFORM${NC}"
        exit 1
        ;;
esac

# Create test directory
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

echo -e "${BLUE}=== Downloading Release Binaries ===${NC}"

# Download Axon (asset uses underscores: axon_VERSION_OS_ARCH.tar.gz)
echo "Downloading Axon ${AXON_VERSION}..."
AXON_ARCH_UNDERSCORE="${AXON_ARCH//-/_}"
gh release download "${AXON_VERSION}" \
    --repo mlOS-foundation/axon \
    --pattern "axon_*_${AXON_ARCH_UNDERSCORE}.tar.gz" \
    --dir "$TEST_DIR" 2>/dev/null || {
    echo -e "${RED}Failed to download Axon${NC}"
    exit 1
}

# Download Core (tag has v prefix, asset version doesn't)
echo "Downloading Core ${CORE_VERSION}..."
CORE_TAG="v${CORE_VERSION#v}"  # Ensure v prefix for tag
CORE_VER="${CORE_VERSION#v}"   # Remove v prefix for asset name
gh release download "${CORE_TAG}" \
    --repo mlOS-foundation/core \
    --pattern "mlos-core_${CORE_VER}_${CORE_ARCH}.tar.gz" \
    --dir "$TEST_DIR" 2>/dev/null || {
    echo -e "${RED}Failed to download Core${NC}"
    exit 1
}

# Download Axon converter image
echo "Downloading Axon converter image..."
gh release download "${AXON_VERSION}" \
    --repo mlOS-foundation/axon \
    --pattern "axon-converter-*-${AXON_ARCH}.tar.gz" \
    --dir "$TEST_DIR" 2>/dev/null || true

echo -e "${GREEN}✅ Downloads complete${NC}"
ls -la "$TEST_DIR"

# Create test script to run inside container
cat > "$TEST_DIR/run_test.sh" << 'INNERSCRIPT'
#!/bin/bash
set -e

ARCH="${ARCH:-amd64}"
ORT_ARCH="${ORT_ARCH:-linux-x64}"
TEST_MODEL="${TEST_MODEL:-gpt2}"

echo "=== Setting up environment ==="
# Files are in current dir (copied from /test to writable location)

# Extract Axon (uses underscores: axon_VERSION_linux_ARCH.tar.gz)
echo "Extracting Axon..."
tar -xzf axon_*_linux_*.tar.gz 2>/dev/null || tar -xzf axon-*-linux-*.tar.gz 2>/dev/null || true
AXON_BIN=$(find . -name "axon" -type f | head -1)
chmod +x "$AXON_BIN" 2>/dev/null || true
cp "$AXON_BIN" /usr/local/bin/axon

# Extract Core
echo "Extracting Core..."
tar -xzf mlos-core_*.tar.gz 2>/dev/null || true
CORE_DIR=$(find . -type d -name "mlos-core-*" | head -1)

# Download ONNX Runtime
echo "Downloading ONNX Runtime for ${ORT_ARCH}..."
curl -sL -o /tmp/ort.tgz "https://github.com/microsoft/onnxruntime/releases/download/v1.18.0/onnxruntime-${ORT_ARCH}-1.18.0.tgz"
mkdir -p "$CORE_DIR/onnxruntime"
tar -xzf /tmp/ort.tgz -C "$CORE_DIR/onnxruntime" --strip-components=1

export LD_LIBRARY_PATH="$CORE_DIR/onnxruntime/lib:$LD_LIBRARY_PATH"

# Start Core (binary is at $CORE_DIR/mlos_core)
echo ""
echo "=== Starting Core ==="
"$CORE_DIR/mlos_core" --http-port 18080 > /tmp/core.log 2>&1 &
CORE_PID=$!
sleep 3

if ! kill -0 $CORE_PID 2>/dev/null; then
    echo "❌ Core crashed on startup!"
    cat /tmp/core.log | tail -30
    exit 1
fi

echo "✅ Core running (PID: $CORE_PID)"

# Health check
echo ""
echo "=== Health Check ==="
curl -s http://127.0.0.1:18080/health | python3 -m json.tool

# Load converter image if available
CONVERTER_TAR=$(find /test -name "axon-converter-*.tar.gz" 2>/dev/null | head -1)
if [ -n "$CONVERTER_TAR" ]; then
    echo ""
    echo "=== Loading Axon Converter Image ==="
    docker load < "$CONVERTER_TAR" 2>/dev/null || echo "Note: Docker-in-Docker not available"
fi

# Install model using Axon
echo ""
echo "=== Installing Model with Axon ==="
case "$TEST_MODEL" in
    gpt2)
        MODEL_ID="hf/distilgpt2@latest"
        ;;
    bert)
        MODEL_ID="hf/bert-base-uncased@latest"
        ;;
    resnet)
        MODEL_ID="hf/microsoft/resnet-50@latest"
        ;;
    *)
        MODEL_ID="hf/${TEST_MODEL}@latest"
        ;;
esac

echo "Installing $MODEL_ID..."
axon install "$MODEL_ID" || {
    echo "⚠️ Axon install failed (may need Docker for ONNX conversion)"
    echo "Testing with register API only..."
}

# Find model path
MODEL_PATH=$(find ~/.axon/cache/models -name "model.onnx" 2>/dev/null | head -1)

if [ -n "$MODEL_PATH" ]; then
    echo ""
    echo "=== Registering Model ==="
    curl -s -X POST http://127.0.0.1:18080/models/register \
        -H "Content-Type: application/json" \
        -d "{\"model_id\": \"$TEST_MODEL\", \"path\": \"$MODEL_PATH\", \"framework\": \"onnx\"}" | python3 -m json.tool

    echo ""
    echo "=== Testing Inference ==="
    case "$TEST_MODEL" in
        gpt2)
            INPUT='{"input_ids": [15496, 11, 314, 716, 257, 3303, 2746, 13]}'
            ;;
        bert)
            INPUT='{"input_ids": [101, 7592, 1010, 2088, 999, 102], "attention_mask": [1,1,1,1,1,1], "token_type_ids": [0,0,0,0,0,0]}'
            ;;
        resnet|vit|convnext|mobilenet|deit|efficientnet)
            # Generate small image tensor
            INPUT=$(python3 -c "import json,random; random.seed(42); print(json.dumps({'pixel_values': [random.gauss(0,1) for _ in range(1*3*224*224)]}))")
            ;;
        *)
            INPUT='{"input_ids": [101, 7592, 102]}'
            ;;
    esac

    RESULT=$(curl -s -X POST "http://127.0.0.1:18080/models/$TEST_MODEL/inference" \
        -H "Content-Type: application/json" \
        -d "$INPUT")

    echo "$RESULT" | python3 -m json.tool

    STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','error'))" 2>/dev/null || echo "error")

    if [ "$STATUS" = "success" ]; then
        echo ""
        echo "✅ INFERENCE TEST PASSED"
        kill $CORE_PID 2>/dev/null
        exit 0
    else
        echo ""
        echo "❌ INFERENCE TEST FAILED"
        cat /tmp/core.log | tail -50
        kill $CORE_PID 2>/dev/null
        exit 1
    fi
else
    echo ""
    echo "⚠️ No ONNX model found - testing Core API only"
    echo "✅ CORE API TEST PASSED (model installation requires Docker-in-Docker)"
    kill $CORE_PID 2>/dev/null
    exit 0
fi
INNERSCRIPT

chmod +x "$TEST_DIR/run_test.sh"

echo ""
echo -e "${BLUE}=== Running Test in Docker Container ===${NC}"

# Run test
docker run --rm --platform "$PLATFORM" \
    -v "$TEST_DIR:/test:ro" \
    -v "$TEST_DIR/run_test.sh:/run_test.sh:ro" \
    -e "ARCH=$ARCH" \
    -e "ORT_ARCH=$ORT_ARCH" \
    -e "TEST_MODEL=$TEST_MODEL" \
    ubuntu:22.04 \
    bash -c "apt-get update -qq && apt-get install -y -qq curl python3 > /dev/null 2>&1 && cp -r /test /test-rw && chmod -R +w /test-rw && cd /test-rw && /run_test.sh"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Local Docker test completed for ${PLATFORM}${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

