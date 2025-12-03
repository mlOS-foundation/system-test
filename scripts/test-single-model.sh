#!/bin/bash

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# MLOS Single Model Test Pipeline
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 
# Tests a single model end-to-end: install → register → inference
# Designed to run in parallel with other model tests
#
# Usage: ./test-single-model.sh <model_name> [--output-dir <dir>]
#
# Environment variables:
#   AXON_VERSION    - Axon version (default: v3.1.1)
#   CORE_VERSION    - Core version (default: 3.2.0-alpha)
#   CORE_URL        - URL to MLOS Core server (default: http://127.0.0.1:18080)
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
CONFIG_DIR="$(dirname "$SCRIPT_DIR")/config"
CONFIG_FILE="$CONFIG_DIR/models.yaml"

# Default configuration
AXON_VERSION="${AXON_VERSION:-v3.1.1}"
CORE_VERSION="${CORE_VERSION:-3.2.0-alpha}"
CORE_URL="${CORE_URL:-http://127.0.0.1:18080}"
OUTPUT_DIR="${OUTPUT_DIR:-./model-results}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-900}"  # 15 minutes
INFERENCE_TIMEOUT="${INFERENCE_TIMEOUT:-120}"

# Parse arguments
MODEL_NAME=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --core-url)
            CORE_URL="$2"
            shift 2
            ;;
        --axon-version)
            AXON_VERSION="$2"
            shift 2
            ;;
        --install-timeout)
            INSTALL_TIMEOUT="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            MODEL_NAME="$1"
            shift
            ;;
    esac
done

if [ -z "$MODEL_NAME" ]; then
    echo "Usage: $0 <model_name> [--output-dir <dir>] [--core-url <url>]"
    echo ""
    echo "Available models (from config/models.yaml):"
    if [ -f "$CONFIG_FILE" ]; then
        python3 -c "
import yaml
with open('$CONFIG_FILE') as f:
    config = yaml.safe_load(f)
for name, model in config.get('models', {}).items():
    status = '✅' if model.get('enabled', False) else '❌'
    print(f'  {status} {name}: {model.get(\"axon_id\", \"N/A\")}')
" 2>/dev/null || echo "  (Install pyyaml to see models)"
    fi
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/${MODEL_NAME}-result.json"
LOG_FILE="$OUTPUT_DIR/${MODEL_NAME}.log"

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} [$MODEL_NAME] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[$(date +'%H:%M:%S')] ERROR:${NC} [$MODEL_NAME] $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARN:${NC} [$MODEL_NAME] $1" | tee -a "$LOG_FILE"
}

# Timestamp functions (milliseconds)
get_timestamp_ms() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import time; print(int(time.time() * 1000))"
    elif command -v gdate >/dev/null 2>&1; then
        echo $(($(gdate +%s%N)/1000000))
    else
        echo $(($(date +%s)*1000))
    fi
}

measure_time() {
    local start=$1
    local end=$2
    echo $((end - start))
}

# Cross-platform timeout function
run_with_timeout() {
    local timeout_seconds=$1
    shift
    local cmd="$@"
    
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_seconds" $cmd
        return $?
    fi
    
    # macOS: Use perl
    if command -v perl >/dev/null 2>&1; then
        perl -e '
            my $timeout = shift;
            my $pid = fork();
            if ($pid == 0) {
                exec @ARGV;
            } else {
                eval {
                    local $SIG{ALRM} = sub { die "timeout" };
                    alarm $timeout;
                    waitpid($pid, 0);
                    alarm 0;
                    exit $? >> 8;
                };
                if ($@ =~ /timeout/) {
                    kill 9, $pid;
                    waitpid($pid, 0);
                    exit 124;
                }
            }
        ' "$timeout_seconds" $cmd
        return $?
    fi
    
    # Fallback: run without timeout
    log_warn "No timeout command available, running without timeout"
    $cmd
    return $?
}

