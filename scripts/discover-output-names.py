#!/usr/bin/env python3
"""
Discover actual output tensor names from Core inference responses.

This script tests each model with include_outputs=true to discover
the actual output tensor names that Core returns.

Usage:
    python discover-output-names.py [--model MODEL] [--core-url URL]
"""

import argparse
import json
import random
import sys
import urllib.request
import urllib.parse
import urllib.error
import yaml
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
CONFIG_DIR = SCRIPT_DIR.parent / "config"
MODELS_CONFIG = CONFIG_DIR / "models.yaml"
GOLDEN_DATA = CONFIG_DIR / "golden-test-data.yaml"


def generate_vision_input(seed=42):
    """Generate random pixel values for vision models."""
    random.seed(seed)
    return [random.gauss(0, 1) for _ in range(1 * 3 * 224 * 224)]


def generate_nlp_input(model_name: str, max_len: int = 16):
    """Generate token input for NLP models."""
    if model_name == "gpt2":
        return {"input_ids": [15496, 11, 314, 716, 257, 3303] + [2746] * (max_len - 6)}
    elif model_name == "bert":
        return {
            "input_ids": [101] + [7592] * (max_len - 2) + [102],
            "attention_mask": [1] * max_len,
            "token_type_ids": [0] * max_len
        }
    elif model_name == "roberta":
        return {"input_ids": [0] + [31414] * (max_len - 2) + [2]}
    elif model_name == "distilbert":
        return {
            "input_ids": [101] + [7592] * (max_len - 2) + [102],
            "attention_mask": [1] * max_len
        }
    elif model_name == "albert":
        return {
            "input_ids": [2] + [13] * (max_len - 2) + [3],
            "attention_mask": [1] * max_len,
            "token_type_ids": [0] * max_len
        }
    elif model_name == "sentence-transformers":
        return {
            "input_ids": [101] + [7592] * (max_len - 2) + [102],
            "attention_mask": [1] * max_len
        }
    elif model_name == "t5":
        return {
            "input_ids": [8774, 6, 26, 21, 408, 8612, 2495, 5, 1] + [0] * (max_len - 9),
            "attention_mask": [1] * 9 + [0] * (max_len - 9),
            "decoder_input_ids": [0] + [320] * (max_len - 1)
        }
    else:
        # Generic fallback
        return {"input_ids": [101, 7592, 102]}


def url_encode(s: str) -> str:
    """URL encode a string."""
    return urllib.parse.quote(s, safe='')


def run_inference(core_url: str, model_id: str, input_data: dict) -> dict:
    """Run inference and return response with outputs."""
    encoded_id = url_encode(model_id)
    url = f"{core_url}/models/{encoded_id}/inference?include_outputs=true"

    req = urllib.request.Request(
        url,
        data=json.dumps(input_data).encode('utf-8'),
        headers={'Content-Type': 'application/json'},
        method='POST'
    )

    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}", "body": e.read().decode('utf-8')[:500]}
    except urllib.error.URLError as e:
        return {"error": str(e)}
    except Exception as e:
        return {"error": str(e)}


def get_tensor_shape(data) -> list:
    """Get shape of nested list tensor."""
    shape = []
    curr = data
    while isinstance(curr, list) and curr:
        shape.append(len(curr))
        curr = curr[0]
    return shape


def discover_model_outputs(core_url: str, model_name: str, axon_id: str, category: str) -> dict:
    """Discover output names and shapes for a model."""
    result = {
        "model_name": model_name,
        "axon_id": axon_id,
        "category": category,
        "outputs": {},
        "status": "unknown"
    }

    # Generate appropriate input
    if category == "vision":
        input_data = {"pixel_values": generate_vision_input()}
    elif category == "multimodal":
        # CLIP
        random.seed(42)
        input_data = {
            "input_ids": [49406] + [320] * 75 + [49407],
            "attention_mask": [1] * 77,
            "pixel_values": generate_vision_input()
        }
    elif category == "nlp":
        input_data = generate_nlp_input(model_name)
    else:
        input_data = generate_nlp_input(model_name)

    # Run inference
    response = run_inference(core_url, axon_id, input_data)

    if "error" in response:
        result["status"] = "error"
        result["error"] = response["error"]
        return result

    if response.get("status") != "success":
        result["status"] = "inference_failed"
        result["error"] = response.get("message", "Unknown error")
        return result

    # Extract outputs
    if "outputs" in response:
        result["status"] = "success"
        for name, data in response["outputs"].items():
            shape = get_tensor_shape(data)
            result["outputs"][name] = {"shape": shape}
    else:
        result["status"] = "no_outputs"
        result["note"] = "Response did not include outputs (include_outputs may not be supported)"

    result["inference_time_us"] = response.get("inference_time_us", 0)
    return result


def main():
    parser = argparse.ArgumentParser(description="Discover output tensor names from Core")
    parser.add_argument('--model', '-m', help='Specific model to test')
    parser.add_argument('--core-url', default='http://127.0.0.1:8080', help='Core URL')
    parser.add_argument('--register', action='store_true', help='Register models before testing')
    args = parser.parse_args()

    # Load models config
    if not MODELS_CONFIG.exists():
        print(f"Error: Config not found: {MODELS_CONFIG}")
        sys.exit(1)

    with open(MODELS_CONFIG) as f:
        config = yaml.safe_load(f)

    models = config.get('models', {})

    # Filter to specific model if requested
    if args.model:
        if args.model not in models:
            print(f"Error: Model '{args.model}' not found in config")
            sys.exit(1)
        models = {args.model: models[args.model]}

    results = []

    for name, model in models.items():
        if not model.get('enabled', False):
            print(f"⏭️  Skipping disabled model: {name}")
            continue

        axon_id = model.get('axon_id', '')
        category = model.get('category', 'nlp')

        print(f"\n🔍 Testing {name} ({category})")
        print(f"   Axon ID: {axon_id}")

        # Register if requested
        if args.register:
            import subprocess
            print(f"   📝 Registering...")
            subprocess.run(
                [str(Path.home() / ".local/bin/axon"), "register", axon_id],
                capture_output=True,
                env={"MLOS_CORE_ENDPOINT": args.core_url, **dict(__import__('os').environ)}
            )

        # Discover outputs
        result = discover_model_outputs(args.core_url, name, axon_id, category)
        results.append(result)

        if result["status"] == "success":
            print(f"   ✅ Success!")
            for out_name, out_info in result["outputs"].items():
                print(f"      - {out_name}: shape={out_info['shape']}")
        else:
            print(f"   ❌ {result['status']}: {result.get('error', 'unknown')}")

    # Summary
    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)

    successful = [r for r in results if r["status"] == "success"]
    failed = [r for r in results if r["status"] != "success"]

    print(f"\n✅ Successful: {len(successful)}")
    print(f"❌ Failed: {len(failed)}")

    if successful:
        print("\n📊 Discovered Output Names:")
        print("-" * 40)
        for r in successful:
            outputs = ", ".join(f"{k}:{v['shape']}" for k, v in r["outputs"].items())
            print(f"  {r['model_name']}: {outputs}")

    if failed:
        print("\n⚠️  Failed Models:")
        print("-" * 40)
        for r in failed:
            print(f"  {r['model_name']}: {r['status']} - {r.get('error', '')}")

    # Output JSON for further processing
    output_file = SCRIPT_DIR.parent / "discovered-outputs.json"
    with open(output_file, 'w') as f:
        json.dump(results, f, indent=2)
    print(f"\n📄 Results saved to: {output_file}")


if __name__ == '__main__':
    main()
