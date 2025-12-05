#!/bin/bash

set -e

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# MLOS Release E2E Validation Script
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 
# Tests the latest releases of Axon and MLOS Core with E2E inference validation
# Generates comprehensive HTML report with visual metrics
#
# Usage: ./test-release-e2e.sh
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
AXON_RELEASE_VERSION="${AXON_VERSION:-v3.1.2}"
CORE_RELEASE_VERSION="${CORE_VERSION:-3.2.7-alpha}"
TEST_DIR="$(pwd)/release-test-$(date +%s)"
REPORT_FILE="$TEST_DIR/release-validation-report.html"
METRICS_FILE="$TEST_DIR/metrics.json"
LOG_FILE="$TEST_DIR/test.log"

# Script directory (for finding config files)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(dirname "$SCRIPT_DIR")/config"
CONFIG_FILE="$CONFIG_DIR/models.yaml"

# Load models from config/models.yaml
load_models_from_config() {
    local config_loader="$SCRIPT_DIR/load-config.py"
    
    if [ -f "$config_loader" ] && [ -f "$CONFIG_FILE" ]; then
        echo "📋 Loading models from config/models.yaml..."
        
        # Source the bash variables from config
        eval "$(python3 "$config_loader" --bash 2>/dev/null)"
        
        # Build TEST_MODELS array from config
        TEST_MODELS=()
        for model_name in $CONFIG_ENABLED_MODELS; do
            # Get model details using uppercase variable names
            local upper_name=$(echo "$model_name" | tr '[:lower:]' '[:upper:]')
            local axon_id_var="MODEL_${upper_name}_AXON_ID"
            local category_var="MODEL_${upper_name}_CATEGORY"
            local input_type_var="MODEL_${upper_name}_INPUT_TYPE"
            
            local axon_id="${!axon_id_var}"
            local category="${!category_var:-nlp}"
            local input_type="${!input_type_var:-text}"
            
            # Determine model type (single/multi) based on model
            local model_type="single"
            if [[ "$model_name" == "bert" ]]; then
                model_type="multi"
            fi
            
            if [ -n "$axon_id" ]; then
                TEST_MODELS+=("${axon_id}:${model_name}:${model_type}:${category}")
            fi
        done
        
        echo "✅ Loaded ${#TEST_MODELS[@]} models from config"
        return 0
    else
        echo "⚠️ Config not found, using default models"
        return 1
    fi
}

# Try to load from config, fallback to hardcoded defaults
if ! load_models_from_config 2>/dev/null; then
    # Fallback: Hardcoded models (for backward compatibility)
    TEST_MODELS=(
        "hf/distilgpt2@latest:gpt2:single:nlp"
        "hf/bert-base-uncased@latest:bert:multi:nlp"
        "hf/roberta-base@latest:roberta:single:nlp"
    )
fi

# Additional models (tested if TEST_ALL_MODELS=1 or model already installed)
ADDITIONAL_MODELS=(
    # Vision Models - BLOCKED: Axon converter needs --task parameter for vision models
    # "hf/microsoft/resnet-50@latest:resnet:single:vision"
)

# Add additional models if TEST_ALL_MODELS is set or if they're already installed
if [ "${TEST_ALL_MODELS:-0}" = "1" ]; then
    TEST_MODELS+=("${ADDITIONAL_MODELS[@]}")
else
    for model_spec in "${ADDITIONAL_MODELS[@]}"; do
        IFS=':' read -r model_id model_name model_type model_category <<< "$model_spec"
        model_path="$HOME/.axon/cache/models/${model_id%@*}/${model_id##*@}/model.onnx"
        if [ -f "$model_path" ]; then
            TEST_MODELS+=("$model_spec")
        fi
    done
fi

# Metrics storage (using simple variables instead of associative array for Bash 3.2 compatibility)
METRIC_start_time=$(date +%s)

# Functions
# Check log size and rotate if too large (prevent disk space issues)
check_log_size() {
    if [ -f "$LOG_FILE" ]; then
        local log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo "0")
        local max_size=$((10 * 1024 * 1024))  # 10MB limit (reduced to prevent disk space issues)
        if [ "$log_size" -gt "$max_size" ]; then
            # Keep last 5000 lines instead of rotating completely
            tail -n 5000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
            echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN:${NC} Log file rotated (was ${log_size} bytes, kept last 5000 lines)" >> "$LOG_FILE"
        fi
    fi
}

log() {
    check_log_size
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    check_log_size
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    check_log_size
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN:${NC} $1" | tee -a "$LOG_FILE"
}

# Cross-platform timeout function
# Usage: run_with_timeout <seconds> <command> [args...]
# Returns exit code 124 if timeout, otherwise returns command's exit code
run_with_timeout() {
    local timeout_seconds=$1
    shift
    local cmd="$@"
    
    # Check if timeout command is available (Linux)
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_seconds" $cmd
        return $?
    fi
    
    # macOS: Use perl to implement timeout
    if command -v perl >/dev/null 2>&1; then
        perl -e '
            my $timeout = shift;
            my $pid = fork();
            if ($pid == 0) {
                # Child process: execute command
                exec @ARGV;
            } else {
                # Parent process: wait with timeout
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
    
    # Fallback: run without timeout (not ideal, but better than failing)
    log_warn "No timeout command available, running without timeout (may hang)"
    $cmd
    return $?
}

# Collect hardware specifications
collect_hardware_specs() {
    log "Collecting hardware specifications..."
    
    # OS and Kernel
    METRIC_hw_os=$(uname -s)
    METRIC_hw_os_version=$(uname -r)
    METRIC_hw_arch=$(uname -m)
    
    # CPU Information
    if [ "$METRIC_hw_os" = "Darwin" ]; then
        # macOS
        METRIC_hw_cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Unknown")
        METRIC_hw_cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "Unknown")
        METRIC_hw_cpu_threads=$(sysctl -n hw.logicalcpu 2>/dev/null || echo "Unknown")
        METRIC_hw_ram_total=$(sysctl -n hw.memsize 2>/dev/null)
        if [ -n "$METRIC_hw_ram_total" ] && [ "$METRIC_hw_ram_total" != "Unknown" ]; then
            METRIC_hw_ram_total_gb=$(awk "BEGIN {printf \"%.2f\", $METRIC_hw_ram_total / 1024 / 1024 / 1024}")
        else
            METRIC_hw_ram_total_gb="Unknown"
        fi
    else
        # Linux
        METRIC_hw_cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//' || echo "Unknown")
        METRIC_hw_cpu_cores=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "Unknown")
        METRIC_hw_cpu_threads=$METRIC_hw_cpu_cores
        METRIC_hw_ram_total=$(grep "MemTotal" /proc/meminfo | awk '{print $2}' 2>/dev/null)
        if [ -n "$METRIC_hw_ram_total" ] && [ "$METRIC_hw_ram_total" != "Unknown" ]; then
            METRIC_hw_ram_total_gb=$(awk "BEGIN {printf \"%.2f\", $METRIC_hw_ram_total * 1024 / 1024 / 1024 / 1024}")
        else
            METRIC_hw_ram_total_gb="Unknown"
        fi
    fi
    
    # GPU Information
    if command -v nvidia-smi >/dev/null 2>&1; then
        METRIC_hw_gpu_model=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 | sed 's/^ *//' || echo "None")
        METRIC_hw_gpu_count=$(nvidia-smi --list-gpus | wc -l | tr -d ' ')
        METRIC_hw_gpu_memory=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -1 | sed 's/^ *//' || echo "Unknown")
    elif [ "$METRIC_hw_os" = "Darwin" ] && system_profiler SPDisplaysDataType >/dev/null 2>&1; then
        METRIC_hw_gpu_model=$(system_profiler SPDisplaysDataType | grep "Chipset Model" | head -1 | cut -d: -f2 | sed 's/^ *//' || echo "None")
        METRIC_hw_gpu_count="1"
        METRIC_hw_gpu_memory="Unknown"
    else
        METRIC_hw_gpu_model="None detected"
        METRIC_hw_gpu_count="0"
        METRIC_hw_gpu_memory="N/A"
    fi
    
    # Disk Information
    if [ "$METRIC_hw_os" = "Darwin" ]; then
        METRIC_hw_disk_total=$(df -h / | tail -1 | awk '{print $2}' || echo "Unknown")
        METRIC_hw_disk_available=$(df -h / | tail -1 | awk '{print $4}' || echo "Unknown")
    else
        METRIC_hw_disk_total=$(df -h / | tail -1 | awk '{print $2}' || echo "Unknown")
        METRIC_hw_disk_available=$(df -h / | tail -1 | awk '{print $4}' || echo "Unknown")
    fi
    
    log "✅ Hardware specs collected"
}

# Monitor resource usage for a process
monitor_process_resources() {
    local process_name=$1
    local duration=${2:-5}  # Monitor for 5 seconds by default
    local output_file=$3
    
    if [ -z "$output_file" ]; then
        output_file=$(mktemp)
    fi
    
    local pids=$(pgrep -f "$process_name" 2>/dev/null)
    if [ -z "$pids" ]; then
        echo "Process not found: $process_name" > "$output_file"
        return 1
    fi
    
    local max_cpu=0
    local max_mem=0
    local total_cpu=0
    local total_mem=0
    local samples=0
    
    for pid in $pids; do
        if [ "$METRIC_hw_os" = "Darwin" ]; then
            # macOS - use ps and top
            for i in $(seq 1 $duration); do
                local stats=$(ps -p $pid -o %cpu,rss 2>/dev/null | tail -1)
                if [ -n "$stats" ]; then
                    local cpu=$(echo "$stats" | awk '{print $1}')
                    local mem_kb=$(echo "$stats" | awk '{print $2}')
                    local mem_mb=$(awk "BEGIN {printf \"%.2f\", $mem_kb / 1024}")
                    
                    if [ -n "$cpu" ] && [ "$cpu" != "%CPU" ] && [ "$cpu" != "0" ]; then
                        total_cpu=$(awk "BEGIN {printf \"%.2f\", $total_cpu + $cpu}")
                        if [ -n "$max_cpu" ] && [ "$max_cpu" != "0" ]; then
                            if (( $(awk "BEGIN {print ($cpu > $max_cpu)}") )); then
                                max_cpu=$cpu
                            fi
                        else
                            max_cpu=$cpu
                        fi
                    fi
                    
                    if [ -n "$mem_mb" ] && [ "$mem_mb" != "RSS" ] && [ "$mem_mb" != "0" ]; then
                        total_mem=$(awk "BEGIN {printf \"%.2f\", $total_mem + $mem_mb}")
                        if [ -n "$max_mem" ] && [ "$max_mem" != "0" ]; then
                            if (( $(awk "BEGIN {print ($mem_mb > $max_mem)}") )); then
                                max_mem=$mem_mb
                            fi
                        else
                            max_mem=$mem_mb
                        fi
                    fi
                    ((samples++))
                fi
                sleep 1
            done
        else
            # Linux - use ps
            for i in $(seq 1 $duration); do
                local stats=$(ps -p $pid -o %cpu,rss 2>/dev/null | tail -1)
                if [ -n "$stats" ]; then
                    local cpu=$(echo "$stats" | awk '{print $1}')
                    local mem_kb=$(echo "$stats" | awk '{print $2}')
                    local mem_mb=$(awk "BEGIN {printf \"%.2f\", $mem_kb / 1024}")
                    
                    if [ -n "$cpu" ] && [ "$cpu" != "%CPU" ] && [ "$cpu" != "0" ]; then
                        total_cpu=$(awk "BEGIN {printf \"%.2f\", $total_cpu + $cpu}")
                        if [ -n "$max_cpu" ] && [ "$max_cpu" != "0" ]; then
                            if (( $(awk "BEGIN {print ($cpu > $max_cpu)}") )); then
                                max_cpu=$cpu
                            fi
                        else
                            max_cpu=$cpu
                        fi
                    fi
                    
                    if [ -n "$mem_mb" ] && [ "$mem_mb" != "RSS" ] && [ "$mem_mb" != "0" ]; then
                        total_mem=$(awk "BEGIN {printf \"%.2f\", $total_mem + $mem_mb}")
                        if [ -n "$max_mem" ] && [ "$max_mem" != "0" ]; then
                            if (( $(awk "BEGIN {print ($mem_mb > $max_mem)}") )); then
                                max_mem=$mem_mb
                            fi
                        else
                            max_mem=$mem_mb
                        fi
                    fi
                    ((samples++))
                fi
                sleep 1
            done
        fi
    done
    
    local avg_cpu=0
    local avg_mem=0
    if [ $samples -gt 0 ]; then
        avg_cpu=$(awk "BEGIN {printf \"%.2f\", $total_cpu / $samples}")
        avg_mem=$(awk "BEGIN {printf \"%.2f\", $total_mem / $samples}")
    fi
    
    echo "max_cpu=$max_cpu" > "$output_file"
    echo "avg_cpu=$avg_cpu" >> "$output_file"
    echo "max_mem=$max_mem" >> "$output_file"
    echo "avg_mem=$avg_mem" >> "$output_file"
    echo "samples=$samples" >> "$output_file"
    
    echo "$output_file"
}

log_info() {
    echo -e "${CYAN}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" | tee -a "$LOG_FILE"
}

banner() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
    echo -e "${MAGENTA}$1${NC}" | tee -a "$LOG_FILE"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
}

measure_time() {
    local start=$1
    local end=$2
    echo $((end - start))
}

# Get millisecond timestamp (compatible with macOS)
get_timestamp_ms() {
    # Check if we're on Linux (GNU date) or macOS (BSD date)
    # GNU date supports %N for nanoseconds, BSD date doesn't
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS - use Python
        python3 -c "import time; print(int(time.time() * 1000))"
    else
        # Linux - use GNU date
        date +%s%3N
    fi
}

cleanup() {
    log_warn "Cleaning up..."
    
    # Stop MLOS Core if running
    if [ -f "$TEST_DIR/mlos.pid" ]; then
        local pid=$(cat "$TEST_DIR/mlos.pid")
        if ps -p $pid > /dev/null 2>&1; then
            log "Stopping MLOS Core (PID: $pid)..."
            kill $pid 2>/dev/null || true
            sleep 2
            kill -9 $pid 2>/dev/null || true
        fi
    fi
    
    # Additional cleanup for any stray MLOS Core processes (both binary names)
    pkill -f mlos-server 2>/dev/null || true
    pkill -f mlos_core 2>/dev/null || true
}

trap cleanup EXIT

check_prerequisites() {
    banner "✅ Checking Prerequisites"
    
    # Check for gh CLI
    if ! command -v gh &> /dev/null; then
        log_error "GitHub CLI (gh) is not installed"
        log_error "Install it from: https://cli.github.com/"
        exit 1
    fi
    log "✅ GitHub CLI found: $(gh --version | head -n 1)"
    
    # Check gh authentication
    if ! gh auth status &> /dev/null; then
        log_error "GitHub CLI is not authenticated"
        log_error "Please run: gh auth login"
        exit 1
    fi
    log "✅ GitHub CLI authenticated"
    
    # Check for curl
    if ! command -v curl &> /dev/null; then
        log_error "curl is not installed"
        exit 1
    fi
    log "✅ curl found"
    
    # Check for sudo (needed for MLOS Core)
    if ! command -v sudo &> /dev/null; then
        log_error "sudo is not available"
        exit 1
    fi
    log "✅ sudo available"
    
    # Ensure ~/.local/bin exists
    mkdir -p "$HOME/.local/bin"
    log "✅ ~/.local/bin directory ready"
    
    # Check if ~/.local/bin is in PATH
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        log_warn "~/.local/bin is not in PATH"
        log_warn "Add it to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
}

