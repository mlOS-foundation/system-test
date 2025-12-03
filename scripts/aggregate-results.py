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
    """Aggregate individual model results into a summary."""
    
    summary = {
        "generated_at": datetime.utcnow().isoformat() + "Z",
        "total_models": len(results),
        "successful_models": 0,
        "partial_models": 0,
        "failed_models": 0,
        "phases": {
            "install": {"success": 0, "failed": 0, "total_time_ms": 0},
            "register": {"success": 0, "failed": 0, "total_time_ms": 0},
            "inference_small": {"success": 0, "failed": 0, "total_time_ms": 0},
            "inference_large": {"success": 0, "failed": 0, "total_time_ms": 0}
        },
        "models": {},
        "total_time_ms": 0
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
        
        # Aggregate phase metrics
        model_summary = {
            "status": status,
            "phases": {}
        }
        
        for phase_name, phase_data in phases.items():
            phase_status = phase_data.get("status", "unknown")
            phase_time = phase_data.get("time_ms", 0)
            
            model_summary["phases"][phase_name] = {
                "status": phase_status,
                "time_ms": phase_time
            }
            
            if phase_data.get("error"):
                model_summary["phases"][phase_name]["error"] = phase_data["error"]
            
            # Update summary counters
            if phase_name in summary["phases"]:
                if phase_status == "success":
                    summary["phases"][phase_name]["success"] += 1
                elif phase_status == "failed":
                    summary["phases"][phase_name]["failed"] += 1
                summary["phases"][phase_name]["total_time_ms"] += phase_time
        
        model_summary["total_time_ms"] = result.get("total_time_ms", 0)
        summary["models"][model_name] = model_summary
        summary["total_time_ms"] += result.get("total_time_ms", 0)
    
    # Calculate success rates
    if summary["total_models"] > 0:
        summary["success_rate"] = round(
            (summary["successful_models"] / summary["total_models"]) * 100, 2
        )
    else:
        summary["success_rate"] = 0
    
    # Calculate phase success rates
    for phase_name, phase_data in summary["phases"].items():
        total = phase_data["success"] + phase_data["failed"]
        if total > 0:
            phase_data["success_rate"] = round((phase_data["success"] / total) * 100, 2)
            phase_data["avg_time_ms"] = round(phase_data["total_time_ms"] / total, 2)
        else:
            phase_data["success_rate"] = 0
            phase_data["avg_time_ms"] = 0
    
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

