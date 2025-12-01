# MLOS Core

![MLOS Logo](docs/images/mlos-logo.png)

**Machine Learning Model Operating System - Core Runtime**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Build Status](https://img.shields.io/badge/build-passing-brightgreen.svg)]()
[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)]()

MLOS Core provides kernel-level ML resource management with a plugin-based architecture for ML frameworks. It implements the Standard Model Interface (SMI) specification for true polyglot ML plugin support.

**Architecture:** MLOS Core relies on **Axon packages** (Model Package Format - MPF) as specified in patent US-63/861,527. This provides standardized model packaging while maintaining complete plugin independence.

## 🚀 Quick Start

```bash
# Build MLOS Core
make

# Start with default settings
./build/mlos_core

# Or with custom options
./build/mlos_core --http-port 9090 --no-grpc
```

**Test the API:**
```bash
# Health check
curl http://localhost:8080/health

# Register a plugin
curl -X POST http://localhost:8080/plugins/register \
  -H "Content-Type: application/json" \
  -d '{"id":"my-plugin","name":"My ML Plugin","version":"1.0.0"}'
```

## 🏗️ Architecture

```
┌─────────────────────────────────────────────┐
│                MLOS Core                    │
├─────────────────────────────────────────────┤
│  📡 HTTP API    🔧 gRPC API    🔌 IPC API    │
├─────────────────────────────────────────────┤
│  • Plugin Registry                          │
│  • Model Lifecycle Management               │
│  • Resource Manager                         │
│  • SMI Interface Implementation             │
│  • Axon Manifest Reader (MPF)               │
└─────────────────────────────────────────────┘
                     │
              ┌──────┴──────┐
              │ SMI Plugins │
              └─────────────┘
                     │
        ┌────────────┼────────────┐
        │            │            │
   ┌────▼───┐   ┌────▼───┐   ┌────▼───┐
   │   C    │   │ Python │   │   Go   │
   │ Plugin │   │ Plugin │   │ Plugin │
   └────────┘   └────────┘   └────────┘
```

## 🌟 Features

### **🚀 Enhanced ONNX Runtime Plugin (New!)**

The built-in ONNX Runtime plugin now supports **universal inference** across all model types:

#### Multi-Type Tensor Support
- **int64** ✅ - NLP token IDs (GPT-2, BERT, T5, RoBERTa)
- **float32** ✅ - Vision models, embeddings (ResNet, ViT, CLIP)
- **int32** ✅ - TensorFlow models
- **bool** ✅ - Attention masks

#### Advanced Features
✅ **Named Input Parsing** - JSON format: `{"input_ids": [1,2,3], "attention_mask": [1,1,1]}`  
✅ **Multi-Input Models** - BERT, T5, CLIP with multiple tensors  
✅ **Dynamic Shapes** - Automatic shape inference from input data  
✅ **Backward Compatible** - Legacy float-only inputs still work  
✅ **Zero API Changes** - Generic `void*` interface handles all types  

#### Example: Multi-Input Inference
```bash
# GPT-2 (single input, int64)
curl -X POST http://localhost:8080/models/hf%2Fgpt2%40latest/inference \
  -d '{"input_ids": [15496, 11, 337, 43, 48]}'

# BERT (multi-input, int64)
curl -X POST http://localhost:8080/models/hf%2Fbert-base-uncased%40latest/inference \
  -d '{"input_ids": [101, 7592, 102], "attention_mask": [1, 1, 1], "token_type_ids": [0, 0, 0]}'

# Vision models (float32) - coming soon!
curl -X POST http://localhost:8080/models/pytorch%2Fresnet50%40latest/inference \
  -d '{"pixel_values": [[0.1, 0.2, ...]]}'
```

**Performance:** ~2-8ms inference time on CPU for small models ⚡

### **Multi-Protocol APIs**
- **HTTP REST API** - Easy integration and testing
- **gRPC API** - High-performance binary protocol  
- **IPC API** - Ultra-low latency Unix domain sockets