setup_test_environment() {
    banner "🔧 Setting Up Test Environment"
    
    log "Creating test directory: $TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    
    log "Test directory: $TEST_DIR"
    log "Report file: $REPORT_FILE"
    log "Metrics file: $METRICS_FILE"
    log "Log file: $LOG_FILE"
    
    # Initialize metrics
    echo "{}" > "$METRICS_FILE"
}

download_axon_release() {
    banner "📦 Downloading Axon ${AXON_RELEASE_VERSION}"
    
    # Check if USE_LOCAL_AXON is set and use local binary
    if [ -n "$USE_LOCAL_AXON" ] && [ -n "$LOCAL_AXON_BINARY" ] && [ -f "$LOCAL_AXON_BINARY" ]; then
        log "Using local Axon binary: $LOCAL_AXON_BINARY"
        mkdir -p "$TEST_DIR"
        cp "$LOCAL_AXON_BINARY" "$TEST_DIR/axon"
        chmod +x "$TEST_DIR/axon"
        
        # Install to ~/.local/bin
        cp "$TEST_DIR/axon" "$HOME/.local/bin/axon"
        chmod +x "$HOME/.local/bin/axon"
        
        METRIC_axon_version="local-$(cd "$(dirname "$LOCAL_AXON_BINARY")/.." && git rev-parse --short HEAD 2>/dev/null || echo fix)"
        METRIC_axon_download_time_ms=0
        log "✅ Using local Axon binary: $TEST_DIR/axon"
        log "✅ Axon installed to ~/.local/bin/axon"
        return 0
    fi
    
    local start_time=$(get_timestamp_ms)
    
    # Detect platform
    local OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    local ARCH=$(uname -m)
    
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        arm64|aarch64)
            ARCH="arm64"
            ;;
        *)
            log_error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
    
    log "Detected platform: ${OS}/${ARCH}"
    
    local AXON_BINARY="axon_${AXON_RELEASE_VERSION#v}_${OS}_${ARCH}.tar.gz"
    local DOWNLOAD_URL="https://github.com/mlOS-foundation/axon/releases/download/${AXON_RELEASE_VERSION}/${AXON_BINARY}"
    
    log "Downloading from: $DOWNLOAD_URL"
    
    if curl -L -f -o "$AXON_BINARY" "$DOWNLOAD_URL"; then
        log "✅ Downloaded: $AXON_BINARY"
    else
        log_error "Failed to download Axon release"
        exit 1
    fi
    
    log "Extracting Axon binary..."
    tar -xzf "$AXON_BINARY"
    chmod +x axon
    
    local end_time=$(get_timestamp_ms)
    local download_time=$(measure_time $start_time $end_time)
    METRIC_axon_download_time_ms=$download_time
    
    log "✅ Axon downloaded and extracted (${download_time}ms)"
    
    # Install to ~/.local/bin
    log "Installing Axon to ~/.local/bin/..."
    cp axon "$HOME/.local/bin/axon"
    chmod +x "$HOME/.local/bin/axon"
    log "✅ Axon installed to ~/.local/bin/axon"
    
    # Verify from installed location
    if "$HOME/.local/bin/axon" version 2>/dev/null; then
        METRIC_axon_version=$("$HOME/.local/bin/axon" version 2>/dev/null | head -n 1 || echo "unknown")
        log "Axon version: ${METRIC_axon_version}"
    else
        log_warn "Could not verify Axon version"
    fi
}

download_core_release() {
    banner "📦 Downloading MLOS Core ${CORE_RELEASE_VERSION}"
    
    # Check if USE_LOCAL_CORE is set and use local binary
    if [ -n "$USE_LOCAL_CORE" ] && [ -n "$LOCAL_CORE_BINARY" ] && [ -f "$LOCAL_CORE_BINARY" ]; then
        log "Using local Core binary: $LOCAL_CORE_BINARY"
        mkdir -p mlos-core/build
        cp "$LOCAL_CORE_BINARY" mlos-core/build/mlos_core
        chmod +x mlos-core/build/mlos_core
        
        # Set paths - MLOS_CORE_DIR is where we cd to, MLOS_CORE_BINARY is relative to that
        MLOS_CORE_DIR="$(pwd)/mlos-core"
        MLOS_CORE_BINARY="build/mlos_core"
        
        # Verify the binary exists at the expected location
        if [ ! -f "$MLOS_CORE_DIR/$MLOS_CORE_BINARY" ]; then
            log_error "Failed to copy local core binary to $MLOS_CORE_DIR/$MLOS_CORE_BINARY"
            exit 1
        fi
        
        METRIC_core_version="local-$(cd "$(dirname "$LOCAL_CORE_BINARY")/../.." && git rev-parse --short HEAD 2>/dev/null || echo fix)"
        log "✅ Using local Core binary: $MLOS_CORE_DIR/$MLOS_CORE_BINARY"
        cp "$MLOS_CORE_DIR/$MLOS_CORE_BINARY" "$HOME/.local/bin/mlos_core"
        chmod +x "$HOME/.local/bin/mlos_core"
        log "✅ MLOS Core installed to ~/.local/bin/mlos_core"
        return 0
    fi
    
    local start_time=$(get_timestamp_ms)
    
    # Detect platform and architecture
    local OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    local ARCH=$(uname -m)
    
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        arm64|aarch64)
            ARCH="arm64"
            ;;
        *)
            log_error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
    
    log "Detected platform: ${OS}/${ARCH}"
    log "Downloading MLOS Core release via gh CLI..."
    log "Release: ${CORE_RELEASE_VERSION}"
    
    # Try to download platform-specific archive first (note: uses hyphen between OS and ARCH)
    local specific_pattern="mlos-core_${CORE_RELEASE_VERSION}_${OS}-${ARCH}.tar.gz"
    log "Trying platform-specific download: $specific_pattern"
    
    local core_archive=""
    
    if gh release download ${CORE_RELEASE_VERSION} --pattern "$specific_pattern" --repo mlOS-foundation/core >> "$LOG_FILE" 2>&1; then
        log "✅ Downloaded platform-specific Core archive"
        core_archive="$specific_pattern"
    else
        log_warn "Platform-specific archive not found, downloading all archives..."
        
        # Download all platform archives (they use hyphens: darwin-arm64, linux-amd64, etc.)
        local pattern="mlos-core_${CORE_RELEASE_VERSION}_*.tar.gz"
        if gh release download ${CORE_RELEASE_VERSION} --pattern "$pattern" --repo mlOS-foundation/core >> "$LOG_FILE" 2>&1; then
            log "✅ Downloaded Core release archives"
            
            # Find the matching platform archive (with hyphen)
            core_archive=$(ls mlos-core_${CORE_RELEASE_VERSION}_${OS}-${ARCH}.tar.gz 2>/dev/null)
            
            if [ -z "$core_archive" ]; then
                log_warn "No matching platform archive found"
                log "Available archives:"
                ls mlos-core_${CORE_RELEASE_VERSION}_*.tar.gz 2>/dev/null | tee -a "$LOG_FILE" || log "None found"
                core_archive=""
            else
                log "Found matching archive: $core_archive"
            fi
        fi
    fi
    
    # Ensure we found a release archive - try curl fallback for public repos
    if [ -z "$core_archive" ]; then
        log_warn "gh download failed, trying curl for public release..."
        # GitHub release tags always have 'v' prefix, so add it if missing
        local release_tag="${CORE_RELEASE_VERSION}"
        if [[ ! "$release_tag" =~ ^v ]]; then
            release_tag="v${release_tag}"
        fi
        local core_url="https://github.com/mlOS-foundation/core-releases/releases/download/${release_tag}/${specific_pattern}"
        log "Trying curl download from: $core_url"
        if curl -L -f -# -o "$specific_pattern" "$core_url" >> "$LOG_FILE" 2>&1; then
            log "✅ Downloaded via curl"
            core_archive="$specific_pattern"
        else
            log_error "Failed to download MLOS Core release (both gh and curl failed)"
            log_error "No matching platform-specific archive found"
            log_error "Please ensure:"
            log_error "  1. You're logged in with: gh auth login (or set GH_TOKEN)"
            log_error "  2. The release includes binaries for your platform (${OS}-${ARCH})"
            log_error "  3. Release version exists: ${CORE_RELEASE_VERSION} (or ${release_tag})"
            log_error "  4. Tried URL: $core_url"
            exit 1
        fi
    fi
    
    log "Extracting Core from: $core_archive"
    mkdir -p mlos-core
    tar -xzf "$core_archive" -C mlos-core
    log "✅ Core archive extracted"
    
    cd mlos-core
    
    # Debug: Show what was extracted
    log "Contents of extracted archive:"
    ls -la >> "$LOG_FILE" 2>&1
    
    # Handle nested directory structure (archive may extract to a subdirectory)
    # If there's only one directory, cd into it
    local dir_count=$(find . -maxdepth 1 -type d ! -name '.' | wc -l | tr -d ' ')
    if [ "$dir_count" -eq 1 ]; then
        local nested_dir=$(find . -maxdepth 1 -type d ! -name '.' -print -quit)
        log "Found nested directory: $nested_dir, entering..."
        cd "$nested_dir"
        log "Contents of nested directory:"
        ls -la >> "$LOG_FILE" 2>&1
    fi
    
    # Search for MLOS Core binary (can be named mlos_core or mlos-server)
    log "Searching for MLOS Core binary..."
    find . -type f \( -name "mlos_core" -o -name "mlos-server" \) >> "$LOG_FILE" 2>&1 || log "No MLOS binary found in archive"
    
    # Look for the pre-built binary
    local binary_path=""
    
    # Look for pre-built binary in various possible locations (try both names)
    if [ -f "mlos_core" ]; then
        binary_path="mlos_core"
        log "Found binary in current directory: mlos_core"
    elif [ -f "mlos-server" ]; then
        binary_path="mlos-server"
        log "Found binary in current directory: mlos-server"
    elif [ -f "bin/mlos_core" ]; then
        binary_path="bin/mlos_core"
        log "Found binary in bin/: mlos_core"
    elif [ -f "bin/mlos-server" ]; then
        binary_path="bin/mlos-server"
        log "Found binary in bin/: mlos-server"
    elif [ -f "build/mlos-server" ]; then
        binary_path="build/mlos-server"
        log "Found binary in build/: mlos-server"
    elif [ -f "build/mlos_core" ]; then
        binary_path="build/mlos_core"
        log "Found binary in build/: mlos_core"
    else
        # Search recursively for the binary (either name)
        binary_path=$(find . -type f \( -name "mlos_core" -o -name "mlos-server" \) -print -quit 2>/dev/null)
        if [ -n "$binary_path" ]; then
            log "Found binary via recursive search: $binary_path"
        fi
    fi
    
    if [ -n "$binary_path" ] && [ -f "$binary_path" ]; then
        log "✅ Found pre-built MLOS Core binary at: $binary_path"
        
        # Preserve original binary name (mlos_core, not mlos-server)
        local binary_basename=$(basename "$binary_path")
        mkdir -p build
        
        # Only copy if not already in build/ directory with correct name
        if [[ "$binary_path" == "build/"* ]] || [[ "$binary_path" == "./build/"* ]]; then
            log "Binary already in build/ directory: $binary_basename"
        else
            # Copy to build/ preserving original name
            cp "$binary_path" "build/$binary_basename"
            chmod +x "build/$binary_basename"
            log "Copied binary to build/$binary_basename"
        fi
        
        # Set the binary name for later use
        MLOS_CORE_BINARY="build/$binary_basename"
        
        # Verify the binary
        if [ -f "$MLOS_CORE_BINARY" ]; then
            log "✅ Binary ready at: $(pwd)/$MLOS_CORE_BINARY"
        else
            log_error "Failed to copy binary to build directory"
            exit 1
        fi
    else
        log_error "No pre-built binary found in release archive"
        log_error "Current directory: $(pwd)"
        log_error "Archive contents:"
        ls -laR | tee -a "$LOG_FILE"
        log_error ""
        log_error "This script only tests pre-built release binaries."
        log_error "Please ensure the release includes platform-specific binaries."
        exit 1
    fi
    
    local end_time=$(get_timestamp_ms)
    local download_time=$(measure_time $start_time $end_time)
    METRIC_core_download_time_ms=$download_time
    
    log "✅ MLOS Core downloaded and extracted (${download_time}ms)"
    
    # Save the current directory and binary name
    MLOS_CORE_DIR=$(pwd)
    log "MLOS Core directory: $MLOS_CORE_DIR"
    
    # Verify binary exists
    log "Checking for MLOS Core binary..."
    if [ -f "$MLOS_CORE_BINARY" ]; then
        METRIC_core_version=$CORE_RELEASE_VERSION
        log "✅ MLOS Core binary found: $(pwd)/$MLOS_CORE_BINARY"
        log "MLOS Core version: ${METRIC_core_version}"
        
        # Install to ~/.local/bin (preserve original name)
        local binary_name=$(basename "$MLOS_CORE_BINARY")
        log "Installing MLOS Core to ~/.local/bin/..."
        cp "$MLOS_CORE_BINARY" "$HOME/.local/bin/$binary_name"
        chmod +x "$HOME/.local/bin/$binary_name"
        log "✅ MLOS Core installed to ~/.local/bin/$binary_name"
    else
        log_error "MLOS Core binary not found at: $(pwd)/$MLOS_CORE_BINARY"
        log "Directory contents:"
        find . -name "mlos_core" -o -name "mlos-server" 2>/dev/null | tee -a "$LOG_FILE" || log "No binary found"
        ls -la build/ >> "$LOG_FILE" 2>&1 || log "Build directory doesn't exist"
        ls -la . >> "$LOG_FILE" 2>&1
        exit 1
    fi
    
    cd ..
}

