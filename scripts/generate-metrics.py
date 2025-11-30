#!/usr/bin/env python3
"""
Generate metrics.json from E2E test results.
Used by GitHub Actions workflow to create metrics for the Python renderer.
"""

import json
import os
import re
from datetime import datetime
from pathlib import Path


def find_result_dir():
    """Find the E2E test results directory."""
    for d in ['e2e-results', '.', 'scripts']:
        base = Path(d)
        for p in base.glob('release-test-*'):
            if p.is_dir():
                return p
        for p in base.glob('e2e-results*'):
            if p.is_dir():
                return p
    return Path('e2e-results')


def main():
    result_dir = find_result_dir()
    
    metrics = {
        "timestamp": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "test_dir": str(result_dir),
        "versions": {
            "axon": os.environ.get("AXON_RELEASE_VERSION", "N/A"),
            "core": os.environ.get("CORE_RELEASE_VERSION", "N/A")
        },
        "hardware": {
            "os": "Linux",
            "os_version": "Ubuntu 22.04",
            "arch": "x86_64",
            "cpu_model": "GitHub Actions Runner",
            "cpu_cores": 2,
            "cpu_threads": 2,
            "memory_gb": 7,
            "gpu_name": "None",
            "gpu_count": 0,
            "gpu_memory": "N/A",
            "disk_total": "N/A",
            "disk_available": "N/A"
        },
        "timings": {
            "axon_download_ms": 0,
            "core_download_ms": 0,
            "core_startup_ms": 0,
            "total_model_install_ms": 0,
            "total_register_ms": 0,
            "total_inference_ms": 0,
            "total_duration_s": 0
        },
        "resources": {
            "core_idle_cpu": 0,
            "core_idle_mem_mb": 0,
            "core_load_cpu_avg": 0,
            "core_load_cpu_max": 0,
            "core_load_mem_avg_mb": 0,
            "core_load_mem_max_mb": 0,
            "axon_cpu": 0,
            "axon_mem_mb": 0,
            "gpu_status": "Not used (CPU-only inference)"
        },
        "models": {}
    }
    
    # Try to parse test.log for metrics
    log_file = result_dir / "test.log" if result_dir.exists() else None
    if log_file and log_file.exists():
        with open(log_file) as f:
            content = f.read()
            
            # Extract timing patterns
            patterns = {
                "axon_download_ms": r"Axon download.*?(\d+)\s*ms",
                "core_download_ms": r"Core download.*?(\d+)\s*ms",
                "core_startup_ms": r"Core startup.*?(\d+)\s*ms",
            }
            for key, pattern in patterns.items():
                match = re.search(pattern, content, re.IGNORECASE)
                if match:
                    metrics["timings"][key] = int(match.group(1))
    
    # Default model data
    for model in ["gpt2", "bert", "roberta", "resnet"]:
        category = "nlp" if model in ["gpt2", "bert", "roberta"] else "vision"
        metrics["models"][model] = {
            "category": category,
            "tested": False,
            "install_time_ms": 0,
            "register_time_ms": 0,
            "inference_status": "unknown",
            "inference_time_ms": 0,
            "inference_large_tested": False,
            "inference_large_status": "unknown",
            "inference_large_time_ms": 0
        }
    
    # Ensure output directory exists
    output_dir = Path("scripts/metrics")
    output_dir.mkdir(parents=True, exist_ok=True)
    
    output_file = output_dir / "latest.json"
    with open(output_file, "w") as f:
        json.dump(metrics, f, indent=2)
    
    print(f"✅ Metrics written to {output_file}")


if __name__ == "__main__":
    main()

