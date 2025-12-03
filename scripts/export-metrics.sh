#!/bin/bash
#
# Export metrics from bash environment variables to JSON
# Called at the end of test-release-e2e.sh.bash to generate metrics.json
#
# Usage: source export-metrics.sh && export_metrics_json <output_file>
#

export_metrics_json() {
    local output_file="${1:-metrics.json}"
    local test_dir="${TEST_DIR:-$(pwd)}"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Create JSON using jq if available, otherwise use Python
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg timestamp "$timestamp" \
            --arg test_dir "$test_dir" \
            --arg axon_ver "${METRIC_axon_version:-N/A}" \
            --arg core_ver "${METRIC_core_version:-N/A}" \
            --arg os "${METRIC_hw_os:-Unknown}" \
            --arg os_ver "${METRIC_hw_os_version:-}" \
            --arg arch "${METRIC_hw_arch:-Unknown}" \
            --arg cpu_model "${METRIC_hw_cpu_model:-Unknown}" \
            --argjson cpu_cores "${METRIC_hw_cpu_cores:-0}" \
            --argjson cpu_threads "${METRIC_hw_cpu_threads:-0}" \
            --argjson memory_gb "${METRIC_hw_ram_total_gb:-0}" \
            --arg gpu_name "${METRIC_hw_gpu_model:-None detected}" \
            --argjson gpu_count "${METRIC_hw_gpu_count:-0}" \
            --arg gpu_memory "${METRIC_hw_gpu_memory:-N/A}" \
            --arg disk_total "${METRIC_hw_disk_total:-N/A}" \
            --arg disk_available "${METRIC_hw_disk_available:-N/A}" \
            --argjson axon_dl "${METRIC_axon_download_time_ms:-0}" \
            --argjson core_dl "${METRIC_core_download_time_ms:-0}" \
            --argjson core_startup "${METRIC_core_startup_time_ms:-0}" \
            --argjson model_install "${METRIC_total_model_install_time_ms:-0}" \
            --argjson total_register "${METRIC_total_register_time_ms:-0}" \
            --argjson total_inference "${METRIC_total_inference_time_ms:-0}" \
            --argjson total_duration "${METRIC_total_duration_seconds:-0}" \
            --argjson core_idle_cpu "${METRIC_core_idle_cpu_avg:-0}" \
            --argjson core_idle_mem "${METRIC_core_idle_mem_mb:-0}" \
            --argjson core_load_cpu_avg "${METRIC_core_load_cpu_avg:-0}" \
            --argjson core_load_cpu_max "${METRIC_core_load_cpu_max:-0}" \
            --argjson core_load_mem_avg "${METRIC_core_load_mem_avg:-0}" \
            --argjson core_load_mem_max "${METRIC_core_load_mem_max:-0}" \
            --argjson axon_cpu "${METRIC_axon_cpu_avg:-0}" \
            --argjson axon_mem "${METRIC_axon_mem_mb:-0}" \
            '{
                timestamp: $timestamp,
                test_dir: $test_dir,
                versions: {
                    axon: $axon_ver,
                    core: $core_ver
                },
                hardware: {
                    os: $os,
                    os_version: $os_ver,
                    arch: $arch,
                    cpu_model: $cpu_model,
                    cpu_cores: $cpu_cores,
                    cpu_threads: $cpu_threads,
                    memory_gb: $memory_gb,
                    gpu_name: $gpu_name,
                    gpu_count: $gpu_count,
                    gpu_memory: $gpu_memory,
                    disk_total: $disk_total,
                    disk_available: $disk_available
                },
                timings: {
                    axon_download_ms: $axon_dl,
                    core_download_ms: $core_dl,
                    core_startup_ms: $core_startup,
                    total_model_install_ms: $model_install,
                    total_register_ms: $total_register,
                    total_inference_ms: $total_inference,
                    total_duration_s: $total_duration
                },
                resources: {
                    core_idle_cpu: $core_idle_cpu,
                    core_idle_mem_mb: $core_idle_mem,
                    core_load_cpu_avg: $core_load_cpu_avg,
                    core_load_cpu_max: $core_load_cpu_max,
                    core_load_mem_avg_mb: $core_load_mem_avg,
                    core_load_mem_max_mb: $core_load_mem_max,
                    axon_cpu: $axon_cpu,
                    axon_mem_mb: $axon_mem,
                    gpu_status: "Not used (CPU-only inference)"
                },
                models: {}
            }' > "$output_file"
        
        # Add model data - include all enabled models from config
        for model in gpt2 bert roberta resnet vit convnext mobilenet deit efficientnet; do
            eval "install_time=\${METRIC_model_${model}_install_time_ms:-0}"
            eval "register_time=\${METRIC_model_${model}_register_time_ms:-0}"
            eval "inference_status=\${METRIC_model_${model}_inference_status:-unknown}"
            eval "inference_time=\${METRIC_model_${model}_inference_time_ms:-0}"
            eval "large_status=\${METRIC_model_${model}_large_inference_status:-unknown}"
            eval "large_time=\${METRIC_model_${model}_long_inference_time_ms:-0}"
            
            # Determine category
            case "$model" in
                gpt2|bert|roberta|t5) category="nlp" ;;
                resnet|vgg|vit|convnext|mobilenet|deit|efficientnet|swin) category="vision" ;;
                *) category="multimodal" ;;
            esac
            
            # Determine if tested
            tested="false"
            if [ "$inference_status" != "unknown" ] && [ "$inference_status" != "ready_not_tested" ]; then
                tested="true"
            fi
            
            # Determine if large inference tested
            large_tested="false"
            if [ "$large_status" != "unknown" ] && [ "$large_status" != "ready_not_tested" ]; then
                large_tested="true"
            fi
            
            # Update JSON with model data
            jq --arg model "$model" \
               --arg category "$category" \
               --argjson tested "$tested" \
               --argjson install_time "${install_time:-0}" \
               --argjson register_time "${register_time:-0}" \
               --arg inference_status "$inference_status" \
               --argjson inference_time "${inference_time:-0}" \
               --argjson large_tested "$large_tested" \
               --arg large_status "$large_status" \
               --argjson large_time "${large_time:-0}" \
               '.models[$model] = {
                   category: $category,
                   tested: $tested,
                   install_time_ms: $install_time,
                   register_time_ms: $register_time,
                   inference_status: $inference_status,
                   inference_time_ms: $inference_time,
                   inference_large_tested: $large_tested,
                   inference_large_status: $large_status,
                   inference_large_time_ms: $large_time
               }' "$output_file" > "${output_file}.tmp" && mv "${output_file}.tmp" "$output_file"
        done
        
    else
        # Fallback to Python
        python3 << PYTHON_EOF
