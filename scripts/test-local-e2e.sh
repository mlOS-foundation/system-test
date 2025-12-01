#!/bin/bash
# =============================================================================
# Local E2E Test with Local Axon Build
# =============================================================================
# Tests the full stack using:
# - Local Axon binary from mlOS-foundation/axon
# - Local Docker converter image (axon-converter:local)
# - Core from release
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AXON_DIR="$(cd "$ROOT_DIR/../axon" && pwd)"

# Configuration
CORE_VERSION="${CORE_VERSION:-3.1.6-alpha}"
TEST_MODEL="${TEST_MODEL:-resnet}"  # Default to resnet for vision testing

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 Local E2E Test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Axon: $AXON_DIR/bin/axon"
echo "Docker Image: axon-converter:local"
echo "Core Version: $CORE_VERSION"
echo "Test Model: $TEST_MODEL"
echo ""

# Check prerequisites
if [ ! -f "$AXON_DIR/bin/axon" ]; then
    echo "❌ Axon binary not found at $AXON_DIR/bin/axon"
    echo "   Run: cd $AXON_DIR && make build"
    exit 1
fi

if ! docker image inspect axon-converter:local &>/dev/null; then
    echo "❌ Docker image axon-converter:local not found"
    echo "   Run: cd $AXON_DIR && docker build -t axon-converter:local -f docker/Dockerfile.local ."
    exit 1
fi

# Create test directory
TEST_DIR="$SCRIPT_DIR/local-test-$(date +%s)"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

echo "📁 Test directory: $TEST_DIR"
echo ""

# Copy local Axon binary
cp "$AXON_DIR/bin/axon" ./axon
chmod +x ./axon

# Set environment to use local Docker image
export AXON_CONVERTER_IMAGE="axon-converter:local"
export AXON_HOME="$TEST_DIR/.axon"
export PATH="$TEST_DIR:$PATH"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1️⃣  Testing Axon"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
./axon version || echo "Version check failed"
echo ""

# Download Core
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "2️⃣  Downloading MLOS Core $CORE_VERSION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
    CORE_ARCH="arm64"
else
    CORE_ARCH="amd64"
fi
OS=$(uname -s | tr '[:upper:]' '[:lower:]')

CORE_ASSET="mlos-core_${CORE_VERSION}_${OS}-${CORE_ARCH}.tar.gz"
echo "Downloading: $CORE_ASSET"

# Use gh CLI for private repos
gh release download "v${CORE_VERSION}" --repo mlOS-foundation/core --pattern "$CORE_ASSET" --clobber
tar -xzf "$CORE_ASSET"
rm -f "$CORE_ASSET"
# Find and move the binary (it's in a subfolder)
CORE_BINARY=$(find . -name "mlos_core" -type f | head -1)
if [ -n "$CORE_BINARY" ]; then
    mv "$CORE_BINARY" ./mlos_core
    rm -rf mlos-core-*  # Clean up extracted folder
fi
chmod +x mlos_core
echo "✅ Core downloaded"
echo ""

# Download ONNX Runtime
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "2.5️⃣  Downloading ONNX Runtime"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
mkdir -p onnxruntime

if [[ "$OS" == "darwin" ]]; then
    ONNX_URL="https://github.com/microsoft/onnxruntime/releases/download/v1.18.0/onnxruntime-osx-${CORE_ARCH}-1.18.0.tgz"
else
    ONNX_URL="https://github.com/microsoft/onnxruntime/releases/download/v1.18.0/onnxruntime-linux-${CORE_ARCH}-1.18.0.tgz"
fi

