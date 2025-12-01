# Universal Model Plugin (UMP) Implementation Plan
## Changes Required in Axon and Core Repositories

## Summary

**Yes, changes are needed in BOTH repositories**, but the division is clean:

- **Core**: Inference execution, metadata extraction, preprocessing
- **Axon**: Enhanced manifest generation with complete I/O schema

---

## Core Repository Changes

### 1. ONNX Runtime Plugin (`core/plugins/builtin/onnx_runtime_plugin.c`)

**Current State:**
- ✅ Extracts input/output names
- ✅ Extracts input/output counts
- ❌ Only uses first input
- ❌ Doesn't extract shapes/types
- ❌ No preprocessing support

**Required Changes:**

#### A. Enhanced Metadata Extraction
```c
// Add to onnx_model_state_t
typedef struct {
    char name[256];
    ONNXTensorElementDataType dtype;
    int64_t shape[8];
    size_t num_dims;
    bool is_dynamic;
} onnx_tensor_spec_t;

// Enhance model state
typedef struct {
    // ... existing fields ...
    onnx_tensor_spec_t input_specs[16];  // NEW: Full input specs
    onnx_tensor_spec_t output_specs[16]; // NEW: Full output specs
} onnx_model_state_t;
```

**Tasks:**
- [ ] Extract shapes for all inputs/outputs
- [ ] Extract data types for all inputs/outputs
- [ ] Detect dynamic dimensions
- [ ] Store in model state

#### B. Multi-Input Tensor Creation
```c
// OLD: Only first input
const char* input_name = model_state->input_names[0];
OrtValue* input_tensors[] = {input_tensor};

// NEW: All inputs
const char* input_names[16];
OrtValue* input_tensors[16];
for (size_t i = 0; i < model_state->num_inputs; i++) {
    // Create tensor for each input with proper shape/type
}
```

**Tasks:**
- [ ] Create tensors for ALL inputs (not just first)
- [ ] Use actual input names from metadata
- [ ] Use actual shapes from metadata
- [ ] Use actual data types from metadata

#### C. Preprocessing Integration
```c
// Detect preprocessing needs
bool needs_tokenization(const onnx_model_state_t* model_state);
bool needs_image_preprocessing(const onnx_model_state_t* model_state);

// Apply preprocessing
smi_status_t preprocess_input(
    const void* raw_input,
    size_t raw_input_size,
    const char* input_format,  // "text", "image", "tensor"
    const onnx_model_state_t* model_state,
    OrtValue** input_tensors,
    size_t* num_inputs
);
```

**Tasks:**
- [ ] Integrate ONNX Runtime Extensions (or tokenizer library)
- [ ] Read tokenizer.json from Axon package
- [ ] Implement text tokenization
- [ ] Implement image preprocessing
- [ ] Detect preprocessing needs from model metadata

#### D. Axon Manifest I/O Schema Reading
```c
// Read I/O schema from manifest.yaml
smi_status_t read_io_schema_from_manifest(
    const char* manifest_path,
    onnx_tensor_spec_t* input_specs,
    size_t* num_inputs,
    onnx_tensor_spec_t* output_specs,
    size_t* num_outputs
);
```

**Tasks:**
- [ ] Parse `spec.io.inputs` from manifest.yaml
- [ ] Parse `spec.io.outputs` from manifest.yaml
- [ ] Use for input validation
- [ ] Use for preprocessing hints

**Files to Modify:**
- `core/plugins/builtin/onnx_runtime_plugin.c` - Main plugin implementation
- `core/src/axon_manifest_reader.c` - Add I/O schema parsing (optional, can be done in plugin)

---

## Axon Repository Changes

### 1. Enhanced I/O Schema Generation

**Current State:**
- ✅ Has `IO` struct with `Inputs` and `Outputs`
- ✅ Basic I/O spec with name, dtype, shape
- ❌ Often generates generic "input"/"output" instead of actual names
- ❌ Doesn't include preprocessing hints
- ❌ Doesn't include tokenizer information

**Required Changes:**

#### A. Extract Actual Input/Output Names from Models

**For Hugging Face Models:**
```go
// In internal/registry/builtin/huggingface.go
func (h *HuggingFaceAdapter) extractIOSchema(modelPath string) ([]types.IOSpec, []types.IOSpec, error) {
    // Load model config
    configPath := filepath.Join(modelPath, "config.json")
    config, err := loadModelConfig(configPath)
    
    // Extract input names from model architecture
    // For BERT: input_ids, attention_mask, token_type_ids
    // For GPT: input_ids, attention_mask
    // etc.
    
    inputs := []types.IOSpec{
        {Name: "input_ids", DType: "int64", Shape: []int{-1, -1}},
        {Name: "attention_mask", DType: "int64", Shape: []int{-1, -1}},
        {Name: "token_type_ids", DType: "int64", Shape: []int{-1, -1}},
    }
    
    return inputs, outputs, nil
}
```

**Tasks:**
- [ ] Extract actual input names from model configs
- [ ] Extract actual output names from model configs
- [ ] Determine shapes from model architecture
- [ ] Determine data types from model architecture

#### B. Add Preprocessing Hints to Manifest

**Enhance IOSpec:**
```go
// In pkg/types/manifest.go
type IOSpec struct {
    Name        string `yaml:"name"`
    DType       string `yaml:"dtype"`
    Shape       []int  `yaml:"shape"`
    Description string `yaml:"description,omitempty"`
    
    // NEW: Preprocessing hints
    Preprocessing *PreprocessingSpec `yaml:"preprocessing,omitempty"`
}

type PreprocessingSpec struct {
    Type        string `yaml:"type"`        // "tokenization", "normalization", "resize", etc.
    Tokenizer    string `yaml:"tokenizer,omitempty"`    // Path to tokenizer.json
    TokenizerType string `yaml:"tokenizer_type,omitempty"` // "bert", "gpt2", etc.
    Config      map[string]interface{} `yaml:"config,omitempty"`
}
```

