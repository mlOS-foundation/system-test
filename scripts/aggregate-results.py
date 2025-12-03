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


def aggregate_results(results: list) -> dict:
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
        'gpt2': 'nlp', 'bert': 'nlp', 'roberta': 'nlp', 't5': 'nlp',
        'resnet': 'vision', 'vit': 'vision', 'convnext': 'vision',
        'mobilenet': 'vision', 'deit': 'vision', 'efficientnet': 'vision', 'swin': 'vision',
        'clip': 'multimodal'
    }
    
    total_inferences = 0
    successful_inferences = 0
    total_install_time = 0
    total_register_time = 0
    
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
        # Add version info (will be overwritten if available)
        "axon_version": "v3.1.1",
        "core_version": "3.2.5-alpha",
        # Hardware placeholders (render.py expects these)
        "hardware": {
            "os": "Linux",
            "arch": "x86_64",
            "cpu": "GitHub Actions Runner",
            "cpu_cores": 2,
            "cpu_threads": 2,
            "memory_gb": 7,
            "gpu_count": 0,
            "gpu_name": "None",
            "gpu_memory": "N/A"
        },
        # Resource metrics placeholders
        "resource_usage": {
            "core_idle_cpu": 0,
            "core_idle_mem": 0,
            "core_load_cpu": 0,
            "core_load_cpu_max": 0,
            "core_load_mem": 0,
            "core_load_mem_max": 0,
            "axon_cpu": 0,
            "axon_mem": 0
        },
        # Timing metrics
        "timing": {
            "axon_download_ms": 0,
            "core_download_ms": 0,
            "core_startup_ms": 0,
            "total_model_install_ms": 0
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
            summary["axon_version"] = result["axon_version"]
        if result.get("core_version"):
            summary["core_version"] = result["core_version"]
        
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
    
    # Update timing
    summary["timing"]["total_model_install_ms"] = total_install_time
    
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
        f"| Partial | {summary['partial_models']} |",
        f"| Failed | {summary['failed_models']} |",
        f"| Success Rate | {summary['success_rate']}% |",
        f"| Total Time | {summary['total_time_ms']}ms |",
        "",
        "## Phase Breakdown",
        "",
        "| Phase | Success | Failed | Avg Time |",
        "|-------|---------|--------|----------|",
    ]
    
    for phase_name, phase_data in summary["phases"].items():
        lines.append(
            f"| {phase_name} | {phase_data['success']} | {phase_data['failed']} | {phase_data['avg_time_ms']}ms |"
        )
    
    lines.extend([
        "",
        "## Model Details",
        "",
    ])
    
    for model_name, model_data in summary.get("models", {}).items():
        status_emoji = "✅" if model_data["status"] == "success" else "⚠️" if model_data["status"] == "partial" else "❌"
        lines.append(f"### {status_emoji} {model_name}")
        lines.append("")
        lines.append(f"- **Status**: {model_data['status']}")
        lines.append(f"- **Total Time**: {model_data['total_time_ms']}ms")
        lines.append("")
        
        for phase_name, phase_data in model_data.get("phases", {}).items():
            phase_emoji = "✅" if phase_data["status"] == "success" else "❌"
            error_info = f" - {phase_data['error']}" if phase_data.get("error") else ""
            lines.append(f"  - {phase_emoji} {phase_name}: {phase_data['time_ms']}ms{error_info}")
        
        lines.append("")
    
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Aggregate parallel model test results")
    parser.add_argument("--results-dir", required=True, help="Directory containing result JSON files")
    parser.add_argument("--output", default="aggregated-metrics.json", help="Output JSON file")
    parser.add_argument("--markdown", help="Optional markdown report output")
    parser.add_argument("--github-summary", action="store_true", help="Write to GITHUB_STEP_SUMMARY")
    
    args = parser.parse_args()
    
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
            "error": "No results found"
        }
    else:
        print(f"Found {len(results)} model results")
        summary = aggregate_results(results)
    
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

