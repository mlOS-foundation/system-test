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
            'gpt2': '#667eea',
            'bert': '#764ba2',
            'roberta': '#f093fb',
            't5': '#f59e0b',  # Orange for T5 (encoder-decoder)
            'resnet': '#11998e',
            'vgg': '#38ef7d',
            'clip': '#8b5cf6',  # Purple for CLIP (multi-encoder)
            'vit': '#10b981',
            'convnext': '#06b6d4',
            'mobilenet': '#ec4899',
            'deit': '#14b8a6',
            'efficientnet': '#84cc16'
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
        categories = {'nlp': [], 'vision': [], 'multimodal': []}
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
        
        return '\n'.join(html_parts)
    
    def generate_model_details_html(self) -> str:
        """Generate HTML for model details section - one card per model with timing data points inside."""
        models = self.metrics.get('models', {})
        html_parts = []
        
        # Group by category
        categories = {'nlp': [], 'vision': [], 'multimodal': []}
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
        
        return '\n'.join(html_parts)
    
    def build_replacements(self) -> Dict[str, str]:
        """Build all template replacements."""
        overall = self.calculate_overall_status()
        nlp_status = self.calculate_category_status('nlp')
        vision_status = self.calculate_category_status('vision')
        multimodal_status = self.calculate_category_status('multimodal')
        
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
        
        enabled_count = sum(1 for d in models.values() if d.get('enabled', False))
        
        # Generate HTML for each category
        nlp_html = '\n'.join(self.generate_model_card_html(n, d) for n, d in nlp_models) or '<p class="no-models">No NLP models configured</p>'
        vision_html = '\n'.join(self.generate_model_card_html(n, d) for n, d in vision_models) or '<p class="no-models">No vision models configured</p>'
        multimodal_html = '\n'.join(self.generate_model_card_html(n, d) for n, d in multimodal_models) or '<p class="no-models">No multimodal models configured</p>'
        
        return {
            '{{TOTAL_MODELS}}': str(len(models)),
            '{{ENABLED_MODELS}}': str(enabled_count),
            '{{NLP_COUNT}}': str(len(nlp_models)),
            '{{VISION_COUNT}}': str(len(vision_models)),
            '{{MULTIMODAL_COUNT}}': str(len(multimodal_models)),
            '{{NLP_MODELS_HTML}}': nlp_html,
            '{{VISION_MODELS_HTML}}': vision_html,
            '{{MULTIMODAL_MODELS_HTML}}': multimodal_html,
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
    
    # Success if main report succeeded (models page is optional)
    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()