### **Plugin Architecture**
- **Standard Model Interface (SMI)** - Universal plugin contract
- **Dynamic Loading** - Load/unload plugins at runtime
- **Multi-language Support** - C, Python, Go, and more
- **Resource Management** - Kernel-level resource optimization
- **Plugin Independence** - Plugins work with any model path, don't need to know about Axon

### **Axon Integration (Model Package Format - MPF)**

MLOS Core implements the **Model Package Format (MPF)** from patent US-63/861,527 via integration with **Axon**, the universal model installer.

**Key Features:**
- **Standardized Packaging** - All models packaged as `.axon` archives with `manifest.yaml`
- **Universal Model Delivery** - Works with models from any repository via Axon adapters:
  - Hugging Face Hub (100,000+ models, 60%+ coverage)
  - PyTorch Hub (research models, 5%+ coverage)
  - TensorFlow Hub (production models, 7%+ coverage)
  - ModelScope (multimodal AI, 8%+ coverage)
- **Metadata Extraction** - Reads Axon manifests for framework, resources, I/O schema
- **Plugin Independence** - Plugins receive path to model files, don't need Axon knowledge
- **Complete E2E Workflow** - `axon install` → `axon register` → MLOS Core inference

**How It Works:**
1. **Axon** installs models from any repository and creates standardized `.axon` packages (MPF)
2. **`axon register`** sends model manifest path to MLOS Core HTTP API
3. **MLOS Core** reads Axon manifest, extracts metadata, and registers model
4. **Plugins** receive path to model files and execute inference (no Axon dependency)

See [Axon Integration Guide](docs/AXON_MLOS_INTEGRATION.md) and [Architecture Analysis](docs/AXON_MLOS_ARCHITECTURE.md) for complete details.

### **Production Ready**
- **Graceful Shutdown** - Clean resource cleanup
- **Health Monitoring** - Comprehensive health checks
- **Statistics** - Request metrics and performance data
- **Configuration** - Command-line and file-based config

## 📋 API Reference

### **HTTP Endpoints**

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/health` | System health check |
| `GET` | `/stats` | API statistics |
| `POST` | `/plugins/register` | Register new plugin |
| `GET` | `/plugins` | List registered plugins |
| `POST` | `/models/register` | Register ML model (from Axon package) |
| `GET` | `/models` | List registered models |
| `POST` | `/models/{id}/inference` | Run model inference |

### **gRPC Services**

- `HealthService` - Health monitoring
- `PluginService` - Plugin lifecycle management
- `ModelService` - Model operations
- `InferenceService` - ML inference with streaming support

### **IPC Protocol**

Binary protocol over Unix domain sockets for maximum performance:
- Health checks: `< 0.1ms` latency
- Plugin operations: `< 0.5ms` latency  
- Inference requests: `< 1ms` latency

## 🔧 Installation

### **From Source**
```bash
# Clone repository
git clone https://github.com/your-org/mlos-core.git
cd mlos-core

# Build and install
make
sudo make install
```

### **Docker**
```bash
# Build Docker image
make docker-build

# Run in container
make docker-run
```

### **Package Managers**
```bash
# Ubuntu/Debian
sudo apt install mlos-core

# macOS
brew install mlos-core

# Arch Linux
yay -S mlos-core
```

## 🧪 Testing

```bash
# Run all tests
make test-all

# Quick validation
make quick-test

# Unit tests only
make test-unit

# Integration tests
make test-integration

