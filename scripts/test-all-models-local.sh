#!/bin/bash

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# MLOS Full Model Test Suite - Local Build
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# Runs ALL enabled models from config/models.yaml using a locally built Core.
# This script:
# 1. Starts the local Core binary
# 2. Runs test-single-model.sh for each enabled model
# 3. Aggregates results and generates a report
#
# Usage: ./test-all-models-local.sh [--core-path <path>] [--skip-llm]
#
# Environment variables:
#   CORE_PATH       - Path to MLOS Core binary (default: ~/src/mlOS-foundation/core/build/mlos_core)
#   SKIP_LLM        - Set to 1 to skip LLM/GGUF models (faster testing)
#   CORE_PORT       - Port for Core server (default: 8080)
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$ROOT_DIR/config/models.yaml"

# Default configuration
CORE_PATH="${CORE_PATH:-$HOME/src/mlOS-foundation/core/build/mlos_core}"
CORE_PORT="${CORE_PORT:-8080}"
CORE_URL="http://127.0.0.1:$CORE_PORT"
SKIP_LLM="${SKIP_LLM:-0}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/model-results}"
REPORT_DIR="$ROOT_DIR/report-data"
CORE_PID=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --core-path)
            CORE_PATH="$2"
            shift 2
            ;;
        --skip-llm)
            SKIP_LLM=1
            shift
            ;;
        --port)
            CORE_PORT="$2"
            CORE_URL="http://127.0.0.1:$CORE_PORT"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    if [ -n "$CORE_PID" ]; then
        kill $CORE_PID 2>/dev/null || true
        wait $CORE_PID 2>/dev/null || true
    fi
    pkill -f mlos_core 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# Check prerequisites
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}🧪 MLOS Full Model Test Suite - Local Build${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check Core binary
if [ ! -f "$CORE_PATH" ]; then
    echo -e "${RED}❌ Core binary not found at: $CORE_PATH${NC}"
    echo "   Build Core first: cd ~/src/mlOS-foundation/core && make"
    exit 1
fi
echo -e "${GREEN}✅ Core binary: $CORE_PATH${NC}"

# Check config file
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}❌ Config file not found: $CONFIG_FILE${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Config file: $CONFIG_FILE${NC}"

# Get list of enabled models
MODELS=$(python3 -c "
import yaml
with open('$CONFIG_FILE') as f:
    config = yaml.safe_load(f)
models = []
for name, model in config.get('models', {}).items():
    if model.get('enabled', False):
        category = model.get('category', 'nlp')
        models.append(f'{name}:{category}')
print(' '.join(models))
" 2>/dev/null)

if [ -z "$MODELS" ]; then
    echo -e "${RED}❌ No enabled models found in config${NC}"
    exit 1
fi

# Count models
TOTAL_MODELS=0
NLP_COUNT=0
VISION_COUNT=0
MULTIMODAL_COUNT=0
LLM_COUNT=0

for model_info in $MODELS; do
    name="${model_info%%:*}"
    category="${model_info##*:}"
    case "$category" in
        nlp) NLP_COUNT=$((NLP_COUNT + 1)) ;;
        vision) VISION_COUNT=$((VISION_COUNT + 1)) ;;
        multimodal) MULTIMODAL_COUNT=$((MULTIMODAL_COUNT + 1)) ;;
        llm) LLM_COUNT=$((LLM_COUNT + 1)) ;;
    esac
    TOTAL_MODELS=$((TOTAL_MODELS + 1))
done

echo ""
echo "📊 Enabled models: $TOTAL_MODELS total"
echo "   NLP:        $NLP_COUNT"
echo "   Vision:     $VISION_COUNT"
echo "   Multimodal: $MULTIMODAL_COUNT"
echo "   LLM/GGUF:   $LLM_COUNT"

if [ "$SKIP_LLM" = "1" ]; then
    echo -e "   ${YELLOW}(Skipping LLM models)${NC}"
    TOTAL_MODELS=$((TOTAL_MODELS - LLM_COUNT))
fi

echo ""

# Create output directories
mkdir -p "$OUTPUT_DIR"
mkdir -p "$REPORT_DIR"

