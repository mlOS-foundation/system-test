# Manifest-First Architecture: Future-Proofing Design

## Executive Summary

**Key Insight:** Using manifest as the **source of truth for I/O schema** (instead of ONNX) provides critical architectural flexibility for future format changes.

**Benefit:** If Axon moves away from ONNX format (e.g., native PyTorch, TensorFlow, new formats), Core requires **minimal changes** because it relies on manifest metadata, not format-specific extraction.

---

## The Problem: Format Coupling

### Current Approach: ONNX-First

```
Core extracts I/O from ONNX → Uses manifest for operational metadata
```

**If Axon moves away from ONNX:**
- ❌ Core's I/O extraction logic breaks (ONNX-specific)
- ❌ Need to rewrite extraction for new format
- ❌ Core becomes format-coupled
- ❌ Changes required in Core for every format change

### Proposed Approach: Manifest-First

```
Core reads I/O from manifest → Validates against execution format (if available)
```

**If Axon moves away from ONNX:**
- ✅ Core's I/O logic unchanged (manifest is format-agnostic)
- ✅ Only execution layer needs format-specific code
- ✅ Core remains format-decoupled
- ✅ Zero changes in Core for format transitions

---

## Architecture Comparison

### ONNX-First Architecture (Current)

```
┌─────────────────────────────────────────────────────────┐
│                    Axon (Delivery)                      │
│  • Downloads model                                      │
│  • Converts to ONNX                                     │
│  • Generates manifest (operational metadata only)      │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────┐
│                  Core (Execution)                       │
│  • Extracts I/O from ONNX file ← FORMAT-COUPLED        │
│  • Reads manifest for preprocessing                    │
│  • Executes via ONNX Runtime                          │
└─────────────────────────────────────────────────────────┘

Problem: If ONNX goes away, Core breaks
```

### Manifest-First Architecture (Proposed)

```
┌─────────────────────────────────────────────────────────┐
│                    Axon (Delivery)                      │
│  • Downloads model                                      │
│  • Extracts I/O schema from model (format-agnostic)   │
│  • Generates manifest (I/O + operational metadata)   │
│  • Converts to execution format (ONNX, PyTorch, etc.) │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────┐
│                  Core (Execution)                       │
│  • Reads I/O from manifest ← FORMAT-AGNOSTIC          │
│  • Validates against execution format (optional)        │
│  • Executes via appropriate runtime                    │
└─────────────────────────────────────────────────────────┘

Benefit: If execution format changes, Core unchanged
```

---

## Functional Benefits

### 1. **Format Independence**

**Manifest-First:**
- Core doesn't care if model is ONNX, PyTorch, TensorFlow, etc.
- I/O schema is format-agnostic
- Execution format is just an implementation detail

**ONNX-First:**
- Core tightly coupled to ONNX
- Format change = Core changes

### 2. **Multi-Format Support**

**Manifest-First:**
```yaml
spec:
  format:
    type: onnx  # or pytorch, tensorflow, etc.
  io:
    inputs: [...]  # Format-agnostic schema
```

Core can support multiple execution formats:
- ONNX Runtime (current)
- PyTorch JIT (future)
- TensorFlow SavedModel (future)
- Custom formats (future)

**ONNX-First:**
- Limited to ONNX format
- Adding new formats requires Core changes

### 3. **Gradual Migration**

**Manifest-First:**
- Can migrate formats incrementally
- Old format: manifest + old runtime
- New format: manifest + new runtime
- Core unchanged

**ONNX-First:**
- Format migration = breaking change
- Requires coordinated Core + Axon changes

---

## Non-Functional Benefits

### 1. **Maintainability**

**Manifest-First:**
- Single source of truth (manifest)
- Clear separation: metadata (manifest) vs execution (runtime)
- Easier to understand and maintain

**ONNX-First:**
- Two sources of truth (ONNX + manifest)
- Potential for drift
- More complex

### 2. **Testability**

**Manifest-First:**
- Can test I/O logic without ONNX files
- Mock manifests for testing
- Faster unit tests

**ONNX-First:**
- Requires ONNX files for testing
- Slower tests
- More dependencies

### 3. **Performance**

**Manifest-First:**
- Fast metadata access (YAML read)
- No model loading required
- Better for catalog/discovery

**ONNX-First:**
- Requires ONNX file access
- May need model loading for metadata
- Slower for discovery

---

## Implementation Strategy

### Phase 1: Manifest as Source of Truth

**Core Changes:**
```c
// OLD: Extract from ONNX
extract_onnx_metadata(onnx_path, &metadata);

// NEW: Read from manifest
read_io_schema_from_manifest(manifest_path, &io_schema);

// Optional: Validate against ONNX (if available)
if (onnx_exists) {
    validate_manifest_against_onnx(&io_schema, onnx_path);
}
```

**Axon Changes:**
```go
// Extract I/O schema from model (format-agnostic)
func extractIOSchema(modelPath string, format string) ([]IOSpec, []IOSpec) {
    switch format {
    case "onnx":
        return extractFromONNX(modelPath)
    case "pytorch":
        return extractFromPyTorch(modelPath)
    case "tensorflow":
        return extractFromTensorFlow(modelPath)
    }
}
```