install_models() {
    banner "📥 Installing Test Models with Axon"
    
    # Check if models are already installed from previous runs
    # NOTE: Axon stores models in ~/.axon/cache/models/ not ~/.axon/models/
    local existing_models=0
    for model_spec in "${TEST_MODELS[@]}"; do
        IFS=':' read -r model_id model_name model_type model_category <<< "$model_spec"
        # Correct path: ~/.axon/cache/models/{namespace}/{model}/{version}/model.onnx
        local model_path="$HOME/.axon/cache/models/${model_id%@*}/${model_id##*@}/model.onnx"
        if [ -f "$model_path" ]; then
            log "✅ Model already installed: $model_name at $model_path"
            ((existing_models++))
        fi
    done
    
    if [ $existing_models -eq ${#TEST_MODELS[@]} ]; then
        log "All ${#TEST_MODELS[@]} models already installed, skipping installation"
        METRIC_models_installed=$existing_models
        METRIC_total_model_install_time_ms=0
        return 0
    fi
    
    log "Installing models using Axon release binary..."
    
    # Check Docker availability
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed - Axon cannot convert to ONNX"
        return 1
    fi
    
    if ! docker ps >/dev/null 2>&1; then
        log_error "Docker daemon is not running - Axon cannot convert to ONNX"
        return 1
    fi
    
    # Test if we can actually run containers (user might not be in docker group)
    if ! docker run --rm hello-world >/dev/null 2>&1; then
        log_error "Cannot run Docker containers - user may need to be in docker group"
        log_error "Run: sudo usermod -aG docker $USER && newgrp docker"
        return 1
    fi
    log "✅ Docker available for ONNX conversion"
    
    # Verify converter image is actually usable
    if docker images | grep -q "axon-converter"; then
        log "Testing converter image with a simple command..."
        local converter_image=$(docker images | grep "axon-converter" | head -1 | awk '{print $1":"$2}')
        if [ -n "$converter_image" ]; then
            local test_output=$(docker run --rm "$converter_image" python -c "import torch; print('OK')" 2>&1)
            local test_exit=$?
            if [ $test_exit -eq 0 ]; then
                log "✅ Converter image is functional"
            else
                log_warn "⚠️  Converter image test failed (exit code: $test_exit)"
                log_warn "Test output: $test_output"
                log_warn "This may indicate Docker permission issues or image problems"
            fi
        fi
    fi
    
    # Pre-load Axon converter image for ONNX conversion
    log "Loading Axon converter image from release..."
    local OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    local ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        arm64|aarch64) ARCH="arm64" ;;
    esac
    
    local converter_artifact="axon-converter-${AXON_RELEASE_VERSION#v}-${OS}-${ARCH}.tar.gz"
    local converter_url="https://github.com/mlOS-foundation/axon/releases/download/${AXON_RELEASE_VERSION}/${converter_artifact}"
    
    # Check if image is already loaded
    if docker images | grep -q "axon-converter"; then
        log "✅ Converter image already loaded"
        # Verify it's tagged as :latest (Axon expects this)
        if ! docker images | grep -q "axon-converter.*latest"; then
            log "Tagging converter image as :latest for Axon compatibility..."
            local converter_image=$(docker images | grep "axon-converter" | head -1 | awk '{print $1":"$2}')
            if [ -n "$converter_image" ]; then
                docker tag "$converter_image" "ghcr.io/mlos-foundation/axon-converter:latest" 2>/dev/null || true
            fi
        fi
    else
        log "Downloading converter image: $converter_artifact"
        if curl -L -f -# -o "/tmp/$converter_artifact" "$converter_url" >> "$LOG_FILE" 2>&1; then
            log "Loading converter image into Docker..."
            if docker load -i "/tmp/$converter_artifact" >> "$LOG_FILE" 2>&1; then
                # Tag as :latest for Axon compatibility
                local version_tag="ghcr.io/mlos-foundation/axon-converter:${AXON_RELEASE_VERSION#v}"
                local latest_tag="ghcr.io/mlos-foundation/axon-converter:latest"
                docker tag "$version_tag" "$latest_tag" 2>/dev/null || true
                log "✅ Converter image loaded successfully"
                rm -f "/tmp/$converter_artifact"
            else
                log_warn "Failed to load converter image, Axon may try to pull it automatically"
            fi
        else
            log_warn "Failed to download converter image, Axon may try to pull it automatically"
        fi
    fi
    
    local total_start=$(get_timestamp_ms)
    local model_count=0
    
    for model_spec in "${TEST_MODELS[@]}"; do
        IFS=':' read -r model_id model_name model_type model_category <<< "$model_spec"
        
        log "Installing model: $model_id (name: $model_name, type: $model_type, category: ${model_category:-nlp})"
        
        local start_time=$(get_timestamp_ms)
        
        # Multimodal models now supported with multi-encoder architecture
        # CLIP and other multi-encoder models are handled via onnx_manifest.json
        
        # Clear model cache to force fresh installation with ONNX conversion
        # If model was previously installed in PyTorch format, we need to reinstall for ONNX
        local model_cache_dir="$HOME/.axon/cache/models/${model_id%@*}/${model_id##*@}"
        if [ -d "$model_cache_dir" ]; then
            # Check if ONNX model exists:
            # - Single model: model.onnx
            # - Multi-encoder (CLIP): onnx_manifest.json or onnx/ subdirectory with model.onnx
            # - Seq2seq (T5/BART): encoder_model.onnx + decoder_model.onnx
            local has_onnx=false
            if [ -f "$model_cache_dir/model.onnx" ]; then
                has_onnx=true
            elif [ -f "$model_cache_dir/onnx_manifest.json" ]; then
                has_onnx=true
            elif [ -f "$model_cache_dir/encoder_model.onnx" ] && [ -f "$model_cache_dir/decoder_model.onnx" ]; then
                has_onnx=true
            elif [ -d "$model_cache_dir/onnx" ] && [ -f "$model_cache_dir/onnx/encoder_model.onnx" ]; then
                has_onnx=true
            fi

            if [ "$has_onnx" = "false" ]; then
                log "Clearing cache for $model_id (no ONNX model found, forcing reinstall)..."
                rm -rf "$model_cache_dir"
            else
                log "ONNX model already exists, skipping reinstall"
            fi
        fi
        
        # Use the installed Axon release binary
        # Use timeout to prevent hanging (15 minutes max for model download + conversion)
        local axon_output=$(mktemp)
        local install_exit_code=0
        
        log "Running: axon install $model_id (timeout: 15 minutes)"
        
        # Create a sentinel file for progress indicator
        local sentinel_file=$(mktemp)
        echo "running" > "$sentinel_file"
        
        # Start progress indicator in background (shows every 60s to reduce log noise)
        (
            local count=0
            while [ $count -lt 15 ] && [ -f "$sentinel_file" ]; do  # 15 * 60s = 15 minutes max
                sleep 60
                # Check sentinel file still exists (deleted when install completes)
                if [ ! -f "$sentinel_file" ]; then
                    break
                fi
                count=$((count + 1))
                echo "⏳ Installing $model_name... ${count}m elapsed" >&2
            done
        ) &
        local progress_pid=$!
        
        # Run with timeout and filter output to reduce noise
        # First exclude noisy download progress, then only show important lines
        # This dramatically reduces GitHub Actions log size (prevents truncation)
        if run_with_timeout 900 "$HOME/.local/bin/axon" install "$model_id" 2>&1 | \
            tee "$axon_output" | \
            grep -v --line-buffered "Downloading\.\.\." | \
            grep -v --line-buffered "bytes)" | \
            grep -v --line-buffered "^[0-9]*\.[0-9]*%" | \
            grep -E --line-buffered "Propagating|Using|Package will|✓|✅|❌|⚠️|ERROR|Error|failed|SUCCESS|success|Converting|Docker|ONNX|Complete|Installed|already|Starting|Pulling|Layer" | \
            head -50; then
            install_exit_code=0
        else
            install_exit_code=$?
            # Check if it was a timeout (exit code 124 from timeout command)
            if [ $install_exit_code -eq 124 ]; then
                log_error "Axon install timed out after 15 minutes for $model_id"
                log_error "This usually means Docker conversion is stuck or very slow"
            else
                log_error "Axon install failed for $model_id (exit code: $install_exit_code)"
            fi
        fi
        
        # Stop progress indicator by removing sentinel file and killing process
        rm -f "$sentinel_file" 2>/dev/null || true
        kill $progress_pid 2>/dev/null || true
        wait $progress_pid 2>/dev/null || true
        
        # Always show output if model installation fails or model not found
        local end_time=$(get_timestamp_ms)
        local install_time=$(measure_time $start_time $end_time)
        
        # Verify the model was actually installed
        # Correct path: ~/.axon/cache/models/{namespace}/{model}/{version}/model.onnx
        # For multi-encoder models: ~/.axon/cache/models/{namespace}/{model}/{version}/onnx_manifest.json
        # For seq2seq models: encoder_model.onnx + decoder_model.onnx
        local model_dir="$HOME/.axon/cache/models/${model_id%@*}/${model_id##*@}"
        local model_path="$model_dir/model.onnx"
        local manifest_path="$model_dir/onnx_manifest.json"
        local encoder_path="$model_dir/encoder_model.onnx"
        local decoder_path="$model_dir/decoder_model.onnx"

        if [ -f "$model_path" ]; then
            log "✅ Model file verified at: $model_path"
            eval "METRIC_model_${model_name}_install_time_ms=$install_time"
            log "✅ Installed $model_name (${install_time}ms)"
            ((model_count++))
            rm -f "$axon_output"

            # Clean up unnecessary files to save disk space (keep only model.onnx)
            if [ -d "$model_dir" ]; then
                # Remove large weight files that are redundant after ONNX conversion
                rm -f "$model_dir/pytorch_model.bin" "$model_dir/tf_model.h5" "$model_dir/model.safetensors" 2>/dev/null || true
                rm -f "$model_dir/flax_model.msgpack" 2>/dev/null || true
            fi
        elif [ -f "$manifest_path" ]; then
            log "✅ Multi-encoder model manifest verified at: $manifest_path"
            eval "METRIC_model_${model_name}_install_time_ms=$install_time"
            log "✅ Installed $model_name (multi-encoder, ${install_time}ms)"
            ((model_count++))
            rm -f "$axon_output"
        elif [ -f "$encoder_path" ] && [ -f "$decoder_path" ]; then
            log "✅ Seq2seq model files verified at: $encoder_path, $decoder_path"
            eval "METRIC_model_${model_name}_install_time_ms=$install_time"
            log "✅ Installed $model_name (seq2seq, ${install_time}ms)"
            ((model_count++))
            rm -f "$axon_output"

            # Clean up unnecessary files to save disk space
            if [ -d "$model_dir" ]; then
                rm -f "$model_dir/pytorch_model.bin" "$model_dir/tf_model.h5" "$model_dir/model.safetensors" 2>/dev/null || true
                rm -f "$model_dir/flax_model.msgpack" 2>/dev/null || true
            fi
        elif [ -d "$model_dir/onnx" ] && [ -f "$model_dir/onnx/encoder_model.onnx" ]; then
            log "✅ Seq2seq model files verified at: $model_dir/onnx/"
            eval "METRIC_model_${model_name}_install_time_ms=$install_time"
            log "✅ Installed $model_name (seq2seq, ${install_time}ms)"
            ((model_count++))
            rm -f "$axon_output"
        else
            # Model not found - output was already shown in real-time, but summarize key issues
            log_warn "Model file not found at expected location: $model_path or $manifest_path"
            
            # Check for ONNX conversion issues in captured output
            if grep -qi "onnx\|conversion\|docker" "$axon_output" 2>/dev/null; then
                log_info "ONNX conversion related output (from captured log):"
                grep -i "onnx\|conversion\|docker\|error\|failed\|warning" "$axon_output" 2>/dev/null | head -20 | tee -a "$LOG_FILE" || true
            fi
            
            log "Searching in ~/.axon/cache/models/..."
            local found_model=$(find "$HOME/.axon/cache/models" -name "model.onnx" -path "*${model_id%%/*}*" 2>/dev/null | head -n 1)
            local found_manifest=$(find "$HOME/.axon/cache/models" -name "onnx_manifest.json" -path "*${model_id%%/*}*" 2>/dev/null | head -n 1)
            local found_encoder=$(find "$HOME/.axon/cache/models" -name "encoder_model.onnx" -path "*${model_id%%/*}*" 2>/dev/null | head -n 1)
            if [ -n "$found_model" ]; then
                log "✅ Found model at: $found_model"
                eval "METRIC_model_${model_name}_install_time_ms=$install_time"
                log "✅ Installed $model_name (${install_time}ms)"
                ((model_count++))
            elif [ -n "$found_manifest" ]; then
                log "✅ Found multi-encoder manifest at: $found_manifest"
                eval "METRIC_model_${model_name}_install_time_ms=$install_time"
                log "✅ Installed $model_name (multi-encoder, ${install_time}ms)"
                ((model_count++))
            elif [ -n "$found_encoder" ]; then
                log "✅ Found seq2seq encoder at: $found_encoder"
                eval "METRIC_model_${model_name}_install_time_ms=$install_time"
                log "✅ Installed $model_name (seq2seq, ${install_time}ms)"
                ((model_count++))
            else
                log_error "Model installation failed - file not found"
                log "Axon cache contents:"
                ls -la "$HOME/.axon/cache/models/" 2>&1 | tee -a "$LOG_FILE" || log "Cache directory doesn't exist"
                
                # Show what's actually in the model's cache directory
                local model_cache_dir="$HOME/.axon/cache/models/${model_id%@*}/${model_id##*@}"
                if [ -d "$model_cache_dir" ]; then
                    log "Contents of $model_cache_dir:"
                    ls -la "$model_cache_dir" 2>&1 | tee -a "$LOG_FILE" || true
                    log "Looking for .onnx files:"
                    find "$model_cache_dir" -name "*.onnx" 2>/dev/null | tee -a "$LOG_FILE" || log "No .onnx files found"
                fi
                
                eval "METRIC_model_${model_name}_install_status=failed"
            fi
            rm -f "$axon_output"
        fi
        
        if [ $install_exit_code -ne 0 ]; then
            log_error "Failed to install $model_id (exit code: $install_exit_code)"
            eval "METRIC_model_${model_name}_install_status=failed"
            rm -f "$axon_output"
        fi
    done
    
    local total_end=$(get_timestamp_ms)
    local total_time=$(measure_time $total_start $total_end)
    
    METRIC_total_model_install_time_ms=$total_time
    METRIC_models_installed=$model_count
    
    if [ $model_count -eq 0 ]; then
        log_error "No models installed - E2E test will be incomplete"
        return 1
    fi
    
    log "✅ Installed $model_count models (total: ${total_time}ms)"
}

start_mlos_core() {
    banner "🚀 Starting MLOS Core Server"
    
    cd "$MLOS_CORE_DIR"
    log "Using MLOS Core from: $(pwd)"
    
    # Ensure MLOS_CORE_BINARY is set (fallback to mlos_core)
    if [ -z "$MLOS_CORE_BINARY" ]; then
        if [ -f "build/mlos_core" ]; then
            MLOS_CORE_BINARY="build/mlos_core"
        elif [ -f "build/mlos-server" ]; then
            MLOS_CORE_BINARY="build/mlos-server"
        else
            log_error "MLOS Core binary not found"
            exit 1
        fi
    fi
    
    # Check if binary is valid (use absolute path to be sure)
    local abs_binary_path="$(pwd)/$MLOS_CORE_BINARY"
    if [ ! -f "$abs_binary_path" ]; then
        log_error "Binary not found at: $abs_binary_path"
        log_error "Current directory: $(pwd)"
        log_error "MLOS_CORE_BINARY: $MLOS_CORE_BINARY"
        log_error "Directory contents:"
        ls -la >> "$LOG_FILE" 2>&1
        exit 1
    fi
    if ! file "$MLOS_CORE_BINARY" >> "$LOG_FILE" 2>&1; then
        log_error "Binary file check failed"
        exit 1
    fi
    
    # Check binary dependencies (macOS)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        log "Checking binary dependencies..."
        otool -L "$MLOS_CORE_BINARY" >> "$LOG_FILE" 2>&1 || log_warn "Could not check dependencies"
    fi
    
    # Check if ONNX Runtime is needed and install it
    if [ ! -f "build/onnxruntime/lib/libonnxruntime.1.18.0.dylib" ] && [[ "$OSTYPE" == "darwin"* ]]; then
        log "ONNX Runtime not found, downloading..."
        
        # Detect architecture
        local onnx_arch
        case "$(uname -m)" in
            x86_64)
                onnx_arch="x86_64"
                ;;
            arm64)
                onnx_arch="arm64"
                ;;
            *)
                log_error "Unsupported architecture for ONNX Runtime"
                exit 1
                ;;
        esac
        
        local onnx_url="https://github.com/microsoft/onnxruntime/releases/download/v1.18.0/onnxruntime-osx-${onnx_arch}-1.18.0.tgz"
        log "Downloading ONNX Runtime from: $onnx_url"
        
        if curl -L -f -o build/onnxruntime.tgz "$onnx_url" >> "$LOG_FILE" 2>&1; then
            log "✅ Downloaded ONNX Runtime"
            
            # Extract to build directory
            cd build
            tar -xzf onnxruntime.tgz
            
            # Rename to expected directory structure
            if [ -d "onnxruntime-osx-${onnx_arch}-1.18.0" ]; then
                mv onnxruntime-osx-${onnx_arch}-1.18.0 onnxruntime
                log "✅ ONNX Runtime installed"
            else
                log_error "ONNX Runtime extraction failed"
                exit 1
            fi
            
            cd ..
        else
            log_error "Failed to download ONNX Runtime"
            exit 1
        fi
    elif [ ! -f "build/onnxruntime/lib/libonnxruntime.1.18.0.so" ] && [[ "$OSTYPE" == "linux"* ]]; then
        log "ONNX Runtime not found, downloading..."
        
        # For Linux
        local onnx_arch
        case "$(uname -m)" in
            x86_64)
                onnx_arch="x64"
                ;;
            aarch64)
                onnx_arch="aarch64"
                ;;
            *)
                log_error "Unsupported architecture for ONNX Runtime"
                exit 1
                ;;
        esac
        
        local onnx_url="https://github.com/microsoft/onnxruntime/releases/download/v1.18.0/onnxruntime-linux-${onnx_arch}-1.18.0.tgz"
        log "Downloading ONNX Runtime from: $onnx_url"
        
        if curl -L -f -o build/onnxruntime.tgz "$onnx_url" >> "$LOG_FILE" 2>&1; then
            log "✅ Downloaded ONNX Runtime"
            
            # Extract to build directory
            cd build
            tar -xzf onnxruntime.tgz
            
            # Rename to expected directory structure
            if [ -d "onnxruntime-linux-${onnx_arch}-1.18.0" ]; then
                mv onnxruntime-linux-${onnx_arch}-1.18.0 onnxruntime
                log "✅ ONNX Runtime installed"
            else
                log_error "ONNX Runtime extraction failed"
                exit 1
            fi
            
            cd ..
        else
            log_error "Failed to download ONNX Runtime"
            exit 1
        fi
    else
        log "ONNX Runtime already present"
    fi
    
    log "Starting MLOS Core server..."
    log "Using port 18080 (non-privileged, no sudo required)"
    
    # Start server in background
    local start_time=$(get_timestamp_ms)
    
    # Set LD_LIBRARY_PATH for Linux to find ONNX Runtime library
    local core_cmd="./$MLOS_CORE_BINARY --http-port 18080"
    if [[ "$OSTYPE" == "linux"* ]]; then
        local onnx_lib_dir="$(pwd)/build/onnxruntime/lib"
        if [ -d "$onnx_lib_dir" ]; then
            export LD_LIBRARY_PATH="$onnx_lib_dir:${LD_LIBRARY_PATH:-}"
            log "Set LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
        fi
    fi
    
    # Create log directory for Core output
    mkdir -p "$TEST_DIR/mlos-core-logs"
    local core_stdout="$TEST_DIR/mlos-core-logs/core-stdout.log"
    local core_stderr="$TEST_DIR/mlos-core-logs/core-stderr.log"
    
    $core_cmd >> "$core_stdout" 2>> "$core_stderr" &
    local pid=$!
    echo $pid > "$TEST_DIR/mlos.pid"
    
    log "MLOS Core server started (PID: $pid)"
    log "Core logs: stdout=$core_stdout, stderr=$core_stderr"
    
    # Wait for server to be ready
    log "Waiting for server to be ready..."
    local max_wait=30
    local waited=0
    
    while [ $waited -lt $max_wait ]; do
        # Check if process is still running
        if ! ps -p $pid > /dev/null 2>&1; then
            log_error "MLOS Core process died (PID: $pid)"
            log_error "Last 20 lines of stdout:"
            tail -20 "$core_stdout" 2>/dev/null | tee -a "$LOG_FILE" || log "No stdout log"
            log_error "Last 20 lines of stderr:"
            tail -20 "$core_stderr" 2>/dev/null | tee -a "$LOG_FILE" || log "No stderr log"
            cd ..
            return 1
        fi
        
        if curl -s http://127.0.0.1:18080/health > /dev/null 2>&1; then
            local end_time=$(get_timestamp_ms)
            local startup_time=$(measure_time $start_time $end_time)
            METRIC_core_startup_time_ms=$startup_time
            log "✅ MLOS Core ready (${startup_time}ms)"
            
            # Monitor MLOS Core resource usage (idle state)
            log "Monitoring MLOS Core resource usage (idle)..."
            local binary_name=$(basename "$MLOS_CORE_BINARY")
            local mlos_resources=$(monitor_process_resources "$binary_name" 3 "$TEST_DIR/mlos_resources_idle.txt")
            if [ -f "$TEST_DIR/mlos_resources_idle.txt" ]; then
                source "$TEST_DIR/mlos_resources_idle.txt"
                METRIC_core_idle_cpu_avg=$avg_cpu
                METRIC_core_idle_mem_mb=$avg_mem
                log "📊 Core idle: CPU=${avg_cpu}%, Memory=${avg_mem}MB"
            fi
            
            cd ..
            return 0
        fi
        sleep 1
        ((waited++))
    done
    
    log_error "MLOS Core failed to start within ${max_wait}s"
    if ps -p $pid > /dev/null 2>&1; then
        log_error "Process is still running but not responding"
    else
        log_error "Process is not running"
    fi
    log_error "Last 20 lines of log:"
    tail -20 "$LOG_FILE" | tee -a "$LOG_FILE"
    cd ..
    return 1
}

