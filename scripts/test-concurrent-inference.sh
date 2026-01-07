#!/bin/bash

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# MLOS Concurrent Inference Test
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# Tests concurrent inference performance to measure kernel scheduler benefits
# Sends N parallel requests and measures throughput + latency distribution
#
# Usage: ./test-concurrent-inference.sh <model_name> [options]
#
# Options:
#   --concurrency <N>   Number of parallel requests (default: 8)
#   --iterations <N>    Number of test iterations (default: 3)
#   --core-url <url>    Core server URL
#   --output-dir <dir>  Output directory for results
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$REPO_ROOT/config/models.yaml"

# Default configuration
CORE_URL="${CORE_URL:-http://127.0.0.1:8080}"
OUTPUT_DIR="${OUTPUT_DIR:-./concurrent-results}"
CONCURRENCY="${CONCURRENCY:-8}"
ITERATIONS="${ITERATIONS:-3}"

# Parse arguments
MODEL_NAME=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --concurrency) CONCURRENCY="$2"; shift 2 ;;
        --iterations) ITERATIONS="$2"; shift 2 ;;
        --core-url) CORE_URL="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) MODEL_NAME="$1"; shift ;;
    esac
done

if [ -z "$MODEL_NAME" ]; then
    echo "Usage: $0 <model_name> [--concurrency N] [--iterations N]"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Get model config
get_model_config() {
    python3 -c "
import yaml
with open('$CONFIG_FILE') as f:
    config = yaml.safe_load(f)
model = config.get('models', {}).get('$MODEL_NAME', {})
print(model.get('axon_id', ''))
print(model.get('input_type', 'text'))
print(model.get('category', 'nlp'))
"
}

read -r AXON_ID INPUT_TYPE CATEGORY <<< "$(get_model_config | tr '\n' ' ')"

if [ -z "$AXON_ID" ]; then
    echo "ERROR: Model '$MODEL_NAME' not found in config"
    exit 1
fi

# URL encode function
url_encode() {
    python3 -c "import urllib.parse; print(urllib.parse.quote('$1', safe=''))"
}

ENCODED_MODEL_ID=$(url_encode "$AXON_ID")

# Generate test input based on model type
generate_input() {
    case "$INPUT_TYPE" in
        text)
            echo '{"inputs": "The quick brown fox jumps over the lazy dog. This is a test sentence for concurrent inference benchmarking."}'
            ;;
        image)
            # Use a small test image (base64)
            echo '{"inputs": {"pixel_values": [[[[0.5, 0.5, 0.5]]]]}}'
            ;;
        tokens)
            echo '{"inputs": {"input_ids": [[101, 2054, 2003, 1996, 3099, 1029, 102]]}}'
            ;;
        *)
            echo '{"inputs": "test input"}'
            ;;
    esac
}

TEST_INPUT=$(generate_input)
INFERENCE_URL="$CORE_URL/models/${ENCODED_MODEL_ID}/inference"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CONCURRENT INFERENCE TEST"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Model: $MODEL_NAME ($AXON_ID)"
echo "Concurrency: $CONCURRENCY parallel requests"
echo "Iterations: $ITERATIONS"
echo "Core URL: $CORE_URL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Verify model is available
echo "Verifying model is registered..."
if ! curl -sf "$CORE_URL/models/${ENCODED_MODEL_ID}" > /dev/null 2>&1; then
    echo "ERROR: Model not found. Please ensure model is installed and registered."
    exit 1
fi
echo "✓ Model available"

# Results file
RESULTS_FILE="$OUTPUT_DIR/${MODEL_NAME}-concurrent.json"
LATENCY_FILE="/tmp/latencies_$$.txt"

# Initialize results
cat > "$RESULTS_FILE" << EOF
{
    "model": "$MODEL_NAME",
    "axon_id": "$AXON_ID",
    "concurrency": $CONCURRENCY,
    "iterations": $ITERATIONS,
    "results": []
}
EOF

# Function to run single inference and record latency
run_single_inference() {
    local start_ns=$(date +%s%N)
    local http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
        -X POST "$INFERENCE_URL" \
        -H "Content-Type: application/json" \
        -d "$TEST_INPUT" 2>/dev/null || echo "000")
    local end_ns=$(date +%s%N)

    local latency_ms=$(( (end_ns - start_ns) / 1000000 ))

    if [ "$http_code" = "200" ]; then
        echo "$latency_ms" >> "$LATENCY_FILE"
        echo "OK:$latency_ms"
    else
        echo "FAIL:$http_code"
    fi
}