# URL encode function
url_encode() {
    local string="$1"
    local encoded=""
    local i=0
    while [ $i -lt ${#string} ]; do
        local c="${string:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) encoded+="$c" ;;
            *) encoded+=$(printf '%%%02X' "'$c") ;;
        esac
        i=$((i + 1))
    done
    echo "$encoded"
}

# Get model configuration from YAML
get_model_config() {
    local model_name="$1"
    python3 -c "
import yaml
import json
import sys

with open('$CONFIG_FILE') as f:
    config = yaml.safe_load(f)

model = config.get('models', {}).get('$model_name')
if not model:
    print(json.dumps({'error': 'Model not found'}))
    sys.exit(1)

# Return model config as JSON
print(json.dumps({
    'axon_id': model.get('axon_id', ''),
    'category': model.get('category', 'nlp'),
    'input_type': model.get('input_type', 'text'),
    'enabled': model.get('enabled', False),
    'description': model.get('description', ''),
    'small_input': model.get('small_input', {}),
    'large_input': model.get('large_input', {})
}))
" 2>/dev/null
}

# Generate test input based on model type
generate_test_input() {
    local model_name="$1"
    local input_type="$2"
    local category="$3"
    local size="$4"  # small or large
    
    python3 -c "
import yaml
import json
import random

with open('$CONFIG_FILE') as f:
    config = yaml.safe_load(f)

model = config.get('models', {}).get('$model_name', {})
category = model.get('category', '$category')
input_config = model.get('${size}_input', {})

if category == 'vision':
    # Generate image tensor [batch, channels, height, width]
    width = input_config.get('width', 64 if '$size' == 'small' else 224)
    height = input_config.get('height', 64 if '$size' == 'small' else 224)
    channels = input_config.get('channels', 3)
    
    # Random normalized pixel values
    tensor = [[[[random.random() for _ in range(width)] 
                for _ in range(height)] 
               for _ in range(channels)]]
    
    print(json.dumps({'pixel_values': tensor}))
else:
    # NLP: Generate token sequence
    tokens = input_config.get('tokens', 7 if '$size' == 'small' else 128)
    sequence = input_config.get('sequence', [101] + [random.randint(1000, 30000) for _ in range(tokens-2)] + [102])
    
    # BERT-style input
    print(json.dumps({
        'input_ids': [sequence],
        'attention_mask': [[1] * len(sequence)]
    }))
" 2>/dev/null
}

# Initialize result structure
init_result() {
    cat > "$RESULT_FILE" << EOF
{
    "model_name": "$MODEL_NAME",
    "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "axon_version": "$AXON_VERSION",
    "core_version": "$CORE_VERSION",
    "status": "running",
    "phases": {
        "install": {"status": "pending"},
        "register": {"status": "pending"},
        "inference_small": {"status": "pending"},
        "inference_large": {"status": "pending"}
    }
}
EOF
}

# Update result JSON
update_result() {
    local phase="$1"
    local status="$2"
    local time_ms="${3:-0}"
    local error="${4:-}"
    
    python3 -c "
import json

with open('$RESULT_FILE', 'r') as f:
    result = json.load(f)

result['phases']['$phase'] = {
    'status': '$status',
    'time_ms': $time_ms
}
if '$error':
    result['phases']['$phase']['error'] = '$error'

with open('$RESULT_FILE', 'w') as f:
    json.dump(result, f, indent=2)
" 2>/dev/null || echo "Warning: Could not update result file"
}

# Finalize result
finalize_result() {
    local overall_status="$1"
    
    python3 -c "
import json

with open('$RESULT_FILE', 'r') as f:
    result = json.load(f)

result['status'] = '$overall_status'
result['completed_at'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'

# Calculate totals
total_time = sum(p.get('time_ms', 0) for p in result['phases'].values())
result['total_time_ms'] = total_time

with open('$RESULT_FILE', 'w') as f:
    json.dump(result, f, indent=2)
" 2>/dev/null || echo "Warning: Could not finalize result file"
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PHASE 1: Install Model
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
install_model() {
    log "📥 Phase 1: Installing model..."
    
    # Get model config
    local config=$(get_model_config "$MODEL_NAME")
    if echo "$config" | grep -q '"error"'; then
        log_error "Model '$MODEL_NAME' not found in config"
        update_result "install" "failed" 0 "Model not found in config"
        return 1
    fi
    
    AXON_ID=$(echo "$config" | python3 -c "import json,sys; print(json.load(sys.stdin)['axon_id'])")
    CATEGORY=$(echo "$config" | python3 -c "import json,sys; print(json.load(sys.stdin)['category'])")
    INPUT_TYPE=$(echo "$config" | python3 -c "import json,sys; print(json.load(sys.stdin)['input_type'])")
    
    log "  Axon ID: $AXON_ID"
    log "  Category: $CATEGORY"
    
    # Check if already installed
    local model_path="$HOME/.axon/cache/models/${AXON_ID%@*}/${AXON_ID##*@}/model.onnx"
    if [ -f "$model_path" ]; then
        log "✅ Model already installed at: $model_path"
        update_result "install" "success" 0
        return 0
    fi
    
    # Ensure Axon is available
    if ! command -v axon >/dev/null 2>&1 && [ ! -f "$HOME/.local/bin/axon" ]; then
        log_error "Axon not found. Please install Axon first."
        update_result "install" "failed" 0 "Axon not found"
        return 1
    fi
    
    local axon_cmd="${HOME}/.local/bin/axon"
    if [ ! -f "$axon_cmd" ]; then
        axon_cmd="axon"
    fi
    
    # Check Docker for ONNX conversion
    if ! docker ps >/dev/null 2>&1; then
        log_warn "Docker not running - ONNX conversion may fail"
    fi
    
    local start_time=$(get_timestamp_ms)
    
    # Run installation with timeout
    log "  Running: $axon_cmd install $AXON_ID"
    if run_with_timeout "$INSTALL_TIMEOUT" "$axon_cmd" install "$AXON_ID" >> "$LOG_FILE" 2>&1; then
        local end_time=$(get_timestamp_ms)
        local install_time=$(measure_time $start_time $end_time)
        
        # Verify installation
        if [ -f "$model_path" ]; then
            log "✅ Model installed successfully (${install_time}ms)"
            update_result "install" "success" "$install_time"
            return 0
        else
            # Search for model
            local found_model=$(find "$HOME/.axon/cache/models" -name "model.onnx" -path "*${AXON_ID%%/*}*" 2>/dev/null | head -1)
            if [ -n "$found_model" ]; then
                log "✅ Model found at: $found_model (${install_time}ms)"
                model_path="$found_model"
                update_result "install" "success" "$install_time"
                return 0
            fi
            log_error "Model file not found after installation"
            update_result "install" "failed" "$install_time" "Model file not found"
            return 1
        fi
    else
        local exit_code=$?
        local end_time=$(get_timestamp_ms)
        local install_time=$(measure_time $start_time $end_time)
        
        if [ $exit_code -eq 124 ]; then
            log_error "Installation timed out after ${INSTALL_TIMEOUT}s"
            update_result "install" "failed" "$install_time" "Timeout"
        else
            log_error "Installation failed (exit code: $exit_code)"
            update_result "install" "failed" "$install_time" "Exit code: $exit_code"
        fi
        return 1
    fi
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PHASE 2: Register Model with Core
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
register_model() {
    log "📝 Phase 2: Registering model with Core..."
    
    # Check Core is running
    if ! curl -s "$CORE_URL/health" >/dev/null 2>&1; then
        log_error "MLOS Core not running at $CORE_URL"
        update_result "register" "failed" 0 "Core not running"
        return 1
    fi
    
    # Find model path
    local model_path="$HOME/.axon/cache/models/${AXON_ID%@*}/${AXON_ID##*@}/model.onnx"
    if [ ! -f "$model_path" ]; then
        model_path=$(find "$HOME/.axon/cache/models" -name "model.onnx" -path "*${AXON_ID%%/*}*" 2>/dev/null | head -1)
    fi
    
    if [ ! -f "$model_path" ]; then
        log_error "Cannot find model to register"
        update_result "register" "failed" 0 "Model file not found"
        return 1
    fi
    
    log "  Model path: $model_path"
    
    local start_time=$(get_timestamp_ms)
    
    # Register with Core
    local register_payload=$(cat <<EOF
{
    "model_id": "$AXON_ID",
    "model_path": "$model_path",
    "runtime": "onnx"
}
EOF
)
    
    local response=$(curl -s -w "\n%{http_code}" -X POST "$CORE_URL/models" \
        -H "Content-Type: application/json" \
        -d "$register_payload" 2>&1)
    
    local http_code=$(echo "$response" | tail -n 1)
    local body=$(echo "$response" | sed '$d')
    
    local end_time=$(get_timestamp_ms)
    local register_time=$(measure_time $start_time $end_time)
    
    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || echo "$body" | grep -qi "already registered"; then
        log "✅ Model registered (${register_time}ms)"
        update_result "register" "success" "$register_time"
        return 0
    else
        log_error "Registration failed (HTTP $http_code): $body"
        update_result "register" "failed" "$register_time" "HTTP $http_code"
        return 1
    fi
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PHASE 3: Run Inference Tests
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
run_inference() {
    local size="$1"  # small or large
    log "🧪 Phase 3: Running $size inference test..."
    
    local encoded_model_id=$(url_encode "$AXON_ID")
    
    # Generate test input
    local test_input=$(generate_test_input "$MODEL_NAME" "$INPUT_TYPE" "$CATEGORY" "$size")
    
    if [ -z "$test_input" ] || [ "$test_input" = "null" ]; then
        log_error "Failed to generate test input"
        update_result "inference_$size" "failed" 0 "Failed to generate input"
        return 1
    fi
    
    # Write input to temp file (for large inputs)
    local tmp_input="/tmp/inference_${MODEL_NAME}_${size}_$$.json"
    echo "$test_input" > "$tmp_input"
    
    local start_time=$(get_timestamp_ms)
    
    # Run inference
    local response=$(curl -s -w "\n%{http_code}" --max-time "$INFERENCE_TIMEOUT" \
        -X POST "$CORE_URL/models/${encoded_model_id}/inference" \
        -H "Content-Type: application/json" \
        -d "@$tmp_input" 2>&1)
    
    rm -f "$tmp_input"
    
    local http_code=$(echo "$response" | tail -n 1)
    local body=$(echo "$response" | sed '$d')
    
    local end_time=$(get_timestamp_ms)
    local inference_time=$(measure_time $start_time $end_time)
    
    if [ "$http_code" = "200" ]; then
        log "✅ $size inference successful (${inference_time}ms)"
        update_result "inference_$size" "success" "$inference_time"
        return 0
    else
        log_error "$size inference failed (HTTP $http_code)"
        log_error "Response: $(echo "$body" | head -c 500)"
        update_result "inference_$size" "failed" "$inference_time" "HTTP $http_code"
        return 1
    fi
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Main Pipeline
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
main() {
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "🚀 Single Model Test Pipeline: $MODEL_NAME"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Initialize result tracking
    init_result
    
    local overall_status="success"
    
    # Phase 1: Install
    if ! install_model; then
        overall_status="failed"
        finalize_result "$overall_status"
        log_error "Pipeline failed at install phase"
        exit 1
    fi
    
    # Phase 2: Register
    if ! register_model; then
        overall_status="failed"
        finalize_result "$overall_status"
        log_error "Pipeline failed at register phase"
        exit 1
    fi
    
    # Phase 3: Small inference
    if ! run_inference "small"; then
        overall_status="partial"
    fi
    
    # Phase 4: Large inference (optional, don't fail the whole pipeline)
    if ! run_inference "large"; then
        if [ "$overall_status" = "success" ]; then
            overall_status="partial"
        fi
    fi
    
    # Finalize
    finalize_result "$overall_status"
    
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "$overall_status" = "success" ]; then
        log "✅ ${GREEN}Pipeline completed successfully!${NC}"
    elif [ "$overall_status" = "partial" ]; then
        log "⚠️  ${YELLOW}Pipeline completed with partial success${NC}"
    else
        log "❌ ${RED}Pipeline failed${NC}"
    fi
    log "  Results: $RESULT_FILE"
    log "  Log: $LOG_FILE"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [ "$overall_status" = "failed" ]; then
        exit 1
    fi
    exit 0
}

main

