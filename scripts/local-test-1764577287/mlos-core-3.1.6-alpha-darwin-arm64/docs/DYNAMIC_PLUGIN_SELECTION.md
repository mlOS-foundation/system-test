# Dynamic Plugin Selection via Manifest
## Manifest-First Architecture Enables Format-Agnostic Plugin Selection

## Executive Summary

**Current State:** ONNX Runtime is hardcoded as the default/universal plugin.

**With Manifest-First:** Execution format specified in manifest enables **dynamic plugin selection** - Core can automatically choose the appropriate plugin based on the model's execution format, not hardcoded defaults.

**Benefit:** Core becomes truly format-agnostic - can support multiple execution formats simultaneously, and default plugin can change per model without code changes.

---

## Current Architecture: Hardcoded ONNX Default

### Current Plugin Selection Logic

```c
// Current: Hardcoded ONNX Runtime as default
if (!plugin_id || plugin_id[0] == '\0') {
    // Auto-select plugin based on framework
    // Priority: ONNX Runtime (built-in) > Framework-specific plugins
    
    // 1. Try ONNX Runtime (hardcoded as universal)
    if (strcmp(plugin->plugin_id, "onnx-runtime-builtin") == 0) {
        plugin = onnx_plugin;  // Hardcoded default
    }
    
    // 2. Fallback to framework-specific plugins
    // ...
}
```

### Current Flow

```
Model Registration
    ↓
No plugin specified?
    ↓
Auto-select: ONNX Runtime (hardcoded)
    ↓
Axon converts to ONNX (if needed)
    ↓
Core executes via ONNX Runtime
```

**Limitation:** ONNX is hardcoded as the default. To change default, need code changes.

---

## Manifest-First: Dynamic Plugin Selection

### Enhanced Manifest Structure

```yaml
spec:
  format:
    type: onnx  # or pytorch, tensorflow, etc.
    execution_format: onnx  # NEW: Specifies execution format
  framework:
    name: PyTorch
    version: 2.0.0
  io:
    inputs: [...]
    outputs: [...]
```

### Dynamic Plugin Selection Logic

```c
// NEW: Read execution format from manifest
typedef enum {
    EXEC_FORMAT_ONNX,
    EXEC_FORMAT_PYTORCH,
    EXEC_FORMAT_TENSORFLOW,
    EXEC_FORMAT_AUTO  // Auto-detect from available formats
} execution_format_t;

// Read format from manifest
execution_format_t format = read_execution_format_from_manifest(manifest_path);

// Select plugin based on format (not hardcoded)
smi_plugin_t* select_plugin_by_format(mlos_core_t* core, execution_format_t format) {
    switch (format) {
    case EXEC_FORMAT_ONNX:
        return find_plugin(core, "onnx-runtime-builtin");
    case EXEC_FORMAT_PYTORCH:
        return find_plugin(core, "pytorch-plugin");
    case EXEC_FORMAT_TENSORFLOW:
        return find_plugin(core, "tensorflow-plugin");
    case EXEC_FORMAT_AUTO:
        // Auto-detect: Check available formats in package
        return auto_detect_plugin(core, model_path);
    }
}
```

### New Flow

```
Model Registration
    ↓
Read manifest.yaml
    ↓
Extract execution_format from manifest
    ↓
Select plugin based on format (dynamic)
    ↓
Execute via selected plugin
```

**Benefit:** Default plugin is **per-model**, not hardcoded. Core adapts automatically.

---

## Real-World Scenarios

### Scenario 1: Mixed Format Support

**Manifest 1 (ONNX):**
```yaml
spec:
  format:
    execution_format: onnx
```

**Manifest 2 (PyTorch):**
```yaml
spec:
  format:
    execution_format: pytorch
```

**Core Behavior:**
- Model 1 → ONNX Runtime plugin
- Model 2 → PyTorch plugin
- **No code changes** - Core adapts automatically

### Scenario 2: Format Migration

**Before:**
```yaml
spec:
  format:
    execution_format: onnx
```

**After (Axon migrates to PyTorch):**
```yaml
spec:
  format:
    execution_format: pytorch
```

**Core Behavior:**
- ✅ Automatically uses PyTorch plugin
- ✅ No Core code changes
- ✅ Seamless migration

### Scenario 3: Multi-Format Package

**Manifest:**
```yaml
spec:
  format:
    execution_format: auto  # Auto-detect from available files
    available_formats:
      - onnx
      - pytorch
      - tensorflow
```

**Core Behavior:**
- Checks available formats in package
- Selects best plugin based on availability
- Falls back gracefully

---

## Implementation

### Phase 1: Add Format to Manifest

**Axon Changes:**
```go
// In pkg/types/manifest.go
type Format struct {
    Type            string   `yaml:"type"`              // Original format (pytorch, tensorflow)
    ExecutionFormat string   `yaml:"execution_format"`  // NEW: Execution format (onnx, pytorch, etc.)
    AvailableFormats []string `yaml:"available_formats,omitempty"`  // NEW: Available formats
}
```

**Example Manifest:**
```yaml
spec:
  format:
    type: pytorch  # Original format from repository
    execution_format: onnx  # Converted to ONNX for execution
    available_formats:
      - onnx
      - pytorch  # Original also available
```

### Phase 2: Core Reads Format from Manifest

