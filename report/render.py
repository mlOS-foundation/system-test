#!/usr/bin/env python3
"""
MLOS E2E Report Renderer

Renders HTML report from metrics JSON file and HTML template.
All business logic for status calculation, chart data generation, etc. is here.

Usage:
    python3 render.py [--metrics PATH] [--template PATH] [--output PATH]
    
    --metrics   Path to metrics JSON file (default: scripts/metrics/latest.json)
    --template  Path to HTML template (default: report/template.html)
    --output    Path to output HTML file (default: output/index.html)
"""

import json
import os
import sys
import argparse
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, List, Optional

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False


def format_time(ms: int) -> str:
    """Format milliseconds to human-readable time.
    
    - < 1000ms: show as ms (e.g., "523 ms")
    - 1-60s: show as seconds (e.g., "5.2s")
    - 1-60min: show as minutes (e.g., "3.5 min")
    - > 60min: show as hours (e.g., "1.2 hr")
    """
    if ms < 1000:
        return f"{ms} ms"
    
    seconds = ms / 1000
    if seconds < 60:
        return f"{seconds:.1f}s"
    
    minutes = seconds / 60
    if minutes < 60:
        return f"{minutes:.1f} min"
    
    hours = minutes / 60
    return f"{hours:.1f} hr"


class ReportRenderer:
    """Renders E2E test report from metrics JSON."""
    
    def __init__(self, metrics_path: str, template_path: str, output_path: str):
        self.metrics_path = Path(metrics_path)
        self.template_path = Path(template_path)
        self.output_path = Path(output_path)
        self.metrics: Dict[str, Any] = {}
        
    def load_metrics(self) -> bool:
        """Load metrics from JSON file."""
        if not self.metrics_path.exists():
            print(f"❌ Metrics file not found: {self.metrics_path}")
            return False
        
        try:
            with open(self.metrics_path, 'r', encoding='utf-8') as f:
                self.metrics = json.load(f)
            print(f"✅ Loaded metrics from {self.metrics_path}")
            return True
        except json.JSONDecodeError as e:
            print(f"❌ Invalid JSON in metrics file: {e}")
            return False
    
    def load_template(self) -> Optional[str]:
        """Load HTML template."""
        if not self.template_path.exists():
            print(f"❌ Template file not found: {self.template_path}")
            return None
        
        with open(self.template_path, 'r', encoding='utf-8') as f:
            return f.read()
    
    def calculate_overall_status(self) -> Dict[str, Any]:
        """Calculate overall test status from metrics."""
        models = self.metrics.get('models', {})
        total_tests = 0
        passed_tests = 0
        
        for model_name, model_data in models.items():
            if model_data.get('tested', False):
                total_tests += 1
                if model_data.get('inference_status') == 'success':
                    passed_tests += 1
                # Count large inference separately if tested
                if model_data.get('inference_large_status') == 'success':
                    total_tests += 1
                    passed_tests += 1
                elif model_data.get('inference_large_tested', False):
                    total_tests += 1
        
        success_rate = (passed_tests / total_tests * 100) if total_tests > 0 else 0
        
        return {
            'total_tests': total_tests,
            'passed_tests': passed_tests,
            'success_rate': round(success_rate, 1),
            'status_class': 'success' if success_rate == 100 else ('warning' if success_rate >= 50 else 'failed')
        }
    
    def calculate_category_status(self, category: str) -> Dict[str, Any]:
        """Calculate status for a model category (nlp, vision, multimodal)."""
        models = self.metrics.get('models', {})
        tested = 0
        passed = 0
        
        for model_name, model_data in models.items():
            if model_data.get('category') == category and model_data.get('tested', False):
                tested += 1
                if model_data.get('inference_status') == 'success':
                    passed += 1
        
        if tested == 0:
            return {
                'status': '⏳ Ready',
                'status_class': 'ready_not_tested',
                'tested': 0,
                'passed': 0
            }
        elif passed == tested:
            return {
                'status': '✅ Passing',
                'status_class': 'success',
                'tested': tested,
                'passed': passed
            }
        else:
            return {
                'status': '❌ Failed',
                'status_class': 'failed',
                'tested': tested,
                'passed': passed
            }
    
    def get_model_status(self, model_name: str, test_type: str = 'small') -> Dict[str, str]:
        """Get status badge info for a specific model."""
        models = self.metrics.get('models', {})
        model_data = models.get(model_name, {})
        
        if test_type == 'large':
            status_key = 'inference_large_status'
            tested_key = 'inference_large_tested'
        else:
            status_key = 'inference_status'
            tested_key = 'tested'
        
        if not model_data.get(tested_key, False):
            return {'status': '⏳', 'status_class': 'ready_not_tested'}
        elif model_data.get(status_key) == 'success':
            return {'status': '✅', 'status_class': 'success'}
        else:
            return {'status': '❌', 'status_class': 'failed'}
    
    def generate_installation_chart_data(self) -> Dict[str, Any]:
        """Generate data for installation times chart."""
        timings = self.metrics.get('timings', {})
        
        labels = ['Axon Download', 'Core Download', 'Core Startup', 'Model Install']
        data = [
            timings.get('axon_download_ms', 0),
            timings.get('core_download_ms', 0),
            timings.get('core_startup_ms', 0),
            timings.get('total_model_install_ms', 0)
        ]
        colors = ['#667eea', '#764ba2', '#38ef7d', '#11998e']
        
        return {
            'labels': json.dumps(labels),
            'data': json.dumps(data),
            'colors': json.dumps(colors)
        }
    
    def generate_inference_chart_data(self) -> Dict[str, Any]:
        """Generate data for inference performance chart."""
        models = self.metrics.get('models', {})
        
        labels = []
        data = []
        colors = []
        
        color_map = {
            # NLP models
            'gpt2': '#667eea',
            'bert': '#764ba2',
            'roberta': '#f093fb',
            't5': '#f59e0b',  # Orange for T5 (encoder-decoder)
            'distilbert': '#a855f7',  # Purple
            'albert': '#6366f1',  # Indigo
            'sentence-transformers': '#3b82f6',  # Blue
            # Vision models
            'resnet': '#11998e',
            'vgg': '#38ef7d',
            'vit': '#10b981',
            'convnext': '#06b6d4',
            'mobilenet': '#ec4899',
            'deit': '#14b8a6',
            'efficientnet': '#84cc16',
            'swin': '#22c55e',
            'detr': '#eab308',
            'segformer': '#f97316',
            # Multimodal models
            'clip': '#8b5cf6',  # Purple for CLIP (multi-encoder)
            'wav2vec2': '#d946ef',
            # LLM models (GGUF)
            'tinyllama': '#f59e0b',  # Amber
            'phi2': '#f97316',  # Orange
            'qwen2-0.5b': '#fb923c',  # Light orange
            'llama-3.2-1b': '#ef4444',  # Red
            'llama-3.2-3b': '#dc2626',  # Dark red
            'deepseek-coder-1.3b': '#0ea5e9',  # Sky blue
            'deepseek-llm-7b': '#0284c7',  # Blue
        }
        
        for model_name, model_data in models.items():
            if model_data.get('tested', False):
                # Small inference
                if model_data.get('inference_time_ms', 0) > 0:
                    labels.append(f"{model_name.upper()} (small)")
                    data.append(model_data['inference_time_ms'])
                    colors.append(color_map.get(model_name, '#888888'))
                
                # Large inference
                if model_data.get('inference_large_time_ms', 0) > 0:
                    labels.append(f"{model_name.upper()} (large)")
                    data.append(model_data['inference_large_time_ms'])
                    colors.append(color_map.get(model_name, '#888888'))
        
        return {
            'labels': json.dumps(labels),
            'data': json.dumps(data),
            'colors': json.dumps(colors)
        }
    
    def generate_breakdown_chart_data(self) -> Dict[str, Any]:
        """Generate data for performance breakdown pie chart."""
        timings = self.metrics.get('timings', {})
        
        # Quick operations only (exclude model install which dominates)
        labels = ['Axon Download', 'Core Download', 'Core Startup', 'Registration', 'Inference']
        data = [
            timings.get('axon_download_ms', 0),
            timings.get('core_download_ms', 0),
            timings.get('core_startup_ms', 0),
            timings.get('total_register_ms', 0),
            timings.get('total_inference_ms', 0)
        ]
        colors = ['#667eea', '#764ba2', '#38ef7d', '#f093fb', '#11998e']
        
        return {
            'labels': json.dumps(labels),
            'data': json.dumps(data),
            'colors': json.dumps(colors),
            'model_install_ms': timings.get('total_model_install_ms', 0)
        }
    
    def generate_inference_metrics_html(self) -> str:
        """Generate HTML for inference metrics cards - one card per model with both small/large inside."""
        models = self.metrics.get('models', {})
        html_parts = []
        
        # Group by category for better organization
        categories = {'nlp': [], 'vision': [], 'multimodal': [], 'llm': []}
        for model_name, model_data in models.items():
            if not model_data.get('tested', False):
                continue
            cat = model_data.get('category', 'nlp')
            if cat in categories:
                categories[cat].append((model_name, model_data))
        
        # NLP Models
        if categories['nlp']:
            html_parts.append('<div class="category-section"><h4 style="color: #667eea; margin-bottom: 8px; margin-top: 0;">🔤 NLP Models</h4>')
            html_parts.append('<div class="metrics-grid">')
            for model_name, model_data in categories['nlp']:
                display_name = model_name.upper()
                time_small = model_data.get('inference_time_ms', 0)
                time_large = model_data.get('inference_large_time_ms', 0)
                overall_status = self.get_model_status(model_name)
                
                html_parts.append(f'''
                    <div class="metric-card">
                        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem;">
                            <h4 style="margin: 0;">{display_name}</h4>
                            <span class="status-badge {overall_status['status_class']}">{overall_status['status']}</span>
                        </div>
                        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 1rem;">
                            <div>
                                <div style="font-size: 0.75rem; color: var(--text-muted); margin-bottom: 0.25rem;">Small Inference</div>
                                <div class="metric-value" style="font-size: 1.1rem;">{format_time(time_small)}</div>
                            </div>
                            <div>
                                <div style="font-size: 0.75rem; color: var(--text-muted); margin-bottom: 0.25rem;">Large Inference</div>
                                <div class="metric-value" style="font-size: 1.1rem;">{format_time(time_large) if time_large > 0 else 'N/A'}</div>
                            </div>
                        </div>
                    </div>
                ''')
            html_parts.append('</div>')
            html_parts.append('</div>')
        # Vision Models
        if categories['vision']:
            html_parts.append('<div class="category-section"><h4 style="color: #17998e; margin-bottom: 8px; margin-top: 20px;">👁️ Vision Models</h4>')
            html_parts.append('<div class="metrics-grid">')
            for model_name, model_data in categories['vision']:
                display_name = model_name.upper()
                time_small = model_data.get('inference_time_ms', 0)
                time_large = model_data.get('inference_large_time_ms', 0)
                overall_status = self.get_model_status(model_name)
                
                html_parts.append(f'''
                    <div class="metric-card" style="border-left-color: #17998e;">
                        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem;">
                            <h4 style="margin: 0;">{display_name}</h4>
                            <span class="status-badge {overall_status['status_class']}">{overall_status['status']}</span>
                        </div>
                        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 1rem;">
                            <div>
                                <div style="font-size: 0.75rem; color: var(--text-muted); margin-bottom: 0.25rem;">Small Inference</div>
                                <div class="metric-value" style="font-size: 1.1rem;">{format_time(time_small)}</div>
                            </div>
                            <div>
                                <div style="font-size: 0.75rem; color: var(--text-muted); margin-bottom: 0.25rem;">Large Inference</div>
                                <div class="metric-value" style="font-size: 1.1rem;">{format_time(time_large) if time_large > 0 else 'N/A'}</div>
                            </div>
                        </div>
                    </div>
                ''')
            html_parts.append('</div>')
            html_parts.append('</div>')
        
        # Multimodal Models
        if categories['multimodal']:
            html_parts.append('<div class="category-section"><h4 style="color: #764ba2; margin-bottom: 8px; margin-top: 20px;">🎨 Multimodal Models</h4>')
            html_parts.append('<div class="metrics-grid">')
            for model_name, model_data in categories['multimodal']:
                display_name = model_name.upper()
                time_small = model_data.get('inference_time_ms', 0)
                time_large = model_data.get('inference_large_time_ms', 0)
                overall_status = self.get_model_status(model_name)
                
                html_parts.append(f'''
                    <div class="metric-card" style="border-left-color: #764ba2;">
                        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem;">
                            <h4 style="margin: 0;">{display_name}</h4>
                            <span class="status-badge {overall_status['status_class']}">{overall_status['status']}</span>
                        </div>
                        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 1rem;">
                            <div>
                                <div style="font-size: 0.75rem; color: var(--text-muted); margin-bottom: 0.25rem;">Small Inference</div>
                                <div class="metric-value" style="font-size: 1.1rem;">{format_time(time_small)}</div>
                            </div>
                            <div>
                                <div style="font-size: 0.75rem; color: var(--text-muted); margin-bottom: 0.25rem;">Large Inference</div>
                                <div class="metric-value" style="font-size: 1.1rem;">{format_time(time_large) if time_large > 0 else 'N/A'}</div>
                            </div>
                        </div>
                    </div>
                ''')
            html_parts.append('</div>')
            html_parts.append('</div>')

        # LLM Models (GGUF)
        if categories['llm']:
            html_parts.append('<div class="category-section"><h4 style="color: #f59e0b; margin-bottom: 8px; margin-top: 20px;">🤖 LLM Models</h4>')
            html_parts.append('<div class="metrics-grid">')
            for model_name, model_data in categories['llm']:
                display_name = model_name.upper()
                time_small = model_data.get('inference_time_ms', 0)
                time_large = model_data.get('inference_large_time_ms', 0)
                overall_status = self.get_model_status(model_name)

                html_parts.append(f'''
                    <div class="metric-card" style="border-left-color: #f59e0b;">
                        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem;">
                            <h4 style="margin: 0;">{display_name}</h4>
                            <span class="status-badge {overall_status['status_class']}">{overall_status['status']}</span>
                        </div>
                        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 1rem;">
                            <div>
                                <div style="font-size: 0.75rem; color: var(--text-muted); margin-bottom: 0.25rem;">Small Inference</div>
                                <div class="metric-value" style="font-size: 1.1rem;">{format_time(time_small)}</div>
                            </div>
                            <div>
                                <div style="font-size: 0.75rem; color: var(--text-muted); margin-bottom: 0.25rem;">Large Inference</div>
                                <div class="metric-value" style="font-size: 1.1rem;">{format_time(time_large) if time_large > 0 else 'N/A'}</div>
                            </div>
                        </div>
                    </div>
                ''')
            html_parts.append('</div>')
            html_parts.append('</div>')

        return '\n'.join(html_parts)

    def generate_model_details_html(self) -> str:
        """Generate HTML for model details section - one card per model with timing data points inside."""
        models = self.metrics.get('models', {})
        html_parts = []

        # Group by category
        categories = {'nlp': [], 'vision': [], 'multimodal': [], 'llm': []}
        for model_name, model_data in models.items():
            cat = model_data.get('category', 'nlp')
            if cat in categories:
                categories[cat].append((model_name, model_data))
        
        # NLP Models
        if categories['nlp']:
            html_parts.append('<div class="category-section"><h4 style="color: #667eea; margin-bottom: 8px; margin-top: 0;">🔤 NLP Models</h4>')
            html_parts.append('<div class="metrics-grid">')
            for model_name, model_data in categories['nlp']:
                display_name = model_name.upper()
                install_time = model_data.get('install_time_ms', 0)
                register_time = model_data.get('register_time_ms', 0)
                overall_status = self.get_model_status(model_name)
                
                html_parts.append(f'''
                    <div class="metric-card">
                        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem;">
                            <h4 style="margin: 0;">{display_name}</h4>
                            <span class="status-badge {overall_status['status_class']}">{overall_status['status']}</span>
                        </div>
                        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 1rem;">
                            <div>
                                <div style="font-size: 0.75rem; color: var(--text-muted); margin-bottom: 0.25rem;">Install Time</div>
                                <div class="metric-value" style="font-size: 1.1rem;">{format_time(install_time)}</div>
                            </div>
                            <div>
                                <div style="font-size: 0.75rem; color: var(--text-muted); margin-bottom: 0.25rem;">Register Time</div>
                                <div class="metric-value" style="font-size: 1.1rem;">{format_time(register_time)}</div>
                            </div>
                        </div>
                    </div>
                ''')
            html_parts.append('</div>')
            html_parts.append('</div>')
        # Vision Models
        if categories['vision']:
            html_parts.append('<div class="category-section"><h4 style="color: #17998e; margin-bottom: 8px; margin-top: 20px;">👁️ Vision Models</h4>')
            html_parts.append('<div class="metrics-grid">')
            for model_name, model_data in categories['vision']:
                display_name = model_name.upper()
                install_time = model_data.get('install_time_ms', 0)
                register_time = model_data.get('register_time_ms', 0)
                overall_status = self.get_model_status(model_name)
                
                html_parts.append(f'''
                    <div class="metric-card" style="border-left-color: #17998e;">
                        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem;">
                            <h4 style="margin: 0;">{display_name}</h4>
                            <span class="status-badge {overall_status['status_class']}">{overall_status['status']}</span>
                        </div>
                        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 1rem;">
                            <div>
                                <div style="font-size: 0.75rem; color: var(--text-muted); margin-bottom: 0.25rem;">Install Time</div>
                                <div class="metric-value" style="font-size: 1.1rem;">{format_time(install_time)}</div>
                            </div>
                            <div>
                                <div style="font-size: 0.75rem; color: var(--text-muted); margin-bottom: 0.25rem;">Register Time</div>
                                <div class="metric-value" style="font-size: 1.1rem;">{format_time(register_time)}</div>
                            </div>
                        </div>
                    </div>
                ''')
            html_parts.append('</div>')
            html_parts.append('</div>')
        
        # Multimodal Models
        if categories['multimodal']:
            html_parts.append('<div class="category-section"><h4 style="color: #764ba2; margin-bottom: 8px; margin-top: 20px;">🎨 Multimodal Models</h4>')
            html_parts.append('<div class="metrics-grid">')
            for model_name, model_data in categories['multimodal']:
                display_name = model_name.upper()
                install_time = model_data.get('install_time_ms', 0)
                register_time = model_data.get('register_time_ms', 0)
                overall_status = self.get_model_status(model_name)
                
                html_parts.append(f'''
                    <div class="metric-card" style="border-left-color: #764ba2;">
                        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem;">
                            <h4 style="margin: 0;">{display_name}</h4>
                            <span class="status-badge {overall_status['status_class']}">{overall_status['status']}</span>
                        </div>
                        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 1rem;">
                            <div>
                                <div style="font-size: 0.75rem; color: var(--text-muted); margin-bottom: 0.25rem;">Install Time</div>
                                <div class="metric-value" style="font-size: 1.1rem;">{format_time(install_time)}</div>
                            </div>
                            <div>
                                <div style="font-size: 0.75rem; color: var(--text-muted); margin-bottom: 0.25rem;">Register Time</div>
                                <div class="metric-value" style="font-size: 1.1rem;">{format_time(register_time)}</div>
                            </div>
                        </div>
                    </div>
                ''')
            html_parts.append('</div>')
            html_parts.append('</div>')

        # LLM Models
        if categories['llm']:
            html_parts.append('<div class="category-section"><h4 style="color: #f59e0b; margin-bottom: 8px; margin-top: 20px;">🤖 LLM Models</h4>')
            html_parts.append('<div class="metrics-grid">')
            for model_name, model_data in categories['llm']:
                display_name = model_name.upper()
                install_time = model_data.get('install_time_ms', 0)
                register_time = model_data.get('register_time_ms', 0)
                overall_status = self.get_model_status(model_name)

                html_parts.append(f'''
                    <div class="metric-card" style="border-left-color: #f59e0b;">
                        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem;">
                            <h4 style="margin: 0;">{display_name}</h4>
                            <span class="status-badge {overall_status['status_class']}">{overall_status['status']}</span>
                        </div>
                        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 1rem;">
                            <div>
                                <div style="font-size: 0.75rem; color: var(--text-muted); margin-bottom: 0.25rem;">Install Time</div>
                                <div class="metric-value" style="font-size: 1.1rem;">{format_time(install_time)}</div>
                            </div>
                            <div>
                                <div style="font-size: 0.75rem; color: var(--text-muted); margin-bottom: 0.25rem;">Register Time</div>
                                <div class="metric-value" style="font-size: 1.1rem;">{format_time(register_time)}</div>
                            </div>
                        </div>
                    </div>
                ''')
            html_parts.append('</div>')
            html_parts.append('</div>')

        return '\n'.join(html_parts)

    def _get_kernel_mode_display(self, kernel_mode: str) -> str:
        """Get human-readable kernel mode description."""
        mode_display = {
            'userspace': 'Userspace Only (No Kernel Optimizations)',
            'kernel_basic': 'Kernel Module (Memory Manager)',
            'kernel_sched': 'Kernel Module (Memory + Scheduler)',
            'kernel_full': 'Kernel Module (Full: Memory, Scheduler, GPU)',
            'kernel_tuned': 'Kernel Module (Tuned Configuration)'
        }
        return mode_display.get(kernel_mode, f'Unknown ({kernel_mode})')

    def build_replacements(self) -> Dict[str, str]:
        """Build all template replacements."""
        overall = self.calculate_overall_status()
        nlp_status = self.calculate_category_status('nlp')
        vision_status = self.calculate_category_status('vision')
        multimodal_status = self.calculate_category_status('multimodal')
        llm_status = self.calculate_category_status('llm')
        
        install_chart = self.generate_installation_chart_data()
        inference_chart = self.generate_inference_chart_data()
        breakdown_chart = self.generate_breakdown_chart_data()
        
        versions = self.metrics.get('versions', {})
        hardware = self.metrics.get('hardware', {})
        timings = self.metrics.get('timings', {})
        resources = self.metrics.get('resources', {})
        models = self.metrics.get('models', {})
        
        replacements = {
            # Overall status
            '{{OVERALL_SUCCESS_RATE}}': str(overall['success_rate']),
            '{{TOTAL_DURATION}}': str(timings.get('total_duration_s', 0)),
            '{{TOTAL_INFERENCES}}': f"{overall['passed_tests']}/{overall['total_tests']}",
            '{{MODELS_TESTED}}': str(len([m for m in models.values() if m.get('tested')])),
            
            # Versions
            '{{AXON_VERSION}}': versions.get('axon', 'N/A'),
            '{{CORE_VERSION}}': versions.get('core', 'N/A'),
            
            # Hardware
            '{{OS_NAME}}': hardware.get('os', 'Unknown'),
            '{{OS_VERSION}}': hardware.get('os_version', ''),
            '{{ARCH}}': hardware.get('arch', 'Unknown'),
            '{{CPU_MODEL}}': hardware.get('cpu_model', 'Unknown'),
            '{{CPU_CORES}}': str(hardware.get('cpu_cores', 0)),
            '{{CPU_THREADS}}': str(hardware.get('cpu_threads', 0)),
            '{{MEMORY_GB}}': str(hardware.get('memory_gb', 0)),
            '{{GPU_NAME}}': hardware.get('gpu_name', 'None detected'),
            '{{GPU_COUNT}}': str(hardware.get('gpu_count', 0)),
            '{{GPU_MEMORY}}': hardware.get('gpu_memory', 'N/A'),
            '{{DISK_TOTAL}}': hardware.get('disk_total', 'N/A'),
            '{{DISK_AVAILABLE}}': hardware.get('disk_available', 'N/A'),
            
            # Resource usage
            '{{CORE_IDLE_CPU}}': str(resources.get('core_idle_cpu', 0)),
            '{{CORE_IDLE_MEM}}': str(resources.get('core_idle_mem_mb', 0)),
            '{{CORE_LOAD_CPU_AVG}}': str(resources.get('core_load_cpu_avg', 0)),
            '{{CORE_LOAD_CPU_MAX}}': str(resources.get('core_load_cpu_max', 0)),
            '{{CORE_LOAD_MEM_AVG}}': str(resources.get('core_load_mem_avg_mb', 0)),
            '{{CORE_LOAD_MEM_MAX}}': str(resources.get('core_load_mem_max_mb', 0)),
            '{{AXON_CPU}}': str(resources.get('axon_cpu', 0)),
            '{{AXON_MEM}}': str(resources.get('axon_mem_mb', 0)),
            '{{GPU_STATUS}}': resources.get('gpu_status', 'Not used (CPU-only inference)'),
            '{{KERNEL_MODE}}': resources.get('kernel_mode', 'userspace'),
            '{{KERNEL_MODE_DISPLAY}}': self._get_kernel_mode_display(resources.get('kernel_mode', 'userspace')),
            '{{KERNEL_MODULE_LOADED}}': 'Yes' if resources.get('kernel_module_loaded', False) else 'No',
            
            # Timings (formatted for display)
            '{{AXON_DOWNLOAD_TIME}}': format_time(timings.get('axon_download_ms', 0)),
            '{{CORE_DOWNLOAD_TIME}}': format_time(timings.get('core_download_ms', 0)),
            '{{CORE_STARTUP_TIME}}': format_time(timings.get('core_startup_ms', 0)),
            '{{TOTAL_MODEL_INSTALL_TIME}}': format_time(timings.get('total_model_install_ms', 0)),
            
            # Category status
            '{{NLP_STATUS}}': nlp_status['status'],
            '{{NLP_STATUS_CLASS}}': nlp_status['status_class'],
            '{{VISION_STATUS}}': vision_status['status'],
            '{{VISION_STATUS_CLASS}}': vision_status['status_class'],
            '{{MULTIMODAL_STATUS}}': multimodal_status['status'],
            '{{MULTIMODAL_STATUS_CLASS}}': multimodal_status['status_class'],
            '{{LLM_STATUS}}': llm_status['status'],
            '{{LLM_STATUS_CLASS}}': llm_status['status_class'],
            
            # Chart data
            '{{INSTALL_CHART_LABELS}}': install_chart['labels'],
            '{{INSTALL_CHART_DATA}}': install_chart['data'],
            '{{INSTALL_CHART_COLORS}}': install_chart['colors'],
            '{{INFERENCE_CHART_LABELS}}': inference_chart['labels'],
            '{{INFERENCE_CHART_DATA}}': inference_chart['data'],
            '{{INFERENCE_CHART_COLORS}}': inference_chart['colors'],
            '{{BREAKDOWN_CHART_LABELS}}': breakdown_chart['labels'],
            '{{BREAKDOWN_CHART_DATA}}': breakdown_chart['data'],
            '{{BREAKDOWN_CHART_COLORS}}': breakdown_chart['colors'],
            '{{MODEL_INSTALL_TIME_CALLOUT}}': format_time(breakdown_chart['model_install_ms']),
            
            # Dynamic HTML sections
            '{{INFERENCE_METRICS_HTML}}': self.generate_inference_metrics_html(),
            '{{MODEL_DETAILS_HTML}}': self.generate_model_details_html(),
            
            # Model-specific status (for Model Support section)
            # NLP Models
            '{{GPT2_STATUS}}': self.get_model_status('gpt2')['status'],
            '{{GPT2_STATUS_CLASS}}': self.get_model_status('gpt2')['status_class'],
            '{{BERT_STATUS}}': self.get_model_status('bert')['status'],
            '{{BERT_STATUS_CLASS}}': self.get_model_status('bert')['status_class'],
            '{{ROBERTA_STATUS}}': self.get_model_status('roberta')['status'],
            '{{ROBERTA_STATUS_CLASS}}': self.get_model_status('roberta')['status_class'],
            '{{T5_STATUS}}': self.get_model_status('t5')['status'],
            '{{T5_STATUS_CLASS}}': self.get_model_status('t5')['status_class'],
            # Vision Models
            '{{RESNET_STATUS}}': self.get_model_status('resnet')['status'],
            '{{RESNET_STATUS_CLASS}}': self.get_model_status('resnet')['status_class'],
            '{{VIT_STATUS}}': self.get_model_status('vit')['status'],
            '{{VIT_STATUS_CLASS}}': self.get_model_status('vit')['status_class'],
            '{{CONVNEXT_STATUS}}': self.get_model_status('convnext')['status'],
            '{{CONVNEXT_STATUS_CLASS}}': self.get_model_status('convnext')['status_class'],
            '{{MOBILENET_STATUS}}': self.get_model_status('mobilenet')['status'],
            '{{MOBILENET_STATUS_CLASS}}': self.get_model_status('mobilenet')['status_class'],
            '{{DEIT_STATUS}}': self.get_model_status('deit')['status'],
            '{{DEIT_STATUS_CLASS}}': self.get_model_status('deit')['status_class'],
            '{{EFFICIENTNET_STATUS}}': self.get_model_status('efficientnet')['status'],
            '{{EFFICIENTNET_STATUS_CLASS}}': self.get_model_status('efficientnet')['status_class'],
            # Multimodal Models
            '{{CLIP_STATUS}}': self.get_model_status('clip')['status'],
            '{{CLIP_STATUS_CLASS}}': self.get_model_status('clip')['status_class'],
            '{{WAV2VEC2_STATUS}}': self.get_model_status('wav2vec2')['status'],
            '{{WAV2VEC2_STATUS_CLASS}}': self.get_model_status('wav2vec2')['status_class'],
            
            # Metadata
            '{{TIMESTAMP}}': self.metrics.get('timestamp', datetime.now().strftime('%Y-%m-%d %H:%M:%S')),
            '{{TEST_DIR}}': self.metrics.get('test_dir', 'N/A'),
        }
        
        return replacements
    
    def render(self) -> bool:
        """Render the report."""
        # Load metrics
        if not self.load_metrics():
            return False
        
        # Load template
        template = self.load_template()
        if template is None:
            return False
        
        # Build replacements
        replacements = self.build_replacements()
        
        # Apply replacements
        content = template
        for key, value in sorted(replacements.items(), key=lambda x: len(x[0]), reverse=True):
            count = content.count(key)
            if count > 0:
                content = content.replace(key, str(value))
                print(f"  Replaced {key}: {count} occurrence(s)")
        
        # Write output
        self.output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.output_path, 'w', encoding='utf-8') as f:
            f.write(content)
        
        print(f"✅ Report generated: {self.output_path}")
        return True