# Kill any existing Core processes
pkill -f mlos_core 2>/dev/null || true
sleep 1

# Start Core
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Starting MLOS Core..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

"$CORE_PATH" &
CORE_PID=$!
sleep 3

# Check Core is running
if ! curl -s "$CORE_URL/health" >/dev/null 2>&1; then
    echo -e "${RED}❌ Core failed to start${NC}"
    exit 1
fi

CORE_VERSION=$(curl -s "$CORE_URL/health" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data.get('version', 'unknown'))" 2>/dev/null || echo "unknown")
echo -e "${GREEN}✅ Core started (PID: $CORE_PID, Version: $CORE_VERSION)${NC}"
echo ""

# Run tests for each model
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 Running model tests..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

TEST_COUNT=0
PASSED_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0

START_TIME=$(date +%s)

for model_info in $MODELS; do
    name="${model_info%%:*}"
    category="${model_info##*:}"

    # Skip LLM models if requested
    if [ "$SKIP_LLM" = "1" ] && [ "$category" = "llm" ]; then
        echo -e "${YELLOW}⏭️  Skipping LLM model: $name${NC}"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi

    TEST_COUNT=$((TEST_COUNT + 1))
    echo -e "${BLUE}[$TEST_COUNT/$TOTAL_MODELS]${NC} Testing: $name ($category)"

    # Run the single model test
    if CORE_URL="$CORE_URL" "$SCRIPT_DIR/test-single-model.sh" "$name" --output-dir "$OUTPUT_DIR" >/dev/null 2>&1; then
        # Check the result file
        RESULT_FILE="$OUTPUT_DIR/${name}-result.json"
        if [ -f "$RESULT_FILE" ]; then
            STATUS=$(python3 -c "import json; data=json.load(open('$RESULT_FILE')); print(data.get('status', 'unknown'))" 2>/dev/null)
            if [ "$STATUS" = "success" ] || [ "$STATUS" = "partial" ]; then
                echo -e "   ${GREEN}✅ $name: $STATUS${NC}"
                PASSED_COUNT=$((PASSED_COUNT + 1))
            else
                echo -e "   ${RED}❌ $name: $STATUS${NC}"
                FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
        else
            echo -e "   ${YELLOW}⚠️  $name: No result file${NC}"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    else
        echo -e "   ${RED}❌ $name: Test script failed${NC}"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
done

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Test Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "Total models tested: $TEST_COUNT"
echo -e "${GREEN}Passed: $PASSED_COUNT${NC}"
echo -e "${RED}Failed: $FAILED_COUNT${NC}"
if [ "$SKIPPED_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}Skipped: $SKIPPED_COUNT${NC}"
fi
echo ""
echo "Total time: ${TOTAL_TIME}s"
echo ""

# Generate aggregated metrics file for report generation
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📝 Generating report data..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Aggregate results
AGGREGATE_SCRIPT="$SCRIPT_DIR/aggregate-results.py"
if [ -f "$AGGREGATE_SCRIPT" ]; then
    python3 "$AGGREGATE_SCRIPT" "$OUTPUT_DIR" --output "$REPORT_DIR/metrics.json" 2>/dev/null || true
    echo -e "${GREEN}✅ Metrics aggregated to: $REPORT_DIR/metrics.json${NC}"
fi

# Generate HTML report
RENDER_SCRIPT="$ROOT_DIR/report/render.py"
if [ -f "$RENDER_SCRIPT" ]; then
    python3 "$RENDER_SCRIPT" \
        --metrics "$REPORT_DIR/metrics.json" \
        --output "$REPORT_DIR" \
        --config "$CONFIG_FILE" \
        --golden-data "$ROOT_DIR/config/golden-test-data.yaml" \
        --response-dir "$OUTPUT_DIR" \
        2>/dev/null || echo -e "${YELLOW}⚠️  Report generation had issues${NC}"

    if [ -f "$REPORT_DIR/index.html" ]; then
        echo -e "${GREEN}✅ HTML report: $REPORT_DIR/index.html${NC}"
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📁 Output files:"
echo "   Results: $OUTPUT_DIR/"
echo "   Report:  $REPORT_DIR/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Exit with failure if any tests failed
if [ "$FAILED_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
