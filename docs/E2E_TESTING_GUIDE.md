# MLOS E2E Testing System Guide

This document explains how the MLOS End-to-End (E2E) testing system works and how to extend it for new models.

## Overview

The E2E testing system validates the complete MLOS stack:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        E2E Test Pipeline                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  1. Download Releases          2. Install Models                    │
│  ┌──────────────────┐         ┌──────────────────┐                 │
│  │  Axon v3.1.1     │         │  Hugging Face    │                 │
│  │  Core v3.2.1     │         │  Models → ONNX   │                 │
│  └──────────────────┘         └──────────────────┘                 │
│           │                            │                            │
│           ▼                            ▼                            │
│  3. Start MLOS Core           4. Register Models                    │
│  ┌──────────────────┐         ┌──────────────────┐                 │
│  │  HTTP API :18080 │◄────────│  axon register   │                 │
│  │  ONNX Runtime    │         │  model.onnx      │                 │
│  └──────────────────┘         └──────────────────┘                 │
│           │                                                         │
│           ▼                                                         │
│  5. Run Inference Tests       6. Generate Report                    │
│  ┌──────────────────┐         ┌──────────────────┐                 │
│  │  POST /inference │────────►│  HTML Report     │                 │
│  │  Validate Output │         │  GitHub Pages    │                 │
│  └──────────────────┘         └──────────────────┘                 │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Configuration Files

### 1. Model Configuration (`config/models.yaml`)

Defines which models to test and their metadata:

```yaml
models:
  gpt2:
    enabled: true
    category: nlp
    axon_id: "hf/distilgpt2@latest"
    description: "DistilGPT2 - Text generation"
    input_type: text
    
  resnet:
    enabled: true
    category: vision
    axon_id: "hf/microsoft/resnet-50@latest"
    description: "ResNet-50 - Image classification"
    input_type: image
```

**Fields:**
- `enabled`: Whether to include in tests
- `category`: `nlp`, `vision`, or `multimodal`
- `axon_id`: Full Axon model identifier
- `input_type`: Type of input data needed

### 2. Test Input Configuration (`config/test-inputs.yaml`)

Defines test inputs for each model:

```yaml
models:
  gpt2:
    category: nlp
    tokenizer: "distilgpt2"
    test_text:
      small: "Hello, I am a language model."
      medium: "The quick brown fox..."
      large: "Machine learning has transformed..."
    max_length:
      small: 16
      medium: 64
      large: 128
    required_inputs: ["input_ids"]  # ONNX model inputs
    
  resnet:
    category: vision
    input_name: "pixel_values"
    image_size: 224
    channels: 3
    normalization:
      mean: [0.485, 0.456, 0.406]
      std: [0.229, 0.224, 0.225]
```

**Key Points:**
- `required_inputs`: Must match ONNX model's actual input names
- `tokenizer`: HuggingFace tokenizer for NLP models
- `normalization`: ImageNet normalization for vision models

## Adding a New Model

### Step 1: Add to `config/models.yaml`

```yaml
models:
  # Add your new model
  my_new_model:
    enabled: true
    category: nlp  # or vision, multimodal
    axon_id: "hf/organization/model-name@latest"
    description: "My New Model - Task description"
    input_type: text  # or image
```

### Step 2: Add to `config/test-inputs.yaml`

For NLP models:
```yaml
models:
  my_new_model:
    category: nlp
    tokenizer: "organization/model-name"
    test_text:
      small: "Test sentence for the model."
      medium: "Longer test sentence with more context."
      large: "Even longer text for stress testing..."
    max_length:
      small: 16
      medium: 64
      large: 128
    required_inputs: ["input_ids"]  # Check ONNX model!
```

For vision models:
```yaml
models:
  my_new_model:
    category: vision
    input_name: "pixel_values"
    image_size: 224
    channels: 3
    normalization:
      mean: [0.485, 0.456, 0.406]
      std: [0.229, 0.224, 0.225]
    test_seed: 42
```

### Step 3: Verify ONNX Model Inputs

**Critical**: Check what inputs your ONNX model actually needs:

```bash
# Using Docker
docker run --rm --entrypoint="" \
  -v ~/.axon/cache/models/hf/your-model:/model \
  ghcr.io/mlos-foundation/axon-converter:latest \
  python3 -c "
import onnx
model = onnx.load('/model/model.onnx')
print('Model inputs:')
for inp in model.graph.input:
    print(f'  - {inp.name}')
"
```

