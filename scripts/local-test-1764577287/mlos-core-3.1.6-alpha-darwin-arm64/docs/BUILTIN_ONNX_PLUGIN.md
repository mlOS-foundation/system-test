# Built-in ONNX Runtime Plugin Design

## Overview

This document describes the design for a built-in ONNX Runtime plugin in MLOS Core that enables inference for all models from all repositories without requiring explicit plugin registration.

## Goals

1. **Universal Model Support**: Enable inference for models from any repository (Hugging Face, PyTorch Hub, TensorFlow Hub, ModelScope) without framework-specific plugins
2. **Zero Plugin Setup**: Models can be executed immediately after registration without manual plugin loading
3. **Automatic Conversion**: Convert models to ONNX format automatically during registration
4. **Performance**: Leverage ONNX Runtime's optimized execution providers (CPU, GPU, TensorRT, OpenVINO)

## Architecture

### Current Architecture
```
Model Registration → Plugin Selection → Plugin Loading (manual) → Inference
```

### New Architecture with Built-in ONNX Runtime
```
Model Registration → Auto-Convert to ONNX → Built-in ONNX Runtime → Inference
```

## Design Components

### 1. Built-in ONNX Runtime Plugin

**Location**: `core/plugins/builtin/onnx_runtime_plugin.c`

**Characteristics**:
- Compiled directly into MLOS Core (not a separate .so file)
- Always available (no `dlopen` required)
- Implements full SMI interface
- Uses ONNX Runtime C API

**Key Functions**:
```c
// Plugin initialization (called during mlos_core_init)
smi_plugin_t* onnx_runtime_plugin_init(void);

// Model registration
smi_status_t onnx_register_model(const smi_model_metadata_t* metadata, 
                                 smi_model_handle_t* handle);

// Model loading (from ONNX file)
smi_status_t onnx_load_model(smi_model_handle_t handle, const char* path);

// Inference execution
smi_status_t onnx_inference(smi_model_handle_t handle,
                           const void* input, size_t input_size,
                           void* output, size_t* output_size);
```

### 2. Model Conversion Pipeline

**Location**: `core/src/model_converter.c`

**Conversion Strategy**:
1. **Check for existing ONNX model**: If model package already contains `.onnx` file, use it directly
2. **Auto-convert during registration**: Convert PyTorch/TensorFlow models to ONNX
3. **Cache converted models**: Store converted ONNX models in Axon cache

**Supported Conversions**:
- PyTorch → ONNX (via `torch.onnx.export`)
- TensorFlow → ONNX (via `tf2onnx`)
- Hugging Face → ONNX (via `transformers.onnx`)

**Implementation Options**:
- **Option A**: Python conversion service (separate process)
- **Option B**: Embedded Python interpreter in MLOS Core
- **Option C**: Pre-conversion in Axon during installation

**Recommended**: Option C - Convert during `axon install` to avoid runtime conversion overhead

### 3. Integration with MLOS Core

**Modified Functions**:

```c
// mlos_core_init() - Auto-register built-in ONNX Runtime plugin
int mlos_core_init(mlos_core_t* core) {
    // ... existing initialization ...
    
    // Register built-in ONNX Runtime plugin
    smi_plugin_t* onnx_plugin = onnx_runtime_plugin_init();
    if (onnx_plugin) {
        core->plugins[0].plugin = onnx_plugin;
        core->plugins[0].loaded = true;
        strncpy(core->plugins[0].plugin_path, "builtin:onnx-runtime", 
                sizeof(core->plugins[0].plugin_path) - 1);
        core->num_plugins = 1;
        printf("✅ Built-in ONNX Runtime plugin registered\n");
    }
    
    return 0;
}
```

**Model Registration Priority**:
1. If model is already in ONNX format → Use built-in ONNX Runtime plugin
2. If model can be converted to ONNX → Convert and use ONNX Runtime
3. If conversion fails → Fall back to framework-specific plugin (if available)

