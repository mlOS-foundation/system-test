# ONNX vs Manifest Metadata: Duplication Analysis

## Executive Summary

**ONNX is a standard spec** - it provides input/output metadata. However, manifest metadata serves **complementary purposes** beyond what ONNX provides, with clear functional and non-functional benefits.

**Key Insight:** Manifest metadata is **NOT duplication** - it's **operational metadata** that ONNX doesn't provide.

---

## What ONNX Provides (Standard Spec)

### ONNX Model Metadata (Extractable via ONNX Runtime)

```c
// ONNX Runtime can extract:
- Input names: "input_ids", "attention_mask", "token_type_ids"
- Input shapes: [batch_size, sequence_length]
- Input types: INT64, FLOAT32, etc.
- Output names: "logits", "pooler_output"
- Output shapes: [batch_size, sequence_length, vocab_size]
- Output types: FLOAT32
```

**ONNX Runtime APIs:**
- `SessionGetInputCount()` - Number of inputs
- `SessionGetInputName()` - Input names
- `SessionGetInputTypeInfo()` - Input types and shapes
- `SessionGetOutputCount()` - Number of outputs
- `SessionGetOutputName()` - Output names
- `SessionGetOutputTypeInfo()` - Output types and shapes

**What ONNX Does NOT Provide:**
- ❌ Preprocessing requirements (tokenization, normalization)
- ❌ Tokenizer file locations
- ❌ Model operational context (deployment configs)
- ❌ Performance characteristics
- ❌ Resource requirements
- ❌ Security policies
- ❌ Repository source information
- ❌ Model versioning (beyond ONNX version)

---

## What Manifest Provides (MPF - Model Package Format)

### Operational Metadata (Beyond ONNX)

```yaml
spec:
  io:
    inputs:
      - name: input_ids
        dtype: int64
        shape: [-1, -1]
        preprocessing:  # NOT in ONNX
          type: tokenization
          tokenizer: tokenizer.json
          tokenizer_type: bert
  requirements:  # NOT in ONNX
    compute:
      cpu:
        min_cores: 2
      memory:
        min_gb: 2.0
  performance:  # NOT in ONNX
    inference_time:
      cpu: "50ms"
      gpu: "5ms"
```

---

## Functional Benefits

### 1. **Preprocessing Information** (Critical Gap)

**ONNX:** Only knows about tensor inputs
**Manifest:** Knows HOW to create those tensors

**Example:**
- ONNX says: "I need `input_ids` tensor of shape [1, 128]"
- Manifest says: "To create `input_ids`, tokenize text using `tokenizer.json`"

**Benefit:** Enables automatic preprocessing without model-specific code

### 2. **Resource Planning** (Deployment Context)

**ONNX:** No resource requirements
**Manifest:** CPU, memory, GPU requirements

**Benefit:** 
- Pre-deployment validation
- Resource allocation
- Cost estimation
- Cluster planning

### 3. **Performance Characteristics** (Operational Context)

**ONNX:** No performance data
**Manifest:** Inference time, throughput, accuracy

**Benefit:**
- SLO planning
- Capacity planning
- Performance monitoring
- A/B testing

### 4. **Model Discovery** (Repository Context)

**ONNX:** No source information
**Manifest:** Repository, namespace, version, license

**Benefit:**
- Model cataloging
- License compliance
- Version tracking
- Repository management

### 5. **Security & Compliance** (Operational Context)

**ONNX:** No security metadata
**Manifest:** Access controls, compliance tags, data lineage

**Benefit:**
- Security policies
- Compliance tracking
- Audit trails

---

## Non-Functional Benefits

### 1. **Performance: Fast Metadata Access**

**ONNX:** Requires loading model session (expensive)
**Manifest:** YAML file read (fast)

**Benefit:**
- Model discovery without loading models
- Fast catalog queries
- Pre-registration validation

**Example:**
```bash
# Fast: Read manifest.yaml
axon list  # Reads manifests, no model loading

# Slow: Load ONNX models
# Would require loading every model to get metadata
```

### 2. **Separation of Concerns**

**ONNX:** Model execution metadata
**Manifest:** Model operational metadata

**Benefit:**
- Clear boundaries
- Independent evolution
- Better maintainability

### 3. **Framework Agnostic**

**ONNX:** Only for ONNX models
**Manifest:** Works for all frameworks (PyTorch, TensorFlow, etc.)

**Benefit:**
- Unified metadata format
- Consistent API
- Framework-independent tooling

### 4. **Human Readable**

**ONNX:** Binary format (requires tools)
**Manifest:** YAML (human readable)

**Benefit:**
- Easy debugging
- Manual inspection
- Documentation
- Version control friendly

### 5. **Pre-Deployment Validation**

**ONNX:** Can only validate after model load
**Manifest:** Can validate before deployment

**Benefit:**
- Early error detection
- CI/CD integration
- Pre-flight checks

---

## Is It Duplication?

### Analysis: What Overlaps vs What's Unique

