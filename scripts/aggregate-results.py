#!/usr/bin/env python3
"""
Aggregate results from parallel model test pipelines.

Usage:
    python aggregate-results.py --results-dir ./model-results --output metrics.json
"""

import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path


def load_result_files(results_dir: str) -> list:
    """Load all model result JSON files from a directory."""
    results = []
    results_path = Path(results_dir)
    
    if not results_path.exists():
        print(f"Warning: Results directory not found: {results_dir}")
        return results
    
    for result_file in results_path.glob("*-result.json"):
        try:
            with open(result_file) as f:
                data = json.load(f)
                data['_source_file'] = str(result_file)
                results.append(data)
        except json.JSONDecodeError as e:
            print(f"Warning: Could not parse {result_file}: {e}")
        except Exception as e:
            print(f"Warning: Error reading {result_file}: {e}")
    
    return results


def aggregate_results(results: list, hardware: dict = None, setup_timings: dict = None, resources: dict = None) -> dict:
    """Aggregate individual model results into a summary.
    
    Output format is compatible with report/render.py which expects:
    - models.{name}.tested (bool)
    - models.{name}.inference_status ('success'|'failed')
    - models.{name}.install_time_ms (int)
    - models.{name}.register_time_ms (int)
    - models.{name}.inference_time_ms (int)
    - models.{name}.category ('nlp'|'vision'|'multimodal')
    """
    
    # Model categories (from config)
    MODEL_CATEGORIES = {
        # NLP models
        'gpt2': 'nlp', 'bert': 'nlp', 'roberta': 'nlp', 't5': 'nlp',
        'distilbert': 'nlp', 'albert': 'nlp', 'sentence-transformers': 'nlp',
        # Vision models
        'resnet': 'vision', 'vit': 'vision', 'convnext': 'vision',
        'mobilenet': 'vision', 'deit': 'vision', 'efficientnet': 'vision', 'swin': 'vision',
        'detr': 'vision', 'segformer': 'vision',
        # Multimodal models
        'clip': 'multimodal', 'wav2vec2': 'multimodal',
        # LLM models (GGUF format)
        'tinyllama': 'llm', 'phi2': 'llm', 'qwen2-0.5b': 'llm'
    }
    
    total_inferences = 0
    successful_inferences = 0
    total_install_time = 0
    total_register_time = 0
    total_inference_time = 0
    
    # Use provided hardware info or defaults
    if hardware is None:
        hardware = {
            "os": "Linux",
            "os_version": "Unknown",
            "arch": "x86_64",
            "cpu_model": "Unknown",
            "cpu_cores": 2,
            "cpu_threads": 2,
            "memory_gb": 7,
            "gpu_count": 0,
            "gpu_name": "None",
            "gpu_memory": "N/A",
            "disk_total": "N/A",
            "disk_available": "N/A"
        }
    
    # Use provided setup timings or defaults
    if setup_timings is None:
        setup_timings = {
            "axon_download_ms": 0,
            "core_download_ms": 0,
            "core_startup_ms": 0
        }
    
    # Use provided resources or defaults
    if resources is None:
        resources = {
            "core_idle_cpu": 0,
            "core_idle_mem_mb": 0,
            "core_load_cpu_avg": 0,
            "core_load_cpu_max": 0,
            "core_load_mem_avg_mb": 0,
            "core_load_mem_max_mb": 0,
            "axon_cpu": 0,
            "axon_mem_mb": 0,
            "gpu_status": "Not used (CPU-only inference)"
        }
    
    summary = {
        "generated_at": datetime.utcnow().isoformat() + "Z",
        "total_models": len(results),
        "successful_models": 0,
        "partial_models": 0,
        "failed_models": 0,
        "total_inferences": 0,
        "successful_inferences": 0,
        "models": {},
        "total_time_ms": 0,
        # Versions - render.py expects versions.axon and versions.core
        # Get from environment variables or use defaults
        "versions": {
            "axon": os.environ.get("AXON_VERSION", os.environ.get("AXON_RELEASE_VERSION", "unknown")),
            "core": os.environ.get("CORE_VERSION", os.environ.get("CORE_RELEASE_VERSION", "unknown"))
        },
        # Hardware - from actual runner
        "hardware": hardware,
        # Resources - from actual measurements
        "resources": resources,
        # Timings - merge setup timings with model timings
        "timings": {
            "axon_download_ms": setup_timings.get("axon_download_ms", 0),
            "core_download_ms": setup_timings.get("core_download_ms", 0),
            "core_startup_ms": setup_timings.get("core_startup_ms", 0),
            "total_model_install_ms": 0,
            "total_register_ms": 0,
            "total_inference_ms": 0,
            "total_duration_s": 0
        }
    }
    
    for result in results:
        model_name = result.get("model_name", "unknown")
        status = result.get("status", "unknown")
        phases = result.get("phases", {})
        
        # Count overall status
        if status == "success":
            summary["successful_models"] += 1
        elif status == "partial":
            summary["partial_models"] += 1
        else:
            summary["failed_models"] += 1
        
        # Get version info from first result
        if result.get("axon_version"):
            summary["versions"]["axon"] = result["axon_version"]
        if result.get("core_version"):
            summary["versions"]["core"] = result["core_version"]
        
        # Build model entry in format render.py expects
        install_phase = phases.get("install", {})
        register_phase = phases.get("register", {})
        inference_small = phases.get("inference_small", {})
        inference_large = phases.get("inference_large", {})
        
        install_time = install_phase.get("time_ms", 0)
        register_time = register_phase.get("time_ms", 0)
        inference_time = inference_small.get("time_ms", 0)
        inference_large_time = inference_large.get("time_ms", 0)
        
        total_install_time += install_time
        total_register_time += register_time
        total_inference_time += inference_time + inference_large_time
        
        # Determine inference status
        inference_status = inference_small.get("status", "not_tested")
        inference_large_status = inference_large.get("status", "not_tested")
        
        # Count inferences
        if inference_small.get("status"):
            total_inferences += 1
            if inference_status == "success":
                successful_inferences += 1
        if inference_large.get("status"):
            total_inferences += 1
            if inference_large_status == "success":
                successful_inferences += 1
        
        model_summary = {
            # Fields expected by render.py
            "tested": install_phase.get("status") == "success",
            "category": MODEL_CATEGORIES.get(model_name, "nlp"),
            "install_time_ms": install_time,
            "register_time_ms": register_time,
            "inference_time_ms": inference_time,
            "inference_large_time_ms": inference_large_time,
            "inference_status": inference_status,
            "inference_large_status": inference_large_status,
            "inference_large_tested": inference_large.get("status") is not None,
            "status": status,
            # Also keep phases for detailed view
            "phases": {}
        }
        
        for phase_name, phase_data in phases.items():
            model_summary["phases"][phase_name] = {
                "status": phase_data.get("status", "unknown"),
                "time_ms": phase_data.get("time_ms", 0)
            }
            if phase_data.get("error"):
                model_summary["phases"][phase_name]["error"] = phase_data["error"]
        
        model_summary["total_time_ms"] = result.get("total_time_ms", 0)
        summary["models"][model_name] = model_summary
        summary["total_time_ms"] += result.get("total_time_ms", 0)
    
    # Update inference counts
    summary["total_inferences"] = total_inferences
    summary["successful_inferences"] = successful_inferences
    
    # Update timings
    summary["timings"]["total_model_install_ms"] = total_install_time
    summary["timings"]["total_register_ms"] = total_register_time
    summary["timings"]["total_inference_ms"] = total_inference_time
    summary["timings"]["total_duration_s"] = round(summary["total_time_ms"] / 1000, 1)
    
    # Calculate success rates
    if summary["total_models"] > 0:
        summary["success_rate"] = round(
            (summary["successful_models"] / summary["total_models"]) * 100, 2
        )
    else:
        summary["success_rate"] = 0
    
    return summary


