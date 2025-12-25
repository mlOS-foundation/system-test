# MLOS E2E Validation System

## Overview

The MLOS Foundation has built a comprehensive end-to-end (E2E) validation system that automatically tests every release of Axon (the model packaging CLI) and MLOS Core (the inference runtime). This system provides transparent, reproducible validation of ML inference across multiple model architectures.

**Live Report:** https://mlos-foundation.github.io/system-test/

## What We've Achieved

### 1. Automated Release Validation

Every release of Axon and MLOS Core is automatically validated against 18+ production ML models spanning:

| Category | Models | Use Cases |
|----------|--------|-----------|
| **NLP** | BERT, GPT-2, RoBERTa, T5, DistilBERT, ALBERT | Text classification, embeddings, Q&A |
| **Vision** | ResNet-50, ViT, ConvNeXt, MobileNet, DeiT, EfficientNet | Image classification, feature extraction |
| **Multi-Modal** | CLIP, Wav2Vec2 | Image-text matching, audio processing |
| **LLMs** | TinyLlama, Llama-3.2-1B, Qwen2-0.5B, DeepSeek-Coder-1.3B | Text generation, code completion |

### 2. Kernel vs Userspace Performance Comparison

A unique feature of MLOS is the **kernel module** (`mlos-ml.ko`) that provides:

- **Zero-copy tensor transfers** - Direct memory access without CPU copies
- **ML-aware scheduling** - Priority-based inference queue management
- **Kernel-level memory management** - LRU eviction and memory pool optimization
- **Secure isolation** - Kernel-level inference isolation

The E2E system runs identical tests in both kernel mode (with module loaded) and userspace mode, providing direct performance comparisons.

### 3. Format-Agnostic Runtime Validation

MLOS Core supports multiple model formats without user intervention:

- **ONNX** - Standard ML interchange format (vision, NLP models)
- **GGUF** - Quantized format for LLMs (TinyLlama, Llama, etc.)
- **SafeTensors** - HuggingFace native format (auto-converted)

The E2E tests validate that format detection and loading work correctly across all supported formats.

---

## Understanding the Report

### Summary Cards

The top-level cards provide at-a-glance metrics:

| Metric | Description |
|--------|-------------|
| **Overall Success Rate** | Percentage of models that passed all test phases |
| **Total Duration** | End-to-end test execution time |
| **Inferences** | Total number of inference requests executed |
| **Models Tested** | Count of unique models validated |

### Release Versions

Shows the exact versions being tested:

- **Axon Version** - The CLI tool version (e.g., v3.1.9)
- **MLOS Core Version** - The runtime version (e.g., 5.0.1-alpha)
- **Runtime Mode** - Kernel module status (Userspace or Kernel + mode)

### Hardware Specifications

Documents the test environment for reproducibility:

- **Operating System** - OS and version
- **CPU** - Model, cores, and threads
- **Memory** - Total RAM available
- **GPU** - GPU details (if available)
- **Disk** - Storage capacity and availability

### Resource Usage

Monitors runtime resource consumption:

| Metric | Idle | Under Load |
|--------|------|------------|
| **CPU** | Baseline usage | Peak during inference |
| **Memory** | Base footprint | Max memory with models loaded |

This helps identify resource requirements for deployment planning.

### Installation & Setup Times

Breaks down the setup overhead:

| Phase | Description |
|-------|-------------|
| **Axon Download** | Time to download Axon CLI |
| **Core Download** | Time to download MLOS Core runtime |
| **Core Startup** | Time for Core to initialize and be ready |
| **Model Install** | Time to download, convert, and register models |

Model installation dominates total time (~99%) as it includes:
1. Downloading from HuggingFace
2. ONNX conversion via Docker (for non-ONNX models)
3. Registration with MLOS Core

### Inference Performance

The bar chart and metrics show per-model inference latency:

- **Inference Time (ms)** - Time for a single inference request
- Measured using standardized test inputs per model category
- Includes both "small" (quick validation) and "large" (realistic workload) tests

### Model Support by Category

Visual status of each model organized by type:

| Status | Meaning |
|--------|---------|
| **PASS** (green) | Model installed, registered, and inference succeeded |
| **FAIL** (red) | One or more phases failed |

Each category card shows:
- Individual model status
- Category-level summary

### Kernel Module Performance Section

When kernel comparison data is available, this section shows:

#### Performance Comparison Table

| Column | Description |
|--------|-------------|
| **Model** | Model name |
| **Kernel Mode** | Inference time with kernel module |
| **Userspace** | Inference time without kernel module |
| **Delta** | Absolute difference (positive = kernel faster) |
| **Speedup** | Ratio (>1.0 = kernel faster) |

#### Interpreting Speedup

- **1.0x** - No difference between kernel and userspace
- **>1.0x** - Kernel mode is faster (e.g., 1.32x = 32% faster)
- **<1.0x** - Userspace is faster (rare, usually within margin of error)

Typical results show 2-5% average speedup, with some models showing 20-30% improvement depending on:
- Model architecture (memory-bound vs compute-bound)
- Input size
- Hardware configuration

---

## Test Phases

Each model goes through these phases:

