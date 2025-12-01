# Universal Model Plugin (UMP) Design
## Patent-Aligned Architecture for Universal ONNX Inference

**Patent Reference:** US-63/861,527 - Model Package Format (MPF) and Universal Model Plugin Architecture

## Executive Summary

This document describes the design for a **Universal Model Plugin (UMP)** that enables generic inference for all ONNX models without model-specific code. The UMP leverages:

1. **ONNX Model Metadata** - Extracts input/output schemas directly from ONNX files
2. **Axon Manifest I/O Schema** - Uses standardized MPF metadata for preprocessing hints
3. **ONNX Runtime Extensions** - Handles text tokenization and other preprocessing generically
4. **Metadata-Driven Inference** - Dynamically adapts to any model's requirements

**Feasibility:** ✅ **YES** - This is architecturally sound and aligns with the MLOS patent's vision of universal model execution.

---

## Problem Statement

### Current Limitations

The existing ONNX Runtime plugin has these limitations:

1. **Single Input Assumption** - Only handles first input (`input_names[0]`)
2. **Fixed Shape Assumption** - Assumes simple 2D shape `[1, input_size]`
3. **No Preprocessing** - Cannot handle text tokenization or other preprocessing
4. **No Multi-Input Support** - Cannot handle models like BERT with 3+ inputs
5. **No Metadata Extraction** - Doesn't query actual model input/output requirements

### Impact

- ❌ BERT models fail (need 3 inputs: `input_ids`, `attention_mask`, `token_type_ids`)
- ❌ Vision models may fail (need proper image preprocessing)
- ❌ NLP models fail (need text tokenization)
- ❌ Any model with multiple inputs fails

---

## Solution: Universal Model Plugin (UMP)

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Inference Request                        │
│  {"input": "Hello, MLOS!", "input_format": "text"}         │
└──────────────────────┬────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              UMP Preprocessing Layer                        │
│  • Extract model metadata from ONNX file                    │
│  • Read Axon manifest.yaml for I/O schema                  │
│  • Detect input format (text, image, tensor, etc.)          │
│  • Apply appropriate preprocessing:                        │
│    - Text → Tokenization (via ONNX Extensions or metadata) │
│    - Image → Normalization/Resize (via metadata)          │
│    - Tensor → Shape validation                             │
└──────────────────────┬────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│            ONNX Runtime Execution                           │
│  • Create tensors for ALL inputs (not just first)          │
│  • Use actual model input names and shapes                 │
│  • Execute inference with proper tensor types             │
└──────────────────────┬────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              UMP Postprocessing Layer                      │
│  • Extract outputs for ALL outputs (not just first)        │
│  • Apply postprocessing if needed (detokenization, etc.)  │
│  • Format response according to output schema              │
└──────────────────────┬────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                    Inference Response                       │
│  {"status": "success", "output": {...}}                    │
└─────────────────────────────────────────────────────────────┘
```

---

## Design Components

### 1. Model Metadata Extraction

**Extract from ONNX File:**

```c
typedef struct {
    char name[256];
    ONNXTensorElementDataType dtype;
    int64_t shape[8];  // Max 8 dimensions
    size_t num_dims;
    bool is_dynamic;  // Has dynamic dimensions
} onnx_tensor_spec_t;

typedef struct {
    onnx_tensor_spec_t inputs[16];  // Max 16 inputs
    onnx_tensor_spec_t outputs[16];  // Max 16 outputs
    size_t num_inputs;
    size_t num_outputs;
    char model_type[64];  // "nlp", "vision", "audio", "generic"
    bool needs_tokenization;  // Detected from input names/types
} onnx_model_metadata_t;

// Extract metadata from ONNX model
smi_status_t extract_onnx_metadata(const char* onnx_path, 
                                   onnx_model_metadata_t* metadata);
