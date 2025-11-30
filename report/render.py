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
            'resnet': '#11998e',
            'vgg': '#38ef7d'
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
        """Generate HTML for inference metrics cards."""
        models = self.metrics.get('models', {})
        html_parts = []
        
        for model_name, model_data in models.items():
            if not model_data.get('tested', False):
                continue
            
            display_name = model_name.upper()
            
            # Small inference
            time_ms = model_data.get('inference_time_ms', 0)
            status = self.get_model_status(model_name, 'small')
            html_parts.append(f'''
                <div class="metric-card">
                    <h4>{display_name} (small)</h4>
                    <div class="metric-value">{time_ms} ms</div>
                    <div class="status-badge {status['status_class']}">{status['status']} Success</div>
                </div>
            ''')
            
            # Large inference (if tested)
            if model_data.get('inference_large_tested', False):
                time_ms_large = model_data.get('inference_large_time_ms', 0)
                status_large = self.get_model_status(model_name, 'large')
                html_parts.append(f'''
                    <div class="metric-card">
                        <h4>{display_name} (large)</h4>
                        <div class="metric-value">{time_ms_large} ms</div>
                        <div class="status-badge {status_large['status_class']}">{status_large['status']} Success</div>
                    </div>
                ''')
        
        return '\n'.join(html_parts)
    
    def generate_model_details_html(self) -> str:
        """Generate HTML for model details section."""
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
            html_parts.append('<h4 style="color: #667eea; margin-bottom: 15px;">🔤 NLP Models</h4>')
            html_parts.append('<div class="metrics-grid">')
            for model_name, model_data in categories['nlp']:
                display_name = model_name.upper()
                install_time = model_data.get('install_time_ms', 0)
                register_time = model_data.get('register_time_ms', 0)
                html_parts.append(f'''
                    <div class="metric-card">
                        <h4>{display_name} Install Time</h4>
                        <div class="metric-value">{install_time} ms</div>
                    </div>
                    <div class="metric-card">
                        <h4>{display_name} Register Time</h4>
                        <div class="metric-value">{register_time} ms</div>
                    </div>
                ''')
            html_parts.append('</div>')
        
        # Vision Models
        if categories['vision']:
            html_parts.append('<h4 style="color: #17998e; margin: 25px 0 15px 0;">👁️ Vision Models</h4>')
            html_parts.append('<div class="metrics-grid">')
            for model_name, model_data in categories['vision']:
                display_name = model_name.upper()
                install_time = model_data.get('install_time_ms', 0)
                register_time = model_data.get('register_time_ms', 0)
                html_parts.append(f'''
                    <div class="metric-card" style="border-left-color: #17998e;">
                        <h4>{display_name} Install Time</h4>
                        <div class="metric-value">{install_time} ms</div>
                    </div>
                    <div class="metric-card" style="border-left-color: #17998e;">
                        <h4>{display_name} Register Time</h4>
                        <div class="metric-value">{register_time} ms</div>
                    </div>
                ''')
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
            
            # Timings
            '{{AXON_DOWNLOAD_TIME}}': str(timings.get('axon_download_ms', 0)),
            '{{CORE_DOWNLOAD_TIME}}': str(timings.get('core_download_ms', 0)),
            '{{CORE_STARTUP_TIME}}': str(timings.get('core_startup_ms', 0)),
            '{{TOTAL_MODEL_INSTALL_TIME}}': str(timings.get('total_model_install_ms', 0)),
            
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
            '{{MODEL_INSTALL_TIME_CALLOUT}}': str(breakdown_chart['model_install_ms']),
            
            # Dynamic HTML sections
            '{{INFERENCE_METRICS_HTML}}': self.generate_inference_metrics_html(),
            '{{MODEL_DETAILS_HTML}}': self.generate_model_details_html(),
            
            # Model-specific status (for Model Support section)
            '{{GPT2_STATUS}}': self.get_model_status('gpt2')['status'],
            '{{GPT2_STATUS_CLASS}}': self.get_model_status('gpt2')['status_class'],
            '{{BERT_STATUS}}': self.get_model_status('bert')['status'],
            '{{BERT_STATUS_CLASS}}': self.get_model_status('bert')['status_class'],
            '{{ROBERTA_STATUS}}': self.get_model_status('roberta')['status'],
            '{{ROBERTA_STATUS_CLASS}}': self.get_model_status('roberta')['status_class'],
            '{{RESNET_STATUS}}': self.get_model_status('resnet')['status'],
            '{{RESNET_STATUS_CLASS}}': self.get_model_status('resnet')['status_class'],
            
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


def main():
    parser = argparse.ArgumentParser(description='Render MLOS E2E test report')
    parser.add_argument('--metrics', default='scripts/metrics/latest.json',
                        help='Path to metrics JSON file')
    parser.add_argument('--template', default='report/template.html',
                        help='Path to HTML template')
    parser.add_argument('--output', default='output/index.html',
                        help='Path to output HTML file')
    
    args = parser.parse_args()
    
    # Resolve paths relative to script location
    script_dir = Path(__file__).parent.parent
    metrics_path = script_dir / args.metrics
    template_path = script_dir / args.template
    output_path = script_dir / args.output
    
    renderer = ReportRenderer(str(metrics_path), str(template_path), str(output_path))
    success = renderer.render()
    
    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()

