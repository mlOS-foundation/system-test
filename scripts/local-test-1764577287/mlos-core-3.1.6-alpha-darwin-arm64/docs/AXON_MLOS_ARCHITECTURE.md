# Axon-MLOS Architecture: Patent Alignment & Plugin Design

## Executive Summary

**Yes, this architecture perfectly aligns with the patent and does NOT hamper the plugin architecture.** Here's why:

### Patent Alignment ✅

The patent (US-63/861,527) specifically calls out **"Model Package Format (MPF)"** as a key innovation:
> "4. **Model Package Format (MPF)**: Standardized packaging system for ML models including metadata, dependencies, resource requirements, and security policies."

**Axon packages ARE the MPF implementation.** MLOS Core relying on Axon packages is the intended architecture.

### Plugin Architecture ✅

**Plugins remain completely framework-agnostic and unchanged:**
- Plugins receive a **path** to model files (from Axon package location)
- Plugins don't need to know about Axon - they just load their framework's model format
- SMI interface is unchanged - plugins still get metadata and path
- MLOS Core handles Axon manifest reading, not plugins

## Architecture Layers

```
┌─────────────────────────────────────────────────────────────┐
│                    Delivery Layer (Axon)                     │
│  • Universal model installer                                 │
│  • Creates standardized .axon packages (MPF)                │
│  • Handles all repository adapters                           │
│  • Provides manifest.yaml with metadata                      │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           │ Axon Package (MPF)
                           │ • manifest.yaml (metadata)
                           │ • model files (framework-specific)
                           │
┌──────────────────────────▼──────────────────────────────────┐
│              Execution Layer (MLOS Core)                     │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Axon Manifest Reader                                │  │
│  │  • Reads manifest.yaml                               │  │
│  │  • Extracts metadata (framework, requirements)      │  │
│  │  • Converts to SMI metadata format                   │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Model Registry                                      │  │
│  │  • Stores model metadata from Axon manifest         │  │
│  │  • Maps model_id → plugin_id → model_path          │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Plugin Registry                                     │  │
│  │  • Manages framework plugins                         │  │
│  │  • Routes models to appropriate plugins             │  │
│  └──────────────────────────────────────────────────────┘  │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           │ SMI Interface (unchanged)
                           │ • metadata (from Axon manifest)
                           │ • path (to Axon package location)
                           │
┌──────────────────────────▼──────────────────────────────────┐
│              Framework Layer (Plugins)                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │ PyTorch      │  │ TensorFlow   │  │ ONNX         │     │
│  │ Plugin       │  │ Plugin       │  │ Plugin       │     │
│  └──────────────┘  └──────────────┘  └──────────────┘     │
│                                                             │
│  Plugins:                                                   │
│  • Receive path to model files (from Axon package)         │
│  • Load framework-specific model format                    │
│  • Don't need to know about Axon                           │
│  • SMI interface unchanged                                 │
└─────────────────────────────────────────────────────────────┘
```

## Key Design Principles

### 1. Separation of Concerns

**Axon (Delivery Layer):**
- Handles all repository interactions
- Creates standardized packages
- Provides metadata in manifest.yaml
- **Does NOT execute models**

**MLOS Core (Execution Layer):**
- Reads Axon manifests for metadata
- Manages model lifecycle
- Routes to appropriate plugins
- **Does NOT access repositories directly**

**Plugins (Framework Layer):**
- Load framework-specific model formats
- Execute inference
- **Do NOT need to know about Axon**

### 2. Plugin Independence

Plugins remain completely independent:

```c
// Plugin's load_model() function - UNCHANGED
smi_status_t load_model(smi_model_handle_t handle, const char* path) {
    // Plugin receives path to model files
    // Path happens to be in Axon package location
    // Plugin doesn't care - just loads its framework's format
    
    // Example: PyTorch plugin
    model = torch.load(path);  // Works with any path
    
    // Example: TensorFlow plugin  
    model = tf.saved_model.load(path);  // Works with any path
    
    return SMI_SUCCESS;
}
```

**Key Point:** Plugins receive a **path**, not an Axon package. The path just happens to point to files within an Axon package directory.

### 3. Metadata Flow

```
Axon Package
├── manifest.yaml (Axon format)
│   ├── metadata.name
│   ├── metadata.framework
│   ├── spec.requirements
│   └── spec.io
│
MLOS Core reads manifest.yaml
│
Converts to SMI metadata
│
Passes to Plugin via SMI interface
│
Plugin uses metadata for:
├── Resource allocation
├── Input/output validation
└── Model loading
```

## Patent Alignment Details

### US-63/861,527: MLOS System

**Claimed Innovation #4: Model Package Format (MPF)**
> "Standardized packaging system for ML models including metadata, dependencies, resource requirements, and security policies."

**Implementation:**
- ✅ Axon creates `.axon` packages (MPF)
- ✅ Packages include `manifest.yaml` with all required metadata
- ✅ MLOS Core reads MPF to extract metadata
- ✅ This is the intended architecture per patent

**Claimed Innovation #1: Model Abstraction Layer**
> "Native OS-level abstraction that treats ML models as managed resources"

**Implementation:**
- ✅ MLOS Core provides OS-level model registry
- ✅ Models managed via Axon packages (standardized format)
- ✅ Lifecycle management through MLOS Core

### US-63/865,176: Kernel-Level Optimizations