def generate_markdown_report(summary: dict) -> str:
    """Generate a markdown summary report."""
    total_inferences = summary.get('total_inferences', 0)
    successful_inferences = summary.get('successful_inferences', 0)
    
    lines = [
        "# E2E Test Results Summary",
        "",
        f"Generated: {summary['generated_at']}",
        "",
        "## Overview",
        "",
        f"| Metric | Value |",
        f"|--------|-------|",
        f"| Total Models | {summary['total_models']} |",
        f"| Successful | {summary['successful_models']} |",
        f"| Partial | {summary.get('partial_models', 0)} |",
        f"| Failed | {summary.get('failed_models', 0)} |",
        f"| Success Rate | {summary.get('success_rate', 0)}% |",
        f"| Total Inferences | {successful_inferences}/{total_inferences} |",
        f"| Total Time | {summary.get('total_time_ms', 0)}ms |",
        "",
        "## Model Details",
        "",
    ]
    
    for model_name, model_data in summary.get("models", {}).items():
        status_emoji = "✅" if model_data.get("status") == "success" else "⚠️" if model_data.get("status") == "partial" else "❌"
        lines.append(f"### {status_emoji} {model_name.upper()}")
        lines.append("")
        lines.append(f"- **Category**: {model_data.get('category', 'unknown')}")
        lines.append(f"- **Install**: {model_data.get('install_time_ms', 0)}ms")
        lines.append(f"- **Register**: {model_data.get('register_time_ms', 0)}ms")
        lines.append(f"- **Inference (small)**: {model_data.get('inference_time_ms', 0)}ms - {model_data.get('inference_status', 'N/A')}")
        lines.append(f"- **Inference (large)**: {model_data.get('inference_large_time_ms', 0)}ms - {model_data.get('inference_large_status', 'N/A')}")
        lines.append("")
    
    return "\n".join(lines)