**Example Manifest:**
```yaml
spec:
  io:
    inputs:
      - name: input_ids
        dtype: int64
        shape: [-1, -1]
        description: "Token IDs from tokenizer"
        preprocessing:
          type: tokenization
          tokenizer: tokenizer.json
          tokenizer_type: bert
      - name: attention_mask
        dtype: int64
        shape: [-1, -1]
        description: "Attention mask"
        preprocessing:
          type: tokenization
          tokenizer: tokenizer.json
          tokenizer_type: bert
      - name: token_type_ids
        dtype: int64
        shape: [-1, -1]
        description: "Token type IDs"
        preprocessing:
          type: tokenization
          tokenizer: tokenizer.json
          tokenizer_type: bert
```

**Tasks:**
- [ ] Add `PreprocessingSpec` to `IOSpec`
- [ ] Detect preprocessing needs from model type
- [ ] Include tokenizer file path in manifest
- [ ] Include preprocessing config (normalization params, etc.)

#### C. Ensure Tokenizer Files in Package

**Current State:**
- ✅ Hugging Face adapter downloads tokenizer.json
- ✅ Files are included in package

**Verification Needed:**
- [ ] Ensure tokenizer.json is always included
- [ ] Ensure tokenizer_config.json is included
- [ ] Ensure vocab.txt is included (if needed)

**Files to Modify:**
- `axon/pkg/types/manifest.go` - Add PreprocessingSpec
- `axon/internal/registry/builtin/huggingface.go` - Extract I/O schema
- `axon/internal/registry/builtin/pytorch.go` - Extract I/O schema
- `axon/internal/registry/builtin/tensorflow.go` - Extract I/O schema

---

## Implementation Phases

### Phase 1: Core - Multi-Input Support (Manifest-First Architecture)
**Goal:** Make inference work with multiple inputs using manifest as source of truth

**Core Changes:**
- Read I/O schema from manifest (format-agnostic)
- Create tensors for all inputs based on manifest
- Use all inputs in inference
- Optional: Validate manifest against ONNX (if available)

**Axon Changes:** 
- Extract actual I/O schema from models (format-agnostic)
- Generate complete manifest with I/O schema

**Result:** BERT models work if inputs are provided as tensors (no text preprocessing yet)
**Architectural Benefit:** Core is format-agnostic - if Axon moves away from ONNX, Core requires zero changes

### Phase 2: Core - Preprocessing (Minimal Axon Changes)
**Goal:** Handle text/image inputs

**Core Changes:**
- Integrate ONNX Runtime Extensions or tokenizer library
- Read tokenizer.json from Axon package
- Apply preprocessing based on input format

**Axon Changes:**
- Ensure tokenizer.json is in package (already done)
- Optionally: Add preprocessing hints to manifest

**Result:** BERT models work with text input

### Phase 3: Axon - Enhanced I/O Schema (Core Uses It)
**Goal:** Better manifest generation

**Core Changes:**
- Read I/O schema from manifest for validation/hints

**Axon Changes:**
- Extract actual input/output names from models
- Add preprocessing hints to manifest
- Generate complete I/O schema

**Result:** Better validation, clearer preprocessing requirements

---

## Dependency Analysis

### Core Dependencies on Axon

**Current:**
- ✅ Reads manifest.yaml for framework, requirements
- ✅ Uses model path from Axon package

**New Dependencies:**
- ✅ Reads `spec.io` from manifest.yaml (**REQUIRED** - source of truth for I/O schema)
- ✅ Reads tokenizer.json from Axon package (required for preprocessing)
- ✅ Uses preprocessing hints from manifest (required for preprocessing)

**Architectural Decision: Manifest-First**
- **Manifest = Source of Truth** for I/O schema (format-agnostic)
- **Execution Format = Implementation Detail** (ONNX, PyTorch, etc.)
- **Core = Format-Agnostic** execution layer

**Conclusion:** Core relies on manifest for I/O schema. This provides:
- ✅ **Format independence** - Core decoupled from execution format
- ✅ **Future-proof** - Easy format transitions (ONNX → PyTorch → etc.)
- ✅ **Minimal Core changes** if Axon moves away from ONNX

### Axon Dependencies on Core

**None** - Axon is independent and doesn't depend on Core.

---

## Migration Strategy

### Backward Compatibility

**Core:**
- ✅ Works with existing manifests (extracts metadata from ONNX)
- ✅ Falls back if I/O schema missing in manifest
- ✅ Works without preprocessing hints (detects from model)

**Axon:**
- ✅ Existing manifests continue to work
- ✅ New manifests have enhanced I/O schema
- ✅ Old manifests can be upgraded (optional)

---

## Testing Strategy

### Phase 1 Testing
- Test with existing BERT model (provide pre-tokenized inputs)
- Verify multi-input tensor creation
- Verify all inputs used in inference

### Phase 2 Testing
- Test with text input to BERT model
- Verify tokenization works
- Verify all inputs created from text

### Phase 3 Testing
- Test with enhanced manifests
- Verify I/O schema validation
- Verify preprocessing hints used

---

## Summary

**Core Changes:**
1. Enhanced metadata extraction (shapes, types)
2. Multi-input tensor creation
3. Preprocessing integration
4. Manifest I/O schema reading (optional)

**Axon Changes:**
1. Extract actual I/O names from models
2. Add preprocessing hints to manifest
3. Ensure tokenizer files in package

**Key Insight:** Core can work with minimal Axon changes (extracts from ONNX), but enhanced Axon manifests improve the experience and enable better validation.