class ModelsPageRenderer:
    """Renders models configuration page from YAML config."""
    
    def __init__(self, config_path: str, template_path: str, output_path: str):
        self.config_path = Path(config_path)
        self.template_path = Path(template_path)
        self.output_path = Path(output_path)
        self.config: Dict[str, Any] = {}
    
    def load_config(self) -> bool:
        """Load config from YAML file."""
        if not HAS_YAML:
            print("⚠️ PyYAML not installed, skipping models page")
            return False
        
        if not self.config_path.exists():
            print(f"⚠️ Config file not found: {self.config_path}")
            return False
        
        try:
            with open(self.config_path, 'r', encoding='utf-8') as f:
                self.config = yaml.safe_load(f)
            print(f"✅ Loaded config from {self.config_path}")
            return True
        except Exception as e:
            print(f"❌ Error loading config: {e}")
            return False
    
    def load_template(self) -> Optional[str]:
        """Load HTML template."""
        if not self.template_path.exists():
            print(f"⚠️ Models template not found: {self.template_path}")
            return None
        
        with open(self.template_path, 'r', encoding='utf-8') as f:
            return f.read()
    
    def generate_model_card_html(self, name: str, data: Dict[str, Any]) -> str:
        """Generate HTML for a single model card."""
        enabled = data.get('enabled', False)
        enabled_class = 'enabled' if enabled else 'disabled'
        status_class = 'enabled' if enabled else 'disabled'
        status_text = 'Enabled' if enabled else 'Disabled'
        
        description = data.get('description', 'No description')
        axon_id = data.get('axon_id', 'N/A')
        category = data.get('category', 'nlp')
        input_type = data.get('input_type', 'text')
        
        # Input specs
        small_input = data.get('small_input', {})
        large_input = data.get('large_input', {})
        
        input_specs_html = ''
        if input_type == 'text':
            small_tokens = small_input.get('tokens', 7)
            large_tokens = large_input.get('tokens', 128)
            input_specs_html = f'''
                <table class="input-table">
                    <tr><td>Small Test</td><td>{small_tokens} tokens</td></tr>
                    <tr><td>Large Test</td><td>{large_tokens} tokens</td></tr>
                </table>
            '''
        elif input_type == 'image':
            small_w = small_input.get('width', 32)
            small_h = small_input.get('height', 32)
            large_w = large_input.get('width', 64)
            large_h = large_input.get('height', 64)
            channels = small_input.get('channels', 3)
            input_specs_html = f'''
                <table class="input-table">
                    <tr><td>Small Test</td><td>{small_w}x{small_h}x{channels}</td></tr>
                    <tr><td>Large Test</td><td>{large_w}x{large_h}x{channels}</td></tr>
                </table>
            '''
        elif input_type == 'multimodal':
            input_specs_html = '<p style="font-size: 0.8rem; color: var(--text-muted);">Text + Image input</p>'
        elif input_type == 'text_generation':
            # LLM models
            small_prompt = small_input.get('prompt', 'N/A')[:30] + '...' if len(small_input.get('prompt', '')) > 30 else small_input.get('prompt', 'N/A')
            small_tokens = small_input.get('max_tokens', 32)
            large_tokens = large_input.get('max_tokens', 256)
            format_type = data.get('format', 'gguf').upper()
            input_specs_html = f'''
                <table class="input-table">
                    <tr><td>Format</td><td>{format_type}</td></tr>
                    <tr><td>Small Test</td><td>{small_tokens} tokens</td></tr>
                    <tr><td>Large Test</td><td>{large_tokens} tokens</td></tr>
                </table>
            '''
        
        # Notes section
        notes_html = ''
        notes = data.get('notes', '')
        if notes:
            notes_html = f'<div class="model-notes">⚠️ {notes}</div>'
        
        return f'''
            <div class="model-card {enabled_class}">
                <div class="model-header">
                    <h3 class="model-name">{name.replace('_', ' ').title()}</h3>
                    <span class="model-status {status_class}">{status_text}</span>
                </div>
                <p class="model-description">{description}</p>
                <div class="model-axon-id">{axon_id}</div>
                <div class="model-meta">
                    <div class="meta-item">
                        <div class="meta-label">Category</div>
                        <div class="meta-value">{category.upper()}</div>
                    </div>
                    <div class="meta-item">
                        <div class="meta-label">Input Type</div>
                        <div class="meta-value">{input_type.title()}</div>
                    </div>
                </div>
                <div class="input-specs">
                    <h4>Input Specifications</h4>
                    {input_specs_html}
                </div>
                {notes_html}
            </div>
        '''
    
    def build_replacements(self) -> Dict[str, str]:
        """Build all template replacements."""
        models = self.config.get('models', {})

        # Count models by category
        nlp_models = [(n, d) for n, d in models.items() if d.get('category') == 'nlp']
        vision_models = [(n, d) for n, d in models.items() if d.get('category') == 'vision']
        multimodal_models = [(n, d) for n, d in models.items() if d.get('category') == 'multimodal']
        llm_models = [(n, d) for n, d in models.items() if d.get('category') == 'llm']

        enabled_count = sum(1 for d in models.values() if d.get('enabled', False))

        # Generate HTML for each category
        nlp_html = '\n'.join(self.generate_model_card_html(n, d) for n, d in nlp_models) or '<p class="no-models">No NLP models configured</p>'
        vision_html = '\n'.join(self.generate_model_card_html(n, d) for n, d in vision_models) or '<p class="no-models">No vision models configured</p>'
        multimodal_html = '\n'.join(self.generate_model_card_html(n, d) for n, d in multimodal_models) or '<p class="no-models">No multimodal models configured</p>'
        llm_html = '\n'.join(self.generate_model_card_html(n, d) for n, d in llm_models) or '<p class="no-models">No LLM models configured</p>'

        return {
            '{{TOTAL_MODELS}}': str(len(models)),
            '{{ENABLED_MODELS}}': str(enabled_count),
            '{{NLP_COUNT}}': str(len(nlp_models)),
            '{{VISION_COUNT}}': str(len(vision_models)),
            '{{MULTIMODAL_COUNT}}': str(len(multimodal_models)),
            '{{LLM_COUNT}}': str(len(llm_models)),
            '{{NLP_MODELS_HTML}}': nlp_html,
            '{{VISION_MODELS_HTML}}': vision_html,
            '{{MULTIMODAL_MODELS_HTML}}': multimodal_html,
            '{{LLM_MODELS_HTML}}': llm_html,
            '{{TIMESTAMP}}': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        }
    
    def render(self) -> bool:
        """Render the models page."""
        if not self.load_config():
            return False
        
        template = self.load_template()
        if template is None:
            return False
        
        replacements = self.build_replacements()
        
        content = template
        for key, value in sorted(replacements.items(), key=lambda x: len(x[0]), reverse=True):
            content = content.replace(key, str(value))
        
        self.output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.output_path, 'w', encoding='utf-8') as f:
            f.write(content)
        
        print(f"✅ Models page generated: {self.output_path}")
        return True