### Phase 1: Install
```
axon install hf/<org>/<model>@latest
```
- Downloads model from HuggingFace
- Converts to ONNX if needed (via Docker converter)
- Creates `.axon` package

### Phase 2: Register
```
POST /v1/models/register
{
  "model_id": "<model>",
  "path": "<axon_package_path>"
}
```
- Registers model with MLOS Core
- Loads model into memory
- Validates model format

### Phase 3: Inference (Small)
Quick validation with minimal input:
- NLP: Short text sequence
- Vision: Single image
- LLM: Short prompt

### Phase 4: Inference (Large)
Realistic workload test:
- NLP: Longer text sequences
- Vision: Batch of images
- LLM: Multi-turn conversation

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    GitHub Actions Workflows                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────┐      ┌──────────────────────────────────┐ │
│  │  e2e-parallel.yml │      │      e2e-kernel.yml              │ │
│  │  (GitHub Runner)  │      │   (Self-Hosted Runner)           │ │
│  │                   │      │                                   │ │
│  │  - Userspace mode │      │  - Kernel module loaded          │ │
│  │  - All 18 models  │      │  - Same 18 models                │ │
│  │  - Deploys report │      │  - Uploads comparison data       │ │
│  └────────┬──────────┘      └────────────────┬─────────────────┘ │
│           │                                   │                   │
│           │    ┌──────────────────────┐      │                   │
│           └───►│   GitHub Pages       │◄─────┘                   │
│                │   (Report Host)      │                          │
│                └──────────────────────┘                          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Workflow Coordination

1. **e2e-kernel.yml** runs on self-hosted runner with kernel module
   - Tests all models in kernel mode
   - Optionally tests in userspace mode for comparison
   - Uploads `kernel-comparison.json` as artifact

2. **e2e-parallel.yml** runs on GitHub-hosted runner
   - Tests all models in userspace mode
   - Fetches kernel comparison data from latest kernel run
   - Generates HTML report with both datasets
   - Deploys to GitHub Pages

---

## Key Metrics Explained

### Inference Latency

Measured as wall-clock time from request to response:

```
latency = time(response_received) - time(request_sent)
```

Includes:
- Input preprocessing (tokenization, image resize)
- Model forward pass
- Output postprocessing

Does NOT include:
- Model loading (measured separately)
- Network latency (localhost)

### Speedup Calculation

```
speedup = userspace_latency / kernel_latency
```

Example:
- Userspace: 529ms
- Kernel: 442ms
- Speedup: 529/442 = 1.20x (20% faster)

### Success Criteria

A model "passes" if:
1. Installation completes without error
2. Registration succeeds (model loaded)
3. Small inference returns valid output
4. Large inference returns valid output

---

## Interpreting Results

### Healthy Report Indicators

- **90%+ success rate** - Most models working
- **Consistent inference times** - Low variance between runs
- **Kernel speedup 1.0-1.1x** - Expected range for CPU-only
- **No timeout failures** - All phases complete in time

### Warning Signs

- **Vision model failures** - Often converter image issues
- **LLM timeouts** - May need longer timeout or more memory
- **0ms inference times** - Data extraction bug, not real result
- **Negative speedup** - Check for interference or measurement error

### Common Failure Causes

| Symptom | Likely Cause |
|---------|--------------|
| Install fails | Missing converter image, network issues |
| Register fails | Incompatible model format, missing ONNX |
| Inference fails | OOM, unsupported operators, timeout |
| 0.0ms times | Result JSON parsing issue |

---

## Running Locally

### Prerequisites

```bash
# Install Axon CLI
curl -L https://github.com/mlOS-foundation/axon/releases/latest/download/axon_linux_amd64.tar.gz | tar xz
sudo mv axon /usr/local/bin/

# Download MLOS Core
curl -L https://github.com/mlOS-foundation/core-releases/releases/latest/download/mlos-core_linux-amd64.tar.gz | tar xz

# Pull converter image
docker pull ghcr.io/mlos-foundation/axon-converter:latest
```

### Run Single Model Test

```bash
cd system-test
./scripts/test-single-model.sh bert
```

### Run Full E2E Suite

```bash
make e2e-test
```

### Generate Report

```bash
python3 report/render.py \
  --metrics metrics/latest.json \
  --template report/template.html \
  --output output/index.html
```

---

## Contributing

### Adding New Models

1. Edit `config/models.yaml`:
```yaml
models:
  - id: new-model
    axon_id: hf/org/model-name@latest
    category: nlp
    enabled: true
```

2. Add test inputs in `config/test-inputs.yaml`

3. Run local test to validate

### Reporting Issues

File issues at: https://github.com/mlOS-foundation/system-test/issues

Include:
- Model that failed
- Error message from logs
- Hardware/OS details
- Axon and Core versions

---

## Summary

The MLOS E2E Validation System provides:

1. **Transparency** - Public reports for every release
2. **Reproducibility** - Documented environments and versions
3. **Comprehensive Coverage** - 18+ models across 4 categories
4. **Performance Insights** - Kernel vs userspace comparisons
5. **Quality Assurance** - Automated validation before release

This ensures users can confidently deploy MLOS knowing it has been validated against real-world ML workloads.

---

**MLOS Foundation** - Signal. Propagate. Myelinate.
