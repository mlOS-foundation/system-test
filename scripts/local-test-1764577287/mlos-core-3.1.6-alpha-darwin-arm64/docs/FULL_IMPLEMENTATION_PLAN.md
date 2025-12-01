# Full Implementation Plan: Manifest-First Architecture
## No Migration Path - Direct Implementation (No Users Yet)

## Executive Summary

Since there are **no users yet**, we can implement the **full manifest-first architecture** directly without backward compatibility concerns. This enables:

1. **Format-agnostic Core** - Reads I/O from manifest, not ONNX
2. **Dynamic plugin selection** - Based on execution_format in manifest
3. **Multi-input support** - From manifest I/O schema
4. **Preprocessing integration** - From manifest hints

**No migration needed** - Clean implementation from the start.

---

## Implementation Overview

### Axon Repository Changes

**Goal:** Generate complete manifest with I/O schema and execution format

**Changes:**
1. Add `execution_format` to Format struct
2. Extract actual I/O schema from models (format-agnostic)
3. Add preprocessing hints to I/O schema
4. Ensure tokenizer files in package

### Core Repository Changes

**Goal:** Use manifest as source of truth for I/O and plugin selection

**Changes:**
1. Read I/O schema from manifest (not ONNX)
2. Dynamic plugin selection based on execution_format
3. Multi-input tensor creation from manifest
4. Preprocessing based on manifest hints

---

## Phase 1: Axon - Enhanced Manifest Generation

### 1.1 Add Execution Format to Manifest

**File:** `axon/pkg/types/manifest.go`

```go
// Format describes the model file format
type Format struct {
    Type            string   `yaml:"type"`              // Original format (pytorch, tensorflow)
    ExecutionFormat string   `yaml:"execution_format"`  // NEW: Execution format (onnx, pytorch, tensorflow)
    Files           []ModelFile `yaml:"files"`
}
```

**Default Logic:**
- If ONNX file exists → `execution_format: onnx`
- If PyTorch model → `execution_format: pytorch` (or `onnx` if converted)
- If TensorFlow model → `execution_format: tensorflow` (or `onnx` if converted)

### 1.2 Add Preprocessing to I/O Schema

**File:** `axon/pkg/types/manifest.go`

```go
// IOSpec describes an input or output
type IOSpec struct {
    Name        string `yaml:"name"`
    DType       string `yaml:"dtype"`
    Shape       []int  `yaml:"shape"`
    Description string `yaml:"description,omitempty"`
    
    // NEW: Preprocessing hints
    Preprocessing *PreprocessingSpec `yaml:"preprocessing,omitempty"`
}

// PreprocessingSpec describes preprocessing requirements
type PreprocessingSpec struct {
    Type         string                 `yaml:"type"`         // "tokenization", "normalization", "resize"
    Tokenizer    string                 `yaml:"tokenizer,omitempty"`    // Path to tokenizer.json
    TokenizerType string                `yaml:"tokenizer_type,omitempty"` // "bert", "gpt2", etc.
    Config       map[string]interface{} `yaml:"config,omitempty"`       // Normalization params, etc.
}
```

### 1.3 Extract I/O Schema from Models

**File:** `axon/internal/registry/builtin/huggingface.go`

**Add function:**
```go
// extractIOSchema extracts I/O schema from Hugging Face model
func (h *HuggingFaceAdapter) extractIOSchema(modelPath string) ([]types.IOSpec, []types.IOSpec, error) {
    // Read model config
    configPath := filepath.Join(modelPath, "config.json")
    config, err := loadModelConfig(configPath)
    if err != nil {
        return nil, nil, err
    }
    
    // Detect model type from config
    modelType := config["model_type"].(string)
    
    // Extract inputs based on model type
    var inputs []types.IOSpec
    switch modelType {
    case "bert", "roberta", "distilbert":
        inputs = []types.IOSpec{
            {
                Name:  "input_ids",
                DType: "int64",
                Shape: []int{-1, -1}, // batch_size, sequence_length
                Preprocessing: &types.PreprocessingSpec{
                    Type:         "tokenization",
                    Tokenizer:    "tokenizer.json",
                    TokenizerType: modelType,
                },
            },
            {
                Name:  "attention_mask",
                DType: "int64",
                Shape: []int{-1, -1},
                Preprocessing: &types.PreprocessingSpec{
                    Type:         "tokenization",
                    Tokenizer:    "tokenizer.json",
                    TokenizerType: modelType,
                },
            },
            {
                Name:  "token_type_ids",
                DType: "int64",
                Shape: []int{-1, -1},
                Preprocessing: &types.PreprocessingSpec{
                    Type:         "tokenization",
                    Tokenizer:    "tokenizer.json",
                    TokenizerType: modelType,
                },
            },
        }
    case "gpt2", "gpt":
        inputs = []types.IOSpec{
            {
                Name:  "input_ids",
                DType: "int64",
                Shape: []int{-1, -1},
                Preprocessing: &types.PreprocessingSpec{
                    Type:         "tokenization",
                    Tokenizer:    "tokenizer.json",
                    TokenizerType: "gpt2",
                },
            },
            {
                Name:  "attention_mask",
                DType: "int64",
                Shape: []int{-1, -1},
                Preprocessing: &types.PreprocessingSpec{
                    Type:         "tokenization",
                    Tokenizer:    "tokenizer.json",
                    TokenizerType: "gpt2",
                },
            },
        }
    // Add more model types...
    }
    
    // Extract outputs (typically logits, pooler_output, etc.)
    outputs := []types.IOSpec{
        {
            Name:  "logits",
            DType: "float32",
            Shape: []int{-1, -1, -1}, // batch, sequence, vocab_size
        },
    }
    
    return inputs, outputs, nil
}
```