import json
import os
from datetime import datetime

metrics = {
    "timestamp": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "test_dir": os.environ.get("TEST_DIR", os.getcwd()),
    
    "versions": {
        "axon": os.environ.get("METRIC_axon_version", "N/A"),
        "core": os.environ.get("METRIC_core_version", "N/A")
    },
    
    "hardware": {
        "os": os.environ.get("METRIC_hw_os", "Unknown"),
        "os_version": os.environ.get("METRIC_hw_os_version", ""),
        "arch": os.environ.get("METRIC_hw_arch", "Unknown"),
        "cpu_model": os.environ.get("METRIC_hw_cpu_model", "Unknown"),
        "cpu_cores": int(os.environ.get("METRIC_hw_cpu_cores", 0) or 0),
        "cpu_threads": int(os.environ.get("METRIC_hw_cpu_threads", 0) or 0),
        "memory_gb": float(os.environ.get("METRIC_hw_ram_total_gb", 0) or 0),
        "gpu_name": os.environ.get("METRIC_hw_gpu_model", "None detected"),
        "gpu_count": int(os.environ.get("METRIC_hw_gpu_count", 0) or 0),
        "gpu_memory": os.environ.get("METRIC_hw_gpu_memory", "N/A"),
        "disk_total": os.environ.get("METRIC_hw_disk_total", "N/A"),
        "disk_available": os.environ.get("METRIC_hw_disk_available", "N/A")
    },
    
    "timings": {
        "axon_download_ms": int(os.environ.get("METRIC_axon_download_time_ms", 0) or 0),
        "core_download_ms": int(os.environ.get("METRIC_core_download_time_ms", 0) or 0),
        "core_startup_ms": int(os.environ.get("METRIC_core_startup_time_ms", 0) or 0),
        "total_model_install_ms": int(os.environ.get("METRIC_total_model_install_time_ms", 0) or 0),
        "total_register_ms": int(os.environ.get("METRIC_total_register_time_ms", 0) or 0),
        "total_inference_ms": int(os.environ.get("METRIC_total_inference_time_ms", 0) or 0),
        "total_duration_s": int(os.environ.get("METRIC_total_duration_seconds", 0) or 0)
    },
    
    "resources": {
        "core_idle_cpu": float(os.environ.get("METRIC_core_idle_cpu_avg", 0) or 0),
        "core_idle_mem_mb": float(os.environ.get("METRIC_core_idle_mem_mb", 0) or 0),
        "core_load_cpu_avg": float(os.environ.get("METRIC_core_load_cpu_avg", 0) or 0),
        "core_load_cpu_max": float(os.environ.get("METRIC_core_load_cpu_max", 0) or 0),
        "core_load_mem_avg_mb": float(os.environ.get("METRIC_core_load_mem_avg", 0) or 0),
        "core_load_mem_max_mb": float(os.environ.get("METRIC_core_load_mem_max", 0) or 0),
        "axon_cpu": float(os.environ.get("METRIC_axon_cpu_avg", 0) or 0),
        "axon_mem_mb": float(os.environ.get("METRIC_axon_mem_mb", 0) or 0),
        "gpu_status": "Not used (CPU-only inference)"
    },
    
    "models": {}
}

