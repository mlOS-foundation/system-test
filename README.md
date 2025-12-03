# MLOS System Test & E2E Validation

[![E2E Test](https://github.com/mlOS-foundation/system-test/actions/workflows/e2e-test.yml/badge.svg)](https://github.com/mlOS-foundation/system-test/actions/workflows/e2e-test.yml)
[![Pages Deploy](https://github.com/mlOS-foundation/system-test/actions/workflows/pages.yml/badge.svg)](https://github.com/mlOS-foundation/system-test/actions/workflows/pages.yml)

**📊 [View Latest Report](https://mlos-foundation.github.io/system-test/)** | **🔗 [GitHub Actions](https://github.com/mlOS-foundation/system-test/actions)**

---

End-to-end testing framework for validating MLOS Core and Axon releases across platforms.

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         System Test Pipeline                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐   │
│  │  Test Runner    │───▶│  Metrics Output  │───▶│  HTML Renderer  │   │
│  │  (Bash Script)  │    │  (JSON)          │    │  (Python)       │   │
│  └─────────────────┘    └──────────────────┘    └─────────────────┘   │
│          │                      │                       │              │
│          ▼                      ▼                       ▼              │
│  • Downloads releases    • Hardware specs       • Template engine      │
│  • Installs models       • Timing metrics       • Chart generation     │
│  • Runs inference        • Status results       • Status badges        │
│  • Captures metrics      • Resource usage       • Category rollups     │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Design Principles

1. **Separation of Concerns**: Testing/metrics collection is decoupled from rendering
2. **Data-Driven**: All report content comes from `metrics.json`
3. **Reproducible**: Re-render reports without re-running expensive tests
4. **Platform Parity**: Local runs match GitHub Actions runs exactly

## 📁 Project Structure

```
system-test/
├── .github/
│   └── workflows/
│       ├── e2e-test.yml          # On-demand E2E test workflow
│       └── pages.yml             # Scheduled report generation & deploy
│
├── config/
│   ├── models.yaml               # 📋 Model configuration (add models here!)
│   └── test-inputs.yaml          # 🧪 Test input configuration per model
│
├── scripts/
│   ├── test-release-e2e.sh.bash  # Main test runner
│   ├── generate-test-input.py    # 🆕 Test input generator
│   ├── generate-metrics.py       # Metrics JSON generator
│   ├── load-config.py            # YAML config loader
│   └── metrics/                  # Stored metrics from test runs
│       └── latest.json           # Most recent test metrics
│
├── docs/
│   └── E2E_TESTING_GUIDE.md      # 📖 Detailed testing documentation
│
├── report/
│   ├── render.py                 # Python renderer (all business logic)
│   ├── template.html             # Main report template
│   ├── models-template.html      # Models page template
│   └── styles.css                # CSS styles (shared)
│
├── output/                       # Generated reports
│   ├── index.html                # Main report
│   ├── models.html               # Models configuration page
│   └── styles.css                # Copied styles
│
├── Makefile                      # Build commands
└── README.md                     # This file
```

## 🔄 How Report Generation Works

### Phase 1: Test Execution & Metrics Collection

```bash
# Run full E2E tests (expensive, ~15-30 min)
make test
```

The test runner (`scripts/test-release-e2e.sh`) performs:

1. **Environment Setup**
   - Downloads Axon release binary
   - Downloads MLOS Core release binary
   - Collects hardware specifications

2. **Model Testing** (for each model: GPT-2, BERT, RoBERTa, ResNet, etc.)
   - `axon install hf/<model>@latest` - Install from HuggingFace
   - `axon register` - Register with MLOS Core
   - `curl /inference` - Run inference tests (small & large inputs)

3. **Metrics Output**
   - All timing, status, and resource data → `scripts/metrics/latest.json`

### Phase 2: Report Rendering

```bash
# Render report from existing metrics (fast, <1 sec)
make render
```

The Python renderer (`report/render.py`) performs:

1. **Load Metrics**: Read `scripts/metrics/latest.json`
2. **Calculate Status**: Derive pass/fail from raw results
3. **Generate Charts**: Build Chart.js data arrays
4. **Apply Template**: Replace `{{PLACEHOLDERS}}` in template
5. **Write Output**: Save to `output/index.html`

### Phase 3: Serving & Deployment

```bash
# Local preview
make serve  # Opens http://localhost:8080

# GitHub Pages (automatic via workflow)
# - Publishes to https://mlos-foundation.github.io/system-test/
```

## 📊 Metrics Schema

```json
{
  "timestamp": "2024-11-30T12:00:00Z",
  "test_dir": "/tmp/mlos-e2e-xxx",
  
  "versions": {
    "axon": "v3.0.2",
    "core": "3.1.6-alpha"
  },
  
  "hardware": {
    "os": "Linux",
    "os_version": "Ubuntu 22.04",
    "arch": "x86_64",
    "cpu_model": "Intel Xeon...",
    "cpu_cores": 4,
    "memory_gb": 16
  },
  
  "timings": {
    "axon_download_ms": 1234,
    "core_download_ms": 2345,
    "core_startup_ms": 500,
    "total_model_install_ms": 600000,
    "total_register_ms": 1000,
    "total_inference_ms": 5000,
    "total_duration_s": 900
  },
  
  "models": {
    "gpt2": {
      "category": "nlp",
      "tested": true,
      "install_time_ms": 120000,
      "register_time_ms": 500,
      "inference_status": "success",
      "inference_time_ms": 1500,
      "inference_large_tested": true,
      "inference_large_status": "success",
      "inference_large_time_ms": 3000
    }
  },
  
  "resources": {
    "core_idle_cpu": 0.5,
    "core_idle_mem_mb": 50,
    "core_load_cpu_avg": 45,
    "core_load_mem_avg_mb": 500
  }
}
```

## 🚀 Quick Start

### Prerequisites

- Python 3.8+
- Bash
- curl, jq
- Docker (for model conversion)

### Run Full E2E Test

```bash
# Clone and enter directory
cd system-test

# Run full test suite
make test

# View report
make serve
```

### Re-render Existing Report

```bash
# If you already have metrics from a previous run
make render

# Preview
make serve
```

### GitHub Actions

**Manual Trigger:**
1. Go to Actions → "E2E Test & Report"
2. Click "Run workflow"
3. Select Core version (default: `3.1.6-alpha`)
4. Wait ~15-30 min
5. View at https://mlos-foundation.github.io/system-test/

**Scheduled:**
- Runs weekly (Sunday midnight UTC)
- Auto-publishes to GitHub Pages

## 🧪 Tested Models

> 📋 Models are configured in `config/models.yaml`. View full details at **[models.html](https://mlos-foundation.github.io/system-test/models.html)**.

### Current Tested Versions
- **Axon**: v3.1.1 (Vision model support, Docker base image fix)
- **Core**: v3.2.3-alpha (Linux tensor name fix, large input handling)

| Category | Model | Status | Notes |
|----------|-------|--------|-------|
| **NLP** | GPT-2 | ✅ Enabled | DistilGPT-2 - text generation |
| | BERT | ✅ Enabled | BERT base - masked language model |
| | RoBERTa | ✅ Enabled | RoBERTa base - robust BERT variant |
| | T5 | ⏳ Disabled | Encoder-decoder needs special handling |
| **Vision** | ResNet-50 | ✅ Enabled | Image classification (1000 classes) |
| | ViT | ✅ Enabled | Vision Transformer - patch-based |
| | ConvNeXt | ✅ Enabled | Modern CNN architecture |
| | MobileNetV2 | ✅ Enabled | Efficient mobile architecture |
| | DeiT | ✅ Enabled | Data-efficient Image Transformer |
| | Swin | ⏳ Disabled | PyTorch-to-ONNX export issues |
| | EfficientNet | ⏳ Disabled | Not yet tested |
| **Multi-Modal** | CLIP | ⏳ Disabled | Pending - requires text+image input |

### Vision Model Support (New in v3.1.0)

Vision models are now fully supported via:
- **Axon v3.1.0**: Automatic task detection from model config (50+ architectures)
- **Core v3.2.3-alpha**: Linux tensor name fix, large input handling (16MB), shape inference

Standard ImageNet input (224×224×3 RGB) works out of the box.

## 📖 Documentation

For detailed information about the E2E testing system:

- **[E2E Testing Guide](docs/E2E_TESTING_GUIDE.md)** - Comprehensive guide on how the system works
- **[Test Input Configuration](config/test-inputs.yaml)** - Per-model input specifications
- **[Model Configuration](config/models.yaml)** - Model definitions and settings

### Quick Reference: Test Input Generation

```bash
# Generate test input for any model
python3 scripts/generate-test-input.py bert small
python3 scripts/generate-test-input.py resnet
python3 scripts/generate-test-input.py gpt2 large --pretty
```

Each model's required inputs are defined in `config/test-inputs.yaml`:

```yaml
models:
  bert:
    required_inputs: ["input_ids", "attention_mask", "token_type_ids"]
  gpt2:
    required_inputs: ["input_ids"]  # Single input only
  resnet:
    input_name: "pixel_values"
```

## 🛠️ Development

### Adding New Models

Models are configured in `config/models.yaml`. Just add your model and run tests!

1. **Edit `config/models.yaml`:**
   ```yaml
   models:
     my_new_model:
       enabled: true
       category: nlp           # nlp, vision, or multimodal
       axon_id: "hf/my-org/my-model@latest"
       description: "My awesome model"
       input_type: text        # text, image, or multimodal
       small_input:
         tokens: 7
       large_input:
         tokens: 128
   ```

2. **Verify config:**
   ```bash
   make config       # Show summary
   make config-list  # List enabled models
   ```

3. **Run tests:**
   ```bash
   make test         # Will automatically include new model
   ```

4. **View reports:**
   - Main report links to models page
   - Models page shows all configured models with specs

### Modifying Report Style

Edit `report/styles.css` - changes take effect on next `make render`.

### Debugging Render Issues

```bash
# Check metrics are valid JSON
python3 -c "import json; json.load(open('scripts/metrics/latest.json'))"

# Run renderer with verbose output
python3 report/render.py --metrics scripts/metrics/latest.json

# Check for missing placeholders
grep -o '{{[A-Z_]*}}' output/index.html
```

## 📋 Makefile Commands

| Command | Description |
|---------|-------------|
| **Testing** | |
| `make test` | Run full E2E tests and generate metrics |
| `make test-quick` | Quick test (GPT-2 only) |
| **Rendering** | |
| `make render` | Render HTML from existing metrics |
| `make render-example` | Render using example/mock data |
| `make serve` | Start local HTTP server on :8080 |
| **Configuration** | |
| `make config` | Show model configuration summary |
| `make config-list` | List enabled model names |
| `make config-all` | Show full config as JSON |
| `make config-edit` | Open models.yaml in editor |
| **Maintenance** | |
| `make clean` | Remove generated files |
| `make lint` | Lint Python and bash scripts |

## 🔗 Related Repositories

- [mlos-foundation/core](https://github.com/mlos-foundation/core) - MLOS Core inference engine
- [mlos-foundation/axon](https://github.com/mlos-foundation/axon) - Model package manager

## 📄 License

Apache 2.0 - See [LICENSE](LICENSE)

---

**MLOS Foundation** - Signal. Propagate. Myelinate. 🧠
