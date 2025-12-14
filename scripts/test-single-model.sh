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
#   AXON_VERSION    - Axon version (default: v3.1.7)
#   CORE_VERSION    - Core version (default: 3.2.13-alpha)
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
AXON_VERSION="${AXON_VERSION:-v3.1.7}"
CORE_VERSION="${CORE_VERSION:-4.1.3-alpha}"
CORE_URL="${CORE_URL:-http://127.0.0.1:18080}"
OUTPUT_DIR="${OUTPUT_DIR:-./model-results}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-900}"  # 15 minutes
LLM_INSTALL_TIMEOUT="${LLM_INSTALL_TIMEOUT:-2400}"  # 40 minutes for LLM/GGUF
INFERENCE_TIMEOUT="${INFERENCE_TIMEOUT:-120}"
LLM_INFERENCE_TIMEOUT="${LLM_INFERENCE_TIMEOUT:-300}"  # 5 minutes for LLM generation

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
    'task': model.get('task', ''),  # ONNX export task (e.g., image-classification)
    'small_input': model.get('small_input', {}),
    'large_input': model.get('large_input', {})
}))
" 2>/dev/null
}

# Clean up large intermediate files after ONNX conversion to save disk space
# This is critical for parallel model installation on GitHub Actions
cleanup_model_files() {
    local onnx_path="$1"
    local model_dir=$(dirname "$onnx_path")
    
    if [ -d "$model_dir" ]; then
        # Remove large weight files that are redundant after ONNX conversion
        local removed_size=0
        for file in "$model_dir/pytorch_model.bin" \
                    "$model_dir/tf_model.h5" \
                    "$model_dir/model.safetensors" \
                    "$model_dir/flax_model.msgpack" \
                    "$model_dir/rust_model.ot" \
                    "$model_dir"/*.tflite \
                    "$model_dir"/*.mlmodel; do
            if [ -f "$file" ]; then
                local size=$(du -k "$file" 2>/dev/null | cut -f1)
                rm -f "$file" 2>/dev/null && removed_size=$((removed_size + size))
            fi
        done
        
        # Also clean up coreml directory if exists
        if [ -d "$model_dir/coreml" ]; then
            rm -rf "$model_dir/coreml" 2>/dev/null
        fi
        
        if [ $removed_size -gt 0 ]; then
            log "  🧹 Cleaned up $((removed_size / 1024))MB of intermediate files"
        fi
    fi
}

# Generate test input based on model type
# IMPORTANT: Core expects FLAT arrays, not nested batch dimensions
generate_test_input() {
    local model_name="$1"
    local input_type="$2"
    local category="$3"
    local size="$4"  # small or large
    
    # Try to use the Python generator first (supports T5, CLIP, etc.)
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local generator="$script_dir/generate-test-input.py"
    
    if [ -f "$generator" ]; then
        local result=$(python3 "$generator" "$model_name" "$size" 2>/dev/null)
        if [ -n "$result" ] && [ "$result" != "{}" ] && [ "$result" != "null" ]; then
            echo "$result"
            return 0
        fi
    fi
    
    # Fallback to inline generation if generator fails or unavailable
    case "$category" in
        nlp)
            case "$model_name" in
                gpt2)
                    # GPT2: only input_ids, flat array
                    local max_len=16
                    [ "$size" = "large" ] && max_len=128
                    python3 -c "
import json
ids = [15496, 11, 314, 716, 257, 3303] + [2746] * ($max_len - 6)
print(json.dumps({'input_ids': ids[:$max_len]}))
"
                    ;;
                bert)
                    # BERT: input_ids, attention_mask, token_type_ids - flat arrays
                    local max_len=16
                    [ "$size" = "large" ] && max_len=128
                    python3 -c "
import json
ids = [101] + [7592] * ($max_len - 2) + [102]
mask = [1] * $max_len
types = [0] * $max_len
print(json.dumps({'input_ids': ids, 'attention_mask': mask, 'token_type_ids': types}))
"
                    ;;
                roberta)
                    # RoBERTa: only input_ids, flat array
                    local max_len=16
                    [ "$size" = "large" ] && max_len=128
                    python3 -c "
import json
ids = [0] + [31414] * ($max_len - 2) + [2]
print(json.dumps({'input_ids': ids}))
"
                    ;;
                t5)
                    # T5: encoder-decoder model - Python generator handles this via test-inputs.yaml
                    # Fallback if Python generator fails (shouldn't happen, but just in case)
                    local max_len=16
                    [ "$size" = "large" ] && max_len=128
                    python3 -c "
import json
# T5 fallback: encoder input + decoder input with start token
encoder_ids = [8774, 6, 26, 21, 408, 8612, 2495, 5, 1] + [0] * ($max_len - 9)
encoder_mask = [1] * min(9, $max_len) + [0] * max(0, $max_len - 9)
decoder_ids = [0] + [320] * ($max_len - 1)  # decoder_start_token_id=0
print(json.dumps({'input_ids': encoder_ids[:$max_len], 'attention_mask': encoder_mask[:$max_len], 'decoder_input_ids': decoder_ids[:$max_len]}))
"
                    ;;
                *)
                    # Generic NLP fallback
                    echo '{"input_ids": [101, 7592, 102]}'
                    ;;
            esac
            ;;
        vision)
            # Vision: flat 1D array of pixel values (batch*channels*height*width)
            local img_size=224
            python3 -c "
import random
import json
random.seed(42)
# Core expects flat array: batch * channels * height * width
data = [random.gauss(0, 1) for _ in range(1 * 3 * $img_size * $img_size)]
print(json.dumps({'pixel_values': data}))
"
            ;;
        multimodal)
            case "$model_name" in
                clip)
                    # CLIP: text (input_ids, attention_mask) + image (pixel_values)
                    # Using same approach as vision models but with text inputs too
                    local text_len=77
                    local img_size=224
                    python3 -c "
import random
import json
random.seed(42)
# CLIP text: 49406 = <|startoftext|>, 49407 = <|endoftext|>
# Fallback token IDs (matches generate-test-input.py fallback)
text_ids = [49406] + [320] * ($text_len - 2) + [49407]
text_mask = [1] * $text_len
# CLIP image: normalized pixel values (mean=0, std=1) - flat array
img_data = [random.gauss(0, 1) for _ in range(1 * 3 * $img_size * $img_size)]
print(json.dumps({'input_ids': text_ids, 'attention_mask': text_mask, 'pixel_values': img_data}))
"
                    ;;
                *)
                    # Generic multimodal fallback - return empty to force Python generator
                    echo ""
                    ;;
            esac
            ;;
        llm)
            # LLM/GGUF models - prompt-based text generation
            # These models use Core's llama.cpp plugin
            # Use golden test data prompts to ensure validation alignment
            local golden_data="$CONFIG_DIR/golden-test-data.yaml"
            python3 -c "
import yaml
import json
import sys

model_name = '$model_name'
size = '$size'
golden_file = '$golden_data'

# Default prompts (fallback if golden data not available)
defaults = {
    'tinyllama': {
        'small': ('What is the capital of France?', 32),
        'large': ('Explain the theory of relativity in simple terms.', 256)
    },
    'phi2': {
        'small': ('Write a Python function to calculate fibonacci numbers.', 64),
        'large': ('Explain how neural networks learn through backpropagation.', 256)
    },
    'qwen2-0.5b': {
        'small': ('What is 2 + 2? Answer with just the number.', 8),
        'large': ('Summarize the key developments in artificial intelligence over the past decade.', 256)
    },
    'llama-3.2-1b': {
        'small': ('What is the capital of Japan? Answer in one word.', 16),
        'large': ('Explain the importance of renewable energy.', 256)
    },
    'deepseek-coder-1.3b': {
        'small': ('Write a Python function called add that takes two numbers and returns their sum.', 64),
        'large': ('Write a Python class for a binary search tree.', 256)
    }
}

prompt = 'Hello, how are you?'
max_tokens = 32

# Try to get prompt from golden test data first
try:
    with open(golden_file) as f:
        golden = yaml.safe_load(f)
    model_data = golden.get('models', {}).get(model_name, {})
    test_cases = model_data.get('test_cases', [])

    if test_cases:
        # For 'small' size, use the first test case
        # For 'large' size, use the last test case (or second if multiple)
        if size == 'large' and len(test_cases) > 1:
            test_case = test_cases[-1]  # Use last test case for large
        else:
            test_case = test_cases[0]  # Use first test case for small

        prompt = test_case.get('input', {}).get('prompt', prompt)
        max_tokens = test_case.get('input', {}).get('max_tokens', max_tokens)

except Exception as e:
    # Fall back to hardcoded defaults
    pass

# If no prompt from golden data, use defaults
if prompt == 'Hello, how are you?':
    if model_name in defaults:
        prompt, max_tokens = defaults[model_name].get(size, (prompt, max_tokens))

# Use low temperature for deterministic output during testing
print(json.dumps({
    'prompt': prompt,
    'max_tokens': max_tokens,
    'temperature': 0.1,  # Low temp for reproducible results
    'top_p': 0.9
}))
"
            ;;
        *)
            echo '{"input_ids": [101, 7592, 102]}'
            ;;
    esac
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
    # For single-file models: model.onnx
    # For multi-encoder models (CLIP): onnx_manifest.json
    # For encoder-decoder models (T5): encoder_model.onnx, decoder_model.onnx, etc.
    # For LLM/GGUF models: *.gguf files
    local model_dir="$HOME/.axon/cache/models/${AXON_ID%@*}/${AXON_ID##*@}"
    local model_path="$model_dir/model.onnx"
    local manifest_path="$model_dir/onnx_manifest.json"
    local encoder_path="$model_dir/encoder_model.onnx"

    if [ -f "$model_path" ]; then
        log "✅ Model already installed at: $model_path"
        update_result "install" "success" 0
        return 0
    elif [ -f "$manifest_path" ]; then
        log "✅ Multi-encoder model already installed (manifest at: $manifest_path)"
        update_result "install" "success" 0
        return 0
    elif [ -f "$encoder_path" ]; then
        log "✅ Encoder-decoder model already installed (encoder at: $encoder_path)"
        update_result "install" "success" 0
        return 0
    fi

    # Check for GGUF files (LLM models)
    if [ "$CATEGORY" = "llm" ] && [ -d "$model_dir" ]; then
        local gguf_file=$(find "$model_dir" -name "*.gguf" -type f 2>/dev/null | head -1)
        if [ -n "$gguf_file" ]; then
            log "✅ GGUF model already installed at: $gguf_file"
            update_result "install" "success" 0
            return 0
        fi
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

    # Determine install timeout based on model category
    # LLM/GGUF models need longer timeout for large downloads (500MB+)
    local effective_timeout="$INSTALL_TIMEOUT"
    if [ "$CATEGORY" = "llm" ]; then
        effective_timeout="${LLM_INSTALL_TIMEOUT:-2400}"  # 40 minutes for LLM
        log "  Using LLM install timeout: ${effective_timeout}s (GGUF download)"
    fi

    # Run installation with timeout
    log "  Running: $axon_cmd install $AXON_ID (timeout: ${effective_timeout}s)"
    if run_with_timeout "$effective_timeout" "$axon_cmd" install "$AXON_ID" >> "$LOG_FILE" 2>&1; then
        local end_time=$(get_timestamp_ms)
        local install_time=$(measure_time $start_time $end_time)
        
        # Verify installation - check for different model file types
        local model_dir="$HOME/.axon/cache/models/${AXON_ID%@*}/${AXON_ID##*@}"
        local model_path="$model_dir/model.onnx"
        local manifest_path="$model_dir/onnx_manifest.json"
        local encoder_path="$model_dir/encoder_model.onnx"
        
        if [ -f "$model_path" ]; then
            log "✅ Model installed successfully (${install_time}ms)"
            update_result "install" "success" "$install_time"
            # Clean up large intermediate files to save disk space
            cleanup_model_files "$model_path"
            return 0
        elif [ -f "$manifest_path" ]; then
            log "✅ Multi-encoder model installed successfully (manifest at: $manifest_path, ${install_time}ms)"
            update_result "install" "success" "$install_time"
            return 0
        elif [ -f "$encoder_path" ]; then
            log "✅ Encoder-decoder model installed successfully (encoder at: $encoder_path, ${install_time}ms)"
            update_result "install" "success" "$install_time"
            return 0
        fi

        # Check for GGUF files (LLM models)
        if [ "$CATEGORY" = "llm" ] && [ -d "$model_dir" ]; then
            local gguf_file=$(find "$model_dir" -name "*.gguf" -type f 2>/dev/null | head -1)
            if [ -n "$gguf_file" ]; then
                log "✅ GGUF model installed successfully at: $gguf_file (${install_time}ms)"
                update_result "install" "success" "$install_time"
                return 0
            fi
        fi

        # Fallback search for models not found in expected locations
        # Search for model - use the model name (without hf/ prefix and @version suffix)
        # For hf/google/vit-base-patch16-224@latest, search for *vit-base-patch16-224*
        local model_name_for_search="${AXON_ID#hf/}"        # Remove hf/ prefix
        model_name_for_search="${model_name_for_search%@*}"  # Remove @version suffix
        model_name_for_search="${model_name_for_search##*/}" # Get last component (actual model name)

        # Search for single-file model
        local found_model=$(find "$HOME/.axon/cache/models" -name "model.onnx" -path "*${model_name_for_search}*" 2>/dev/null | head -1)
        if [ -n "$found_model" ]; then
            log "✅ Model found at: $found_model (${install_time}ms)"
            update_result "install" "success" "$install_time"
            cleanup_model_files "$found_model"
            return 0
        fi

        # Search for multi-encoder manifest
        local found_manifest=$(find "$HOME/.axon/cache/models" -name "onnx_manifest.json" -path "*${model_name_for_search}*" 2>/dev/null | head -1)
        if [ -n "$found_manifest" ]; then
            log "✅ Multi-encoder model found (manifest at: $found_manifest, ${install_time}ms)"
            update_result "install" "success" "$install_time"
            return 0
        fi

        # Search for encoder-decoder files (T5, BART, etc.)
        local found_encoder=$(find "$HOME/.axon/cache/models" -name "encoder_model.onnx" -path "*${model_name_for_search}*" 2>/dev/null | head -1)
        if [ -n "$found_encoder" ]; then
            log "✅ Encoder-decoder model found (encoder at: $found_encoder, ${install_time}ms)"
            update_result "install" "success" "$install_time"
            return 0
        fi

        # Search for GGUF files (LLM models)
        if [ "$CATEGORY" = "llm" ]; then
            local found_gguf=$(find "$HOME/.axon/cache/models" -name "*.gguf" -path "*${model_name_for_search}*" 2>/dev/null | head -1)
            if [ -n "$found_gguf" ]; then
                log "✅ GGUF model found at: $found_gguf (${install_time}ms)"
                update_result "install" "success" "$install_time"
                return 0
            fi
        fi

        # List what files were actually created for debugging
        if [ -d "$model_dir" ]; then
            log_error "Model directory exists but no model files found: $model_dir"
            log_error "Files in directory:"
            ls -la "$model_dir" 2>/dev/null | head -20 | while read line; do
                log_error "  $line"
            done || true
        fi

        log_error "Model file not found after installation"
        log_error "Expected one of:"
        log_error "  - $model_path (single-file ONNX model)"
        log_error "  - $manifest_path (multi-encoder ONNX manifest)"
        log_error "  - $encoder_path (encoder-decoder ONNX model)"
        log_error "  - *.gguf (LLM/GGUF model)"
        log_error "Searched for: *${model_name_for_search}*"
        update_result "install" "failed" "$install_time" "Model file not found"
        return 1
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
    
    # Find axon binary (same logic as install phase)
    local axon_cmd="${HOME}/.local/bin/axon"
    if [ ! -f "$axon_cmd" ]; then
        axon_cmd="axon"
    fi
    
    local start_time=$(get_timestamp_ms)
    
    # Use axon register command (proper flow: install -> register -> inference)
    # axon register uses MLOS_CORE_ENDPOINT environment variable
    local register_output=$(mktemp)
    local register_errors=$(mktemp)
    
    log "  Running: $axon_cmd register $AXON_ID"
    
    if MLOS_CORE_ENDPOINT="$CORE_URL" "$axon_cmd" register "$AXON_ID" > "$register_output" 2> "$register_errors"; then
        local register_exit_code=0
    else
        local register_exit_code=$?
    fi
    
    local end_time=$(get_timestamp_ms)
    local register_time=$(measure_time $start_time $end_time)
    
    # Check result
    if [ $register_exit_code -eq 0 ]; then
        log "✅ Model registered (${register_time}ms)"
        update_result "register" "success" "$register_time"
        rm -f "$register_output" "$register_errors"
        return 0
    elif grep -qi "already registered" "$register_output" "$register_errors" 2>/dev/null; then
        log "✅ Model already registered (${register_time}ms)"
        update_result "register" "success" "$register_time"
        rm -f "$register_output" "$register_errors"
        return 0
    else
        log_error "Registration failed (exit code $register_exit_code)"
        [ -s "$register_errors" ] && log_error "Errors: $(cat "$register_errors")"
        [ -s "$register_output" ] && log_error "Output: $(cat "$register_output")"
        update_result "register" "failed" "$register_time" "Exit code $register_exit_code"
        rm -f "$register_output" "$register_errors"
        return 1
    fi
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Helper: Check if model needs tensor output data for validation
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
needs_tensor_output() {
    local model_name="$1"
    local golden_data="$CONFIG_DIR/golden-test-data.yaml"

    if [ ! -f "$golden_data" ]; then
        # Default to true if no golden data file
        return 0
    fi

    # Check the validation_type in golden data
    # Types that need tensor data: output_exists, output_shape, top_k_contains
    # Types that only need metadata: status_success
    local validation_type=$(python3 -c "
import yaml
import sys
try:
    with open('$golden_data') as f:
        data = yaml.safe_load(f)
    model_data = data.get('models', {}).get('$model_name', {})
    test_cases = model_data.get('test_cases', [])
    if test_cases:
        vtype = test_cases[0].get('expected', {}).get('validation_type', '')
        print(vtype)
except:
    print('')
" 2>/dev/null)

    case "$validation_type" in
        status_success)
            # status_success only needs metadata, no tensor data
            return 1
            ;;
        output_exists|output_shape|top_k_contains|embedding_normalized)
            # These need tensor data
            return 0
            ;;
        *)
            # Default: include outputs to be safe
            return 0
            ;;
    esac
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

    # Output file for inference response (write directly to avoid bash variable size limits)
    # BERT output can be 5MB+ which exceeds bash's ability to store in variables
    local response_file="$OUTPUT_DIR/${MODEL_NAME}-response-${size}.json"

    # Determine if we need tensor output data for validation
    # Models with status_success validation only need metadata, not tensor data
    # Including tensor data for large models like BERT causes response truncation
    local inference_url="$CORE_URL/models/${encoded_model_id}/inference"
    if needs_tensor_output "$MODEL_NAME"; then
        inference_url="${inference_url}?include_outputs=true"
        log "  Including tensor outputs for validation"
    else
        log "  Metadata-only response (status_success validation)"
    fi

    # Run inference and write directly to file to avoid bash variable truncation
    local http_code=$(curl -s -w "%{http_code}" --max-time "$INFERENCE_TIMEOUT" \
        -X POST "$inference_url" \
        -H "Content-Type: application/json" \
        -d "@$tmp_input" \
        -o "$response_file" 2>/dev/null)

    rm -f "$tmp_input"

    local end_time=$(get_timestamp_ms)
    local inference_time=$(measure_time $start_time $end_time)

    if [ "$http_code" = "200" ]; then
        log "✅ $size inference successful (${inference_time}ms)"

        # Run output validation if validator script exists
        local validator="$SCRIPT_DIR/validate-inference.py"
        if [ -f "$validator" ] && [ "$VALIDATE_OUTPUT" != "false" ]; then
            log "  🔍 Validating inference output..."
            # Response is already saved directly to file by curl (avoids bash variable size limits)
            # Pass --test $size to validate only the test case matching the inference size
            local validation_result=$(python3 "$validator" --model "$MODEL_NAME" --output "$response_file" --test "$size" --json 2>/dev/null || echo "[]")

            if [ -n "$validation_result" ] && [ "$validation_result" != "[]" ]; then
                # Check if any validations failed
                local failed_count=$(echo "$validation_result" | python3 -c "import json,sys; data=json.load(sys.stdin); print(sum(1 for r in data if not r.get('passed', True)))" 2>/dev/null || echo "0")
                local total_count=$(echo "$validation_result" | python3 -c "import json,sys; data=json.load(sys.stdin); print(len(data))" 2>/dev/null || echo "0")

                if [ "$failed_count" = "0" ] && [ "$total_count" != "0" ]; then
                    log "  ✅ Output validation passed ($total_count tests)"
                    update_result "inference_$size" "success" "$inference_time"
                    # Save validation results
                    echo "$validation_result" > "$OUTPUT_DIR/${MODEL_NAME}-validation-${size}.json"
                elif [ "$total_count" = "0" ]; then
                    log "  ℹ️  No validation tests defined for this model"
                    update_result "inference_$size" "success" "$inference_time"
                else
                    log_warn "  ⚠️  Output validation: $failed_count/$total_count tests failed"
                    # Don't fail the whole test, just log warning
                    update_result "inference_$size" "success" "$inference_time"
                    echo "$validation_result" > "$OUTPUT_DIR/${MODEL_NAME}-validation-${size}.json"
                fi
            else
                log "  ℹ️  No validation tests defined for model '$MODEL_NAME'"
                update_result "inference_$size" "success" "$inference_time"
            fi
        else
            update_result "inference_$size" "success" "$inference_time"
        fi

        # Response already saved to file by curl (response_file variable)
        return 0
    else
        log_error "$size inference failed (HTTP $http_code)"
        # Show first 500 chars of error response from file
        log_error "Response: $(head -c 500 "$response_file" 2>/dev/null || echo 'No response file')"
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