**Key Innovation: Kernel-Level Execution**
> "ML-aware scheduler, tensor memory management, GPU orchestration"

**Implementation:**
- ✅ MLOS Core provides kernel-level optimizations
- ✅ Works with models from Axon packages
- ✅ Plugins execute with kernel-level support
- ✅ No dependency on model source - works with any Axon package

## Plugin Architecture: Unchanged

### SMI Interface (No Changes)

```c
// SMI interface remains exactly the same
typedef struct {
    smi_status_t (*load_model)(smi_model_handle_t handle, const char* path);
    smi_status_t (*inference)(smi_model_handle_t handle, ...);
    // ... all other functions unchanged
} smi_plugin_interface_t;
```

### Plugin Implementation (No Changes)

Plugins continue to work exactly as before:

```c
// PyTorch Plugin Example
smi_status_t pytorch_load_model(smi_model_handle_t handle, const char* path) {
    // Path is to Axon package directory containing model files
    // Plugin loads PyTorch model from that path
    // No Axon-specific code needed
    
    char model_file[512];
    snprintf(model_file, sizeof(model_file), "%s/model.pth", path);
    
    model = torch::jit::load(model_file);
    return SMI_SUCCESS;
}
```

### What Changed: Only MLOS Core

**Before:**
- MLOS Core could accept models from various sources
- No standardized package format

**After:**
- MLOS Core reads Axon manifests for metadata
- Models come from Axon packages (standardized MPF)
- Plugins receive path to Axon package location
- **Plugins unchanged - still just get a path**

## Benefits of This Architecture

### 1. Patent Alignment ✅
- Implements Model Package Format (MPF) as specified
- Provides standardized packaging system
- Enables deployment-agnostic execution

### 2. Plugin Independence ✅
- Plugins remain framework-agnostic
- No Axon dependencies in plugins
- SMI interface unchanged
- Plugins work with any model path

### 3. Universal Delivery ✅
- Axon handles all repository adapters
- MLOS Core doesn't need repository-specific code
- Single standardized format (MPF)

### 4. Clean Separation ✅
- **Delivery**: Axon (repositories → packages)
- **Execution**: MLOS Core (packages → plugins)
- **Framework**: Plugins (model files → inference)

## Implementation Details

### MLOS Core Model Registration Flow

```c
// 1. Axon sends registration request with manifest_path
POST /models/register
{
    "model_id": "hf/bert-base-uncased@latest",
    "path": "/axon/cache/models/hf/bert-base-uncased/latest",
    "manifest_path": "/axon/cache/models/hf/bert-base-uncased/latest/manifest.yaml"
}

// 2. MLOS Core reads Axon manifest
axon_to_mlos_metadata(manifest_path, &mlos_metadata);

// 3. MLOS Core extracts:
//    - Framework type (to select plugin)
//    - Resource requirements
//    - I/O schema
//    - Model metadata

// 4. MLOS Core registers with appropriate plugin
mlos_register_model(core, plugin_id, &mlos_metadata, model_id);

// 5. Plugin receives:
//    - metadata (framework, requirements, etc.)
//    - path (to Axon package directory)
//    Plugin doesn't know it's an Axon package - just a path
```

### Plugin Model Loading Flow

```c
// 1. MLOS Core calls plugin's load_model()
plugin->interface.load_model(handle, "/axon/cache/models/hf/bert-base-uncased/latest");

// 2. Plugin loads model from path
//    Path contains model files (e.g., model.pth, config.json, etc.)
//    Plugin uses its framework's loader

// 3. Plugin doesn't need to:
//    - Read manifest.yaml (MLOS Core already did that)
//    - Know about Axon (just a path)
//    - Handle repository-specific formats (Axon already standardized)
```

## FAQ

### Q: Does this require plugins to know about Axon?

**A: No.** Plugins receive a path to model files. The path happens to be in an Axon package directory, but plugins just load their framework's model format from that path.

### Q: Can plugins still work with non-Axon models?

**A: Yes, with a caveat.** The intended architecture is that all models come through Axon (standardized MPF). However, if a model is manually placed in the expected directory structure with a manifest.yaml, MLOS Core can still read it.

### Q: Does this violate the plugin architecture?

**A: No.** The plugin architecture remains unchanged:
- SMI interface is the same
- Plugins still receive metadata and path
- Plugins are still framework-agnostic
- Only MLOS Core knows about Axon packages

### Q: What if a plugin needs repository-specific code?

**A: It shouldn't.** Axon handles all repository-specific logic. Plugins receive standardized model files in a standardized location. If a plugin needs repository-specific code, that's a design issue - the model should be standardized by Axon first.

### Q: Does this align with the patent?

**A: Yes, perfectly.** The patent specifically calls out Model Package Format (MPF) as a key innovation. Axon packages ARE the MPF. MLOS Core reading Axon manifests is the intended architecture.

## Conclusion

**This architecture:**
1. ✅ **Aligns with patents** - Implements MPF as specified
2. ✅ **Preserves plugin architecture** - Plugins unchanged, SMI unchanged
3. ✅ **Enables universal delivery** - Axon handles all repositories
4. ✅ **Maintains separation** - Clear boundaries between layers

**The key insight:** MLOS Core reads Axon manifests for **metadata**, but plugins just receive a **path** to model files. Plugins don't need to know about Axon - they just load their framework's model format from the provided path.

---

**MLOS Foundation** - Building the future of ML infrastructure.

