#!/bin/bash
# Test E2E with Linux Core running in Docker (on Mac)
# This reproduces CI environment locally

set -e

echo "🐧 Testing with Linux Core in Docker"
echo ""
echo "This runs:"
echo "  - Axon: Native Mac (ONNX conversion works)"
echo "  - Core: Linux amd64 in Docker (reproduces CI)"
echo "  - Tests: From Mac host"
echo ""

# Set environment variable to force Linux Core download
export FORCE_CORE_PLATFORM="linux/amd64"
export CORE_IN_DOCKER="true"

# Run the E2E test
./bin/e2e-test -minimal -core-version 3.0.0-alpha

echo ""
echo "✅ Test completed"