**Update manifest generation:**
```go
// In CreateManifest or similar function
inputs, outputs, err := h.extractIOSchema(modelPath)
if err == nil {
    manifest.Spec.IO.Inputs = inputs
    manifest.Spec.IO.Outputs = outputs
} else {
    // Fallback to generic I/O
    manifest.Spec.IO.Inputs = []types.IOSpec{
        {Name: "input", DType: "float32", Shape: []int{-1, -1}},
    }
    manifest.Spec.IO.Outputs = []types.IOSpec{
        {Name: "output", DType: "float32", Shape: []int{-1, -1}},
    }
}

// Set execution format
if hasONNXFile(modelPath) {
    manifest.Spec.Format.ExecutionFormat = "onnx"
} else {
    manifest.Spec.Format.ExecutionFormat = strings.ToLower(manifest.Spec.Framework.Name)
}
```

### 1.4 Ensure Tokenizer Files in Package

**File:** `axon/internal/registry/builtin/huggingface.go`

**Update DownloadPackage:**
```go
// Ensure tokenizer files are included
tokenizerFiles := []string{
    "tokenizer.json",
    "tokenizer_config.json",
    "vocab.txt",
}

for _, file := range tokenizerFiles {
    // Check if file exists in model
    // Add to package if exists
}
```

---

## Phase 2: Core - Manifest I/O Reader

### 2.1 Add I/O Schema Structures

**File:** `core/include/axon_manifest_reader.h`

```c
// I/O schema structures
typedef struct {
    char name[256];
    char dtype[32];
    int64_t shape[8];
    size_t num_dims;
    bool is_dynamic;
    
    // Preprocessing hints
    char preprocessing_type[64];      // "tokenization", "normalization", etc.
    char tokenizer_path[512];         // Path to tokenizer.json
    char tokenizer_type[64];          // "bert", "gpt2", etc.
    bool has_preprocessing;
} axon_io_spec_t;

typedef struct {
    axon_io_spec_t inputs[16];
    axon_io_spec_t outputs[16];
    size_t num_inputs;
    size_t num_outputs;
} axon_io_schema_t;

// Execution format
typedef enum {
    EXEC_FORMAT_ONNX = 0,
    EXEC_FORMAT_PYTORCH,
    EXEC_FORMAT_TENSORFLOW,
    EXEC_FORMAT_UNKNOWN
} execution_format_t;
```

### 2.2 Implement I/O Schema Reader

**File:** `core/src/axon_manifest_reader.c`