export -f run_single_inference
export INFERENCE_URL TEST_INPUT LATENCY_FILE

# Run concurrent tests
for iter in $(seq 1 $ITERATIONS); do
    echo ""
    echo "── Iteration $iter/$ITERATIONS ──"

    # Clear latency file
    > "$LATENCY_FILE"

    # Start time
    START_TIME=$(date +%s%N)

    # Launch concurrent requests using background jobs
    pids=()
    for i in $(seq 1 $CONCURRENCY); do
        run_single_inference &
        pids+=($!)
    done

    # Wait for all to complete
    success=0
    failed=0
    for pid in "${pids[@]}"; do
        if wait $pid 2>/dev/null; then
            ((success++)) || true
        else
            ((failed++)) || true
        fi
    done

    END_TIME=$(date +%s%N)

    # Calculate metrics
    TOTAL_TIME_MS=$(( (END_TIME - START_TIME) / 1000000 ))

    if [ -s "$LATENCY_FILE" ]; then
        # Calculate latency statistics
        STATS=$(sort -n "$LATENCY_FILE" | python3 -c "
import sys
latencies = [int(line.strip()) for line in sys.stdin if line.strip()]
if latencies:
    n = len(latencies)
    avg = sum(latencies) / n
    p50 = latencies[int(n * 0.50)]
    p95 = latencies[int(n * 0.95)] if n >= 20 else latencies[-1]
    p99 = latencies[int(n * 0.99)] if n >= 100 else latencies[-1]
    print(f'{len(latencies)} {min(latencies)} {max(latencies)} {avg:.1f} {p50} {p95} {p99}')
else:
    print('0 0 0 0 0 0 0')
")
        read -r COUNT MIN MAX AVG P50 P95 P99 <<< "$STATS"

        # Throughput: requests per second
        THROUGHPUT=$(python3 -c "print(f'{$COUNT / ($TOTAL_TIME_MS / 1000):.2f}')")

        echo "  Completed: $COUNT/$CONCURRENCY requests"
        echo "  Total time: ${TOTAL_TIME_MS}ms"
        echo "  Throughput: $THROUGHPUT req/s"
        echo "  Latency: min=${MIN}ms avg=${AVG}ms max=${MAX}ms"
        echo "  Percentiles: p50=${P50}ms p95=${P95}ms p99=${P99}ms"

        # Append to results
        python3 << PYEOF
import json
with open('$RESULTS_FILE', 'r') as f:
    data = json.load(f)
data['results'].append({
    'iteration': $iter,
    'total_time_ms': $TOTAL_TIME_MS,
    'completed': $COUNT,
    'failed': $((CONCURRENCY - COUNT)),
    'throughput_rps': $THROUGHPUT,
    'latency_min_ms': $MIN,
    'latency_max_ms': $MAX,
    'latency_avg_ms': $AVG,
    'latency_p50_ms': $P50,
    'latency_p95_ms': $P95,
    'latency_p99_ms': $P99
})
with open('$RESULTS_FILE', 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
    else
        echo "  ⚠️ No successful requests"
    fi
done

# Calculate summary statistics
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

python3 << PYEOF
import json
with open('$RESULTS_FILE', 'r') as f:
    data = json.load(f)

results = data['results']
if results:
    avg_throughput = sum(r['throughput_rps'] for r in results) / len(results)
    avg_latency = sum(r['latency_avg_ms'] for r in results) / len(results)
    avg_p95 = sum(r['latency_p95_ms'] for r in results) / len(results)

    data['summary'] = {
        'avg_throughput_rps': round(avg_throughput, 2),
        'avg_latency_ms': round(avg_latency, 1),
        'avg_p95_ms': round(avg_p95, 1)
    }

    with open('$RESULTS_FILE', 'w') as f:
        json.dump(data, f, indent=2)

    print(f"Average Throughput: {avg_throughput:.2f} req/s")
    print(f"Average Latency: {avg_latency:.1f}ms")
    print(f"Average P95: {avg_p95:.1f}ms")
else:
    print("No results to summarize")
PYEOF

echo ""
echo "Results saved to: $RESULTS_FILE"

# Cleanup
rm -f "$LATENCY_FILE"