| Metadata Type | ONNX | Manifest | Overlap? |
|---------------|------|----------|----------|
| Input names | ✅ | ✅ | **Yes** - but manifest adds preprocessing |
| Input shapes | ✅ | ✅ | **Yes** - but manifest adds validation hints |
| Input types | ✅ | ✅ | **Yes** - but manifest adds preprocessing context |
| Output names | ✅ | ✅ | **Yes** - minimal overlap |
| Output shapes | ✅ | ✅ | **Yes** - minimal overlap |
| Preprocessing | ❌ | ✅ | **No** - manifest only |
| Tokenizer info | ❌ | ✅ | **No** - manifest only |
| Resource reqs | ❌ | ✅ | **No** - manifest only |
| Performance | ❌ | ✅ | **No** - manifest only |
| Repository info | ❌ | ✅ | **No** - manifest only |
| Security | ❌ | ✅ | **No** - manifest only |

### Conclusion: **NOT Duplication - Complementary**

**Overlap:** ~30% (I/O names, shapes, types)
**Unique to Manifest:** ~70% (operational metadata)

**The overlap serves a purpose:**
1. **Validation:** Manifest can validate against ONNX
2. **Pre-deployment:** Can check requirements before loading
3. **Documentation:** Human-readable format
4. **Framework-agnostic:** Works for non-ONNX models too

---

## Recommended Architecture

### Option 1: ONNX-First (Current Approach - Recommended)

**Strategy:** Extract from ONNX, use manifest for operational metadata

```c
// 1. Extract I/O schema from ONNX (source of truth)
extract_onnx_metadata(onnx_path, &onnx_metadata);

// 2. Read manifest for operational metadata
read_manifest_metadata(manifest_path, &manifest_metadata);

// 3. Merge: ONNX for I/O, Manifest for preprocessing/requirements
merge_metadata(&onnx_metadata, &manifest_metadata, &final_metadata);
```

**Benefits:**
- ✅ ONNX is source of truth for I/O
- ✅ Manifest provides operational context
- ✅ No duplication - complementary
- ✅ Validation: Manifest can validate against ONNX

### Option 2: Manifest-First (Alternative)

**Strategy:** Use manifest as source of truth, validate against ONNX

```c
// 1. Read manifest (fast, human-readable)
read_manifest_metadata(manifest_path, &manifest_metadata);

// 2. Validate against ONNX (if available)
if (onnx_exists) {
    extract_onnx_metadata(onnx_path, &onnx_metadata);
    validate_manifest_against_onnx(&manifest_metadata, &onnx_metadata);
}
```

**Benefits:**
- ✅ Fast metadata access
- ✅ Works for non-ONNX models
- ✅ Human-readable

**Drawbacks:**
- ❌ Requires maintaining manifest accuracy
- ❌ Potential for drift

### Option 3: ONNX-Only (Not Recommended)

**Strategy:** Extract everything from ONNX, no manifest I/O schema

**Drawbacks:**
- ❌ No preprocessing information
- ❌ No resource requirements
- ❌ No performance characteristics
- ❌ Requires loading model for metadata
- ❌ Framework-specific (ONNX only)

---

## Implementation Recommendation

### Hybrid Approach: ONNX-First with Manifest Enhancement

```c
// Phase 1: Extract from ONNX (source of truth)
onnx_tensor_spec_t* onnx_inputs = extract_onnx_inputs(onnx_path);

// Phase 2: Enhance with manifest (operational context)
if (manifest_exists) {
    preprocessing_spec_t* preprocessing = read_preprocessing_from_manifest(manifest_path);
    
    // Merge: ONNX provides structure, manifest provides context
    for (int i = 0; i < num_inputs; i++) {
        onnx_inputs[i].preprocessing = preprocessing[i];
    }
}
```

**Key Principle:**
- **ONNX = Structural Truth** (what the model needs)
- **Manifest = Operational Truth** (how to provide it)

---

## Cost-Benefit Analysis

### Cost of Manifest I/O Schema

**Development:**
- Extract I/O from models: ~2-3 days
- Generate manifest: Already done (part of Axon)
- Maintenance: Minimal (ONNX is source of truth)

**Runtime:**
- YAML parsing: ~1ms (negligible)
- Storage: ~1KB per model (negligible)

### Benefit of Manifest I/O Schema

**Functional:**
- ✅ Preprocessing automation
- ✅ Resource planning
- ✅ Performance monitoring
- ✅ Security policies

**Non-Functional:**
- ✅ Fast metadata access
- ✅ Human readability
- ✅ Framework agnostic
- ✅ Pre-deployment validation

**ROI:** High - Small cost, significant benefits

---

## Conclusion

### Is Manifest I/O Schema Duplication?

**Answer: NO** - It's **complementary metadata** with clear benefits:

1. **Functional Benefits:**
   - Preprocessing information (critical gap)
   - Resource requirements
   - Performance characteristics
   - Security policies

2. **Non-Functional Benefits:**
   - Fast metadata access
   - Human readability
   - Framework agnostic
   - Pre-deployment validation

3. **Overlap is Intentional:**
   - Validation (manifest vs ONNX)
   - Pre-deployment checks
   - Documentation
   - Framework independence

### Recommended Approach

**ONNX-First with Manifest Enhancement:**
- Extract I/O structure from ONNX (source of truth)
- Enhance with manifest operational metadata
- Use manifest for preprocessing, requirements, performance
- Validate manifest against ONNX for accuracy

**Result:** Best of both worlds - structural accuracy (ONNX) + operational context (Manifest)

---

## References

- [ONNX Specification](https://github.com/onnx/onnx)
- [ONNX Runtime C API](https://onnxruntime.ai/docs/api/c/)
- [MLOS Patent US-63/861,527](PATENTS.md) - Model Package Format (MPF)