**Add function:**
```c
/**
 * Read I/O schema from Axon manifest
 * This is the source of truth for model I/O (format-agnostic)
 */
int axon_read_io_schema(const char* manifest_path, axon_io_schema_t* io_schema) {
    if (!manifest_path || !io_schema) {
        return -1;
    }
    
    FILE* file = fopen(manifest_path, "r");
    if (!file) {
        return -1;
    }
    
    // Read entire file
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    
    char* content = malloc(size + 1);
    if (!content) {
        fclose(file);
        return -1;
    }
    
    fread(content, 1, size, file);
    content[size] = '\0';
    fclose(file);
    
    // Parse YAML/JSON to extract I/O schema
    // Look for spec.io.inputs and spec.io.outputs
    
    // Parse inputs
    char* inputs_start = strstr(content, "\"Inputs\"");
    if (!inputs_start) inputs_start = strstr(content, "inputs:");
    
    if (inputs_start) {
        // Parse input array
        // Extract name, dtype, shape, preprocessing
        // Store in io_schema->inputs[]
    }
    
    // Parse outputs (similar)
    
    free(content);
    return 0;
}

/**
 * Read execution format from manifest
 */
execution_format_t axon_read_execution_format(const char* manifest_path) {
    // Parse manifest
    // Look for spec.format.execution_format
    // Return appropriate enum value
    
    FILE* file = fopen(manifest_path, "r");
    if (!file) {
        return EXEC_FORMAT_UNKNOWN;
    }
    
    // Read and parse
    // Look for "execution_format" or "ExecutionFormat"
    // Return EXEC_FORMAT_ONNX, EXEC_FORMAT_PYTORCH, etc.
    
    fclose(file);
    return EXEC_FORMAT_ONNX; // Default
}
```

---

## Phase 3: Core - Dynamic Plugin Selection

### 3.1 Update Plugin Selection Logic

**File:** `core/src/mlos_core.c`

**Replace hardcoded ONNX selection:**
```c
int mlos_register_model(mlos_core_t* core, const char* plugin_id,
                        const smi_model_metadata_t* metadata, char* model_id,
                        const char* model_path) {
    // ...
    
    if (!plugin_id || plugin_id[0] == '\0') {
        // NEW: Read execution format from manifest
        char manifest_path[512];
        snprintf(manifest_path, sizeof(manifest_path), "%s/manifest.yaml", model_path);
        
        execution_format_t format = axon_read_execution_format(manifest_path);
        
        // Select plugin based on format (dynamic, not hardcoded)
        const char* selected_plugin_id = NULL;
        switch (format) {
        case EXEC_FORMAT_ONNX:
            selected_plugin_id = "onnx-runtime-builtin";
            break;
        case EXEC_FORMAT_PYTORCH:
            selected_plugin_id = "pytorch-plugin";
            break;
        case EXEC_FORMAT_TENSORFLOW:
            selected_plugin_id = "tensorflow-plugin";
            break;
        default:
            // Fallback to ONNX if format unknown
            selected_plugin_id = "onnx-runtime-builtin";
            break;
        }
        
        // Find plugin
        for (size_t i = 0; i < core->num_plugins; i++) {
            if (core->plugins[i].loaded && core->plugins[i].plugin) {
                if (strcmp(core->plugins[i].plugin->plugin_id, selected_plugin_id) == 0) {
                    plugin = core->plugins[i].plugin;
                    printf("🔌 Auto-selected plugin '%s' based on manifest format\n", selected_plugin_id);
                    break;
                }
            }
        }
    }
    
    // ...
}
```

---

## Phase 4: Core - Multi-Input Support

### 4.1 Read I/O Schema During Model Load

**File:** `core/plugins/builtin/onnx_runtime_plugin.c`

**Update onnx_load_model:**
```c
static smi_status_t onnx_load_model(smi_model_handle_t handle, const char* path) {
    // ...
    
    // NEW: Read I/O schema from manifest (source of truth)
    char manifest_path[512];
    snprintf(manifest_path, sizeof(manifest_path), "%s/manifest.yaml", path);
    
    axon_io_schema_t io_schema = {0};
    if (axon_read_io_schema(manifest_path, &io_schema) == 0) {
        // Store I/O schema in model state
        model_state->num_inputs = io_schema.num_inputs;
        model_state->num_outputs = io_schema.num_outputs;
        
        for (size_t i = 0; i < io_schema.num_inputs; i++) {
            // Store input specs
            strncpy(model_state->input_names[i], io_schema.inputs[i].name, 255);
            // Store shapes, types, preprocessing hints
        }
        
        printf("✅ Loaded I/O schema from manifest: %zu inputs, %zu outputs\n",
               io_schema.num_inputs, io_schema.num_outputs);
    } else {
        // Fallback: Extract from ONNX (if manifest missing)
        // ... existing ONNX extraction code ...
    }
    
    // ...
}
```

### 4.2 Multi-Input Tensor Creation

**File:** `core/plugins/builtin/onnx_runtime_plugin.c`