register_models() {
    banner "📝 Registering Models with MLOS Core"
    
    # Check if any models were installed
    if [ "${METRIC_models_installed:-0}" -eq 0 ]; then
        log_error "No models available to register"
        log_error "Skipping model registration and inference tests"
        return 1
    fi
    
    # Ensure Core is running
    if ! curl -s http://127.0.0.1:18080/health > /dev/null 2>&1; then
        log_error "MLOS Core is not running - cannot register models"
        return 1
    fi
    
    local model_count=0
    
    for model_spec in "${TEST_MODELS[@]}"; do
        IFS=':' read -r model_id model_name model_type model_category <<< "$model_spec"
        
        # Verify model was installed (ONNX file exists)
        local model_path="$HOME/.axon/cache/models/${model_id%@*}/${model_id##*@}/model.onnx"
        
        if [ ! -f "$model_path" ]; then
            log_warn "Model file not found at: $model_path, searching..."
            if [ -d "$HOME/.axon/cache/models" ]; then
                model_path=$(find "$HOME/.axon/cache/models" -name "model.onnx" -path "*${model_id%%/*}*" -print -quit 2>/dev/null)
            fi
        fi
        
        if [ -z "$model_path" ] || [ ! -f "$model_path" ]; then
            log_warn "Could not find ONNX model for $model_name - skipping registration"
            eval "METRIC_model_${model_name}_register_status=failed"
            continue
        fi
        
        # Check manifest execution_format (should be "onnx" if model.onnx exists)
        local model_dir="$HOME/.axon/cache/models/${model_id%@*}/${model_id##*@}"
        local manifest_path="$model_dir/manifest.yaml"
        if [ -f "$manifest_path" ]; then
            # Check if execution_format is set to "onnx"
            if command -v yq &> /dev/null; then
                local exec_format=$(yq '.spec.format.execution_format' "$manifest_path" 2>/dev/null)
                if [ "$exec_format" != "onnx" ] && [ "$exec_format" != "ONNX" ]; then
                    log_warn "Manifest execution_format is '$exec_format' but model.onnx exists"
                    log_warn "Core may show framework as PyTorch but will use ONNX Runtime (this is expected)"
                fi
            elif grep -q "execution_format.*onnx" "$manifest_path" 2>/dev/null; then
                log "✅ Manifest execution_format is set to onnx"
            else
                log_warn "Could not verify manifest execution_format (yq not installed)"
            fi
            # Note: Core reads framework.name from manifest (original framework), but correctly
            # auto-selects ONNX Runtime plugin when model.onnx exists. The framework field is
            # just metadata - Core's plugin selection is based on available model files.
            log_info "Note: Core may show 'framework: PyTorch' in logs, but will use ONNX Runtime (model.onnx detected)"
        fi
        
        log "Registering $model_name using axon register..."
        
        local start_time=$(get_timestamp_ms)
        
        # Use axon register command (proper flow: install -> register -> inference)
        # axon register uses MLOS_CORE_ENDPOINT environment variable (not a flag)
        local register_output=$(mktemp)
        local register_errors=$(mktemp)
        
        if MLOS_CORE_ENDPOINT="http://127.0.0.1:18080" "$HOME/.local/bin/axon" register "$model_id" > "$register_output" 2> "$register_errors"; then
            local register_exit_code=0
        else
            local register_exit_code=$?
        fi
        
        local end_time=$(get_timestamp_ms)
        local register_time=$(measure_time $start_time $end_time)
        
        if [ $register_exit_code -eq 0 ]; then
            eval "METRIC_model_${model_name}_register_time_ms=$register_time"
            eval "METRIC_model_${model_name}_register_status=success"
            log "✅ Registered $model_name (${register_time}ms)"
            ((model_count++))
        else
            log_error "Failed to register $model_name (exit code: $register_exit_code)"
            log_error "Axon register stderr:"
            cat "$register_errors" | tee -a "$LOG_FILE"
            if [ -s "$register_output" ]; then
                log_error "Axon register stdout:"
                cat "$register_output" | tee -a "$LOG_FILE"
            fi
            eval "METRIC_model_${model_name}_register_status=failed"
        fi
        
        rm -f "$register_output" "$register_errors"
    done
    
    METRIC_models_registered=$model_count
    log "✅ Registered $model_count models"
}

# Generate test input for a model based on its type and category
# Uses config/test-inputs.yaml for configuration when available
get_test_input() {
    local model_name=$1
    local model_type=$2
    local model_category=$3
    local size=${4:-small}  # small, medium, large
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local generator="$script_dir/generate-test-input.py"
    
    # Try to use the configurable generator first
    if [ -f "$generator" ]; then
        local result=$(python3 "$generator" "$model_name" "$size" 2>/dev/null)
        if [ -n "$result" ] && [ "$result" != "{}" ]; then
            echo "$result"
            return 0
        fi
    fi
    
    # Fallback to inline generation if generator fails
    case "$model_category" in
        nlp)
            case "$model_name" in
                gpt2)
                    # Fallback GPT2 input - only input_ids (ONNX model has single input)
                    local max_len=16
                    [ "$size" = "medium" ] && max_len=64
                    [ "$size" = "large" ] && max_len=128
                    python3 -c "
import json
# GPT2 token IDs: 15496='Hello', 11=',', 314='I', 716='am', etc.
ids = [15496, 11, 314, 716, 257, 3303] + [2746] * ($max_len - 6)
print(json.dumps({'input_ids': ids[:$max_len]}))
"
                    ;;
                bert)
                    # Fallback BERT input - requires 3 inputs
                    local max_len=16
                    [ "$size" = "medium" ] && max_len=64
                    [ "$size" = "large" ] && max_len=128
                    python3 -c "
import json
# BERT tokens: 101=[CLS], 7592='hello', 102=[SEP]
ids = [101] + [7592] * ($max_len - 2) + [102]
mask = [1] * $max_len
types = [0] * $max_len
print(json.dumps({'input_ids': ids, 'attention_mask': mask, 'token_type_ids': types}))
"
                    ;;
                roberta)
                    # Fallback RoBERTa input - only input_ids (ONNX model has single input)
                    local max_len=16
                    [ "$size" = "medium" ] && max_len=64
                    [ "$size" = "large" ] && max_len=128
                    python3 -c "
import json
# RoBERTa tokens: 0=<s>, 31414='hello', 2=</s>
ids = [0] + [31414] * ($max_len - 2) + [2]
print(json.dumps({'input_ids': ids}))
"
                    ;;
                t5)
                    if [ "$size" = "large" ]; then
                        echo '{"input_ids": [8774, 6, 26, 21, 408, 8612, 2495, 5, 1], "decoder_input_ids": [0, 8774, 6, 26, 21, 408, 8612, 2495, 5, 1]}'
                    else
                        echo '{"input_ids": [8774, 6, 26, 21, 408, 8612, 2495, 5, 1], "decoder_input_ids": [0, 8774, 6, 26, 21, 408, 8612, 2495, 5, 1]}'
                    fi
                    ;;
                *)
                    echo '{"input_ids": [101, 7592, 102]}'
                    ;;
            esac
            ;;
        vision)
            # Vision models need image tensor (batch, channels, height, width)
            # ResNet/VGG/ViT expect (1, 3, 224, 224) normalized images
            # Core expects flat JSON format: {"pixel_values": [data...]}
            case "$model_name" in
                resnet|vgg|vit|alexnet|convnext|mobilenet|deit)
                    # Generate image tensor for validation
                    # Using 224x224 (standard ImageNet size) - Core v3.2.1+ supports large payloads
                    local img_size=224
                    # Generate pixel data using Python - flat format for Core
                    local pixel_data=$(python3 -c "
import random
import json
random.seed(42)  # Reproducible
batch = 1
channels = 3
height = $img_size
width = $img_size
# Generate normalized random values (ImageNet normalization range)
data = [random.gauss(0, 1) for _ in range(batch * channels * height * width)]
# Core expects flat JSON: {\"tensor_name\": [data...]}
print(json.dumps({'pixel_values': data}))
")
                    echo "$pixel_data"
                    ;;
                *)
                    # Generic vision model - flat format for Core
                    local pixel_data=$(python3 -c "
import random
import json
random.seed(42)
data = [random.gauss(0, 1) for _ in range(1 * 3 * 224 * 224)]
print(json.dumps({'pixel_values': data}))
")
                    echo "$pixel_data"
                    ;;
            esac
            ;;
        multimodal)
            # Multi-modal models (CLIP, etc.) - use Python generator
            case "$model_name" in
                clip)
                    # CLIP: text (input_ids, attention_mask) + image (pixel_values)
                    local text_len=77
                    local img_size=224
                    python3 -c "
import random
import json
random.seed(42)
# CLIP text: 49406 = <|startoftext|>, 49407 = <|endoftext|>
text_ids = [49406] + [320] * ($text_len - 2) + [49407]
text_mask = [1] * $text_len
# CLIP image: normalized pixel values (mean=0, std=1) - flat array
pixel_data = [random.gauss(0, 1) for _ in range(1 * 3 * $img_size * $img_size)]
print(json.dumps({'input_ids': text_ids, 'attention_mask': text_mask, 'pixel_values': pixel_data}))
"
                    ;;
                *)
                    # Other multimodal models - mark as not tested for now
                    echo ""
                    ;;
            esac
            ;;
        *)
            echo '{"input_ids": [101, 7592, 102]}'
            ;;
    esac
}

# URL-encode a string for use in URL path
url_encode() {
    local string="$1"
    local encoded=""
    local i=0
    while [ $i -lt ${#string} ]; do
        local char="${string:$i:1}"
        case "$char" in
            [a-zA-Z0-9._-])
                encoded="${encoded}${char}"
                ;;
            /)
                encoded="${encoded}%2F"
                ;;
            @)
                encoded="${encoded}%40"
                ;;
            *)
                # URL encode other special characters
                encoded="${encoded}$(printf '%%%02X' "'$char")"
                ;;
        esac
        i=$((i + 1))
    done
    echo "$encoded"
}