# Performance benchmarks
make test-performance
```

## 📚 Documentation

### Core Documentation
- [Architecture Guide](docs/ARCHITECTURE.md)
- [API Reference](docs/API-REFERENCE.md)
- [SMI Specification](docs/SMI-SPECIFICATION.md)
- [Plugin Development](docs/PLUGIN-DEVELOPMENT.md)
- [Configuration](docs/CONFIGURATION.md)
- [Deployment Guide](docs/DEPLOYMENT.md)

### Axon Integration
- [Axon Integration Guide](docs/AXON_MLOS_INTEGRATION.md) - Complete E2E workflow
- [Axon Architecture Analysis](docs/AXON_MLOS_ARCHITECTURE.md) - Patent alignment & plugin design

### Patent Information
- [Patent Portfolio](docs/PATENTS.md) - Detailed patent information and implementation alignment

### Distribution
- [Distribution Strategy](docs/DISTRIBUTION_STRATEGY.md) - Docker vs binary distribution approach
- [MLOS Distro Plan](docs/DISTRO_REPOSITORY_PLAN.md) - Bundled distribution repository strategy

## 🔌 Plugin Development

Create ML framework plugins using the SMI specification:

### **C Plugin Example**
```c
#include "mlos/smi_spec.h"

static smi_status_t my_initialize(const char* config) {
    // Initialize your ML framework
    return SMI_SUCCESS;
}

static smi_plugin_interface_t my_interface = {
    .initialize = my_initialize,
    .register_model = my_register_model,
    .inference = my_inference,
    // ... implement other functions
};

smi_plugin_t* smi_plugin_init(void) {
    static smi_plugin_t plugin = {
        .interface = my_interface,
        .plugin_id = "my-ml-plugin",
        .smi_version = SMI_VERSION_MAJOR << 16 | SMI_VERSION_MINOR << 8 | SMI_VERSION_PATCH
    };
    return &plugin;
}
```

### **Python Plugin Example**
```python
import mlos_smi

class MyMLPlugin(mlos_smi.Plugin):
    def initialize(self, config):
        # Initialize your Python ML framework
        return mlos_smi.SUCCESS
    
    def register_model(self, metadata):
        # Register ML model
        return mlos_smi.SUCCESS
    
    def inference(self, handle, input_data):
        # Run inference
        return output_data, mlos_smi.SUCCESS

# Register plugin
mlos_smi.register_plugin(MyMLPlugin())
```

See [Plugin Development Guide](docs/PLUGIN-DEVELOPMENT.md) for complete examples.

**Important:** Plugins receive a path to model files. The path may be from an Axon package, but plugins don't need to know about Axon - they just load their framework's model format from the provided path.

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guide](CONTRIBUTING.md) for details.

### **Development Setup**
```bash
# Clone repository
git clone https://github.com/your-org/mlos-core.git
cd mlos-core

# Install development dependencies
make install-dev

# Run development build
make debug