class TestDetailsPageRenderer:
    """Renders test details page showing golden test data and validation results."""

    def __init__(self, golden_data_path: str, metrics_path: str, template_path: str, output_path: str):
        self.golden_data_path = Path(golden_data_path)
        self.metrics_path = Path(metrics_path)
        self.template_path = Path(template_path)
        self.output_path = Path(output_path)
        self.golden_data: Dict[str, Any] = {}
        self.metrics: Dict[str, Any] = {}
        self.validation_results: Dict[str, Any] = {}
        self.response_data: Dict[str, Any] = {}

    def load_data(self) -> bool:
        """Load golden test data, metrics, and validation results."""
        if not HAS_YAML:
            print("⚠️ PyYAML not installed, skipping test details page")
            return False

        # Load golden test data
        if not self.golden_data_path.exists():
            print(f"⚠️ Golden data file not found: {self.golden_data_path}")
            return False

        try:
            with open(self.golden_data_path, 'r', encoding='utf-8') as f:
                self.golden_data = yaml.safe_load(f)
            print(f"✅ Loaded golden data from {self.golden_data_path}")
        except Exception as e:
            print(f"❌ Error loading golden data: {e}")
            return False

        # Load metrics
        if self.metrics_path.exists():
            try:
                with open(self.metrics_path, 'r', encoding='utf-8') as f:
                    self.metrics = json.load(f)
            except Exception:
                pass

        # Load validation results from model-results directory
        self._load_validation_results()

        return True

    def _load_validation_results(self) -> None:
        """Load validation results from model-results/{model}-validation-*.json files."""
        # Try multiple locations for model-results directory
        # 1. In CI: model-results is at repo root
        # 2. Locally: may be relative to metrics or golden data
        script_dir = Path(__file__).parent.parent  # system-test root
        results_dir = script_dir / "model-results"

        if not results_dir.exists():
            results_dir = self.metrics_path.parent / "model-results"
        if not results_dir.exists():
            results_dir = self.golden_data_path.parent.parent / "model-results"

        if not results_dir.exists():
            print(f"⚠️ Model results directory not found: {results_dir}")
            return

        # Load both small and large validation files (LLMs have separate files per test size)
        for pattern in ["*-validation-small.json", "*-validation-large.json"]:
            for validation_file in results_dir.glob(pattern):
                # Extract model name and size from filename
                stem = validation_file.stem
                if "-validation-small" in stem:
                    model_name = stem.replace("-validation-small", "")
                else:
                    model_name = stem.replace("-validation-large", "")

                try:
                    with open(validation_file, 'r', encoding='utf-8') as f:
                        results = json.load(f)
                        # Merge results by test_name (don't overwrite existing)
                        if model_name not in self.validation_results:
                            self.validation_results[model_name] = {}
                        for r in results:
                            test_name = r.get('test_name', '')
                            if test_name not in self.validation_results[model_name]:
                                self.validation_results[model_name][test_name] = r
                    print(f"  📊 Loaded validation results for {model_name} from {validation_file.name}")
                except Exception as e:
                    print(f"  ⚠️ Failed to load validation for {model_name}: {e}")

        # Load golden image validation files
        self._load_golden_validation_results(results_dir)

        # Also load response files to get actual inference output data
        self._load_response_data(results_dir)

    def _load_golden_validation_results(self, results_dir: Path) -> None:
        """Load golden image validation results from model-results/{model}-validation-golden-*.json files."""
        if not hasattr(self, 'golden_validation_results'):
            self.golden_validation_results = {}

        for validation_file in results_dir.glob("*-validation-golden-*.json"):
            # Extract model name and test name from filename
            # Format: {model}-validation-golden-{test_name}.json
            stem = validation_file.stem
            parts = stem.split('-validation-golden-')
            if len(parts) == 2:
                model_name = parts[0]
                test_name = parts[1]
            else:
                continue

            try:
                with open(validation_file, 'r', encoding='utf-8') as f:
                    results = json.load(f)
                    if model_name not in self.golden_validation_results:
                        self.golden_validation_results[model_name] = {}
                    # Store results by test name
                    for r in results:
                        result_test_name = r.get('test_name', test_name)
                        self.golden_validation_results[model_name][result_test_name] = r
                print(f"  🖼️  Loaded golden validation for {model_name}/{test_name}")
            except Exception as e:
                print(f"  ⚠️ Failed to load golden validation for {model_name}/{test_name}: {e}")

    def _load_response_data(self, results_dir: Path) -> None:
        """Load inference response data from model-results/{model}-response-small.json files."""
        if not hasattr(self, 'response_data'):
            self.response_data = {}

        for response_file in results_dir.glob("*-response-small.json"):
            model_name = response_file.stem.replace("-response-small", "")
            try:
                with open(response_file, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                    self.response_data[model_name] = data
                print(f"  📈 Loaded response data for {model_name}")
            except Exception as e:
                print(f"  ⚠️ Failed to load response for {model_name}: {e}")

    def load_template(self) -> Optional[str]:
        """Load HTML template."""
        if not self.template_path.exists():
            print(f"⚠️ Test details template not found: {self.template_path}")
            return None

        with open(self.template_path, 'r', encoding='utf-8') as f:
            return f.read()

    def get_category_for_model(self, model_name: str) -> str:
        """Get category for a model."""
        model_data = self.golden_data.get('models', {}).get(model_name, {})
        # Check description for hints or use metrics
        desc = model_data.get('description', '').lower()
        if 'llm' in desc or 'gguf' in desc:
            return 'llm'
        if 'vision' in desc or 'image' in desc or 'resnet' in model_name or 'vit' in model_name:
            return 'vision'
        if 'clip' in model_name or 'multimodal' in desc:
            return 'multimodal'
        # Check metrics category
        metrics_model = self.metrics.get('models', {}).get(model_name, {})
        return metrics_model.get('category', 'nlp')

    def generate_test_case_html(self, model_name: str, test_case: Dict) -> str:
        """Generate HTML for a single test case with side-by-side field comparison.

        Skip top_k_class_match tests here - they are shown in the golden image section.
        """
        test_name = test_case.get('name', 'unnamed')
        input_data = test_case.get('input', {})
        expected = test_case.get('expected', {})
        validation_type = expected.get('validation_type', 'unknown')

        # Skip top_k_class_match tests - they are displayed in the golden image section
        if validation_type == 'top_k_class_match':
            return ''
        notes = expected.get('notes', '')

        # Get metrics data for this model
        model_metrics = self.metrics.get('models', {}).get(model_name, {})

        # Get validation results for this test
        model_validations = self.validation_results.get(model_name, {})
        validation_result = model_validations.get(test_name, {})

        # Format input data for display
        input_display = json.dumps(input_data, indent=2) if input_data else 'N/A'

        # Extract expected values
        expected_shape = expected.get('expected_shape', [])
        expected_labels = expected.get('expected_labels', expected.get('expected_keywords', []))
        min_elements = expected.get('min_elements', 0)
        min_output_size = expected.get('min_output_size', 0)
        output_name = expected.get('output_name', '')
        case_insensitive = expected.get('case_insensitive', False)

        # Get response and validation details
        response = self.response_data.get(model_name, {})
        details = validation_result.get('details', {})

        # Determine overall validation status
        if validation_result:
            passed = validation_result.get('passed', False)
            validation_class = 'validation-passed' if passed else 'validation-failed'
            validation_text = 'PASSED' if passed else 'FAILED'
            validation_message = validation_result.get('message', '')
        else:
            status = model_metrics.get('inference_status', 'unknown')
            if status == 'success':
                validation_class = 'validation-skipped'
                validation_text = 'INFERRED'
            elif status == 'failed':
                validation_class = 'validation-failed'
                validation_text = 'FAILED'
            else:
                validation_class = 'validation-skipped'
                validation_text = 'NOT RUN'
            validation_message = ''

        # Build comparison table rows
        comparison_rows = []

        # Row 1: Validation Type (always shown)
        comparison_rows.append(self._make_comparison_row(
            'Validation Type', validation_type, validation_type, True, 'info'
        ))

        # Row 2: Status
        actual_status = response.get('status', details.get('status', model_metrics.get('inference_status', 'unknown')))
        if validation_type == 'status_success':
            status_passed = actual_status == 'success'
            comparison_rows.append(self._make_comparison_row(
                'Status', 'success', actual_status, status_passed
            ))

        # Row 3: Output Shape (for shape validation)
        if expected_shape:
            actual_shape = details.get('actual_shape', response.get('output_shape', []))
            shape_passed = list(actual_shape) == list(expected_shape) if actual_shape else False
            comparison_rows.append(self._make_comparison_row(
                'Output Shape', str(expected_shape), str(actual_shape) if actual_shape else 'N/A', shape_passed
            ))

        # Row 4: Min Output Size
        if min_output_size:
            actual_output_size = response.get('output_size', details.get('output_size', 0))
            size_passed = actual_output_size >= min_output_size if actual_output_size else False
            comparison_rows.append(self._make_comparison_row(
                'Output Size', f'>= {min_output_size:,} bytes',
                f'{actual_output_size:,} bytes' if actual_output_size else 'N/A',
                size_passed
            ))

        # Row 5: Min Elements
        if min_elements:
            actual_length = details.get('length', 0)
            elements_passed = actual_length >= min_elements if actual_length else False
            comparison_rows.append(self._make_comparison_row(
                'Output Elements', f'>= {min_elements:,}',
                f'{actual_length:,}' if actual_length else 'N/A',
                elements_passed
            ))

        # Row 6: Expected Keywords (for LLM generation_contains)
        if expected_labels:
            generated_text = details.get('generated_text', '')
            if generated_text:
                # Check if any expected keyword is found
                found_keywords = []
                for kw in expected_labels:
                    if case_insensitive:
                        if kw.lower() in generated_text.lower():
                            found_keywords.append(kw)
                    else:
                        if kw in generated_text:
                            found_keywords.append(kw)
                keywords_passed = len(found_keywords) > 0
                actual_display = f'Found: {found_keywords}' if found_keywords else 'None found'
                comparison_rows.append(self._make_comparison_row(
                    'Expected Keywords', str(expected_labels), actual_display, keywords_passed
                ))
                # Show the actual generated text
                truncated_text = generated_text[:200] + '...' if len(generated_text) > 200 else generated_text
                comparison_rows.append(self._make_comparison_row(
                    'Generated Text', '(any containing keywords)', f'"{truncated_text}"', keywords_passed, 'text'
                ))
            else:
                comparison_rows.append(self._make_comparison_row(
                    'Expected Keywords', str(expected_labels), 'No generation output', False
                ))

        # Row 7: Top-K Class Match (for vision semantic validation)
        if validation_type == 'top_k_class_match':
            # Check if this test was skipped (synthetic inference)
            is_skipped = details.get('skipped', False)

            if is_skipped:
                # For skipped tests, show a simplified view
                skip_reason = details.get('reason', 'Skipped for synthetic inference')
                golden_image = details.get('golden_image', '')

                comparison_rows.append(self._make_comparison_row(
                    'Status', 'Semantic validation', 'Skipped', True, 'info'
                ))
                comparison_rows.append(self._make_comparison_row(
                    'Reason', '-', skip_reason, True, 'info'
                ))
                if golden_image:
                    comparison_rows.append(self._make_comparison_row(
                        'Golden Image', golden_image, 'Pending actual image test', True, 'info'
                    ))
            else:
                # Normal validation - show full details
                expected_class = expected.get('expected_class_index', details.get('expected_class'))
                top_k = expected.get('top_k', 5)
                expected_label = expected.get('expected_label', '')
                alternative_classes = details.get('alternative_classes', [])

                # Get actual results from validation details
                top_k_indices = details.get('top_k_indices', [])
                top_k_scores = details.get('top_k_scores', [])
                found_class = details.get('found_class')
                rank = details.get('rank')

                # Display expected class
                expected_display = f'Class {expected_class}'
                if expected_label:
                    expected_display = f'{expected_label} (class {expected_class})'
                if alternative_classes:
                    alt_str = ', '.join(map(str, alternative_classes))
                    expected_display += f' or [{alt_str}]'

                comparison_rows.append(self._make_comparison_row(
                    'Expected Class', expected_display, '-', True, 'info'
                ))

                # Display top-K threshold
                comparison_rows.append(self._make_comparison_row(
                    'Top-K Threshold', str(top_k), '-', True, 'info'
                ))

                # Display actual top-K predictions
                if top_k_indices:
                    # Format top-K as readable string with scores
                    top_k_display = []
                    for i, idx in enumerate(top_k_indices[:5]):
                        score = top_k_scores[i] if i < len(top_k_scores) else 0
                        top_k_display.append(f'{idx}({score:.3f})')
                    actual_str = ', '.join(top_k_display)
                    comparison_rows.append(self._make_comparison_row(
                        'Top-5 Predictions', '-', actual_str, True, 'info'
                    ))

                # Display result: found or not
                if found_class is not None:
                    class_passed = True
                    result_str = f'Found class {found_class} at rank {rank}'
                else:
                    class_passed = False
                    result_str = f'Class {expected_class} not in top-{top_k}'

                comparison_rows.append(self._make_comparison_row(
                    'Classification Result', f'Class {expected_class} in top-{top_k}', result_str, class_passed
                ))

        # Row 8: Inference Time (info only)
        inference_time_us = details.get('inference_time_us', response.get('inference_time_us', 0))
        if inference_time_us:
            inference_time_ms = inference_time_us / 1000
            comparison_rows.append(self._make_comparison_row(
                'Inference Time', '-', f'{inference_time_ms:.2f} ms', True, 'info'
            ))

        # Build the comparison table HTML
        comparison_html = '\n'.join(comparison_rows)

        # Data source link
        data_source = "HuggingFace Model Hub"
        data_source_url = f"https://huggingface.co/{model_name.replace('-', '/')}"
        if 'resnet' in model_name or 'vit' in model_name or 'mobilenet' in model_name:
            data_source = "ONNX Model Zoo / ImageNet"
            data_source_url = "https://github.com/onnx/models"

        # Notes section
        notes_html = f'<div class="test-notes"><strong>Notes:</strong> {notes}</div>' if notes else ''

        return f'''
        <div class="test-case-card">
            <div class="test-case-header">
                <span class="test-name">{test_name}</span>
                <span class="validation-result {validation_class}">{validation_text}</span>
            </div>

            <!-- Input Section -->
            <div class="test-section" style="margin-bottom: 1rem;">
                <h5>Input Data</h5>
                <div class="code-block">{input_display}</div>
            </div>

            <!-- Side-by-Side Comparison Table -->
            <div class="comparison-table-wrapper">
                <table class="comparison-table">
                    <thead>
                        <tr>
                            <th style="width: 25%;">Field</th>
                            <th style="width: 30%;">Expected</th>
                            <th style="width: 30%;">Actual</th>
                            <th style="width: 15%;">Result</th>
                        </tr>
                    </thead>
                    <tbody>
                        {comparison_html}
                    </tbody>
                </table>
            </div>

            {notes_html}
            <p class="data-source">Source: <a href="{data_source_url}" target="_blank">{data_source}</a></p>
        </div>
        '''

    def _make_comparison_row(self, field: str, expected: str, actual: str, passed: bool, row_type: str = 'check') -> str:
        """Generate a single comparison table row with PASS/FAIL indicator."""
        if row_type == 'info':
            result_html = '<span class="result-info">INFO</span>'
        elif row_type == 'text':
            result_class = 'result-pass' if passed else 'result-fail'
            result_text = 'MATCH' if passed else 'NO MATCH'
            result_html = f'<span class="{result_class}">{result_text}</span>'
        else:
            result_class = 'result-pass' if passed else 'result-fail'
            result_text = 'PASS' if passed else 'FAIL'
            result_html = f'<span class="{result_class}">{result_text}</span>'

        # Escape HTML in values
        expected_safe = str(expected).replace('<', '&lt;').replace('>', '&gt;')
        actual_safe = str(actual).replace('<', '&lt;').replace('>', '&gt;')

        return f'''
            <tr>
                <td class="field-name">{field}</td>
                <td class="expected-value">{expected_safe}</td>
                <td class="actual-value">{actual_safe}</td>
                <td class="result-cell">{result_html}</td>
            </tr>
        '''

    def generate_model_section_html(self, model_name: str, model_data: Dict) -> str:
        """Generate HTML for a model's test cases."""
        description = model_data.get('description', 'No description')
        test_cases = model_data.get('test_cases', [])
        category = self.get_category_for_model(model_name)

        category_class = f'category-{category}'
        category_icons = {'nlp': '🔤', 'vision': '👁️', 'multimodal': '🎨', 'llm': '🤖'}
        category_icon = category_icons.get(category, '📦')

        test_cases_html = '\n'.join(
            self.generate_test_case_html(model_name, tc) for tc in test_cases
        )

        return f'''
        <div class="model-section">
            <div class="model-section-header">
                <h3>{category_icon} {model_name.upper()}</h3>
                <span class="category-badge {category_class}">{category.upper()}</span>
            </div>
            <p style="color: var(--text-muted); margin-bottom: 1rem;">{description}</p>
            {test_cases_html}
        </div>
        '''

    def generate_golden_image_tests_html(self) -> str:
        """Generate HTML section for golden image classification tests.

        Shows one card per model with tests horizontally aligned side-by-side.
        """
        if not hasattr(self, 'golden_validation_results') or not self.golden_validation_results:
            return ''  # No golden image tests to show

        html_parts = []
        total_golden_tests = 0
        total_golden_passed = 0
        total_golden_failed = 0
        total_golden_skipped = 0

        # Group tests by model
        for model_name, tests in sorted(self.golden_validation_results.items()):
            model_tests_html = []

            for test_name, result in sorted(tests.items()):
                total_golden_tests += 1
                passed = result.get('passed', False)
                details = result.get('details', {})
                is_skipped = details.get('skipped', False)
                message = result.get('message', '')

                if is_skipped:
                    total_golden_skipped += 1
                    status_class = 'validation-skipped'
                    status_text = 'SKIPPED'
                elif passed:
                    total_golden_passed += 1
                    status_class = 'validation-passed'
                    status_text = 'PASSED'
                else:
                    total_golden_failed += 1
                    status_class = 'validation-failed'
                    status_text = 'FAILED'

                # Build test details
                golden_image = details.get('golden_image', '')
                expected_class = details.get('expected_class', '')
                alternative_classes = details.get('alternative_classes', [])
                found_class = details.get('found_class')
                rank = details.get('rank')
                top_k_indices = details.get('top_k_indices', [])
                top_k_scores = details.get('top_k_scores', [])
                inference_time_us = details.get('inference_time_us', 0)

                # Build compact test card for horizontal layout
                if is_skipped:
                    skip_reason = details.get('reason', 'Skipped')
                    result_html = f'<span style="color: #a0aec0;">Skipped: {skip_reason}</span>'
                else:
                    # Show expected class and result
                    expected_display = f'Class {expected_class}'
                    if alternative_classes:
                        alt_str = ', '.join(map(str, alternative_classes[:2]))
                        expected_display += f' (or {alt_str}...)'

                    # Top-5 predictions formatted compactly
                    if top_k_indices:
                        top_k_display = []
                        for i, idx in enumerate(top_k_indices[:5]):
                            if i < len(top_k_scores):
                                top_k_display.append(f'{idx}({top_k_scores[i]:.1f})')
                            else:
                                top_k_display.append(str(idx))
                        top_k_str = ', '.join(top_k_display)
                    else:
                        top_k_str = 'N/A'

                    # Result line
                    if found_class is not None:
                        result_line = f'<span style="color: #48bb78;">Found at rank {rank}</span>'
                    else:
                        result_line = f'<span style="color: #f56565;">Not in top-5</span>'

                    result_html = f'''
                        <div style="font-size: 0.8rem; margin-bottom: 0.25rem;"><strong>Expected:</strong> {expected_display}</div>
                        <div style="font-size: 0.8rem; margin-bottom: 0.25rem;"><strong>Top-5:</strong> {top_k_str}</div>
                        <div style="font-size: 0.8rem;">{result_line}</div>
                    '''
                    if inference_time_us:
                        inference_ms = inference_time_us / 1000
                        result_html += f'<div style="font-size: 0.75rem; color: var(--text-muted); margin-top: 0.25rem;">Inference: {inference_ms:.1f}ms</div>'

                # Compact card for horizontal layout
                model_tests_html.append(f'''
                <div class="golden-test-item" style="flex: 1; min-width: 280px; max-width: 400px; padding: 1rem; background: var(--card-bg); border-radius: 8px; border: 1px solid var(--border-color);">
                    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.75rem;">
                        <span style="font-weight: 600; font-size: 0.9rem;">{test_name}</span>
                        <span class="validation-result {status_class}" style="font-size: 0.75rem; padding: 0.2rem 0.5rem;">{status_text}</span>
                    </div>
                    <div style="font-size: 0.8rem; color: var(--text-muted); margin-bottom: 0.5rem;">{message}</div>
                    <div>{result_html}</div>
                </div>
                ''')

            # Model section with horizontal layout for tests
            category = self.get_category_for_model(model_name)
            category_icons = {'nlp': '🔤', 'vision': '👁️', 'multimodal': '🎨', 'llm': '🤖'}
            category_icon = category_icons.get(category, '🖼️')

            html_parts.append(f'''
            <div class="golden-model-card" style="background: var(--section-bg); border-radius: 12px; padding: 1.5rem; margin-bottom: 1rem; border-left: 4px solid #17998e;">
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem;">
                    <h3 style="margin: 0; font-size: 1.1rem;">{category_icon} {model_name.upper()}</h3>
                    <span class="category-badge category-vision" style="font-size: 0.7rem; padding: 0.2rem 0.5rem;">VISION</span>
                </div>
                <div style="display: flex; flex-wrap: wrap; gap: 1rem;">
                    {''.join(model_tests_html)}
                </div>
            </div>
            ''')

        if not html_parts:
            return ''

        # Build the full section with header and summary
        summary_html = f'''
        <div class="golden-summary-stats" style="display: flex; gap: 2rem; margin-bottom: 1.5rem; flex-wrap: wrap;">
            <div class="stat-item" style="text-align: center;">
                <div class="stat-value" style="color: #48bb78; font-size: 1.5rem; font-weight: bold;">{total_golden_passed}</div>
                <div class="stat-label" style="font-size: 0.8rem; color: var(--text-muted);">Passed</div>
            </div>
            <div class="stat-item" style="text-align: center;">
                <div class="stat-value" style="color: #f56565; font-size: 1.5rem; font-weight: bold;">{total_golden_failed}</div>
                <div class="stat-label" style="font-size: 0.8rem; color: var(--text-muted);">Failed</div>
            </div>
            <div class="stat-item" style="text-align: center;">
                <div class="stat-value" style="color: #a0aec0; font-size: 1.5rem; font-weight: bold;">{total_golden_skipped}</div>
                <div class="stat-label" style="font-size: 0.8rem; color: var(--text-muted);">Skipped</div>
            </div>
            <div class="stat-item" style="text-align: center;">
                <div class="stat-value" style="font-size: 1.5rem; font-weight: bold;">{total_golden_tests}</div>
                <div class="stat-label" style="font-size: 0.8rem; color: var(--text-muted);">Total Tests</div>
            </div>
        </div>
        '''

        return f'''
        <div class="section golden-tests-section" style="margin-top: 2rem; margin-bottom: 2rem;">
            <h2>🖼️ Golden Image Classification Tests</h2>
            <p style="color: var(--text-muted); margin-bottom: 1rem;">
                Semantic validation tests using real images from the ImageNet dataset to verify that vision models
                correctly classify known objects. These tests run in Phase 4 of the pipeline using actual image inference.
            </p>
            {summary_html}
            {''.join(html_parts)}
        </div>
        '''

    def build_replacements(self) -> Dict[str, str]:
        """Build template replacement values."""
        models = self.golden_data.get('models', {})

        total_tests = 0
        total_passed = 0
        total_failed = 0

        html_parts = []
        for model_name, model_data in models.items():
            test_cases = model_data.get('test_cases', [])
            # Only count non-golden-image tests here (golden image tests counted separately)
            non_golden_tests = [tc for tc in test_cases if tc.get('expected', {}).get('validation_type') != 'top_k_class_match']
            total_tests += len(non_golden_tests)

            # Use actual validation results if available
            model_validations = self.validation_results.get(model_name, {})
            if model_validations:
                for test_case in non_golden_tests:
                    test_name = test_case.get('name', '')
                    result = model_validations.get(test_name, {})
                    if result.get('passed', False):
                        total_passed += 1
                    elif result:  # Has result but failed
                        total_failed += 1
            else:
                # Fall back to metrics-based counting
                model_metrics = self.metrics.get('models', {}).get(model_name, {})
                if model_metrics.get('inference_status') == 'success':
                    total_passed += len(non_golden_tests)
                elif model_metrics.get('inference_status') == 'failed':
                    total_failed += len(non_golden_tests)

            html_parts.append(self.generate_model_section_html(model_name, model_data))

        # Add golden image test counts to the totals
        if hasattr(self, 'golden_validation_results') and self.golden_validation_results:
            for model_name, tests in self.golden_validation_results.items():
                for test_name, result in tests.items():
                    total_tests += 1
                    details = result.get('details', {})
                    is_skipped = details.get('skipped', False)
                    if is_skipped:
                        pass  # Don't count skipped tests in pass/fail
                    elif result.get('passed', False):
                        total_passed += 1
                    else:
                        total_failed += 1

        return {
            '{{TOTAL_PASSED}}': str(total_passed),
            '{{TOTAL_FAILED}}': str(total_failed),
            '{{TOTAL_MODELS}}': str(len(models)),
            '{{TOTAL_TEST_CASES}}': str(total_tests),
            '{{MODEL_TEST_DETAILS_HTML}}': '\n'.join(html_parts),
            '{{GOLDEN_IMAGE_TESTS_HTML}}': self.generate_golden_image_tests_html(),
            '{{TIMESTAMP}}': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        }

    def render(self) -> bool:
        """Render the test details page."""
        if not self.load_data():
            return False

        template = self.load_template()
        if template is None:
            return False

        replacements = self.build_replacements()

        content = template
        for key, value in sorted(replacements.items(), key=lambda x: len(x[0]), reverse=True):
            content = content.replace(key, str(value))

        self.output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.output_path, 'w', encoding='utf-8') as f:
            f.write(content)

        print(f"✅ Test details page generated: {self.output_path}")
        return True