# Add model data - include all enabled models from config
for model in ["gpt2", "bert", "roberta", "resnet", "vit", "convnext", "mobilenet", "deit", "efficientnet"]:
    category = "nlp" if model in ["gpt2", "bert", "roberta", "t5"] else "vision" if model in ["resnet", "vgg", "vit", "convnext", "mobilenet", "deit", "efficientnet", "swin"] else "multimodal"
    
    def get_metric(suffix, default=0):
        val = os.environ.get(f"METRIC_model_{model}_{suffix}", default)
        return val if val else default
    
    inference_status = get_metric("inference_status", "unknown")
    tested = inference_status not in ["unknown", "ready_not_tested"]
    
    large_status = get_metric("large_inference_status", "unknown")
    large_tested = large_status not in ["unknown", "ready_not_tested"]
    
    try:
        install_time = int(get_metric("install_time_ms", 0) or 0)
        register_time = int(get_metric("register_time_ms", 0) or 0)
        inference_time = int(get_metric("inference_time_ms", 0) or 0)
        large_time = int(get_metric("long_inference_time_ms", 0) or 0)
    except (ValueError, TypeError):
        install_time = register_time = inference_time = large_time = 0
    
    metrics["models"][model] = {
        "category": category,
        "tested": tested,
        "install_time_ms": install_time,
        "register_time_ms": register_time,
        "inference_status": inference_status,
        "inference_time_ms": inference_time,
        "inference_large_tested": large_tested,
        "inference_large_status": large_status,
        "inference_large_time_ms": large_time
    }

with open("$output_file", "w") as f:
    json.dump(metrics, f, indent=2)
    
print(f"✅ Metrics exported to $output_file")
PYTHON_EOF
    fi
    
    echo "✅ Metrics exported to $output_file"
}

