#!/usr/bin/env python3
"""
Generate test inputs for E2E inference tests.

This script reads the test-inputs.yaml configuration and generates
proper test inputs using model tokenizers and preprocessors.

Usage:
    python generate-test-input.py <model_name> [size]
    python generate-test-input.py <model_name> --image <path>

    size: small (default), medium, large

Examples:
    python generate-test-input.py bert small
    python generate-test-input.py resnet
    python generate-test-input.py gpt2 large
    python generate-test-input.py resnet --image test-data/golden-images/imagenet/cat_tabby.jpg
"""

import argparse
import json
import os
import random
import sys
import warnings
from pathlib import Path

# Suppress all warnings from transformers/PIL before importing
warnings.filterwarnings("ignore")
os.environ["TRANSFORMERS_VERBOSITY"] = "error"

import yaml


def load_config():
    """Load test input configuration from YAML file."""
    config_path = Path(__file__).parent.parent / "config" / "test-inputs.yaml"
    if not config_path.exists():
        print(f"Error: Config file not found: {config_path}", file=sys.stderr)
        sys.exit(1)
    
    with open(config_path, 'r') as f:
        return yaml.safe_load(f)


def generate_nlp_input(model_config: dict, size: str = "small") -> dict:
    """Generate NLP model input using tokenizer."""
    tokenizer_name = model_config.get("tokenizer")
    test_text = model_config.get("test_text", {}).get(size, "Hello world.")
    max_length = model_config.get("max_length", {}).get(size, 16)
    padding = model_config.get("padding", "max_length")
    truncation = model_config.get("truncation", True)
    required_inputs = model_config.get("required_inputs", ["input_ids"])
    
    try:
        from transformers import AutoTokenizer
        tokenizer = AutoTokenizer.from_pretrained(tokenizer_name)
        
        # Tokenize the text
        inputs = tokenizer(
            test_text,
            max_length=max_length,
            padding=padding,
            truncation=truncation,
            return_tensors="np"
        )
        
        # Convert to list format for JSON
        result = {}
        for key in required_inputs:
            if key in inputs:
                result[key] = inputs[key].tolist()[0]
            elif key == "decoder_input_ids":
                # For encoder-decoder models like T5
                decoder_start = model_config.get("decoder_start_token_id", 0)
                result[key] = [decoder_start] + [0] * (max_length - 1)
        
        return result
        
    except ImportError:
        print("Warning: transformers not installed, using fallback", file=sys.stderr)
        return generate_nlp_fallback(model_config, size)
    except Exception as e:
        print(f"Warning: Tokenizer failed ({e}), using fallback", file=sys.stderr)
        return generate_nlp_fallback(model_config, size)


def generate_nlp_fallback(model_config: dict, size: str = "small") -> dict:
    """Generate fallback NLP input without tokenizer."""
    max_length = model_config.get("max_length", {}).get(size, 16)
    required_inputs = model_config.get("required_inputs", ["input_ids"])
    
    # Use token IDs appropriate for the model
    result = {}
    
    if "input_ids" in required_inputs:
        # Check if this looks like a BERT-style or GPT-style model
        if "token_type_ids" in required_inputs:
            # BERT-style: [CLS]=101, word tokens, [SEP]=102
            result["input_ids"] = [101] + [7592] * (max_length - 2) + [102]
        else:
            # GPT/RoBERTa-style: Just word tokens
            # Using generic word token IDs
            result["input_ids"] = [15496] + [2746] * (max_length - 1)
    
    if "attention_mask" in required_inputs:
        result["attention_mask"] = [1] * max_length
    
    if "token_type_ids" in required_inputs:
        result["token_type_ids"] = [0] * max_length
    
    if "decoder_input_ids" in required_inputs:
        decoder_start = model_config.get("decoder_start_token_id", 0)
        result["decoder_input_ids"] = [decoder_start] + [0] * (max_length - 1)
    
    return result


