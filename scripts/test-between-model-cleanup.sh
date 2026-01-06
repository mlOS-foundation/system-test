#!/bin/bash
#
# Test script to validate between-model cleanup logic
# This simulates what happens in the e2e-unified.yml workflow
#
# Usage: ./test-between-model-cleanup.sh
#

set -e

echo "========================================"
echo "Testing Between-Model Cleanup Logic"
echo "========================================"

# Simulate the model list
MODELS="bert gpt2 resnet vit"
MODEL_COUNT=0
TOTAL_MODELS=$(echo "$MODELS" | wc -w)

echo "Simulating tests for $TOTAL_MODELS models: $MODELS"
echo ""

# Create some temp files to simulate inference artifacts
mkdir -p /tmp/inference_test_bert /tmp/warmup_test_gpt2 2>/dev/null || true
echo "test data" > /tmp/inference_test_bert/data.json 2>/dev/null || true
echo "warmup data" > /tmp/warmup_test_gpt2/data.json 2>/dev/null || true

echo "Initial temp files:"
ls -la /tmp/inference_* /tmp/warmup_* 2>/dev/null || echo "  (no files)"
echo ""

for model in $MODELS; do
    [ -z "$model" ] && continue
    MODEL_COUNT=$((MODEL_COUNT + 1))

    echo "========================================"
    echo "Testing: $model [$MODEL_COUNT/$TOTAL_MODELS]"
    echo "========================================"

    # Log memory state BEFORE test
    echo "Memory before $model:"
    free -m | head -2

    # Simulate model test
    echo "  [Simulating model test for $model...]"
    sleep 0.5

    # ================================================================
    # BETWEEN-MODEL CLEANUP: Isolate each model's performance
    # ================================================================
    echo "--- Cleanup between models ---"

    # 1. Clean temp inference files
    rm -rf /tmp/inference_* /tmp/warmup_* 2>/dev/null || true
    echo "  ✅ Cleaned temp files"

    # 2. Sync filesystem
    sync
    echo "  ✅ Synced filesystem"

    # 3. Drop kernel page cache (requires sudo, may fail in some environments)
    if echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1; then
        echo "  ✅ Dropped kernel caches"
    else
        echo "  ⚠️  Could not drop kernel caches (requires sudo)"
    fi

    # 4. Brief stabilization delay
    sleep 0.2

    echo "Memory after cleanup:"
    free -m | head -2

    # Verify temp files are gone
    if ls /tmp/inference_* /tmp/warmup_* 2>/dev/null; then
        echo "  ❌ ERROR: Temp files still exist!"
        exit 1
    else
        echo "  ✅ Temp files cleaned successfully"
    fi

    echo "----------------------------------------"
done

echo ""
echo "========================================"
echo "✅ Between-model cleanup test PASSED"
echo "========================================"
echo ""
echo "Summary:"
echo "  - Temp file cleanup: Working"
echo "  - Filesystem sync: Working"
echo "  - Memory cache drop: $(if echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1; then echo 'Working'; else echo 'Requires sudo'; fi)"
echo ""