Common patterns:
- **GPT2/RoBERTa**: `input_ids` only
- **BERT**: `input_ids`, `attention_mask`, `token_type_ids`
- **Vision models**: `pixel_values`
- **T5**: `input_ids`, `attention_mask`, `decoder_input_ids`

### Step 4: Test Locally

```bash
# Generate test input
python3 scripts/generate-test-input.py my_new_model small

# Install and register model
axon install hf/organization/model-name@latest
axon register hf/organization/model-name@latest

# Test inference
curl -X POST http://localhost:18080/models/my_new_model/inference \
  -H "Content-Type: application/json" \
  -d "$(python3 scripts/generate-test-input.py my_new_model small)"
```

## Test Input Generator

The `scripts/generate-test-input.py` script generates proper test inputs:

```bash
# Usage
python3 scripts/generate-test-input.py <model_name> [size]

# Examples
python3 scripts/generate-test-input.py bert small
python3 scripts/generate-test-input.py resnet
python3 scripts/generate-test-input.py gpt2 large --pretty
```

### How It Works

1. Reads configuration from `config/test-inputs.yaml`
2. For NLP models:
   - Uses HuggingFace tokenizer if available
   - Falls back to hardcoded token IDs
3. For vision models:
   - Generates normalized random image tensors
   - Uses ImageNet normalization by default
4. Outputs JSON compatible with MLOS Core API

## Core API Input Format

MLOS Core expects a flat JSON format:

```json
// NLP model (single input)
{"input_ids": [101, 7592, 102]}

// NLP model (multiple inputs)
{
  "input_ids": [101, 7592, 102],
  "attention_mask": [1, 1, 1],
  "token_type_ids": [0, 0, 0]
}

// Vision model
{"pixel_values": [0.1, 0.2, 0.3, ...]}
```

**Important**: The JSON keys must match the ONNX model's input names exactly.

## Running Tests

### Locally

```bash
# Full E2E test
./scripts/test-release-e2e.sh.bash

# With specific versions
AXON_VERSION=v3.1.1 CORE_VERSION=3.2.1-alpha ./scripts/test-release-e2e.sh.bash
```

### GitHub Actions

```bash
# Trigger manually
gh workflow run e2e-test.yml -f axon_version=v3.1.1 -f core_version=3.2.1-alpha

# View results
gh run list --workflow=e2e-test.yml
```

## Report Generation

The E2E test generates an HTML report published to GitHub Pages:

**Live Report**: https://mlos-foundation.github.io/system-test/

Report includes:
- Overall pass/fail status
- Inference times per model
- Resource usage metrics
- Hardware specifications
- Model installation times

## Troubleshooting

### Common Issues

**1. "Inference execution failed"**
- Check if ONNX model inputs match test input keys
- Use the ONNX inspection command above

**2. "Model not found"**
- Ensure model is installed: `axon list`
- Ensure model is registered: `curl http://localhost:18080/stats`

**3. "HTTP 400 Bad Request"**
- Check JSON format (must be flat, not nested)
- Verify tensor data types (INT64 for NLP, FLOAT for vision)

**4. "Connection refused"**
- Start MLOS Core: `mlos_core -p 18080`
- Check port isn't in use

### Debug Mode

Enable verbose logging:

```bash
DEBUG=1 ./scripts/test-release-e2e.sh.bash
```

## Architecture

```
system-test/
├── config/
│   ├── models.yaml          # Model definitions
│   └── test-inputs.yaml     # Test input configurations
├── scripts/
│   ├── test-release-e2e.sh.bash    # Main test script
│   ├── generate-test-input.py      # Input generator
│   ├── load-config.py              # Config loader
│   └── render.py                   # Report renderer
├── templates/
│   └── report.html          # Report template
├── docs/
│   └── E2E_TESTING_GUIDE.md # This document
└── .github/
    └── workflows/
        └── e2e-test.yml     # CI workflow
```

## Contributing

1. Fork the repository
2. Add your model to the config files
3. Test locally
4. Submit a PR with test results

For questions, open an issue at: https://github.com/mlOS-foundation/system-test/issues