echo "Downloading: $ONNX_URL"
curl -fsSL "$ONNX_URL" -o onnxruntime.tgz
tar -xzf onnxruntime.tgz
mv onnxruntime-*-${CORE_ARCH}-*/* onnxruntime/ 2>/dev/null || true
rmdir onnxruntime-*-${CORE_ARCH}-* 2>/dev/null || true
rm -f onnxruntime.tgz
echo "✅ ONNX Runtime downloaded"
echo ""

# Start Core
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "3️⃣  Starting MLOS Core"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
./mlos_core &
CORE_PID=$!
sleep 3

if ! kill -0 $CORE_PID 2>/dev/null; then
    echo "❌ Core failed to start"
    exit 1
fi
echo "✅ Core started (PID: $CORE_PID)"
echo ""

# Install test model
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "4️⃣  Installing $TEST_MODEL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

case "$TEST_MODEL" in
    resnet)
        MODEL_ID="hf/microsoft/resnet-50@latest"
        ;;
    vit)
        MODEL_ID="hf/google/vit-base-patch16-224@latest"
        ;;
    bert)
        MODEL_ID="hf/bert-base-uncased@latest"
        ;;
    gpt2)
        MODEL_ID="hf/distilgpt2@latest"
        ;;
    *)
        MODEL_ID="$TEST_MODEL"
        ;;
esac

echo "Installing: $MODEL_ID"
echo "Using Docker image: $AXON_CONVERTER_IMAGE"

# Show what Docker image will be used
echo ""
echo "Docker images available:"
docker images | grep axon-converter | head -5
echo ""

# Install with verbose output
time ./axon install "$MODEL_ID" 2>&1 | tee install.log

echo ""
echo "✅ Installation complete"
echo ""

# Check Axon list
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "5️⃣  Verifying Installation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
./axon list
echo ""

# Check for ONNX file
ONNX_PATH=$(find "$AXON_HOME" -name "*.onnx" 2>/dev/null | head -1)
if [ -n "$ONNX_PATH" ]; then
    echo "✅ ONNX file found: $ONNX_PATH"
    ls -lh "$ONNX_PATH"
else
    echo "⚠️  No ONNX file found in $AXON_HOME"
fi
echo ""

# Test inference if model is registered
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "6️⃣  Testing Inference"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Register with Core
PATHWAY_NAME="test-${TEST_MODEL}"
echo "Registering pathway: $PATHWAY_NAME"

# Get model path from Axon
MODEL_PATH=$(./axon path "$MODEL_ID" 2>/dev/null | grep -o '/.*' | head -1)
if [ -n "$MODEL_PATH" ] && [ -n "$ONNX_PATH" ]; then
    # Register
    REGISTER_RESPONSE=$(curl -s -X POST http://localhost:8080/register \
        -H "Content-Type: application/json" \
        -d "{\"pathway_name\": \"$PATHWAY_NAME\", \"model_path\": \"$ONNX_PATH\"}")
    echo "Register response: $REGISTER_RESPONSE"
    
    # Test inference based on model type
    case "$TEST_MODEL" in
        resnet|vit)
            # Vision model - create small image tensor
            echo "Testing vision inference with 32x32 image..."
            # 32x32x3 = 3072 floats
            INPUT_DATA=$(python3 -c "import json; print(json.dumps([0.5] * 3072))")
            ;;
        *)
            # NLP model - create token input
            echo "Testing NLP inference with 7 tokens..."
            INPUT_DATA="[101, 2054, 2003, 1996, 3462, 102, 0]"
            ;;
    esac
    
    echo "Running inference..."
    INFER_RESPONSE=$(curl -s -X POST "http://localhost:8080/infer/$PATHWAY_NAME" \
        -H "Content-Type: application/json" \
        -d "{\"inputs\": $INPUT_DATA}" \
        --max-time 60)
    
    if echo "$INFER_RESPONSE" | grep -q "outputs"; then
        echo "✅ Inference SUCCESS!"
        echo "Response preview: $(echo "$INFER_RESPONSE" | head -c 200)..."
    else
        echo "❌ Inference failed"
        echo "Response: $INFER_RESPONSE"
    fi
else
    echo "⚠️  Could not determine model/ONNX path for inference test"
fi

echo ""

# Cleanup
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "7️⃣  Cleanup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
kill $CORE_PID 2>/dev/null || true
echo "✅ Core stopped"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Test Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Test directory: $TEST_DIR"
echo "Install log: $TEST_DIR/install.log"
echo ""
echo "To clean up: rm -rf $TEST_DIR"

