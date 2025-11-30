#!/usr/bin/env python3
"""
Load model configuration from YAML and output for bash consumption.

Usage:
    # Get list of enabled models
    python3 load-config.py --list
    
    # Get model details as JSON
    python3 load-config.py --model gpt2
    
    # Get all enabled models as JSON
    python3 load-config.py --all
    
    # Export as bash variables
    python3 load-config.py --bash
"""

import argparse
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML not installed. Run: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


def load_config(config_path=None):
    """Load the models.yaml configuration."""
    if config_path is None:
        # Look in standard locations
        search_paths = [
            Path(__file__).parent.parent / "config" / "models.yaml",
            Path("config/models.yaml"),
            Path("../config/models.yaml"),
        ]
        for p in search_paths:
            if p.exists():
                config_path = p
                break
    
    if config_path is None or not Path(config_path).exists():
        print(f"ERROR: Config file not found", file=sys.stderr)
        sys.exit(1)
    
    with open(config_path, 'r') as f:
        return yaml.safe_load(f)


def get_enabled_models(config):
    """Return list of enabled model names."""
    return [name for name, m in config.get('models', {}).items() if m.get('enabled', False)]


def get_model_info(config, model_name):
    """Return model configuration as dict."""
    models = config.get('models', {})
    if model_name not in models:
        return None
    return models[model_name]


def output_bash_vars(config):
    """Output configuration as bash variables."""
    settings = config.get('settings', {})
    models = config.get('models', {})
    
    enabled = get_enabled_models(config)
    
    print(f'# Auto-generated from config/models.yaml')
    print(f'CONFIG_INSTALL_TIMEOUT={settings.get("install_timeout", 600)}')
    print(f'CONFIG_INFERENCE_TIMEOUT={settings.get("inference_timeout", 60)}')
    print(f'CONFIG_RUN_LARGE_TESTS={"true" if settings.get("run_large_tests", True) else "false"}')
    print(f'CONFIG_ENABLED_MODELS="{" ".join(enabled)}"')
    print(f'CONFIG_MODEL_COUNT={len(enabled)}')
    print()
    
    # Output per-model variables
    for name in enabled:
        m = models[name]
        prefix = f'MODEL_{name.upper()}'
        print(f'{prefix}_AXON_ID="{m.get("axon_id", "")}"')
        print(f'{prefix}_CATEGORY="{m.get("category", "nlp")}"')
        print(f'{prefix}_INPUT_TYPE="{m.get("input_type", "text")}"')
        
        small = m.get('small_input', {})
        large = m.get('large_input', {})
        
        if m.get('input_type') == 'text':
            print(f'{prefix}_SMALL_TOKENS={small.get("tokens", 7)}')
            print(f'{prefix}_LARGE_TOKENS={large.get("tokens", 128)}')
        elif m.get('input_type') == 'image':
            print(f'{prefix}_SMALL_WIDTH={small.get("width", 32)}')
            print(f'{prefix}_SMALL_HEIGHT={small.get("height", 32)}')
            print(f'{prefix}_LARGE_WIDTH={large.get("width", 64)}')
            print(f'{prefix}_LARGE_HEIGHT={large.get("height", 64)}')
        print()


def main():
    parser = argparse.ArgumentParser(description='Load model configuration')
    parser.add_argument('--config', '-c', help='Path to models.yaml')
    parser.add_argument('--list', '-l', action='store_true', help='List enabled model names')
    parser.add_argument('--model', '-m', help='Get specific model info as JSON')
    parser.add_argument('--all', '-a', action='store_true', help='Get all enabled models as JSON')
    parser.add_argument('--bash', '-b', action='store_true', help='Output as bash variables')
    parser.add_argument('--settings', '-s', action='store_true', help='Output settings as JSON')
    
    args = parser.parse_args()
    config = load_config(args.config)
    
    if args.list:
        for name in get_enabled_models(config):
            print(name)
    
    elif args.model:
        info = get_model_info(config, args.model)
        if info:
            print(json.dumps(info, indent=2))
        else:
            print(f"ERROR: Model '{args.model}' not found", file=sys.stderr)
            sys.exit(1)
    
    elif args.all:
        enabled = get_enabled_models(config)
        result = {name: config['models'][name] for name in enabled}
        print(json.dumps(result, indent=2))
    
    elif args.bash:
        output_bash_vars(config)
    
    elif args.settings:
        print(json.dumps(config.get('settings', {}), indent=2))
    
    else:
        # Default: show summary
        enabled = get_enabled_models(config)
        all_models = list(config.get('models', {}).keys())
        print(f"Models configured: {len(all_models)}")
        print(f"Models enabled:    {len(enabled)}")
        print(f"Enabled: {', '.join(enabled)}")


if __name__ == '__main__':
    main()

