#!/usr/bin/env python3
"""
Historical Metrics Manager

Tracks performance metrics across multiple E2E runs and calculates statistics
(mean, median, standard deviation) for consistent benchmarking.

Usage:
    # Add new run data
    python historical-metrics.py add --metrics metrics/latest.json --history metrics/history.json

    # Calculate statistics
    python historical-metrics.py stats --history metrics/history.json --output metrics/statistics.json

    # Reset history (start fresh)
    python historical-metrics.py reset --history metrics/history.json

    # Show summary
    python historical-metrics.py summary --history metrics/history.json
"""

import argparse
import json
import statistics
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Any, Optional


def load_json(path: Path) -> Dict:
    """Load JSON file, return empty dict if not found."""
    if path.exists():
        with open(path) as f:
            return json.load(f)
    return {}


def save_json(path: Path, data: Dict):
    """Save data to JSON file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)


def extract_run_metrics(metrics: Dict) -> Dict:
    """Extract key metrics from a single run for historical tracking."""
    run_data = {
        'timestamp': metrics.get('generated_at', datetime.utcnow().isoformat() + 'Z'),
        'versions': metrics.get('versions', {}),
        'total_models': metrics.get('total_models', 0),
        'successful_models': metrics.get('successful_models', 0),
        'success_rate': metrics.get('success_rate', 0),
        'models': {},
        'kernel_comparison': {}
    }

    # Extract per-model metrics
    for model_name, model_data in metrics.get('models', {}).items():
        if model_data.get('tested'):
            run_data['models'][model_name] = {
                'install_time_ms': model_data.get('install_time_ms', 0),
                'register_time_ms': model_data.get('register_time_ms', 0),
                'inference_time_ms': model_data.get('inference_time_ms', 0),
                'status': model_data.get('status', 'unknown')
            }

    # Extract kernel comparison if available
    kc = metrics.get('kernel_comparison', {})
    if kc.get('comparison_enabled'):
        run_data['kernel_comparison'] = {
            'kernel_mode': kc.get('kernel_mode', 'scheduler'),
            'average_speedup': kc.get('average_speedup', 0),
            'models_tested': kc.get('models_tested', 0),
            'speedup': kc.get('speedup', {}),
            'kernel_results': kc.get('kernel_results', {}),
            'userspace_results': kc.get('userspace_results', {})
        }

    return run_data


def add_run(metrics_path: Path, history_path: Path) -> Dict:
    """Add a new run to the historical data."""
    metrics = load_json(metrics_path)
    history = load_json(history_path)

    if 'runs' not in history:
        history['runs'] = []
        history['created_at'] = datetime.utcnow().isoformat() + 'Z'

    run_data = extract_run_metrics(metrics)
    run_data['run_number'] = len(history['runs']) + 1

    history['runs'].append(run_data)
    history['updated_at'] = datetime.utcnow().isoformat() + 'Z'
    history['total_runs'] = len(history['runs'])

    save_json(history_path, history)

    print(f"Added run #{run_data['run_number']} to history")
    print(f"Total runs: {history['total_runs']}")

    return history


def calculate_statistics(history: Dict) -> Dict:
    """Calculate mean, median, and stddev for all metrics across runs."""
    runs = history.get('runs', [])

    if not runs:
        return {'error': 'No runs in history'}

    stats = {
        'generated_at': datetime.utcnow().isoformat() + 'Z',
        'total_runs': len(runs),
        'first_run': runs[0].get('timestamp') if runs else None,
        'last_run': runs[-1].get('timestamp') if runs else None,
        'models': {},
        'kernel_comparison': {},
        'overall': {}
    }

    # Collect per-model metrics across runs
    model_metrics = {}  # model_name -> {metric_name -> [values]}

    for run in runs:
        for model_name, model_data in run.get('models', {}).items():
            if model_name not in model_metrics:
                model_metrics[model_name] = {
                    'install_time_ms': [],
                    'register_time_ms': [],
                    'inference_time_ms': []
                }

            for metric in ['install_time_ms', 'register_time_ms', 'inference_time_ms']:
                value = model_data.get(metric, 0)
                if value > 0:
                    model_metrics[model_name][metric].append(value)

    # Calculate stats for each model
    for model_name, metrics in model_metrics.items():
        stats['models'][model_name] = {}
        for metric_name, values in metrics.items():
            if len(values) >= 1:
                stats['models'][model_name][metric_name] = calc_stats(values)

    # Collect kernel comparison metrics
    kernel_speedups = {}  # model_name -> [speedup values]
    avg_speedups = []

    for run in runs:
        kc = run.get('kernel_comparison', {})
        if kc:
            if kc.get('average_speedup', 0) > 0:
                avg_speedups.append(kc['average_speedup'])

            for model_name, speedup in kc.get('speedup', {}).items():
                if speedup > 0:
                    if model_name not in kernel_speedups:
                        kernel_speedups[model_name] = []
                    kernel_speedups[model_name].append(speedup)

    # Calculate kernel comparison stats
    if avg_speedups:
        stats['kernel_comparison']['average_speedup'] = calc_stats(avg_speedups)

    stats['kernel_comparison']['models'] = {}
    for model_name, speedups in kernel_speedups.items():
        if speedups:
            stats['kernel_comparison']['models'][model_name] = calc_stats(speedups)

    # Overall success rate
    success_rates = [run.get('success_rate', 0) for run in runs if run.get('success_rate', 0) > 0]
    if success_rates:
        stats['overall']['success_rate'] = calc_stats(success_rates)

    return stats


def calc_stats(values: List[float]) -> Dict[str, float]:
    """Calculate mean, median, stddev for a list of values."""
    if not values:
        return {'mean': 0, 'median': 0, 'stddev': 0, 'min': 0, 'max': 0, 'count': 0}

    result = {
        'mean': round(statistics.mean(values), 2),
        'median': round(statistics.median(values), 2),
        'min': round(min(values), 2),
        'max': round(max(values), 2),
        'count': len(values)
    }

    if len(values) >= 2:
        result['stddev'] = round(statistics.stdev(values), 2)
    else:
        result['stddev'] = 0

    return result


def reset_history(history_path: Path) -> Dict:
    """Reset the historical data."""
    history = {
        'runs': [],
        'created_at': datetime.utcnow().isoformat() + 'Z',
        'updated_at': datetime.utcnow().isoformat() + 'Z',
        'total_runs': 0,
        'reset_at': datetime.utcnow().isoformat() + 'Z'
    }
    save_json(history_path, history)
    print(f"History reset at {history_path}")
    return history


def print_summary(history: Dict):
    """Print a summary of historical data."""
    runs = history.get('runs', [])

    print(f"\n{'='*60}")
    print("Historical Metrics Summary")
    print(f"{'='*60}")
    print(f"Total runs: {len(runs)}")

    if not runs:
        print("No runs recorded yet.")
        return

    print(f"First run: {runs[0].get('timestamp', 'N/A')}")
    print(f"Last run: {runs[-1].get('timestamp', 'N/A')}")

    # Calculate quick stats
    stats = calculate_statistics(history)

    print(f"\n{'='*60}")
    print("Kernel vs Userspace Speedup (across all runs)")
    print(f"{'='*60}")

    kc_stats = stats.get('kernel_comparison', {})
    avg_stats = kc_stats.get('average_speedup', {})
    if avg_stats:
        print(f"Average speedup: {avg_stats.get('mean', 0):.2f}x "
              f"(median: {avg_stats.get('median', 0):.2f}x, "
              f"stddev: {avg_stats.get('stddev', 0):.2f})")

    print(f"\n{'='*60}")
    print("Per-Model Inference Times (ms)")
    print(f"{'='*60}")
    print(f"{'Model':<25} {'Mean':<10} {'Median':<10} {'StdDev':<10} {'Runs':<6}")
    print("-" * 60)

    for model_name, model_stats in sorted(stats.get('models', {}).items()):
        inf_stats = model_stats.get('inference_time_ms', {})
        if inf_stats.get('count', 0) > 0:
            print(f"{model_name:<25} "
                  f"{inf_stats.get('mean', 0):<10.1f} "
                  f"{inf_stats.get('median', 0):<10.1f} "
                  f"{inf_stats.get('stddev', 0):<10.1f} "
                  f"{inf_stats.get('count', 0):<6}")


def main():
    parser = argparse.ArgumentParser(description='Historical Metrics Manager')
    subparsers = parser.add_subparsers(dest='command', help='Commands')

    # Add command
    add_parser = subparsers.add_parser('add', help='Add new run to history')
    add_parser.add_argument('--metrics', required=True, help='Path to latest metrics JSON')
    add_parser.add_argument('--history', required=True, help='Path to history JSON')

    # Stats command
    stats_parser = subparsers.add_parser('stats', help='Calculate statistics')
    stats_parser.add_argument('--history', required=True, help='Path to history JSON')
    stats_parser.add_argument('--output', required=True, help='Path to output statistics JSON')

    # Reset command
    reset_parser = subparsers.add_parser('reset', help='Reset history')
    reset_parser.add_argument('--history', required=True, help='Path to history JSON')

    # Summary command
    summary_parser = subparsers.add_parser('summary', help='Print summary')
    summary_parser.add_argument('--history', required=True, help='Path to history JSON')

    args = parser.parse_args()

    if args.command == 'add':
        add_run(Path(args.metrics), Path(args.history))
    elif args.command == 'stats':
        history = load_json(Path(args.history))
        stats = calculate_statistics(history)
        save_json(Path(args.output), stats)
        print(f"Statistics saved to {args.output}")
    elif args.command == 'reset':
        reset_history(Path(args.history))
    elif args.command == 'summary':
        history = load_json(Path(args.history))
        print_summary(history)
    else:
        parser.print_help()


if __name__ == '__main__':
    main()