### Phase 2: Format-Agnostic Execution

**Core Changes:**
```c
// Execution format is just a detail
typedef enum {
    EXEC_FORMAT_ONNX,
    EXEC_FORMAT_PYTORCH,
    EXEC_FORMAT_TENSORFLOW
} execution_format_t;

// Plugin selection based on format
smi_plugin_t* select_plugin(execution_format_t format) {
    switch (format) {
    case EXEC_FORMAT_ONNX:
        return onnx_runtime_plugin;
    case EXEC_FORMAT_PYTORCH:
        return pytorch_plugin;
    case EXEC_FORMAT_TENSORFLOW:
        return tensorflow_plugin;
    }
}
```

---

## Trade-offs

### Manifest-First: Pros

✅ **Format independence** - Core decoupled from execution format
✅ **Future-proof** - Easy format transitions
✅ **Multi-format support** - Can support multiple formats simultaneously
✅ **Fast metadata** - YAML read vs model loading
✅ **Human readable** - Easier debugging
✅ **Framework agnostic** - Works for all frameworks

### Manifest-First: Cons

❌ **Manifest accuracy** - Must ensure manifest matches model
❌ **Validation needed** - Should validate manifest against model
❌ **Axon responsibility** - Axon must extract I/O correctly

### Mitigation Strategies

1. **Validation:** Core validates manifest against execution format
2. **Fallback:** If manifest missing, extract from execution format
3. **Testing:** Comprehensive tests ensure manifest accuracy

---

## Migration Path

### Step 1: Dual Support (Transition Period)

```c
// Try manifest first, fallback to ONNX
if (manifest_has_io_schema(manifest_path)) {
    read_io_from_manifest(manifest_path, &io_schema);
} else {
    extract_io_from_onnx(onnx_path, &io_schema);
}
```

### Step 2: Manifest Required

```c
// Manifest is required, ONNX is optional validation
read_io_from_manifest(manifest_path, &io_schema);  // Required

if (onnx_exists) {
    validate_manifest_against_onnx(&io_schema, onnx_path);  // Optional
}
```

### Step 3: Format-Agnostic

```c
// Execution format is just a detail
read_io_from_manifest(manifest_path, &io_schema);  // Source of truth
select_execution_runtime(format, &runtime);  // Format-specific execution
```

---

## Real-World Scenarios

### Scenario 1: Move to Native PyTorch

**ONNX-First:**
- ❌ Core needs ONNX extraction logic rewritten
- ❌ Core changes required
- ❌ Breaking change

**Manifest-First:**
- ✅ Core unchanged (uses manifest)
- ✅ Only execution layer changes (PyTorch plugin)
- ✅ Non-breaking

### Scenario 2: Support Multiple Formats

**ONNX-First:**
- ❌ Core needs format-specific extraction for each
- ❌ Complex code paths
- ❌ Hard to maintain

**Manifest-First:**
- ✅ Core uses manifest (format-agnostic)
- ✅ Execution layer handles format specifics
- ✅ Clean separation

### Scenario 3: New Format (e.g., MLIR)

**ONNX-First:**
- ❌ Core needs MLIR extraction logic
- ❌ Core changes required
- ❌ Coupling increases

**Manifest-First:**
- ✅ Core unchanged (uses manifest)
- ✅ Only execution layer adds MLIR support
- ✅ No coupling

---

## Updated Design Recommendation

### Manifest-First Architecture

**Principle:** Manifest is the **source of truth** for I/O schema

**Benefits:**
1. ✅ **Format independence** - Core decoupled from execution format
2. ✅ **Future-proof** - Easy format transitions
3. ✅ **Multi-format support** - Can support multiple formats
4. ✅ **Fast metadata** - YAML read vs model loading
5. ✅ **Framework agnostic** - Works for all frameworks

**Implementation:**
1. Axon extracts I/O schema from models (format-agnostic)
2. Axon generates complete manifest with I/O schema
3. Core reads I/O from manifest (source of truth)
4. Core validates against execution format (optional)
5. Core executes via appropriate runtime (format-specific)

**Validation:**
- Core validates manifest I/O against execution format
- Ensures accuracy
- Catches mismatches early

---

## Conclusion

**Your insight is correct:** Manifest-first architecture provides critical **future-proofing** and **format independence**.

**Key Benefits:**
- ✅ Core remains format-agnostic
- ✅ Easy format transitions
- ✅ Multi-format support
- ✅ Minimal Core changes for format changes

**Recommendation:** Adopt **Manifest-First** architecture where:
- **Manifest = Source of Truth** for I/O schema
- **Execution Format = Implementation Detail**
- **Core = Format-Agnostic** execution layer

This aligns with the MLOS patent's vision of **deployment-agnostic execution** and **universal model support**.

---

## References

- [ONNX vs Manifest Metadata](ONNX_VS_MANIFEST_METADATA.md)
- [Universal Model Plugin Design](UNIVERSAL_MODEL_PLUGIN_DESIGN.md)
- [MLOS Patent US-63/861,527](PATENTS.md)