```

**Key Information Extracted:**
- Input/output names (e.g., `input_ids`, `attention_mask`, `token_type_ids`)
- Input/output shapes (e.g., `[batch_size, sequence_length]`)
- Data types (e.g., `INT64`, `FLOAT32`)
- Dynamic dimensions detection
- Model type inference (from input names/patterns)

### 2. Axon Manifest I/O Schema Integration

**Read from manifest.yaml:**

```yaml
spec:
  io:
    inputs:
      - name: input_ids
        dtype: int64
        shape: [-1, -1]  # batch_size, sequence_length
        description: "Token IDs from tokenizer"
      - name: attention_mask
        dtype: int64
        shape: [-1, -1]
        description: "Attention mask"
      - name: token_type_ids
        dtype: int64
        shape: [-1, -1]
        description: "Token type IDs"
    outputs:
      - name: logits
        dtype: float32
        shape: [-1, -1, 30522]  # batch, sequence, vocab_size
```

**Use Cases:**
- Validate input shapes match model expectations
- Provide hints for preprocessing (e.g., "needs tokenization")
- Document expected input formats
- Enable automatic preprocessing selection

### 3. Preprocessing Pipeline

**Text Tokenization (NLP Models):**

```c
typedef struct {
    char tokenizer_path[512];  // Path to tokenizer.json in Axon package
    char tokenizer_type[64];    // "bert", "gpt2", "t5", etc.
    bool has_attention_mask;
    bool has_token_type_ids;
} tokenizer_config_t;

// Detect if model needs tokenization
bool needs_tokenization(const onnx_model_metadata_t* metadata);

// Tokenize text input
smi_status_t tokenize_input(const char* text,
                            const tokenizer_config_t* config,
                            int64_t** input_ids,
                            int64_t** attention_mask,
                            int64_t** token_type_ids,
                            size_t* sequence_length);
```

**Options for Tokenization:**

1. **ONNX Runtime Extensions** (Recommended)
   - Use `onnxruntime-extensions` library
   - Integrate tokenization as ONNX operators
   - Works generically for all tokenizer types

2. **Metadata-Driven Tokenization**
   - Read `tokenizer.json` from Axon package
   - Use tokenizer metadata to determine tokenization approach
   - Fall back to ONNX Extensions if available

3. **Preprocessing ONNX Model**
   - Some models include preprocessing in the ONNX graph
   - Detect and use if present

**Image Preprocessing (Vision Models):**

```c
typedef struct {
    int target_width;
    int target_height;
    float mean[3];      // Normalization mean
    float std[3];       // Normalization std
    bool normalize;
    bool resize;
} image_preprocessing_config_t;

// Preprocess image input
smi_status_t preprocess_image(const void* image_data,
                              size_t image_size,
                              const image_preprocessing_config_t* config,
                              float** tensor_data,
                              size_t* tensor_size);
```

### 4. Multi-Input Tensor Creation

**Create ALL Input Tensors:**

```c
// Create input tensors for all model inputs
smi_status_t create_input_tensors(
    const onnx_model_metadata_t* metadata,
    const void* raw_input,
    size_t raw_input_size,
    const char* input_format,  // "text", "image", "tensor", "json"
    OrtValue** input_tensors,  // Array of input tensors
    size_t* num_inputs
);
```

**Logic:**
1. Extract model metadata (input names, shapes, types)
2. Determine preprocessing needed based on:
   - Input format from request
   - Model metadata (input names suggest model type)
   - Axon manifest hints
3. Apply preprocessing:
   - Text → Tokenization → Multiple tensors (input_ids, attention_mask, etc.)
   - Image → Normalization → Single tensor
   - Tensor → Shape validation → Direct use
4. Create ONNX Runtime tensors for ALL inputs

### 5. Multi-Output Extraction

**Extract ALL Outputs:**

```c
// Extract outputs for all model outputs
smi_status_t extract_outputs(
    OrtValue** output_tensors,
    size_t num_outputs,
    const onnx_model_metadata_t* metadata,
    char* json_output,
    size_t* output_size
);
```

**Logic:**
1. Extract all output tensors from ONNX Runtime
2. Convert to appropriate format (JSON, binary, etc.)
3. Apply postprocessing if needed (detokenization, etc.)
4. Format response with all outputs

---

## Implementation Plan

### Phase 1: Metadata Extraction ✅ (Foundation)

**Tasks:**
- [x] Extract input/output names from ONNX model
- [x] Extract input/output shapes and types
- [ ] Detect model type (NLP, vision, audio, generic)
- [ ] Store metadata in model state

**Code Location:** `core/plugins/builtin/onnx_runtime_plugin.c`

### Phase 2: Multi-Input Support

**Tasks:**
- [ ] Create tensors for ALL inputs (not just first)
- [ ] Use actual input names from metadata
- [ ] Handle dynamic shapes properly
- [ ] Support different data types per input

**Key Changes:**
```c
// OLD: Only first input
const char* input_name = model_state->input_names[0];
const char* input_names[] = {input_name};
OrtValue* input_tensors[] = {input_tensor};