def load_hardware_info(hardware_file: str) -> dict:
    """Load hardware info from JSON file."""
    default_hardware = {
        "os": "Linux",
        "os_version": "Unknown",
        "arch": "x86_64",
        "cpu_model": "Unknown",
        "cpu_cores": 2,
        "cpu_threads": 2,
        "memory_gb": 7,
        "gpu_count": 0,
        "gpu_name": "None",
        "gpu_memory": "N/A",
        "disk_total": "N/A",
        "disk_available": "N/A"
    }
    
    if not hardware_file or not os.path.exists(hardware_file):
        return default_hardware
    
    try:
        with open(hardware_file) as f:
            hardware = json.load(f)
            # Merge with defaults for any missing fields
            for key, value in default_hardware.items():
                if key not in hardware:
                    hardware[key] = value
            return hardware
    except Exception as e:
        print(f"Warning: Could not load hardware info: {e}")
        return default_hardware


def load_timings_info(timings_file: str) -> dict:
    """Load timing info from JSON file."""
    default_timings = {
        "axon_download_ms": 0,
        "core_download_ms": 0,
        "core_startup_ms": 0
    }
    
    if not timings_file or not os.path.exists(timings_file):
        return default_timings
    
    try:
        with open(timings_file) as f:
            timings = json.load(f)
            # Merge with defaults for any missing fields
            for key, value in default_timings.items():
                if key not in timings:
                    timings[key] = value
            return timings
    except Exception as e:
        print(f"Warning: Could not load timings info: {e}")
        return default_timings


def load_resources_info(resources_file: str) -> dict:
    """Load resource usage info from JSON file."""
    default_resources = {
        "core_idle_cpu": 0,
        "core_idle_mem_mb": 0,
        "core_load_cpu_avg": 0,
        "core_load_cpu_max": 0,
        "core_load_mem_avg_mb": 0,
        "core_load_mem_max_mb": 0,
        "axon_cpu": 0,
        "axon_mem_mb": 0,
        "gpu_status": "Not used (CPU-only inference)"
    }
    
    if not resources_file or not os.path.exists(resources_file):
        return default_resources
    
    try:
        with open(resources_file) as f:
            resources = json.load(f)
            # Merge with defaults for any missing fields
            for key, value in default_resources.items():
                if key not in resources:
                    resources[key] = value
            return resources
    except Exception as e:
        print(f"Warning: Could not load resources info: {e}")
        return default_resources


def main():
    parser = argparse.ArgumentParser(description="Aggregate parallel model test results")
    parser.add_argument("--results-dir", required=True, help="Directory containing result JSON files")
    parser.add_argument("--output", default="aggregated-metrics.json", help="Output JSON file")
    parser.add_argument("--markdown", help="Optional markdown report output")
    parser.add_argument("--hardware-info", help="JSON file with hardware information")
    parser.add_argument("--timings-info", help="JSON file with setup timing information")
    parser.add_argument("--resources-info", help="JSON file with resource usage information")
    parser.add_argument("--github-summary", action="store_true", help="Write to GITHUB_STEP_SUMMARY")
    
    args = parser.parse_args()
    
    # Load hardware info
    hardware = load_hardware_info(args.hardware_info)
    print(f"Hardware: {hardware.get('cpu_model', 'Unknown')} ({hardware.get('cpu_cores', '?')} cores)")
    
    # Load timings info
    setup_timings = load_timings_info(args.timings_info)
    print(f"Setup timings: Axon={setup_timings.get('axon_download_ms', 0)}ms, Core={setup_timings.get('core_download_ms', 0)}ms")
    
    # Load resources info
    resources = load_resources_info(args.resources_info)
    print(f"Resources: Core idle={resources.get('core_idle_cpu', 0)}% CPU, {resources.get('core_idle_mem_mb', 0)}MB RAM")
    
    # Load results
    print(f"Loading results from: {args.results_dir}")
    results = load_result_files(args.results_dir)
    
    if not results:
        print("No results found!")
        # Create empty summary
        summary = {
            "generated_at": datetime.utcnow().isoformat() + "Z",
            "total_models": 0,
            "successful_models": 0,
            "partial_models": 0,
            "failed_models": 0,
            "success_rate": 0,
            "phases": {},
            "models": {},
            "hardware": hardware,
            "error": "No results found"
        }
    else:
        print(f"Found {len(results)} model results")
        summary = aggregate_results(results, hardware, setup_timings, resources)
    
    # Write JSON output
    with open(args.output, 'w') as f:
        json.dump(summary, f, indent=2)
    print(f"Wrote aggregated metrics to: {args.output}")
    
    # Generate markdown report
    markdown = generate_markdown_report(summary)
    
    if args.markdown:
        with open(args.markdown, 'w') as f:
            f.write(markdown)
        print(f"Wrote markdown report to: {args.markdown}")
    
    # Write to GitHub Actions summary
    if args.github_summary:
        summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_file:
            with open(summary_file, 'a') as f:
                f.write(markdown)
            print("Wrote to GITHUB_STEP_SUMMARY")
    
    # Exit with error if all tests failed
    if summary["total_models"] > 0 and summary["successful_models"] == 0:
        print("ERROR: All model tests failed!")
        sys.exit(1)
    
    print(f"\nSummary: {summary['successful_models']}/{summary['total_models']} models passed")
    sys.exit(0)


if __name__ == "__main__":
    main()

