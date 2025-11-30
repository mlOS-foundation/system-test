#!/usr/bin/env python3
"""
Generate metrics.json from E2E test results.
Parses test.log to extract timing and status metrics.
"""

import json
import os
import re
from datetime import datetime
from pathlib import Path


def find_result_dir():
    """Find the E2E test results directory."""
    search_paths = ['.', 'scripts', 'e2e-results']
    for base in search_paths:
        base_path = Path(base)
        if not base_path.exists():
            continue
        # Look for release-test-* directories
        for p in sorted(base_path.glob('release-test-*'), reverse=True):
            if p.is_dir() and (p / 'test.log').exists():
                return p
        # Look for e2e-results directory
        for p in base_path.glob('e2e-results*'):
            if p.is_dir() and (p / 'test.log').exists():
                return p
    return Path('e2e-results')


def parse_test_log(log_file):
    """Parse test.log to extract metrics."""
    metrics = {
        'models': {},
        'timings': {},
        'inference_results': []
    }
    
    if not log_file.exists():
        print(f"⚠️ Log file not found: {log_file}")
        return metrics
    
    with open(log_file, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()
    
    # Strip ANSI color codes
    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    content = ansi_escape.sub('', content)
    
    # Extract Axon download time
    match = re.search(r'Axon download[:\s]+(\d+)\s*ms', content, re.IGNORECASE)
    if match:
        metrics['timings']['axon_download_ms'] = int(match.group(1))
    
    # Extract Core download time
    match = re.search(r'Core download[:\s]+(\d+)\s*ms', content, re.IGNORECASE)
    if match:
        metrics['timings']['core_download_ms'] = int(match.group(1))
    
    # Extract Core startup time
    match = re.search(r'Core (?:startup|ready)[:\s]+\(?(\d+)\s*ms', content, re.IGNORECASE)
    if match:
        metrics['timings']['core_startup_ms'] = int(match.group(1))
    
    # Extract total duration
    match = re.search(r'Test completed in (\d+)s', content)
    if match:
        metrics['timings']['total_duration_s'] = int(match.group(1))
    
    # Extract model install times: "✅ Installed gpt2 (299417ms)"
    install_pattern = re.compile(r'✅\s*Installed\s+(\w+)\s+\((\d+)ms\)', re.IGNORECASE)
    total_install_time = 0
    for match in install_pattern.finditer(content):
        model_name = match.group(1).lower()
        install_time = int(match.group(2))
        total_install_time += install_time
        if model_name not in metrics['models']:
            metrics['models'][model_name] = {'category': 'nlp'}
        metrics['models'][model_name]['install_time_ms'] = install_time
    metrics['timings']['total_model_install_ms'] = total_install_time
    
    # Extract register times: "✅ Registered gpt2 (564ms)"
    register_pattern = re.compile(r'✅\s*Registered\s+(\w+)\s+\((\d+)ms\)', re.IGNORECASE)
    total_register_time = 0
    for match in register_pattern.finditer(content):
        model_name = match.group(1).lower()
        register_time = int(match.group(2))
        total_register_time += register_time
        if model_name not in metrics['models']:
            metrics['models'][model_name] = {'category': 'nlp'}
        metrics['models'][model_name]['register_time_ms'] = register_time
    metrics['timings']['total_register_ms'] = total_register_time
    
    # Extract inference times: "✅ gpt2 inference successful (89ms)"
    inference_pattern = re.compile(r'✅\s*(\w+)\s+inference\s+successful\s+\((\d+)ms\)', re.IGNORECASE)
    total_inference_time = 0
    for match in inference_pattern.finditer(content):
        model_name = match.group(1).lower()
        inference_time = int(match.group(2))
        total_inference_time += inference_time
        if model_name not in metrics['models']:
            metrics['models'][model_name] = {'category': 'nlp'}
        metrics['models'][model_name]['inference_time_ms'] = inference_time
        metrics['models'][model_name]['inference_status'] = 'success'
        metrics['models'][model_name]['tested'] = True
    metrics['timings']['total_inference_ms'] = total_inference_time
    
    # Extract large inference times: "✅ gpt2 large inference successful (169ms)"
    large_inference_pattern = re.compile(r'✅\s*(\w+)\s+large\s+inference\s+successful\s+\((\d+)ms\)', re.IGNORECASE)
    for match in large_inference_pattern.finditer(content):
        model_name = match.group(1).lower()
        inference_time = int(match.group(2))
        if model_name not in metrics['models']:
            metrics['models'][model_name] = {'category': 'nlp'}
        metrics['models'][model_name]['inference_large_time_ms'] = inference_time
        metrics['models'][model_name]['inference_large_status'] = 'success'
        metrics['models'][model_name]['inference_large_tested'] = True
    
    # Extract failed inferences: "❌ resnet inference failed"
    failed_pattern = re.compile(r'(?:❌|ERROR).*?(\w+)\s+inference\s+failed', re.IGNORECASE)
    for match in failed_pattern.finditer(content):
        model_name = match.group(1).lower()
        if model_name not in metrics['models']:
            metrics['models'][model_name] = {'category': 'vision'}
        metrics['models'][model_name]['inference_status'] = 'failed'
        metrics['models'][model_name]['tested'] = True
    
    # Extract total inference count: "Completed 6/7 inference tests"
    match = re.search(r'Completed\s+(\d+)/(\d+)\s+inference\s+tests', content)
    if match:
        metrics['successful_inferences'] = int(match.group(1))
        metrics['total_inferences'] = int(match.group(2))
    
    # Set model categories
    vision_models = ['resnet', 'vgg', 'vit']
    multimodal_models = ['clip', 'wav2vec']
    for model_name in metrics['models']:
        if model_name in vision_models:
            metrics['models'][model_name]['category'] = 'vision'
        elif model_name in multimodal_models:
            metrics['models'][model_name]['category'] = 'multimodal'
        else:
            metrics['models'][model_name]['category'] = 'nlp'
    
    return metrics


def main():
    result_dir = find_result_dir()
    print(f"📁 Result directory: {result_dir}")
    
    log_file = result_dir / "test.log"
    parsed = parse_test_log(log_file)
    
    # Build full metrics structure
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
            "axon_download_ms": parsed['timings'].get('axon_download_ms', 0),
            "core_download_ms": parsed['timings'].get('core_download_ms', 0),
            "core_startup_ms": parsed['timings'].get('core_startup_ms', 0),
            "total_model_install_ms": parsed['timings'].get('total_model_install_ms', 0),
            "total_register_ms": parsed['timings'].get('total_register_ms', 0),
            "total_inference_ms": parsed['timings'].get('total_inference_ms', 0),
            "total_duration_s": parsed['timings'].get('total_duration_s', 0)
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
    
    # Add default models and merge with parsed data
    default_models = {
        "gpt2": {"category": "nlp"},
        "bert": {"category": "nlp"},
        "roberta": {"category": "nlp"},
        "resnet": {"category": "vision"}
    }
    
    for model_name, defaults in default_models.items():
        model_data = parsed['models'].get(model_name, {})
        metrics["models"][model_name] = {
            "category": model_data.get('category', defaults['category']),
            "tested": model_data.get('tested', False),
            "install_time_ms": model_data.get('install_time_ms', 0),
            "register_time_ms": model_data.get('register_time_ms', 0),
            "inference_status": model_data.get('inference_status', 'unknown'),
            "inference_time_ms": model_data.get('inference_time_ms', 0),
            "inference_large_tested": model_data.get('inference_large_tested', False),
            "inference_large_status": model_data.get('inference_large_status', 'unknown'),
            "inference_large_time_ms": model_data.get('inference_large_time_ms', 0)
        }
    
    # Ensure output directory exists
    output_dir = Path("scripts/metrics")
    output_dir.mkdir(parents=True, exist_ok=True)
    
    output_file = output_dir / "latest.json"
    with open(output_file, "w") as f:
        json.dump(metrics, f, indent=2)
    
    # Print summary
    print(f"✅ Metrics written to {output_file}")
    print(f"   Models tested: {sum(1 for m in metrics['models'].values() if m.get('tested'))}")
    print(f"   Total install time: {metrics['timings']['total_model_install_ms']}ms")
    print(f"   Total inference time: {metrics['timings']['total_inference_ms']}ms")


if __name__ == "__main__":
    main()