// NEW: All inputs
const char* input_names[16];
OrtValue* input_tensors[16];
for (size_t i = 0; i < model_state->num_inputs; i++) {
    input_names[i] = model_state->input_names[i];
    // Create tensor for each input
}
```

### Phase 3: Preprocessing Integration

**Tasks:**
- [ ] Integrate ONNX Runtime Extensions for tokenization
- [ ] Read tokenizer config from Axon package
- [ ] Implement text tokenization
- [ ] Implement image preprocessing
- [ ] Add preprocessing detection logic

**Dependencies:**
- ONNX Runtime Extensions library
- Tokenizer files in Axon packages

### Phase 4: Axon Manifest Integration

**Tasks:**
- [ ] Read I/O schema from manifest.yaml
- [ ] Use schema for input validation
- [ ] Use schema for preprocessing hints
- [ ] Validate inputs match schema

**Integration Point:** `core/src/axon_manifest_reader.c`

### Phase 5: Postprocessing

**Tasks:**
- [ ] Extract all outputs
- [ ] Format outputs according to schema
- [ ] Apply postprocessing if needed (detokenization, etc.)

---

## Example: BERT Model Inference

### Current (Fails)

```c
// Only creates one input tensor
input_name = "input_ids";  // Wrong - only first input
input_shape = [1, input_size];  // Wrong - doesn't match model
// Missing: attention_mask, token_type_ids
```

### With UMP (Works)

```c
// 1. Extract metadata
metadata.num_inputs = 3;
metadata.inputs[0] = {name: "input_ids", shape: [1, 128], dtype: INT64};
metadata.inputs[1] = {name: "attention_mask", shape: [1, 128], dtype: INT64};
metadata.inputs[2] = {name: "token_type_ids", shape: [1, 128], dtype: INT64};

// 2. Detect preprocessing needed
needs_tokenization = true;  // Detected from input names

// 3. Apply preprocessing
tokenize_input("Hello, MLOS!", &tokenizer_config,
               &input_ids, &attention_mask, &token_type_ids, &seq_len);

// 4. Create all input tensors
create_tensor(input_ids, shape=[1, seq_len], dtype=INT64, &tensor0);
create_tensor(attention_mask, shape=[1, seq_len], dtype=INT64, &tensor1);
create_tensor(token_type_ids, shape=[1, seq_len], dtype=INT64, &tensor2);

// 5. Run inference with all inputs
OrtRun(session, run_options,
       input_names, input_tensors, 3,  // All 3 inputs
       output_names, output_tensors, 1);