def main():
    parser = argparse.ArgumentParser(description='Render MLOS E2E test report')
    parser.add_argument('--metrics', default='scripts/metrics/latest.json',
                        help='Path to metrics JSON file')
    parser.add_argument('--template', default='report/template.html',
                        help='Path to HTML template')
    parser.add_argument('--output', default='output/index.html',
                        help='Path to output HTML file')
    parser.add_argument('--models-only', action='store_true',
                        help='Only render the models page')
    
    args = parser.parse_args()
    
    # Resolve paths relative to script location
    script_dir = Path(__file__).parent.parent
    
    success = True
    
    # Render main report (unless --models-only)
    if not args.models_only:
        metrics_path = script_dir / args.metrics
        template_path = script_dir / args.template
        output_path = script_dir / args.output
        
        renderer = ReportRenderer(str(metrics_path), str(template_path), str(output_path))
        success = renderer.render()
    
    # Also render models page
    config_path = script_dir / 'config' / 'models.yaml'
    models_template_path = script_dir / 'report' / 'models-template.html'
    models_output_path = script_dir / 'output' / 'models.html'

    models_renderer = ModelsPageRenderer(str(config_path), str(models_template_path), str(models_output_path))
    models_success = models_renderer.render()

    # Also render test details page
    golden_data_path = script_dir / 'config' / 'golden-test-data.yaml'
    test_details_template_path = script_dir / 'report' / 'test-details-template.html'
    test_details_output_path = script_dir / 'output' / 'test-details.html'
    metrics_path = script_dir / args.metrics

    test_details_renderer = TestDetailsPageRenderer(
        str(golden_data_path),
        str(metrics_path),
        str(test_details_template_path),
        str(test_details_output_path)
    )
    test_details_success = test_details_renderer.render()

    # Success if main report succeeded (other pages are optional)
    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()