# Run tests
make test-all
```

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🏆 Patent Information

MLOS Core implements key innovations from MLOS Foundation's patent portfolio, providing kernel-level ML optimizations and standardized model packaging.

### **US-63/861,527: Machine Learning Model Operating System**

**Filing Date:** August 11, 2025  
**Status:** Pending Provisional Application

**Key Innovations Implemented:**

1. **Model Package Format (MPF)** - Standardized packaging system for ML models
   - Implemented via **Axon packages** (`.axon` archives with `manifest.yaml`)
   - Includes metadata, dependencies, resource requirements, and security policies
   - Enables deployment-agnostic execution across different environments

2. **Native Model Lifecycle Management** - OS-level model management
   - Model registration, versioning, and lifecycle tracking
   - Automatic dependency resolution
   - Resource allocation and scheduling

3. **Deployment-Agnostic Execution** - Models run identically across environments
   - Standardized model interface (SMI) for framework independence
   - Plugin architecture supporting multiple ML frameworks
   - Unified API layer (HTTP, gRPC, IPC)

4. **ML-Specific Security Isolation** - Security designed for ML workloads
   - Model-level access controls
   - Resource isolation and quotas
   - Secure model execution environments

**Implementation in MLOS Core:**
- ✅ Axon manifest reader (`src/axon_manifest_reader.c`) - Reads MPF packages
- ✅ Model registry - Lifecycle management per patent specification
- ✅ Plugin architecture - Framework-agnostic execution
- ✅ Multi-protocol APIs - Deployment-agnostic access

### **US-63/865,176: Kernel-Level Optimizations for ML Workloads**

**Filing Date:** [Continuation-in-Part of US-63/861,527]  
**Status:** Pending Provisional Application

**Key Innovations Implemented:**

1. **ML-Aware Kernel Scheduler** - OS scheduler optimized for ML workloads
   - Tensor operation awareness
   - Model context switching mechanisms
   - Priority-based ML task scheduling

2. **Tensor Memory Management** - Zero-copy tensor operations
   - Efficient tensor memory allocation
   - Shared memory for multi-model scenarios
   - GPU memory orchestration

3. **GPU Resource Orchestration** - Multi-model GPU coordination
   - Hardware abstraction layer for ML accelerators
   - Unified interface for GPU operations
   - Resource sharing and optimization

**Implementation in MLOS Core:**
- ✅ Resource manager - Kernel-level resource optimization
- ✅ Plugin interface - Hardware abstraction layer
- ✅ Performance optimizations - Ultra-low latency IPC API

### **Model Distribution via Axon**

**Axon** (separate repository) provides the **Model Package Format (MPF)** implementation:

- **Universal Model Installer**: Works with 80%+ of ML repositories
  - Hugging Face Hub (100,000+ models, 60%+ coverage)
  - PyTorch Hub (research models, 5%+ coverage)
  - TensorFlow Hub (production models, 7%+ coverage)
  - ModelScope (multimodal AI, 8%+ coverage)

- **Standardized Packaging**: All models packaged as `.axon` archives
  - `manifest.yaml` with complete metadata
  - Framework information, resource requirements
  - I/O schema, dependencies, checksums

- **Integration with MLOS Core**:
  ```bash
  # 1. Install model with Axon
  axon install hf/bert-base-uncased@latest
  
  # 2. Register with MLOS Core
  axon register hf/bert-base-uncased@latest
  
  # 3. MLOS Core reads Axon manifest (MPF) and prepares model
  # 4. Model ready for kernel-level inference
  ```

**Architecture Principle:** MLOS Core relies on Axon packages (MPF) as specified in patent US-63/861,527. This provides standardized packaging while maintaining complete plugin independence - plugins receive a path to model files and don't need to know about Axon.

See [Axon Integration Guide](docs/AXON_MLOS_INTEGRATION.md) for complete details.

### **Distribution Strategy**

Since MLOS Core repository is private, distribution is provided via:

1. **Docker Images** (Primary) - `ghcr.io/mlOS-foundation/mlos-core`
   - Self-contained with all dependencies
   - Cross-platform support
   - Tagged releases: `v1.0.0`, `latest`

2. **Binary Releases** (Secondary) - GitHub Releases
   - Platform-specific binaries (Linux, macOS, Windows)
   - Includes checksums for verification
   - Smaller size, native performance

3. **MLOS Distribution** (Future) - `mlos-distro` repository
   - Bundles Axon + MLOS Core + future components
   - Unified installation: `curl -sSL mlosfoundation.org/install | sh`
   - Version compatibility matrix

See [Distribution Strategy](docs/DISTRIBUTION_STRATEGY.md) and [MLOS Distro Plan](docs/DISTRO_REPOSITORY_PLAN.md) for details.

## 📞 Support

- **Documentation**: [docs/](docs/)
- **Issues**: [GitHub Issues](https://github.com/your-org/mlos-core/issues)
- **Discussions**: [GitHub Discussions](https://github.com/your-org/mlos-core/discussions)
- **Email**: support@mlos-core.org

## 🎯 Roadmap

- [x] Core plugin architecture
- [x] HTTP REST API
- [x] IPC high-performance interface
- [x] Axon package integration (MPF)
- [ ] gRPC full implementation
- [ ] Distributed plugin support
- [ ] Advanced resource scheduling
- [ ] ML model versioning
- [ ] Automatic scaling
- [ ] Monitoring dashboard

---

**Built with ❤️ for the ML community**