// 6. Extract all outputs
extract_outputs(output_tensors, 1, &metadata, json_output, &output_size);
```

---

## Feasibility Analysis

### ✅ **YES - This is Feasible**

**Reasons:**

1. **ONNX Standardization**
   - All ONNX models follow the same format
   - Metadata is always extractable
   - ONNX Runtime handles execution generically

2. **Industry Best Practices**
   - ONNX Runtime Extensions already solve preprocessing
   - Many systems use metadata-driven inference
   - Pattern is proven (TensorFlow Serving, TorchServe, etc.)

3. **Patent Alignment**
   - Aligns with US-63/861,527's "Universal Model Plugin" concept
   - Enables "deployment-agnostic execution"
   - Supports "Model Package Format (MPF)" with standardized I/O

4. **Technical Feasibility**
   - ONNX Runtime C API supports all required operations
   - Metadata extraction is straightforward
   - Preprocessing can be generic (tokenization libraries exist)

### Challenges and Solutions

| Challenge | Solution |
|-----------|----------|
| **Text Tokenization** | Use ONNX Runtime Extensions or read tokenizer.json from Axon package |
| **Multiple Inputs** | Extract all input names/shapes from ONNX metadata, create all tensors |
| **Dynamic Shapes** | Use ONNX Runtime's shape inference, validate against manifest schema |
| **Different Data Types** | Extract dtype from ONNX metadata, create tensors with correct types |
| **Preprocessing Overhead** | Cache preprocessing results, optimize tokenization paths |

---

## Patent Alignment

### US-63/861,527: Universal Model Plugin (UMP)

**Patent Claim:** "Universal Model Plugin that enables deployment-agnostic execution of models from any repository without framework-specific code."

**Implementation:**
- ✅ **Universal Coverage**: Works with all ONNX models generically
- ✅ **Metadata-Driven**: Uses model metadata, not hardcoded logic
- ✅ **MPF Integration**: Leverages Axon manifest.yaml for I/O schema
- ✅ **Framework-Agnostic**: ONNX is the universal format

**Key Innovation:**
The UMP achieves true universality by:
1. **Extracting requirements from models** (not hardcoding)
2. **Using standardized metadata** (ONNX + MPF)
3. **Generic preprocessing** (tokenization, normalization, etc.)
4. **Dynamic adaptation** (works with any model structure)

---

## API Design

### Enhanced Inference Request

```json
{
  "model_id": "hf/bert-base-uncased@latest",
  "input": "Hello, MLOS!",
  "input_format": "text",  // "text", "image", "tensor", "json"
  "preprocessing": "auto",  // "auto", "none", "custom"
  "output_format": "json"   // "json", "tensor", "binary"
}
```

### Enhanced Inference Response

```json
{
  "status": "success",
  "model_id": "hf/bert-base-uncased@latest",
  "outputs": {
    "logits": [[0.1, 0.2, ...]],  // All outputs included
    "pooler_output": [[...]]
  },
  "inference_time_us": 1234,
  "metadata": {
    "inputs_processed": 3,
    "outputs_generated": 1,
    "preprocessing_applied": "tokenization"
  }
}
```

---

## Testing Strategy

### Test Cases

1. **BERT Model (3 inputs)**
   - Input: Text string
   - Expected: Tokenization → 3 input tensors → Inference → Output

2. **Vision Model (1 input)**
   - Input: Image data
   - Expected: Normalization → 1 input tensor → Inference → Output

3. **Generic Model (1 input)**
   - Input: Tensor array
   - Expected: Direct tensor → Inference → Output

4. **Multi-Output Model**
   - Input: Tensor
   - Expected: Inference → Multiple outputs extracted

---

## Performance Considerations

1. **Metadata Caching**: Cache extracted metadata per model
2. **Preprocessing Optimization**: Optimize tokenization paths
3. **Tensor Reuse**: Reuse tensor buffers where possible
4. **Batch Support**: Support batch inference for efficiency

---

## Conclusion

**The Universal Model Plugin (UMP) is not only feasible but aligns perfectly with the MLOS patent's vision of universal model execution.**

**Key Benefits:**
- ✅ Works with ALL ONNX models generically
- ✅ No model-specific code required
- ✅ Handles preprocessing automatically
- ✅ Supports multiple inputs/outputs
- ✅ Patent-aligned architecture

**Next Steps:**
1. Implement Phase 1 (metadata extraction) - ✅ Partially done
2. Implement Phase 2 (multi-input support) - 🔄 In progress
3. Integrate ONNX Runtime Extensions for preprocessing
4. Complete Axon manifest integration
5. Comprehensive testing

---

## References

- [ONNX Runtime C API](https://onnxruntime.ai/docs/api/c/)
- [ONNX Runtime Extensions](https://onnxruntime.ai/docs/extensions/)
- [ONNX Model Format](https://github.com/onnx/onnx)
- [MLOS Patent US-63/861,527](PATENTS.md)
- [Built-in ONNX Plugin Design](BUILTIN_ONNX_PLUGIN.md)