**Update onnx_inference:**
```c
static smi_status_t onnx_inference(smi_model_handle_t handle,
                                   const void* input, size_t input_size,
                                   void* output, size_t* output_size) {
    // ...
    
    // NEW: Create tensors for ALL inputs (not just first)
    OrtValue* input_tensors[16] = {NULL};
    const char* input_names[16] = {NULL};
    
    for (size_t i = 0; i < model_state->num_inputs; i++) {
        // Get input spec from model state
        const char* input_name = model_state->input_names[i];
        
        // Create tensor based on input spec
        // Use shape, dtype from manifest I/O schema
        
        // Apply preprocessing if needed
        if (model_state->input_specs[i].has_preprocessing) {
            // Apply preprocessing (tokenization, normalization, etc.)
            preprocess_input(input, input_size, &model_state->input_specs[i],
                           &input_tensors[i]);
        } else {
            // Create tensor directly
            create_tensor_from_input(input, input_size, &model_state->input_specs[i],
                                   &input_tensors[i]);
        }
        
        input_names[i] = input_name;
    }
    
    // Run inference with ALL inputs
    status = g_plugin_state.api->Run(
        model_state->session,
        run_options,
        input_names,
        (const OrtValue* const*)input_tensors,
        model_state->num_inputs,  // ALL inputs
        output_names,
        model_state->num_outputs,  // ALL outputs
        output_tensors
    );
    
    // ...
}
```

---

## Phase 5: Core - Preprocessing Integration

### 5.1 Preprocessing Functions

**File:** `core/plugins/builtin/onnx_runtime_plugin.c`

**Add preprocessing:**
```c
// Tokenization
smi_status_t tokenize_input(const char* text,
                            const axon_io_spec_t* input_spec,
                            int64_t** input_ids,
                            int64_t** attention_mask,
                            int64_t** token_type_ids,
                            size_t* sequence_length) {
    // Read tokenizer.json from package
    char tokenizer_path[512];
    snprintf(tokenizer_path, sizeof(tokenizer_path), "%s/%s",
             model_path, input_spec->tokenizer_path);
    
    // Load tokenizer
    // Tokenize text
    // Return token IDs, attention mask, token type IDs
    
    return SMI_SUCCESS;
}

// Image preprocessing
smi_status_t preprocess_image(const void* image_data,
                              size_t image_size,
                              const axon_io_spec_t* input_spec,
                              float** tensor_data,
                              size_t* tensor_size) {
    // Normalize, resize based on input_spec config
    return SMI_SUCCESS;
}
```

---

## Implementation Checklist

### Axon Repository

- [ ] Add `execution_format` to `Format` struct
- [ ] Add `PreprocessingSpec` to `IOSpec` struct
- [ ] Implement `extractIOSchema()` for Hugging Face models
- [ ] Implement `extractIOSchema()` for PyTorch models
- [ ] Implement `extractIOSchema()` for TensorFlow models
- [ ] Update manifest generation to use extracted I/O schema
- [ ] Set `execution_format` based on available formats
- [ ] Ensure tokenizer files included in package
- [ ] Update tests

### Core Repository

- [ ] Add `axon_io_schema_t` structures to header
- [ ] Add `execution_format_t` enum
- [ ] Implement `axon_read_io_schema()`
- [ ] Implement `axon_read_execution_format()`
- [ ] Update plugin selection to use execution_format
- [ ] Update model load to read I/O from manifest
- [ ] Implement multi-input tensor creation
- [ ] Implement preprocessing functions
- [ ] Update inference to use all inputs
- [ ] Update tests

---

## Testing Strategy

### Unit Tests

**Axon:**
- Test I/O schema extraction for BERT models
- Test I/O schema extraction for GPT models
- Test execution_format setting
- Test preprocessing hints generation

**Core:**
- Test manifest I/O schema reading
- Test execution_format reading
- Test plugin selection based on format
- Test multi-input tensor creation

### Integration Tests

- End-to-end: Install BERT → Register → Inference with text input
- Verify all 3 inputs created (input_ids, attention_mask, token_type_ids)
- Verify preprocessing applied
- Verify inference succeeds

---

## Benefits of Full Implementation

1. **Clean Architecture** - No legacy code, no migration complexity
2. **Format-Agnostic** - Core truly independent of execution format
3. **Future-Proof** - Easy to add new formats/plugins
4. **Complete** - All features from the start (multi-input, preprocessing, dynamic selection)

---

## Timeline Estimate

- **Axon Changes:** 2-3 days
- **Core Changes:** 3-4 days
- **Testing:** 2 days
- **Total:** ~1-2 weeks

---

## Conclusion

Since there are **no users yet**, we can implement the **full manifest-first architecture** directly:

- ✅ **No migration path needed**
- ✅ **Clean implementation**
- ✅ **All features from start**
- ✅ **Format-agnostic Core**
- ✅ **Dynamic plugin selection**

This gives us a **beautiful, future-proof architecture** from day one.