def load_image_input(image_path: str, model_config: dict) -> dict:
    """Load and preprocess a real image file for vision model inference.

    Uses standard torchvision transforms that match ONNX export preprocessing.
    This ensures deterministic, reproducible results matching the model's
    expected input format.

    Args:
        image_path: Path to the image file (JPEG, PNG, etc.)
        model_config: Model configuration from test-inputs.yaml

    Returns:
        Dictionary with preprocessed pixel_values for Core API

    Raises:
        SystemExit: If required dependencies (PIL, numpy, torchvision) are missing
    """
    input_name = model_config.get("input_name", "pixel_values")
    image_size = model_config.get("image_size", 224)
    normalization = model_config.get("normalization", {})
    mean = normalization.get("mean", [0.485, 0.456, 0.406])
    std = normalization.get("std", [0.229, 0.224, 0.225])

    # Check for required dependencies
    try:
        from PIL import Image
        import numpy as np
    except ImportError:
        print("Error: PIL (Pillow) and numpy are required for image loading.", file=sys.stderr)
        print("Install with: pip install pillow numpy", file=sys.stderr)
        sys.exit(1)

    try:
        from torchvision import transforms
    except ImportError:
        print("Error: torchvision is required for vision model preprocessing.", file=sys.stderr)
        print("Install with: pip install torchvision", file=sys.stderr)
        sys.exit(1)

    # Load image
    img = Image.open(image_path).convert('RGB')

    # Use standard ImageNet preprocessing that matches ONNX export
    # This is the standard preprocessing used by torchvision models
    transform = transforms.Compose([
        transforms.Resize(256),           # Resize to 256 on shortest edge
        transforms.CenterCrop(image_size), # Center crop to target size
        transforms.ToTensor(),             # Convert to tensor (0-1 range)
        transforms.Normalize(mean=mean, std=std)
    ])

    # Apply transforms and convert to numpy
    pixel_values = transform(img).numpy()

    # Ensure NCHW format with batch dimension
    if pixel_values.ndim == 3:  # CHW format
        pixel_values = np.expand_dims(pixel_values, 0)  # Add batch dim

    return {input_name: pixel_values.flatten().tolist()}