run_inference_tests() {
    banner "🧪 Running Inference Tests"
    
    local total_inferences=0
    local successful_inferences=0
    
    # Test all registered models
    for model_spec in "${TEST_MODELS[@]}"; do
        IFS=':' read -r model_id model_name model_type model_category <<< "$model_spec"
        model_category=${model_category:-nlp}  # Default to nlp if not specified
        
        # Check if model was registered
        eval "register_status=\${METRIC_model_${model_name}_register_status:-unknown}"
        if [ "$register_status" != "success" ]; then
            log_warn "Skipping inference test for $model_name (not registered)"
            eval "METRIC_model_${model_name}_inference_status=not_registered"
            continue
        fi
        
        # Multimodal models now supported via generate-test-input.py
        # CLIP: text + image input, Wav2Vec2: audio input
        
        # URL-encode the full model_id for use in the URL path
        # Core stores models with the full model_id (e.g., "hf/distilgpt2@latest")
        local encoded_model_id=$(url_encode "$model_id")
        
        # Test small inference
        log "Testing $model_name inference (small request) [model_id: $model_id]..."
        local test_input=$(get_test_input "$model_name" "$model_type" "$model_category" "small")
        
        if [ -z "$test_input" ]; then
            log_warn "No test input available for $model_name"
            eval "METRIC_model_${model_name}_inference_status=ready_not_tested"
            continue
        fi
        
        local start_time=$(get_timestamp_ms)
        # Write input to temp file to avoid "Argument list too long" for large inputs (images)
        local tmp_input="/tmp/inference_input_$$.json"
        echo "$test_input" > "$tmp_input"
        local response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:18080/models/${encoded_model_id}/inference" \
            -H "Content-Type: application/json" \
            -d "@$tmp_input")
        rm -f "$tmp_input"
        
        local http_code=$(echo "$response" | tail -n 1)
        local body=$(echo "$response" | sed '$d')
        local end_time=$(get_timestamp_ms)
        local inference_time=$(measure_time $start_time $end_time)
        
        # Immediately check if Core is still running
        local core_pid=""
        if [ -f "$TEST_DIR/mlos.pid" ]; then
            core_pid=$(cat "$TEST_DIR/mlos.pid" 2>/dev/null)
        fi
        
        ((total_inferences++))
        
        if [ "$http_code" = "200" ]; then
            eval "METRIC_model_${model_name}_inference_time_ms=$inference_time"
            eval "METRIC_model_${model_name}_inference_status=success"
            log "✅ $model_name inference successful (${inference_time}ms)"
            ((successful_inferences++))
            
            # Test large inference for NLP models (except T5 which has different structure)
            if [ "$model_category" = "nlp" ] && [ "$model_name" != "t5" ]; then
                log "Testing $model_name with large inference request (128 tokens)..."
                local large_input=$(get_test_input "$model_name" "$model_type" "$model_category" "large")
                
                local start_time_large=$(get_timestamp_ms)
                # Write input to temp file to avoid "Argument list too long"
                local tmp_large_input="/tmp/inference_large_input_$$.json"
                echo "$large_input" > "$tmp_large_input"
                local response_large=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:18080/models/${encoded_model_id}/inference" \
                    -H "Content-Type: application/json" \
                    -d "@$tmp_large_input")
                rm -f "$tmp_large_input"
                
                local http_code_large=$(echo "$response_large" | tail -n 1)
                local end_time_large=$(get_timestamp_ms)
                local inference_time_large=$(measure_time $start_time_large $end_time_large)
                
                ((total_inferences++))
                
                if [ "$http_code_large" = "200" ]; then
                    eval "METRIC_model_${model_name}_large_inference_time_ms=$inference_time_large"
                    eval "METRIC_model_${model_name}_large_inference_status=success"
                    log "✅ $model_name large inference successful (${inference_time_large}ms)"
                    ((successful_inferences++))
                else
                    log_error "$model_name large inference failed (HTTP $http_code_large)"
                    eval "METRIC_model_${model_name}_large_inference_status=failed"
                fi
            fi
        else
            log_error "$model_name inference failed (HTTP $http_code)"
            log_error "Response: $body"
            eval "METRIC_model_${model_name}_inference_status=failed"
            
            # Check if Core crashed (segmentation fault or process died)
            if [ -n "$core_pid" ] && ! ps -p "$core_pid" > /dev/null 2>&1; then
                    log_error "⚠️  MLOS Core process crashed (PID: $core_pid)"
                    log_error "Displaying Core logs for debugging:"
                    
                    local core_stdout="$TEST_DIR/mlos-core-logs/core-stdout.log"
                    local core_stderr="$TEST_DIR/mlos-core-logs/core-stderr.log"
                    
                    if [ -f "$core_stderr" ]; then
                        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                        log_error "Core stderr (last 50 lines):"
                        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                        tail -50 "$core_stderr" 2>/dev/null | while IFS= read -r line; do
                            log_error "   $line"
                        done || log "Could not read stderr log"
                    fi
                    
                    if [ -f "$core_stdout" ]; then
                        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                        log_error "Core stdout (last 50 lines):"
                        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                        tail -50 "$core_stdout" 2>/dev/null | while IFS= read -r line; do
                            log_error "   $line"
                        done || log "Could not read stdout log"
                    fi
                    
                    # Check for segmentation fault in stderr
                    if [ -f "$core_stderr" ] && grep -qi "segmentation fault\|segfault\|SIGSEGV" "$core_stderr" 2>/dev/null; then
                        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                        log_error "❌ SEGMENTATION FAULT DETECTED"
                        log_error "This is a Core server bug on Linux. Check Core logs above for details."
                        log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    fi
                fi
        fi
    done
    
    METRIC_total_inferences=$total_inferences
    METRIC_successful_inferences=$successful_inferences
    
    # Monitor resource usage during inference (if MLOS Core is still running)
    if [ -f "$TEST_DIR/mlos.pid" ]; then
        local mlos_pid=$(cat "$TEST_DIR/mlos.pid" 2>/dev/null)
        if ps -p "$mlos_pid" > /dev/null 2>&1; then
            log "Monitoring MLOS Core resource usage (under load)..."
            local binary_name=$(basename "$MLOS_CORE_BINARY")
            local mlos_resources=$(monitor_process_resources "$binary_name" 5 "$TEST_DIR/mlos_resources_load.txt")
            if [ -f "$TEST_DIR/mlos_resources_load.txt" ]; then
                source "$TEST_DIR/mlos_resources_load.txt"
                METRIC_core_load_cpu_max=$max_cpu
                METRIC_core_load_cpu_avg=$avg_cpu
                METRIC_core_load_mem_max=$max_mem
                METRIC_core_load_mem_avg=$avg_mem
                log "📊 Core load: CPU=${avg_cpu}% (max:${max_cpu}%), Memory=${avg_mem}MB (max:${max_mem}MB)"
            fi
        fi
    fi
    
    # Monitor Axon processes if any are running
    local axon_pids=$(pgrep -f "axon" 2>/dev/null)
    if [ -n "$axon_pids" ]; then
        log "Monitoring Axon resource usage..."
        local axon_resources=$(monitor_process_resources "axon" 3 "$TEST_DIR/axon_resources.txt")
        if [ -f "$TEST_DIR/axon_resources.txt" ]; then
            source "$TEST_DIR/axon_resources.txt"
            METRIC_axon_cpu_avg=$avg_cpu
            METRIC_axon_mem_mb=$avg_mem
        fi
    fi
    
    log "✅ Completed $successful_inferences/$total_inferences inference tests"
}