### 4. ONNX Runtime C API Integration

**Dependencies**:
- ONNX Runtime C API library (`onnxruntime`)
- Execution providers:
  - CPU (default)
  - CUDA (if GPU available)
  - TensorRT (if NVIDIA GPU)
  - OpenVINO (if Intel CPU)

**Key ONNX Runtime APIs**:
```c
#include <onnxruntime_c_api.h>

// Create inference session
OrtSession* session;
OrtSessionOptions* session_options;
OrtCreateSession(env, model_path, session_options, &session);

// Run inference
OrtRun(session, run_options, input_names, inputs, num_inputs,
       output_names, outputs, num_outputs);
```

## Implementation Plan

### Phase 1: Basic ONNX Runtime Plugin
- [ ] Create `core/plugins/builtin/onnx_runtime_plugin.c`
- [ ] Implement SMI interface functions
- [ ] Integrate ONNX Runtime C API
- [ ] Add to `mlos_core_init()`
- [ ] Test with pre-converted ONNX models

### Phase 2: Model Conversion
- [ ] Add conversion detection in model registration
- [ ] Implement conversion service/client
- [ ] Add ONNX model caching
- [ ] Test with PyTorch models

### Phase 3: Auto-Selection
- [ ] Update model registration to prefer ONNX Runtime
- [ ] Implement framework detection
- [ ] Add conversion fallback logic
- [ ] Test with all repository types

### Phase 4: Optimization
- [ ] Add execution provider selection
- [ ] Implement GPU acceleration
- [ ] Add batch inference support
- [ ] Performance benchmarking

## Benefits

1. **Universal Coverage**: Works with models from all repositories (Hugging Face, PyTorch Hub, TensorFlow Hub, ModelScope)
2. **Zero Setup**: No manual plugin loading required
3. **Performance**: ONNX Runtime is highly optimized with multiple execution providers
4. **Standardization**: ONNX is the industry standard for model interchange
5. **Future-Proof**: New frameworks can be supported by converting to ONNX

## Challenges and Solutions

### Challenge 1: Model Conversion Overhead
**Solution**: Convert during `axon install` to avoid runtime overhead

### Challenge 2: Conversion Failures
**Solution**: Fall back to framework-specific plugins if conversion fails

### Challenge 3: ONNX Runtime Dependency Size
**Solution**: 
- Use minimal ONNX Runtime build (CPU-only for base)
- Make GPU providers optional
- Consider static linking for distribution

### Challenge 4: Framework-Specific Features
**Solution**: 
- ONNX supports most common operations
- Complex models may need framework-specific plugins
- Document limitations

## Example Usage

```bash
# 1. Install model (conversion happens here)
axon install hf/bert-base-uncased@latest
# → Axon converts to ONNX during installation

# 2. Register model (no plugin needed)
axon register hf/bert-base-uncased@latest
# → MLOS Core uses built-in ONNX Runtime plugin

# 3. Run inference (works immediately)
curl -X POST http://localhost:8080/models/hf/bert-base-uncased@latest/inference \
     -H "Content-Type: application/json" \
     -d '{"input": "Hello, MLOS!"}'
# → Inference executes via built-in ONNX Runtime
```

## Future Enhancements

1. **Dynamic Execution Provider Selection**: Auto-select best provider based on hardware
2. **Model Optimization**: Apply ONNX optimizations (quantization, pruning)
3. **Multi-Model Batching**: Batch inference across multiple models
4. **Model Versioning**: Support multiple ONNX versions
5. **Custom Operators**: Support for custom ONNX operators

## References

- [ONNX Runtime C API Documentation](https://onnxruntime.ai/docs/api/c/)
- [ONNX Model Format Specification](https://github.com/onnx/onnx)
- [ONNX Runtime Execution Providers](https://onnxruntime.ai/docs/execution-providers/)