def generate_vision_input(model_config: dict, size: str = "small") -> dict:
    """Generate vision model input (normalized random image tensor)."""
    input_name = model_config.get("input_name", "pixel_values")
    image_size = model_config.get("image_size", 224)
    channels = model_config.get("channels", 3)
    seed = model_config.get("test_seed", 42)
    normalization = model_config.get("normalization", {})

    mean = normalization.get("mean", [0.485, 0.456, 0.406])
    std = normalization.get("std", [0.229, 0.224, 0.225])

    # Set random seed for reproducibility
    random.seed(seed)

    # Generate normalized random image data
    # Shape: [batch, channels, height, width] = [1, 3, 224, 224]
    total_elements = 1 * channels * image_size * image_size

    # Generate values normalized around ImageNet mean/std
    data = []
    for i in range(total_elements):
        c = (i // (image_size * image_size)) % channels
        # Generate values in normalized range: (x - mean) / std
        # Most values will be in range [-2, 2] after normalization
        value = random.gauss(0, 1)  # Standard normal
        data.append(value)

    return {input_name: data}


def generate_multimodal_input(model_config: dict, size: str = "small") -> dict:
    """Generate multi-modal input for CLIP and similar models."""
    model_type = model_config.get("model_type", "clip")

    if model_type == "clip":
        return generate_clip_input(model_config, size)
    elif model_type == "audio":
        return generate_audio_input(model_config, size)
    else:
        print(f"Warning: Unknown multimodal type '{model_type}'", file=sys.stderr)
        return {}


def generate_llm_input(model_config: dict, size: str = "small") -> dict:
    """Generate LLM/GGUF model input (text prompt for generation).

    LLM models use the GGUF format and are executed via Core's llama.cpp plugin.
    Input format: {"prompt": "...", "max_tokens": N, "temperature": 0.7}
    """
    prompts = model_config.get("prompts", {})
    max_tokens = model_config.get("max_tokens", {})

    # Get size-specific values or defaults
    prompt = prompts.get(size, "Hello, how are you?")
    tokens = max_tokens.get(size, 32)

    # Generation parameters
    temperature = model_config.get("temperature", 0.7)
    top_p = model_config.get("top_p", 0.9)

    return {
        "prompt": prompt,
        "max_tokens": tokens,
        "temperature": temperature,
        "top_p": top_p
    }


def generate_clip_input(model_config: dict, size: str = "small") -> dict:
    """Generate CLIP model input (text + image)."""
    # Text input
    text_tokenizer = model_config.get("text_tokenizer", "openai/clip-vit-base-patch32")
    test_text = model_config.get("test_text", {}).get(size, "a photo of a cat")
    text_max_length = model_config.get("text_max_length", {}).get(size, 77)
    
    # Image input
    image_size = model_config.get("image_size", {}).get(size, 224)
    channels = model_config.get("channels", 3)
    seed = model_config.get("test_seed", 42)
    
    result = {}
    
    # Try to use CLIP tokenizer
    try:
        from transformers import CLIPTokenizer
        tokenizer = CLIPTokenizer.from_pretrained(text_tokenizer)
        
        inputs = tokenizer(
            test_text,
            max_length=text_max_length,
            padding="max_length",
            truncation=True,
            return_tensors="np"
        )
        
        result["input_ids"] = inputs["input_ids"].tolist()[0]
        result["attention_mask"] = inputs["attention_mask"].tolist()[0]
        
    except ImportError:
        print("Warning: transformers not installed, using fallback for CLIP text", file=sys.stderr)
        # CLIP fallback: BPE token IDs
        # 49406 = <|startoftext|>, 49407 = <|endoftext|>
        result["input_ids"] = [49406] + [320] * (text_max_length - 2) + [49407]
        result["attention_mask"] = [1] * text_max_length
    except Exception as e:
        print(f"Warning: CLIP tokenizer failed ({e}), using fallback", file=sys.stderr)
        result["input_ids"] = [49406] + [320] * (text_max_length - 2) + [49407]
        result["attention_mask"] = [1] * text_max_length
    
    # Generate image pixel values
    random.seed(seed)
    total_elements = 1 * channels * image_size * image_size
    
    # CLIP uses mean=[0.48145466, 0.4578275, 0.40821073], std=[0.26862954, 0.26130258, 0.27577711]
    pixel_values = [random.gauss(0, 1) for _ in range(total_elements)]
    result["pixel_values"] = pixel_values
    
    return result


def generate_audio_input(model_config: dict, size: str = "small") -> dict:
    """Generate audio model input (waveform)."""
    sample_rate = model_config.get("sample_rate", 16000)
    duration = model_config.get("duration", {}).get(size, 1.0)  # seconds
    seed = model_config.get("test_seed", 42)
    input_name = model_config.get("input_name", "input_values")
    
    # Set random seed for reproducibility
    random.seed(seed)
    
    # Generate audio samples (simple sine wave + noise for testing)
    num_samples = int(sample_rate * duration)
    
    import math
    # Generate a simple sine wave at 440Hz with some noise
    frequency = 440.0
    audio_data = []
    for i in range(num_samples):
        t = i / sample_rate
        sample = 0.5 * math.sin(2 * math.pi * frequency * t) + 0.1 * random.gauss(0, 1)
        audio_data.append(sample)
    
    return {input_name: audio_data}


def main():
    parser = argparse.ArgumentParser(
        description="Generate test inputs for E2E inference tests"
    )
    parser.add_argument("model", help="Model name (e.g., bert, resnet, gpt2)")
    parser.add_argument(
        "size",
        nargs="?",
        default="small",
        choices=["small", "medium", "large"],
        help="Input size (default: small)"
    )
    parser.add_argument(
        "--image",
        help="Path to image file for vision model semantic testing"
    )
    parser.add_argument(
        "--pretty",
        action="store_true",
        help="Pretty-print JSON output"
    )

    args = parser.parse_args()

    # Load configuration
    config = load_config()
    models = config.get("models", {})

    if args.model not in models:
        print(f"Error: Unknown model '{args.model}'", file=sys.stderr)
        print(f"Available models: {', '.join(models.keys())}", file=sys.stderr)
        sys.exit(1)

    model_config = models[args.model]
    category = model_config.get("category", "nlp")

    # If --image is provided, load real image for vision models
    if args.image:
        if category != "vision":
            print(f"Error: --image flag only supported for vision models, not '{category}'", file=sys.stderr)
            sys.exit(1)
        if not Path(args.image).exists():
            print(f"Error: Image file not found: {args.image}", file=sys.stderr)
            sys.exit(1)
        result = load_image_input(args.image, model_config)
    else:
        # Generate synthetic input based on category
        if category == "nlp":
            result = generate_nlp_input(model_config, args.size)
        elif category == "vision":
            result = generate_vision_input(model_config, args.size)
        elif category == "multimodal":
            result = generate_multimodal_input(model_config, args.size)
        elif category == "llm":
            result = generate_llm_input(model_config, args.size)
        else:
            print(f"Error: Unknown category '{category}'", file=sys.stderr)
            sys.exit(1)

    # Output JSON
    if args.pretty:
        print(json.dumps(result, indent=2))
    else:
        print(json.dumps(result))


if __name__ == "__main__":
    main()