**Core Changes:**
```c
// Read execution format from manifest
execution_format_t read_execution_format(const char* manifest_path) {
    // Parse manifest.yaml
    // Extract spec.format.execution_format
    // Return appropriate enum value
}

// Plugin selection based on format
smi_plugin_t* select_plugin_by_format(mlos_core_t* core, execution_format_t format) {
    const char* plugin_id = NULL;
    
    switch (format) {
    case EXEC_FORMAT_ONNX:
        plugin_id = "onnx-runtime-builtin";
        break;
    case EXEC_FORMAT_PYTORCH:
        plugin_id = "pytorch-plugin";
        break;
    case EXEC_FORMAT_TENSORFLOW:
        plugin_id = "tensorflow-plugin";
        break;
    case EXEC_FORMAT_AUTO:
        return auto_detect_plugin(core);
    }
    
    return find_plugin(core, plugin_id);
}
```

### Phase 3: Update Registration Logic

**Core Changes:**
```c
int mlos_register_model(mlos_core_t* core, const char* plugin_id,
                        const smi_model_metadata_t* metadata, char* model_id,
                        const char* model_path) {
    // ...
    
    // NEW: If no plugin specified, read from manifest
    if (!plugin_id || plugin_id[0] == '\0') {
        char manifest_path[512];
        snprintf(manifest_path, sizeof(manifest_path), "%s/manifest.yaml", model_path);
        
        execution_format_t format = read_execution_format(manifest_path);
        plugin = select_plugin_by_format(core, format);
        
        if (plugin) {
            printf("🔌 Auto-selected plugin '%s' based on manifest format\n", plugin->plugin_id);
        }
    }
    
    // ...
}
```

---

## Benefits

### 1. **Format Flexibility**

**Before:** ONNX hardcoded as default
**After:** Format specified per-model in manifest

**Benefit:** 
- ✅ Support multiple formats simultaneously
- ✅ Per-model format selection
- ✅ No hardcoded defaults

### 2. **Future-Proof**

**Before:** Changing default requires code changes
**After:** Change manifest, Core adapts automatically

**Benefit:**
- ✅ Easy format migrations
- ✅ A/B testing different formats
- ✅ Gradual rollout

### 3. **Multi-Format Support**

**Before:** Single default format
**After:** Multiple formats supported simultaneously

**Benefit:**
- ✅ ONNX for some models
- ✅ PyTorch for others
- ✅ TensorFlow for others
- ✅ All in same Core instance

### 4. **Plugin Ecosystem**

**Before:** ONNX Runtime is special (hardcoded)
**After:** All plugins equal, selected by manifest

**Benefit:**
- ✅ Plugin ecosystem growth
- ✅ Third-party plugins
- ✅ Custom plugins
- ✅ No special cases

---

## Migration Path

### Step 1: Add Format to Manifest (Backward Compatible)

```yaml
spec:
  format:
    type: pytorch
    execution_format: onnx  # NEW: Optional, defaults to ONNX if missing
```

**Core Behavior:**
- If `execution_format` present → Use it
- If missing → Default to ONNX (backward compatible)

### Step 2: Update Core to Read Format

```c
execution_format_t format = read_execution_format(manifest_path);
if (format == EXEC_FORMAT_UNKNOWN) {
    format = EXEC_FORMAT_ONNX;  // Default for backward compatibility
}
```

### Step 3: Enable Multi-Format

```c
// Support multiple plugins
register_plugin(core, "onnx-runtime-builtin", onnx_plugin);
register_plugin(core, "pytorch-plugin", pytorch_plugin);
register_plugin(core, "tensorflow-plugin", tensorflow_plugin);

// Select based on manifest
plugin = select_plugin_by_format(core, format);
```

---

## Example: Changing Default Plugin

### Current (Hardcoded ONNX)

```c
// Hardcoded in Core
if (no_plugin_specified) {
    plugin = onnx_runtime_plugin;  // Hardcoded
}
```

**To change default:** Modify Core code, recompile, redeploy

### With Manifest-First (Dynamic)

```yaml
# Model 1: Use ONNX
spec:
  format:
    execution_format: onnx

# Model 2: Use PyTorch
spec:
  format:
    execution_format: pytorch
```

**To change default:** Update manifest, Core adapts automatically

**To change global default:** Update Axon to generate different format in manifest

---

## Architecture Diagram

### Current: Hardcoded Default

```
┌─────────────────────────────────────────┐
│              Core                        │
│  Default Plugin: ONNX Runtime (hardcoded)│
└──────────────────┬──────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────┐
│              Axon                        │
│  Converts to ONNX (required)            │
└─────────────────────────────────────────┘
```

### Manifest-First: Dynamic Selection

```
┌─────────────────────────────────────────┐
│              Core                        │
│  Reads format from manifest             │
│  Selects plugin dynamically              │
│  Supports: ONNX, PyTorch, TensorFlow... │
└──────────────────┬──────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────┐
│              Axon                        │
│  Specifies format in manifest            │
│  Can provide multiple formats            │
└─────────────────────────────────────────┘
```

---

## Conclusion

**Your insight is correct:** Manifest-first architecture enables **dynamic plugin selection** based on execution format specified in manifest, rather than hardcoded defaults.

**Key Benefits:**
- ✅ **Format flexibility** - Per-model format selection
- ✅ **Future-proof** - Easy format migrations
- ✅ **Multi-format support** - Multiple formats simultaneously
- ✅ **Plugin ecosystem** - All plugins equal, no special cases
- ✅ **No code changes** - Change manifest, Core adapts

**This makes Core truly format-agnostic and enables a plugin ecosystem where the "default" plugin is determined by the model's manifest, not hardcoded in Core.**

---

## References

- [Manifest-First Architecture](MANIFEST_FIRST_ARCHITECTURE.md)
- [Universal Model Plugin Design](UNIVERSAL_MODEL_PLUGIN_DESIGN.md)
- [ONNX vs Manifest Metadata](ONNX_VS_MANIFEST_METADATA.md)