generate_html_report() {
    banner "📊 Generating HTML Report"
    
    local end_time=$(date +%s)
    METRIC_end_time=$end_time
    METRIC_total_duration_seconds=$((end_time - ${METRIC_start_time}))
    
    # Calculate success rate
    local success_rate=0
    if [ "${METRIC_total_inferences:-0}" -gt 0 ]; then
        success_rate=$(awk "BEGIN {printf \"%.1f\", (${METRIC_successful_inferences:-0} * 100.0 / ${METRIC_total_inferences})}")
    fi
    
    # Build dynamic inference data for charts and metrics
    local inference_labels="[]"
    local inference_data="[]"
    local inference_colors="[]"
    local inference_metrics_html=""
    local total_inference_time=0
    local total_register_time=0
    
    for model_spec in "${TEST_MODELS[@]}"; do
        IFS=':' read -r model_id model_name model_type model_category <<< "$model_spec"
        model_category=${model_category:-nlp}
        
        # Skip vision and multimodal for inference display
        if [ "$model_category" = "vision" ] || [ "$model_category" = "multimodal" ]; then
            continue
        fi
        
        # Check small inference
        eval "inference_time=\${METRIC_model_${model_name}_inference_time_ms:-0}"
        eval "inference_status=\${METRIC_model_${model_name}_inference_status:-failed}"
        
        if [ "$inference_time" != "0" ] && [ "$inference_time" != "N/A" ] && [ -n "$inference_time" ]; then
            # Add to chart data - format display name nicely
            local display_name=""
            case "$model_name" in
                gpt2) display_name="GPT-2" ;;
                bert) display_name="BERT" ;;
                roberta) display_name="RoBERTa" ;;
                t5) display_name="T5" ;;
                *) display_name=$(echo "$model_name" | awk '{print toupper(substr($0,1,1)) substr($0,2)}') ;;
            esac
            
            if [ "$inference_labels" = "[]" ]; then
                inference_labels="[\"${display_name} (small)\"]"
                inference_data="[$inference_time]"
                inference_colors="[\"rgba(102, 126, 234, 0.8)\"]"
            else
                inference_labels=$(echo "$inference_labels" | sed "s/]$/,\"${display_name} (small)\"]/")
                inference_data=$(echo "$inference_data" | sed "s/]/,$inference_time]/")
                inference_colors=$(echo "$inference_colors" | sed "s/]/,\"rgba(102, 126, 234, 0.8)\"]/")
            fi
            
            # Add to metrics HTML (display_name already set above)
            local status_class="success"
            local status_text="✅ Success"
            if [ "$inference_status" != "success" ]; then
                status_class="failed"
                status_text="❌ Failed"
            fi
            inference_metrics_html="${inference_metrics_html}
                    <div class=\"metric-card $status_class\">
                        <h4>${display_name} (small)</h4>
                        <div class=\"metric-value\">${inference_time} ms</div>
                        <span class=\"status-badge $status_class\">$status_text</span>
                    </div>"
            
            total_inference_time=$((total_inference_time + inference_time))
        fi
        
        # Check large inference
        eval "large_inference_time=\${METRIC_model_${model_name}_large_inference_time_ms:-0}"
        eval "large_inference_status=\${METRIC_model_${model_name}_large_inference_status:-failed}"
        
        if [ "$large_inference_time" != "0" ] && [ "$large_inference_time" != "N/A" ] && [ -n "$large_inference_time" ]; then
            # Format display name nicely (same as small inference)
            local display_name=""
            case "$model_name" in
                gpt2) display_name="GPT-2" ;;
                bert) display_name="BERT" ;;
                roberta) display_name="RoBERTa" ;;
                t5) display_name="T5" ;;
                *) display_name=$(echo "$model_name" | awk '{print toupper(substr($0,1,1)) substr($0,2)}') ;;
            esac
            
            if [ "$inference_labels" = "[]" ]; then
                inference_labels="[\"${display_name} (large)\"]"
                inference_data="[$large_inference_time]"
                inference_colors="[\"rgba(240, 147, 251, 0.8)\"]"
            else
                inference_labels=$(echo "$inference_labels" | sed "s/]$/,\"${display_name} (large)\"]/")
                inference_data=$(echo "$inference_data" | sed "s/]/,$large_inference_time]/")
                inference_colors=$(echo "$inference_colors" | sed "s/]/,\"rgba(240, 147, 251, 0.8)\"]/")
            fi
            
            local status_class="success"
            local status_text="✅ Success"
            if [ "$large_inference_status" != "success" ]; then
                status_class="failed"
                status_text="❌ Failed"
            fi
            inference_metrics_html="${inference_metrics_html}
                    <div class=\"metric-card $status_class\">
                        <h4>${display_name} (large)</h4>
                        <div class=\"metric-value\">${large_inference_time} ms</div>
                        <span class=\"status-badge $status_class\">$status_text</span>
                    </div>"
            
            total_inference_time=$((total_inference_time + large_inference_time))
        fi
        
        # Add register time
        eval "register_time=\${METRIC_model_${model_name}_register_time_ms:-0}"
        if [ "$register_time" != "0" ] && [ "$register_time" != "N/A" ] && [ -n "$register_time" ]; then
            total_register_time=$((total_register_time + register_time))
        fi
    done
    
    # Store for later use
    INFERENCE_LABELS_JSON="$inference_labels"
    INFERENCE_DATA_JSON="$inference_data"
    INFERENCE_COLORS_JSON="$inference_colors"
    INFERENCE_METRICS_HTML_CONTENT="$inference_metrics_html"
    METRIC_total_inference_time_ms=$total_inference_time
    METRIC_total_register_time_ms=$total_register_time
    
    log "Generating HTML report: $REPORT_FILE"
    
    # Disable exit on error for report generation (sed/python may have issues)
    set +e
    
    cat > "$REPORT_FILE" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MLOS Release E2E Validation Report</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        
        .container {
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            border-radius: 20px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            overflow: hidden;
        }
        
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 40px;
            text-align: center;
        }
        
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            font-weight: 700;
        }
        
        .header p {
            font-size: 1.2em;
            opacity: 0.9;
        }
        
        .summary {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            padding: 40px;
            background: #f8f9fa;
        }
        
        .summary-card {
            background: white;
            padding: 30px;
            border-radius: 15px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            transition: transform 0.3s ease, box-shadow 0.3s ease;
        }
        
        .summary-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 8px 12px rgba(0,0,0,0.15);
        }
        
        .summary-card h3 {
            color: #666;
            font-size: 0.9em;
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-bottom: 10px;
        }
        
        .summary-card .value {
            font-size: 2.5em;
            font-weight: 700;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }
        
        .summary-card .unit {
            font-size: 0.8em;
            color: #999;
            margin-left: 5px;
        }
        
        .summary-card.success .value {
            background: linear-gradient(135deg, #11998e 0%, #38ef7d 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        
        .summary-card.warning .value {
            background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        
        .content {
            padding: 40px;
        }
        
        .section {
            margin-bottom: 40px;
        }
        
        .section h2 {
            font-size: 1.8em;
            margin-bottom: 20px;
            color: #333;
            border-bottom: 3px solid #667eea;
            padding-bottom: 10px;
        }
        
        .chart-container {
            background: white;
            padding: 30px;
            border-radius: 15px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            margin-bottom: 30px;
            height: 400px;
            position: relative;
        }
        
        .metrics-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
        }
        
        .metric-card {
            background: #f8f9fa;
            padding: 20px;
            border-radius: 10px;
            border-left: 4px solid #667eea;
        }
        
        .metric-card h4 {
            color: #666;
            font-size: 0.9em;
            margin-bottom: 8px;
            text-transform: uppercase;
        }
        
        .metric-card .metric-value {
            font-size: 1.5em;
            font-weight: 600;
            color: #333;
        }
        
        .metric-card.success {
            border-left-color: #38ef7d;
        }
        
        .metric-card.error {
            border-left-color: #f5576c;
        }
        
        .status-badge {
            display: inline-block;
            padding: 5px 15px;
            border-radius: 20px;
            font-size: 0.85em;
            font-weight: 600;
            text-transform: uppercase;
        }
        
        .status-badge.success {
            background: #d4edda;
            color: #155724;
        }
        
        .status-badge.failed {
            background: #f8d7da;
            color: #721c24;
        }
        
        .footer {
            background: #2d3748;
            color: white;
            padding: 30px 40px;
            text-align: center;
        }
        
        .footer p {
            opacity: 0.8;
            margin: 5px 0;
        }
        
        @media print {
            body {
                background: white;
                padding: 0;
            }
            
            .container {
                box-shadow: none;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 MLOS Release E2E Validation</h1>
            <p>Comprehensive testing of Axon and MLOS Core releases</p>
        </div>
        
        <div class="summary">
            <div class="summary-card success">
                <h3>Overall Status</h3>
                <div class="value">SUCCESS_RATE%</div>
            </div>
            <div class="summary-card">
                <h3>Total Duration</h3>
                <div class="value">TOTAL_DURATION<span class="unit">s</span></div>
            </div>
            <div class="summary-card">
                <h3>Inferences</h3>
                <div class="value">SUCCESSFUL_INFERENCES/TOTAL_INFERENCES</div>
            </div>
            <div class="summary-card">
                <h3>Models Tested</h3>
                <div class="value">MODELS_INSTALLED</div>
            </div>
        </div>
        
        <div class="content">
            <!-- Release Versions -->
            <div class="section">
                <h2>📦 Release Versions</h2>
                <div class="metrics-grid">
                    <div class="metric-card">
                        <h4>Axon Version</h4>
                        <div class="metric-value">AXON_VERSION</div>
                    </div>
                    <div class="metric-card">
                        <h4>MLOS Core Version</h4>
                        <div class="metric-value">CORE_VERSION</div>
                    </div>
                </div>
            </div>
            
            <!-- Hardware Specifications -->
            <div class="section">
                <h2>💻 Hardware Specifications</h2>
                <div class="metrics-grid">
                    <div class="metric-card">
                        <h4>Operating System</h4>
                        <div class="metric-value">HW_OS HW_OS_VERSION</div>
                        <div style="font-size: 0.9em; color: #666; margin-top: 5px;">Architecture: HW_ARCH</div>
                    </div>
                    <div class="metric-card">
                        <h4>CPU</h4>
                        <div class="metric-value" style="font-size: 1.2em;">HW_CPU_MODEL</div>
                        <div style="font-size: 0.9em; color: #666; margin-top: 5px;">
                            Cores: HW_CPU_CORES | Threads: HW_CPU_THREADS
                        </div>
                    </div>
                    <div class="metric-card">
                        <h4>Memory</h4>
                        <div class="metric-value">HW_RAM_TOTAL GB</div>
                    </div>
                    <div class="metric-card">
                        <h4>GPU</h4>
                        <div class="metric-value" style="font-size: 1.2em;">HW_GPU_MODEL</div>
                        <div style="font-size: 0.9em; color: #666; margin-top: 5px;">
                            Count: HW_GPU_COUNT | Memory: HW_GPU_MEMORY
                        </div>
                    </div>
                    <div class="metric-card">
                        <h4>Disk</h4>
                        <div class="metric-value">HW_DISK_TOTAL</div>
                        <div style="font-size: 0.9em; color: #666; margin-top: 5px;">Available: HW_DISK_AVAILABLE</div>
                    </div>
                </div>
            </div>
            
            <!-- Resource Usage -->
            <div class="section">
                <h2>📊 Resource Usage</h2>
                <div class="metrics-grid">
                    <div class="metric-card" style="border-left-color: #667eea;">
                        <h4>MLOS Core (Idle)</h4>
                        <div class="metric-value" style="font-size: 1.2em;">
                            CPU: CORE_IDLE_CPU_AVG% | Memory: CORE_IDLE_MEM_MB MB
                        </div>
                    </div>
                    <div class="metric-card" style="border-left-color: #f5576c;">
                        <h4>MLOS Core (Under Load)</h4>
                        <div class="metric-value" style="font-size: 1.2em;">
                            CPU: CORE_LOAD_CPU_AVG% (max: CORE_LOAD_CPU_MAX%)
                        </div>
                        <div style="font-size: 0.9em; color: #666; margin-top: 5px;">
                            Memory: CORE_LOAD_MEM_AVG MB (max: CORE_LOAD_MEM_MAX MB)
                        </div>
                    </div>
                    <div class="metric-card" style="border-left-color: #38ef7d;">
                        <h4>Axon</h4>
                        <div class="metric-value" style="font-size: 1.2em;">
                            CPU: AXON_CPU_AVG% | Memory: AXON_MEM_MB MB
                        </div>
                    </div>
                </div>
                <div style="margin-top: 20px; padding: 15px; background: #f8f9fa; border-radius: 10px;">
                    <h4 style="margin-top: 0; color: #666;">Resource Type</h4>
                    <div style="font-size: 0.95em; color: #333;">
                        <strong>CPU:</strong> Used for model inference execution, ONNX Runtime operations, and HTTP request handling.<br>
                        <strong>Memory:</strong> Used for model loading, input/output tensor buffers, and ONNX Runtime workspace.<br>
                        <strong>GPU:</strong> HW_GPU_STATUS
                    </div>
                </div>
            </div>
            
            <!-- Installation Metrics -->
            <div class="section">
                <h2>⏱️ Installation & Setup Times</h2>
                <div class="chart-container">
                    <canvas id="installationChart"></canvas>
                </div>
                <div class="metrics-grid">
                    <div class="metric-card">
                        <h4>Axon Download Time</h4>
                        <div class="metric-value">AXON_DOWNLOAD_TIME ms</div>
                    </div>
                    <div class="metric-card">
                        <h4>Core Download Time</h4>
                        <div class="metric-value">CORE_DOWNLOAD_TIME ms</div>
                    </div>
                    <div class="metric-card">
                        <h4>Core Startup Time</h4>
                        <div class="metric-value">CORE_STARTUP_TIME ms</div>
                    </div>
                    <div class="metric-card">
                        <h4>Total Model Install Time</h4>
                        <div class="metric-value">TOTAL_MODEL_INSTALL_TIME ms</div>
                    </div>
                </div>
            </div>
            
            <!-- Inference Performance -->
            <div class="section">
                <h2>🚀 Inference Performance</h2>
                <div class="chart-container">
                    <canvas id="inferenceChart"></canvas>
                </div>
                <div class="metrics-grid" id="inferenceMetricsGrid">
                    INFERENCE_METRICS_HTML
                </div>
            </div>
            
            <!-- Model Categories -->
            <div class="section">
                <h2>🤖 Model Support by Category</h2>
                <div class="metrics-grid" style="grid-template-columns: repeat(3, 1fr); gap: 20px;">
                    <!-- NLP Models Card -->
                    <div class="metric-card" style="border-left: 4px solid #56EF7D;">
                        <h3 style="margin-top: 0;">😊 NLP Models</h3>
                        <ul style="list-style: none; padding: 0; text-align: left;">
                            <li style="margin: 8px 0;"><span class="status-badge GPT2_STATUS_CLASS" style="font-size: 0.8em;">GPT2_STATUS</span> GPT-2</li>
                            <li style="margin: 8px 0;"><span class="status-badge BERT_STATUS_CLASS" style="font-size: 0.8em;">BERT_STATUS</span> BERT</li>
                            <li style="margin: 8px 0;"><span class="status-badge ROBERTA_STATUS_CLASS" style="font-size: 0.8em;">ROBERTA_STATUS</span> RoBERTa</li>
                            <li style="margin: 8px 0;"><span style="color: #856404;">⏳</span> T5 <small style="color: #856404;">(ONNX export blocked)</small></li>
                        </ul>
                        <div style="margin-top: 15px; padding-top: 15px; border-top: 1px solid #e0e0e0;">
                            <strong>Status:</strong> <span class="status-badge NLP_STATUS_CLASS">NLP_STATUS</span>
                        </div>
                    </div>
                    
                    <!-- Vision Models Card -->
                    <div class="metric-card" style="border-left: 4px solid #FF6B6B;">
                        <h3 style="margin-top: 0;">🔥 Vision Models</h3>
                        <ul style="list-style: none; padding: 0; text-align: left;">
                            <li style="margin: 8px 0;"><span class="status-badge RESNET_STATUS_CLASS" style="font-size: 0.8em;">RESNET_STATUS</span> ResNet-50</li>
                            <li style="margin: 8px 0;"><span style="color: #856404;">⏳</span> VGG <small style="color: #856404;">(pending)</small></li>
                            <li style="margin: 8px 0;"><span style="color: #856404;">⏳</span> ViT <small style="color: #856404;">(pending)</small></li>
                        </ul>
                        <div style="margin-top: 15px; padding-top: 15px; border-top: 1px solid #e0e0e0;">
                            <strong>Status:</strong> <span class="status-badge VISION_STATUS_CLASS">VISION_STATUS</span>
                        </div>
                    </div>
                    
                    <!-- Multi-Modal Card -->
                    <div class="metric-card" style="border-left: 4px solid #FFD93D;">
                        <h3 style="margin-top: 0;">🎨 Multi-Modal</h3>
                        <ul style="list-style: none; padding: 0; text-align: left;">
                            <li style="margin: 8px 0;"><span style="color: #856404;">⏳</span> CLIP <small style="color: #856404;">(pending)</small></li>
                            <li style="margin: 8px 0;"><span style="color: #856404;">⏳</span> Wav2Vec2 <small style="color: #856404;">(pending)</small></li>
                        </ul>
                        <div style="margin-top: 15px; padding-top: 15px; border-top: 1px solid #e0e0e0;">
                            <strong>Status:</strong> <span class="status-badge MULTIMODAL_STATUS_CLASS">MULTIMODAL_STATUS</span>
                        </div>
                    </div>
                </div>
            </div>
            
            <!-- Model Details -->
            <div class="section">
                <h2>📊 Model Details</h2>
                <h4 style="color: #667eea; margin-bottom: 15px;">🔤 NLP Models</h4>
                <div class="metrics-grid">
                    <div class="metric-card">
                        <h4>GPT-2 Install Time</h4>
                        <div class="metric-value">GPT2_INSTALL_TIME ms</div>
                    </div>
                    <div class="metric-card">
                        <h4>GPT-2 Register Time</h4>
                        <div class="metric-value">GPT2_REGISTER_TIME ms</div>
                    </div>
                    <div class="metric-card">
                        <h4>BERT Install Time</h4>
                        <div class="metric-value">BERT_INSTALL_TIME ms</div>
                    </div>
                    <div class="metric-card">
                        <h4>BERT Register Time</h4>
                        <div class="metric-value">BERT_REGISTER_TIME ms</div>
                    </div>
                    <div class="metric-card">
                        <h4>RoBERTa Install Time</h4>
                        <div class="metric-value">ROBERTA_INSTALL_TIME ms</div>
                    </div>
                    <div class="metric-card">
                        <h4>RoBERTa Register Time</h4>
                        <div class="metric-value">ROBERTA_REGISTER_TIME ms</div>
                    </div>
                </div>
                <h4 style="color: #17998e; margin: 25px 0 15px 0;">👁️ Vision Models</h4>
                <div class="metrics-grid">
                    <div class="metric-card" style="border-left-color: #17998e;">
                        <h4>ResNet Install Time</h4>
                        <div class="metric-value">RESNET_INSTALL_TIME ms</div>
                    </div>
                    <div class="metric-card" style="border-left-color: #17998e;">
                        <h4>ResNet Register Time</h4>
                        <div class="metric-value">RESNET_REGISTER_TIME ms</div>
                    </div>
                </div>
                <div style="margin-top: 20px; padding: 15px; background: #fff3cd; border-radius: 10px; border-left: 4px solid #ffc107;">
                    <h4 style="margin: 0 0 10px 0; color: #856404;">⚠️ Models Not Tested</h4>
                    <div style="font-size: 0.9em; color: #856404;">
                        <strong>T5:</strong> ONNX export fails (encoder-decoder models need special handling)<br>
                        <strong>Multimodal (CLIP):</strong> Requires complex inputs (text + image)
                    </div>
                </div>
            </div>
            
            <!-- Performance Breakdown -->
            <div class="section">
                <h2>📈 Performance Breakdown</h2>
                <div class="chart-container">
                    <canvas id="breakdownChart"></canvas>
                </div>
                <div style="margin-top: 20px; padding: 15px; background: linear-gradient(135deg, #17998e15 0%, #38ef7d15 100%); border-radius: 10px; border-left: 4px solid #17998e;">
                    <h4 style="margin: 0 0 10px 0; color: #17998e;">📦 Model Installation (not shown in chart)</h4>
                    <div style="font-size: 1.8em; font-weight: bold; color: #333;">TOTAL_MODEL_INSTALL_TIME ms</div>
                    <div style="font-size: 0.9em; color: #666; margin-top: 5px;">
                        Model installation includes downloading from HuggingFace and ONNX conversion via Docker.
                        This dominates the total time (~99%) so it's shown separately.
                    </div>
                </div>
            </div>
        </div>
        
        <div class="footer">
            <p><strong>MLOS Foundation</strong> - Signal. Propagate. Myelinate. 🧠</p>
            <p>Generated: TIMESTAMP</p>
            <p>Test Directory: TEST_DIR</p>
        </div>
    </div>
    
    <script>
        // Installation Times Chart
        const installationCtx = document.getElementById('installationChart').getContext('2d');
        new Chart(installationCtx, {
            type: 'bar',
            data: {
                labels: ['Axon Download', 'Core Download', 'Core Startup', 'Model Install'],
                datasets: [{
                    label: 'Time (ms)',
                    data: [AXON_DOWNLOAD_TIME, CORE_DOWNLOAD_TIME, CORE_STARTUP_TIME, TOTAL_MODEL_INSTALL_TIME],
                    backgroundColor: [
                        'rgba(102, 126, 234, 0.8)',
                        'rgba(118, 75, 162, 0.8)',
                        'rgba(17, 153, 142, 0.8)',
                        'rgba(56, 239, 125, 0.8)'
                    ],
                    borderColor: [
                        'rgb(102, 126, 234)',
                        'rgb(118, 75, 162)',
                        'rgb(17, 153, 142)',
                        'rgb(56, 239, 125)'
                    ],
                    borderWidth: 2
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: {
                        display: false
                    },
                    title: {
                        display: true,
                        text: 'Installation & Setup Times',
                        font: {
                            size: 16,
                            weight: 'bold'
                        }
                    }
                },
                scales: {
                    y: {
                        type: 'logarithmic',
                        min: 10,
                        title: {
                            display: true,
                            text: 'Time (milliseconds) - Log Scale'
                        },
                        ticks: {
                            callback: function(value) {
                                if (value >= 1000000) return (value/1000000).toFixed(0) + 'M';
                                if (value >= 1000) return (value/1000).toFixed(0) + 'K';
                                return value;
                            }
                        }
                    }
                }
            }
        });
        
        // Inference Performance Chart - Dynamic
        const inferenceCtx = document.getElementById('inferenceChart').getContext('2d');
        const inferenceLabels = INFERENCE_LABELS;
        const inferenceData = INFERENCE_DATA;
        const inferenceColors = INFERENCE_COLORS;
        new Chart(inferenceCtx, {
            type: 'bar',
            data: {
                labels: inferenceLabels,
                datasets: [{
                    label: 'Inference Time (ms)',
                    data: inferenceData,
                    backgroundColor: inferenceColors,
                    borderColor: inferenceColors.map(c => c.replace('0.8', '1')),
                    borderWidth: 2
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: {
                        display: false
                    },
                    title: {
                        display: true,
                        text: 'Inference Performance by Model',
                        font: {
                            size: 16,
                            weight: 'bold'
                        }
                    }
                },
                scales: {
                    y: {
                        beginAtZero: true,
                        title: {
                            display: true,
                            text: 'Time (milliseconds)'
                        }
                    }
                }
            }
        });
        
        // Performance Breakdown Chart (Pie) - Excludes Model Installation (too large)
        const breakdownCtx = document.getElementById('breakdownChart').getContext('2d');
        new Chart(breakdownCtx, {
            type: 'doughnut',
            data: {
                labels: ['Axon Download', 'Core Download', 'Model Registration', 'Inference Tests'],
                datasets: [{
                    data: [
                        AXON_DOWNLOAD_TIME,
                        CORE_DOWNLOAD_TIME,
                        TOTAL_REGISTER_TIME,
                        TOTAL_INFERENCE_TIME
                    ],
                    backgroundColor: [
                        'rgba(102, 126, 234, 0.8)',
                        'rgba(118, 75, 162, 0.8)',
                        'rgba(56, 239, 125, 0.8)',
                        'rgba(240, 147, 251, 0.8)'
                    ],
                    borderWidth: 2
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: {
                        position: 'right',
                    },
                    title: {
                        display: true,
                        text: 'Quick Operations Time Distribution (excludes Model Install)',
                        font: {
                            size: 16,
                            weight: 'bold'
                        }
                    }
                }
            }
        });
    </script>
</body>
</html>
EOF
    
    # Replace placeholders with actual values (use | as delimiter to avoid issues with / in values)
    sed -i.bak "s|SUCCESS_RATE|$success_rate|g" "$REPORT_FILE"
    sed -i.bak "s|TOTAL_DURATION|${METRIC_total_duration_seconds}|g" "$REPORT_FILE"
    sed -i.bak "s|SUCCESSFUL_INFERENCES|${METRIC_successful_inferences:-0}|g" "$REPORT_FILE"
    sed -i.bak "s|TOTAL_INFERENCES|${METRIC_total_inferences:-0}|g" "$REPORT_FILE"
    sed -i.bak "s|MODELS_INSTALLED|${METRIC_models_installed:-0}|g" "$REPORT_FILE"
    
    sed -i.bak "s|AXON_VERSION|${METRIC_axon_version:-N/A}|g" "$REPORT_FILE"
    sed -i.bak "s|CORE_VERSION|${METRIC_core_version:-N/A}|g" "$REPORT_FILE"
    
    sed -i.bak "s|AXON_DOWNLOAD_TIME|${METRIC_axon_download_time_ms:-0}|g" "$REPORT_FILE"
    sed -i.bak "s|CORE_DOWNLOAD_TIME|${METRIC_core_download_time_ms:-0}|g" "$REPORT_FILE"
    sed -i.bak "s|CORE_STARTUP_TIME|${METRIC_core_startup_time_ms:-0}|g" "$REPORT_FILE"
    sed -i.bak "s|TOTAL_MODEL_INSTALL_TIME|${METRIC_total_model_install_time_ms:-0}|g" "$REPORT_FILE"
    
    sed -i.bak "s|GPT2_INFERENCE_TIME|${METRIC_model_gpt2_inference_time_ms:-N/A}|g" "$REPORT_FILE"
    sed -i.bak "s|GPT2_LONG_INFERENCE_TIME|${METRIC_model_gpt2_long_inference_time_ms:-N/A}|g" "$REPORT_FILE"
    sed -i.bak "s|BERT_INFERENCE_TIME|${METRIC_model_bert_inference_time_ms:-N/A}|g" "$REPORT_FILE"
    
    sed -i.bak "s|GPT2_INSTALL_TIME|${METRIC_model_gpt2_install_time_ms:-N/A}|g" "$REPORT_FILE"
    sed -i.bak "s|GPT2_REGISTER_TIME|${METRIC_model_gpt2_register_time_ms:-N/A}|g" "$REPORT_FILE"
    sed -i.bak "s|BERT_INSTALL_TIME|${METRIC_model_bert_install_time_ms:-N/A}|g" "$REPORT_FILE"
    sed -i.bak "s|BERT_REGISTER_TIME|${METRIC_model_bert_register_time_ms:-N/A}|g" "$REPORT_FILE"
    sed -i.bak "s|ROBERTA_INSTALL_TIME|${METRIC_model_roberta_install_time_ms:-N/A}|g" "$REPORT_FILE"
    sed -i.bak "s|ROBERTA_REGISTER_TIME|${METRIC_model_roberta_register_time_ms:-N/A}|g" "$REPORT_FILE"
    sed -i.bak "s|T5_INSTALL_TIME|${METRIC_model_t5_install_time_ms:-N/A}|g" "$REPORT_FILE"
    sed -i.bak "s|T5_REGISTER_TIME|${METRIC_model_t5_register_time_ms:-N/A}|g" "$REPORT_FILE"
    sed -i.bak "s|RESNET_INSTALL_TIME|${METRIC_model_resnet_install_time_ms:-N/A}|g" "$REPORT_FILE"
    sed -i.bak "s|RESNET_REGISTER_TIME|${METRIC_model_resnet_register_time_ms:-N/A}|g" "$REPORT_FILE"
    sed -i.bak "s|VGG_INSTALL_TIME|${METRIC_model_vgg_install_time_ms:-N/A}|g" "$REPORT_FILE"
    sed -i.bak "s|VGG_REGISTER_TIME|${METRIC_model_vgg_register_time_ms:-N/A}|g" "$REPORT_FILE"
    
    # Hardware specifications
    sed -i.bak "s|HW_OS|${METRIC_hw_os:-Unknown}|g" "$REPORT_FILE"
    sed -i.bak "s|HW_OS_VERSION|${METRIC_hw_os_version:-Unknown}|g" "$REPORT_FILE"
    sed -i.bak "s|HW_ARCH|${METRIC_hw_arch:-Unknown}|g" "$REPORT_FILE"
    sed -i.bak "s|HW_CPU_MODEL|${METRIC_hw_cpu_model:-Unknown}|g" "$REPORT_FILE"
    sed -i.bak "s|HW_CPU_CORES|${METRIC_hw_cpu_cores:-Unknown}|g" "$REPORT_FILE"
    sed -i.bak "s|HW_CPU_THREADS|${METRIC_hw_cpu_threads:-Unknown}|g" "$REPORT_FILE"
    sed -i.bak "s|HW_RAM_TOTAL|${METRIC_hw_ram_total_gb:-Unknown}|g" "$REPORT_FILE"
    sed -i.bak "s|HW_GPU_MODEL|${METRIC_hw_gpu_model:-None}|g" "$REPORT_FILE"
    sed -i.bak "s|HW_GPU_COUNT|${METRIC_hw_gpu_count:-0}|g" "$REPORT_FILE"
    sed -i.bak "s|HW_GPU_MEMORY|${METRIC_hw_gpu_memory:-N/A}|g" "$REPORT_FILE"
    sed -i.bak "s|HW_DISK_TOTAL|${METRIC_hw_disk_total:-Unknown}|g" "$REPORT_FILE"
    sed -i.bak "s|HW_DISK_AVAILABLE|${METRIC_hw_disk_available:-Unknown}|g" "$REPORT_FILE"
    
    # Resource usage
    sed -i.bak "s|CORE_IDLE_CPU_AVG|${METRIC_core_idle_cpu_avg:-0.0}|g" "$REPORT_FILE"
    sed -i.bak "s|CORE_IDLE_MEM_MB|${METRIC_core_idle_mem_mb:-0.0}|g" "$REPORT_FILE"
    sed -i.bak "s|CORE_LOAD_CPU_MAX|${METRIC_core_load_cpu_max:-0.0}|g" "$REPORT_FILE"
    sed -i.bak "s|CORE_LOAD_CPU_AVG|${METRIC_core_load_cpu_avg:-0.0}|g" "$REPORT_FILE"
    sed -i.bak "s|CORE_LOAD_MEM_MAX|${METRIC_core_load_mem_max:-0.0}|g" "$REPORT_FILE"
    sed -i.bak "s|CORE_LOAD_MEM_AVG|${METRIC_core_load_mem_avg:-0.0}|g" "$REPORT_FILE"
    sed -i.bak "s|AXON_CPU_AVG|${METRIC_axon_cpu_avg:-0.0}|g" "$REPORT_FILE"
    sed -i.bak "s|AXON_MEM_MB|${METRIC_axon_mem_mb:-0.0}|g" "$REPORT_FILE"
    
    # GPU status
    local gpu_status="Not used (CPU-only inference)"
    if [ "$METRIC_hw_gpu_model" != "None detected" ] && [ "$METRIC_hw_gpu_model" != "None" ]; then
        gpu_status="Available but not used (ONNX Runtime CPU provider)"
    fi
    sed -i.bak "s|HW_GPU_STATUS|$gpu_status|g" "$REPORT_FILE"
    
    # Status badges
    # Status badges - use correct variable names (large_inference_status, not long_inference_status)
    local gpt2_status="${METRIC_model_gpt2_inference_status:-failed}"
    local gpt2_large_status="${METRIC_model_gpt2_large_inference_status:-failed}"
    local bert_status="${METRIC_model_bert_inference_status:-failed}"
    local bert_large_status="${METRIC_model_bert_large_inference_status:-failed}"
    local roberta_status="${METRIC_model_roberta_inference_status:-failed}"
    local roberta_large_status="${METRIC_model_roberta_large_inference_status:-failed}"
    
    # Format status text
    local gpt2_status_text="✅ Success"
    if [ "$gpt2_status" != "success" ]; then
        gpt2_status_text="❌ Failed"
    fi
    
    local gpt2_large_status_text="✅ Success"
    if [ "$gpt2_large_status" != "success" ]; then
        gpt2_large_status_text="❌ Failed"
    fi
    
    local bert_status_text="✅ Success"
    if [ "$bert_status" != "success" ]; then
        bert_status_text="❌ Failed"
    fi
    
    local bert_large_status_text="✅ Success"
    if [ "$bert_large_status" != "success" ]; then
        bert_large_status_text="❌ Failed"
    fi
    
    local roberta_status_text="✅ Success"
    if [ "$roberta_status" != "success" ]; then
        roberta_status_text="❌ Failed"
    fi
    
    local roberta_large_status_text="✅ Success"
    if [ "$roberta_large_status" != "success" ]; then
        roberta_large_status_text="❌ Failed"
    fi
    
    # Vision model status
    local resnet_status="${METRIC_model_resnet_inference_status:-failed}"
    local resnet_status_text="✅ Success"
    if [ "$resnet_status" != "success" ]; then
        resnet_status_text="❌ Failed"
    fi
    
    sed -i.bak "s|GPT2_STATUS_CLASS|$gpt2_status|g" "$REPORT_FILE"
    sed -i.bak "s|GPT2_STATUS|$gpt2_status_text|g" "$REPORT_FILE"
    sed -i.bak "s|GPT2_LONG_STATUS_CLASS|$gpt2_large_status|g" "$REPORT_FILE"
    sed -i.bak "s|GPT2_LONG_STATUS|$gpt2_large_status_text|g" "$REPORT_FILE"
    sed -i.bak "s|BERT_STATUS_CLASS|$bert_status|g" "$REPORT_FILE"
    sed -i.bak "s|BERT_STATUS|$bert_status_text|g" "$REPORT_FILE"
    sed -i.bak "s|ROBERTA_STATUS_CLASS|$roberta_status|g" "$REPORT_FILE"
    sed -i.bak "s|ROBERTA_STATUS|$roberta_status_text|g" "$REPORT_FILE"
    sed -i.bak "s|RESNET_STATUS_CLASS|$resnet_status|g" "$REPORT_FILE"
    sed -i.bak "s|RESNET_STATUS|$resnet_status_text|g" "$REPORT_FILE"
    
    # Calculate category statuses
    local nlp_models_tested=0
    local nlp_models_passed=0
    local vision_models_tested=0
    local vision_models_passed=0
    local multimodal_models_tested=0
    local multimodal_models_passed=0
    
    for model_spec in "${TEST_MODELS[@]}"; do
        IFS=':' read -r model_id model_name model_type model_category <<< "$model_spec"
        model_category=${model_category:-nlp}
        
        eval "inference_status=\${METRIC_model_${model_name}_inference_status:-unknown}"
        eval "large_inference_status=\${METRIC_model_${model_name}_large_inference_status:-unknown}"
        
        case "$model_category" in
            nlp)
                # Check small inference
                if [ "$inference_status" = "success" ]; then
                    ((nlp_models_passed++))
                fi
                if [ "$inference_status" != "unknown" ] && [ "$inference_status" != "ready_not_tested" ]; then
                    ((nlp_models_tested++))
                fi
                # Check large inference
                if [ "$large_inference_status" = "success" ]; then
                    ((nlp_models_passed++))
                fi
                if [ "$large_inference_status" != "unknown" ] && [ "$large_inference_status" != "ready_not_tested" ]; then
                    ((nlp_models_tested++))
                fi
                ;;
            vision)
                if [ "$inference_status" = "success" ]; then
                    ((vision_models_passed++))
                fi
                if [ "$inference_status" != "unknown" ] && [ "$inference_status" != "ready_not_tested" ]; then
                    ((vision_models_tested++))
                fi
                ;;
            multimodal)
                if [ "$inference_status" = "success" ]; then
                    ((multimodal_models_passed++))
                fi
                if [ "$inference_status" != "unknown" ] && [ "$inference_status" != "ready_not_tested" ]; then
                    ((multimodal_models_tested++))
                fi
                ;;
        esac
    done
    
    # Determine category status
    local nlp_status="ready_not_tested"
    if [ $nlp_models_tested -gt 0 ]; then
        if [ $nlp_models_passed -eq $nlp_models_tested ]; then
            nlp_status="success"
        else
            nlp_status="failed"
        fi
    fi
    
    local vision_status="ready_not_tested"
    if [ $vision_models_tested -gt 0 ]; then
        if [ $vision_models_passed -eq $vision_models_tested ]; then
            vision_status="success"
        else
            vision_status="failed"
        fi
    fi
    
    local multimodal_status="ready_not_tested"
    if [ $multimodal_models_tested -gt 0 ]; then
        if [ $multimodal_models_passed -eq $multimodal_models_tested ]; then
            multimodal_status="success"
        else
            multimodal_status="failed"
        fi
    fi
    
    # Format status text
    local nlp_status_text="✅ Passing"
    if [ "$nlp_status" = "ready_not_tested" ]; then
        nlp_status_text="⏳ Ready (not tested)"
    elif [ "$nlp_status" = "failed" ]; then
        nlp_status_text="❌ Failed"
    fi
    
    local vision_status_text="⏳ Ready (not tested)"
    if [ "$vision_status" = "success" ]; then
        vision_status_text="✅ Passing"
    elif [ "$vision_status" = "failed" ]; then
        vision_status_text="❌ Failed"
    fi
    
    local multimodal_status_text="⏳ Ready (not tested)"
    if [ "$multimodal_status" = "success" ]; then
        multimodal_status_text="✅ Passing"
    elif [ "$multimodal_status" = "failed" ]; then
        multimodal_status_text="❌ Failed"
    fi
    
    # Handle empty content gracefully
    if [ -z "$INFERENCE_METRICS_HTML_CONTENT" ]; then
        INFERENCE_METRICS_HTML_CONTENT="<p style=\"text-align: center; color: #666;\">No inference tests were run.</p>"
    fi
    if [ -z "$INFERENCE_LABELS_JSON" ] || [ "$INFERENCE_LABELS_JSON" = "[]" ]; then
        INFERENCE_LABELS_JSON="[]"
        INFERENCE_DATA_JSON="[]"
        INFERENCE_COLORS_JSON="[]"
    fi
    
    # Use Python for ALL replacements (sed has Unicode issues on Linux)
    local temp_html=$(mktemp)
    printf '%s' "$INFERENCE_METRICS_HTML_CONTENT" > "$temp_html"
    
    # Export ALL variables for Python - this is comprehensive
    export REPORT_FILE_PATH="$REPORT_FILE"
    export TEMP_HTML_PATH="$temp_html"
    
    # Status variables
    export NLP_STATUS_CLASS_VAL="$nlp_status"
    export NLP_STATUS_VAL="$nlp_status_text"
    export VISION_STATUS_CLASS_VAL="$vision_status"
    export VISION_STATUS_VAL="$vision_status_text"
    export MULTIMODAL_STATUS_CLASS_VAL="$multimodal_status"
    export MULTIMODAL_STATUS_VAL="$multimodal_status_text"
    
    # Inference chart data
    export INFERENCE_LABELS_VAL="$INFERENCE_LABELS_JSON"
    export INFERENCE_DATA_VAL="$INFERENCE_DATA_JSON"
    export INFERENCE_COLORS_VAL="$INFERENCE_COLORS_JSON"
    
    # Timing data (for charts)
    export AXON_DOWNLOAD_TIME_VAL="${METRIC_axon_download_time_ms:-0}"
    export CORE_DOWNLOAD_TIME_VAL="${METRIC_core_download_time_ms:-0}"
    export CORE_STARTUP_TIME_VAL="${METRIC_core_startup_time_ms:-0}"
    export TOTAL_MODEL_INSTALL_TIME_VAL="${METRIC_total_model_install_time_ms:-0}"
    export TOTAL_REGISTER_TIME_VAL="${METRIC_total_register_time_ms:-0}"
    export TOTAL_INFERENCE_TIME_VAL="${METRIC_total_inference_time_ms:-0}"
    
    # Model-specific times
    export GPT2_INSTALL_TIME_VAL="${METRIC_model_gpt2_install_time_ms:-0}"
    export GPT2_REGISTER_TIME_VAL="${METRIC_model_gpt2_register_time_ms:-0}"
    export BERT_INSTALL_TIME_VAL="${METRIC_model_bert_install_time_ms:-0}"
    export BERT_REGISTER_TIME_VAL="${METRIC_model_bert_register_time_ms:-0}"
    export ROBERTA_INSTALL_TIME_VAL="${METRIC_model_roberta_install_time_ms:-0}"
    export ROBERTA_REGISTER_TIME_VAL="${METRIC_model_roberta_register_time_ms:-0}"
    export T5_INSTALL_TIME_VAL="${METRIC_model_t5_install_time_ms:-0}"
    export T5_REGISTER_TIME_VAL="${METRIC_model_t5_register_time_ms:-0}"
    export RESNET_INSTALL_TIME_VAL="${METRIC_model_resnet_install_time_ms:-0}"
    export RESNET_REGISTER_TIME_VAL="${METRIC_model_resnet_register_time_ms:-0}"
    export VGG_INSTALL_TIME_VAL="${METRIC_model_vgg_install_time_ms:-0}"
    export VGG_REGISTER_TIME_VAL="${METRIC_model_vgg_register_time_ms:-0}"
    export GPT2_INFERENCE_TIME_VAL="${METRIC_model_gpt2_inference_time_ms:-0}"
    export GPT2_LONG_INFERENCE_TIME_VAL="${METRIC_model_gpt2_long_inference_time_ms:-0}"
    export BERT_INFERENCE_TIME_VAL="${METRIC_model_bert_inference_time_ms:-0}"
    export BERT_LONG_INFERENCE_TIME_VAL="${METRIC_model_bert_long_inference_time_ms:-0}"
    export ROBERTA_INFERENCE_TIME_VAL="${METRIC_model_roberta_inference_time_ms:-0}"
    export T5_INFERENCE_TIME_VAL="${METRIC_model_t5_inference_time_ms:-0}"
    export RESNET_INFERENCE_TIME_VAL="${METRIC_model_resnet_inference_time_ms:-0}"
    export VGG_INFERENCE_TIME_VAL="${METRIC_model_vgg_inference_time_ms:-0}"
    
    # Status badges
    export GPT2_STATUS_VAL="$gpt2_status_text"
    export GPT2_STATUS_CLASS_VAL="$gpt2_status"
    export GPT2_LONG_STATUS_VAL="$gpt2_large_status_text"
    export GPT2_LONG_STATUS_CLASS_VAL="$gpt2_large_status"
    export BERT_STATUS_VAL="$bert_status_text"
    export BERT_STATUS_CLASS_VAL="$bert_status"
    export BERT_LONG_STATUS_VAL="$bert_large_status_text"
    export BERT_LONG_STATUS_CLASS_VAL="$bert_large_status"
    export ROBERTA_STATUS_VAL="$roberta_status_text"
    export ROBERTA_STATUS_CLASS_VAL="$roberta_status"
    export ROBERTA_LONG_STATUS_VAL="$roberta_large_status_text"
    export ROBERTA_LONG_STATUS_CLASS_VAL="$roberta_large_status"
    export RESNET_STATUS_VAL="$resnet_status_text"
    export RESNET_STATUS_CLASS_VAL="$resnet_status"
    
    # Metadata
    export TIMESTAMP_VAL="$(date '+%Y-%m-%d %H:%M:%S')"
    export TEST_DIR_VAL="$TEST_DIR"
    
    # Debug: Show that we're about to run Python
    log "Running Python replacement script..."
    log "  REPORT_FILE_PATH=$REPORT_FILE_PATH"
    log "  TEMP_HTML_PATH=$TEMP_HTML_PATH"
    
    # Check if files exist before running Python
    if [ ! -f "$REPORT_FILE" ]; then
        log_warn "Report file not found: $REPORT_FILE"
    fi
    
    python3 << 'PYTHON_SCRIPT'
import os
import sys

print("🐍 Python script starting...", flush=True)

try:
    report_file = os.environ.get('REPORT_FILE_PATH', '')
    temp_html = os.environ.get('TEMP_HTML_PATH', '')
    
    print(f"  report_file={report_file}", flush=True)
    print(f"  temp_html={temp_html}", flush=True)
    
    if not report_file or not os.path.exists(report_file):
        print(f"❌ Report file not found: {report_file}", flush=True)
        sys.exit(1)

    # Read the report file
    with open(report_file, 'r', encoding='utf-8') as f:
        content = f.read()

    print(f"  Read {len(content)} bytes from report file", flush=True)
    
    # Read the HTML content for inference metrics
    html_content = ""
    if temp_html and os.path.exists(temp_html):
        with open(temp_html, 'r', encoding='utf-8') as f:
            html_content = f.read()
        print(f"  Read {len(html_content)} bytes from temp HTML", flush=True)
    else:
        print(f"  No temp HTML file, using empty string", flush=True)

    # Build comprehensive replacement dictionary
    replacements = {
        # Inference chart
        'INFERENCE_METRICS_HTML': html_content,
        'INFERENCE_LABELS': os.environ.get('INFERENCE_LABELS_VAL', '[]'),
        'INFERENCE_DATA': os.environ.get('INFERENCE_DATA_VAL', '[]'),
        'INFERENCE_COLORS': os.environ.get('INFERENCE_COLORS_VAL', '[]'),
        
        # Category status (longer _CLASS versions first!)
        'NLP_STATUS_CLASS': os.environ.get('NLP_STATUS_CLASS_VAL', 'ready_not_tested'),
        'NLP_STATUS': os.environ.get('NLP_STATUS_VAL', '⏳ Ready'),
        'VISION_STATUS_CLASS': os.environ.get('VISION_STATUS_CLASS_VAL', 'ready_not_tested'),
        'VISION_STATUS': os.environ.get('VISION_STATUS_VAL', '⏳ Ready'),
        'MULTIMODAL_STATUS_CLASS': os.environ.get('MULTIMODAL_STATUS_CLASS_VAL', 'ready_not_tested'),
        'MULTIMODAL_STATUS': os.environ.get('MULTIMODAL_STATUS_VAL', '⏳ Ready'),
        
        # Timing data for charts
        'AXON_DOWNLOAD_TIME': os.environ.get('AXON_DOWNLOAD_TIME_VAL', '0'),
        'CORE_DOWNLOAD_TIME': os.environ.get('CORE_DOWNLOAD_TIME_VAL', '0'),
        'CORE_STARTUP_TIME': os.environ.get('CORE_STARTUP_TIME_VAL', '0'),
        'TOTAL_MODEL_INSTALL_TIME': os.environ.get('TOTAL_MODEL_INSTALL_TIME_VAL', '0'),
        'TOTAL_REGISTER_TIME': os.environ.get('TOTAL_REGISTER_TIME_VAL', '0'),
        'TOTAL_INFERENCE_TIME': os.environ.get('TOTAL_INFERENCE_TIME_VAL', '0'),
        
        # Model times
        'GPT2_INSTALL_TIME': os.environ.get('GPT2_INSTALL_TIME_VAL', '0'),
        'GPT2_REGISTER_TIME': os.environ.get('GPT2_REGISTER_TIME_VAL', '0'),
        'BERT_INSTALL_TIME': os.environ.get('BERT_INSTALL_TIME_VAL', '0'),
        'BERT_REGISTER_TIME': os.environ.get('BERT_REGISTER_TIME_VAL', '0'),
        'ROBERTA_INSTALL_TIME': os.environ.get('ROBERTA_INSTALL_TIME_VAL', '0'),
        'ROBERTA_REGISTER_TIME': os.environ.get('ROBERTA_REGISTER_TIME_VAL', '0'),
        'T5_INSTALL_TIME': os.environ.get('T5_INSTALL_TIME_VAL', '0'),
        'T5_REGISTER_TIME': os.environ.get('T5_REGISTER_TIME_VAL', '0'),
        'RESNET_INSTALL_TIME': os.environ.get('RESNET_INSTALL_TIME_VAL', '0'),
        'RESNET_REGISTER_TIME': os.environ.get('RESNET_REGISTER_TIME_VAL', '0'),
        'VGG_INSTALL_TIME': os.environ.get('VGG_INSTALL_TIME_VAL', '0'),
        'VGG_REGISTER_TIME': os.environ.get('VGG_REGISTER_TIME_VAL', '0'),
        'GPT2_INFERENCE_TIME': os.environ.get('GPT2_INFERENCE_TIME_VAL', '0'),
        'GPT2_LONG_INFERENCE_TIME': os.environ.get('GPT2_LONG_INFERENCE_TIME_VAL', '0'),
        'BERT_INFERENCE_TIME': os.environ.get('BERT_INFERENCE_TIME_VAL', '0'),
        'BERT_LONG_INFERENCE_TIME': os.environ.get('BERT_LONG_INFERENCE_TIME_VAL', '0'),
        'ROBERTA_INFERENCE_TIME': os.environ.get('ROBERTA_INFERENCE_TIME_VAL', '0'),
        'T5_INFERENCE_TIME': os.environ.get('T5_INFERENCE_TIME_VAL', '0'),
        'RESNET_INFERENCE_TIME': os.environ.get('RESNET_INFERENCE_TIME_VAL', '0'),
        'VGG_INFERENCE_TIME': os.environ.get('VGG_INFERENCE_TIME_VAL', '0'),
        
        # Status badges (longer _CLASS versions first!)
        'GPT2_LONG_STATUS_CLASS': os.environ.get('GPT2_LONG_STATUS_CLASS_VAL', 'failed'),
        'GPT2_LONG_STATUS': os.environ.get('GPT2_LONG_STATUS_VAL', '❌ Failed'),
        'GPT2_STATUS_CLASS': os.environ.get('GPT2_STATUS_CLASS_VAL', 'failed'),
        'GPT2_STATUS': os.environ.get('GPT2_STATUS_VAL', '❌ Failed'),
        'BERT_LONG_STATUS_CLASS': os.environ.get('BERT_LONG_STATUS_CLASS_VAL', 'failed'),
        'BERT_LONG_STATUS': os.environ.get('BERT_LONG_STATUS_VAL', '❌ Failed'),
        'BERT_STATUS_CLASS': os.environ.get('BERT_STATUS_CLASS_VAL', 'failed'),
        'BERT_STATUS': os.environ.get('BERT_STATUS_VAL', '❌ Failed'),
        'ROBERTA_LONG_STATUS_CLASS': os.environ.get('ROBERTA_LONG_STATUS_CLASS_VAL', 'failed'),
        'ROBERTA_LONG_STATUS': os.environ.get('ROBERTA_LONG_STATUS_VAL', '❌ Failed'),
        'ROBERTA_STATUS_CLASS': os.environ.get('ROBERTA_STATUS_CLASS_VAL', 'failed'),
        'ROBERTA_STATUS': os.environ.get('ROBERTA_STATUS_VAL', '❌ Failed'),
        'RESNET_STATUS_CLASS': os.environ.get('RESNET_STATUS_CLASS_VAL', 'failed'),
        'RESNET_STATUS': os.environ.get('RESNET_STATUS_VAL', '❌ Failed'),
        
        # Metadata
        'TIMESTAMP': os.environ.get('TIMESTAMP_VAL', 'N/A'),
        'TEST_DIR': os.environ.get('TEST_DIR_VAL', 'N/A'),
    }

    # Do replacements - ORDER MATTERS: longer strings first to avoid partial matches
    for key in sorted(replacements.keys(), key=len, reverse=True):
        val = str(replacements[key])
        count = content.count(key)
        if count > 0:
            content = content.replace(key, val)
            print(f"  Replaced {key}: {count} occurrence(s)", flush=True)

    # Write back
    with open(report_file, 'w', encoding='utf-8') as f:
        f.write(content)

    print(f"✅ Python replacement complete", flush=True)

except Exception as e:
    print(f"❌ Python error: {e}", flush=True)
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYTHON_SCRIPT
    
    rm -f "$temp_html"
    
    # Remove backup files created by sed (if any remain)
    rm -f "$REPORT_FILE.bak"
    
    # Re-enable exit on error
    set -e
    
    log "✅ HTML report generated: $REPORT_FILE"
}

print_summary() {
    banner "📊 Test Summary"
    
    log "Test completed in ${METRIC_total_duration_seconds}s"
    log ""
    log "Release Versions:"
    log "  - Axon: ${METRIC_axon_version:-N/A}"
    log "  - Core: ${METRIC_core_version:-N/A}"
    log ""
    log "Installation:"
    log "  - Axon download: ${METRIC_axon_download_time_ms:-0}ms"
    log "  - Core download: ${METRIC_core_download_time_ms:-0}ms"
    log "  - Core startup: ${METRIC_core_startup_time_ms:-0}ms"
    log "  - Models installed: ${METRIC_models_installed:-0}"
    log ""
    log "Binaries Installed:"
    log "  - Axon: ~/.local/bin/axon"
    if [ -n "$MLOS_CORE_BINARY" ]; then
        local binary_name=$(basename "$MLOS_CORE_BINARY")
        log "  - Core: ~/.local/bin/$binary_name"
    else
        log "  - Core: ~/.local/bin/mlos_core (or mlos-server)"
    fi
    log ""
    log "Inference:"
    log "  - Total tests: ${METRIC_total_inferences:-0}"
    log "  - Successful: ${METRIC_successful_inferences:-0}"
    log "  - GPT-2 (7 tokens): ${METRIC_model_gpt2_inference_time_ms:-N/A}ms"
    log "  - GPT-2 (16 tokens): ${METRIC_model_gpt2_long_inference_time_ms:-N/A}ms"
    log "  - BERT (3 tokens): ${METRIC_model_bert_inference_time_ms:-N/A}ms"
    log ""
    log "📄 Report: $REPORT_FILE"
    log "📋 Log: $LOG_FILE"
    log ""
    
    if [ "${METRIC_successful_inferences:-0}" -eq "${METRIC_total_inferences:-0}" ] && [ "${METRIC_total_inferences:-0}" -gt 0 ]; then
        log "✅ ${GREEN}ALL TESTS PASSED!${NC}"
        return 0
    else
        log "❌ ${RED}SOME TESTS FAILED${NC}"
        return 1
    fi
}

# Main execution
main() {
    # Create test directory first (before any logging)
    mkdir -p "$TEST_DIR"
    
    banner "🚀 MLOS Release E2E Validation"
    
    log "Testing Axon $AXON_RELEASE_VERSION and MLOS Core $CORE_RELEASE_VERSION"
    
    check_prerequisites
    setup_test_environment
    collect_hardware_specs
    download_axon_release
    download_core_release
    install_models || log_warn "Model installation incomplete, continuing with limited testing..."
    start_mlos_core
    register_models || log_warn "Model registration skipped, continuing..."
    run_inference_tests || log_warn "Inference tests skipped or incomplete..."
    generate_html_report
    print_summary
    
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        log ""
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "✅ ${GREEN}Release E2E validation completed successfully!${NC}"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log ""
        log "📊 Open the report in your browser:"
        log "   file://$REPORT_FILE"
        log ""
        log "🎉 Binaries installed and ready to use:"
        log "   axon --help"
        if [ -n "$MLOS_CORE_BINARY" ]; then
            local binary_name=$(basename "$MLOS_CORE_BINARY")
            log "   $binary_name --help"
        else
            log "   mlos_core --help (or mlos-server --help)"
        fi
        log ""
        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            log "⚠️  Add ~/.local/bin to your PATH to use the binaries:"
            log "   export PATH=\"\$HOME/.local/bin:\$PATH\""
            log "   # Add this line to your ~/.bashrc or ~/.zshrc"
        fi
    else
        log ""
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "❌ ${RED}Release E2E validation completed with failures${NC}"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log ""
        log "📄 Check the log for details: $LOG_FILE"
    fi
    
    exit $exit_code
}

# Run main
main "$@"
