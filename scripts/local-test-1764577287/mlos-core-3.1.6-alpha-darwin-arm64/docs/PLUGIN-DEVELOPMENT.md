# Plugin Development Guide

## Overview

MLOS Core uses the Standard Model Interface (SMI) to provide a unified plugin architecture for ML frameworks. This guide shows how to develop plugins in different languages.

## SMI Specification

All plugins must implement the SMI interface defined in `core/include/smi_spec.h`:

```c
typedef struct {
    // Plugin lifecycle
    smi_status_t (*initialize)(const char* config);
    smi_status_t (*cleanup)(void);
    
    // Model management
    smi_status_t (*register_model)(const smi_model_metadata_t* metadata, 
                                   smi_model_handle_t* handle);
    smi_status_t (*unregister_model)(smi_model_handle_t handle);
    
    // Model operations
    smi_status_t (*load_model)(smi_model_handle_t handle, const char* path);
    smi_status_t (*inference)(smi_model_handle_t handle, 
                              const void* input, size_t input_size,
                              void* output, size_t* output_size);
    
    // Resource management
    smi_status_t (*allocate_resources)(smi_model_handle_t handle,
                                       const smi_resource_req_t* requirements,
                                       size_t num_requirements);
    
    // Plugin information
    const char* (*get_plugin_name)(void);
    const char* (*get_plugin_version)(void);
} smi_plugin_interface_t;
```

## C Plugin Development

### 1. Basic Plugin Structure

```c
// my_plugin.c
#include "mlos/smi_spec.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Plugin state
typedef struct {
    bool initialized;
    char config_path[256];
    void* framework_context;
} my_plugin_state_t;

static my_plugin_state_t g_plugin_state = {0};

// Implementation functions
static smi_status_t my_initialize(const char* config) {
    printf("Initializing My ML Plugin with config: %s\n", config ? config : "default");
    
    if (config) {
        strncpy(g_plugin_state.config_path, config, sizeof(g_plugin_state.config_path) - 1);
    }
    
    // Initialize your ML framework here
    // g_plugin_state.framework_context = initialize_framework();
    
    g_plugin_state.initialized = true;
    return SMI_SUCCESS;
}

static smi_status_t my_cleanup(void) {
    if (!g_plugin_state.initialized) {
        return SMI_ERROR_INVALID_PARAM;
    }
    
    // Cleanup your ML framework
    // cleanup_framework(g_plugin_state.framework_context);
    
    g_plugin_state.initialized = false;
    printf("My ML Plugin cleaned up\n");
    return SMI_SUCCESS;
}

static smi_status_t my_register_model(const smi_model_metadata_t* metadata, 
                                      smi_model_handle_t* handle) {
    if (!metadata || !handle) {
        return SMI_ERROR_INVALID_PARAM;
    }
    
    printf("Registering model: %s (framework: %s)\n", metadata->name, metadata->framework);
    
    // Create model handle
    // *handle = create_model_handle(metadata);
    *handle = (void*)0x12345678; // Mock handle
    
    return SMI_SUCCESS;
}

static smi_status_t my_inference(smi_model_handle_t handle, 
                                 const void* input, size_t input_size,
                                 void* output, size_t* output_size) {
    if (!handle || !input || !output || !output_size) {
        return SMI_ERROR_INVALID_PARAM;
    }
    
    printf("Running inference (input size: %zu)\n", input_size);
    
    // Mock inference - copy input to output
    size_t copy_size = input_size < *output_size ? input_size : *output_size;
    memcpy(output, input, copy_size);
    *output_size = copy_size;
    
    return SMI_SUCCESS;
}

static const char* my_get_plugin_name(void) {
    return "My ML Plugin";
}

static const char* my_get_plugin_version(void) {
    return "1.0.0";
}

// Plugin interface
static smi_plugin_interface_t my_interface = {
    .initialize = my_initialize,
    .cleanup = my_cleanup,
    .register_model = my_register_model,
    .unregister_model = NULL, // Optional
    .load_model = NULL,       // Optional
    .unload_model = NULL,     // Optional
    .inference = my_inference,
    .batch_inference = NULL,  // Optional
    .allocate_resources = NULL, // Optional
    .deallocate_resources = NULL, // Optional
    .get_model_info = NULL,   // Optional
    .get_plugin_name = my_get_plugin_name,
    .get_plugin_version = my_get_plugin_version,
    .get_supported_frameworks = NULL, // Optional
    .get_smi_version = NULL   // Optional
};

// Plugin descriptor
static smi_plugin_t my_plugin = {
    .interface = my_interface,
    .plugin_id = "my-ml-plugin",
    .smi_version = (SMI_VERSION_MAJOR << 16) | (SMI_VERSION_MINOR << 8) | SMI_VERSION_PATCH,
    .private_data = &g_plugin_state
};

// Plugin entry point (required)
smi_plugin_t* smi_plugin_init(void) {
    return &my_plugin;
}
```

### 2. Build System

```makefile
# Makefile for C plugin
CC = gcc
CFLAGS = -Wall -Wextra -std=c99 -fPIC -O2
LDFLAGS = -shared

PLUGIN_NAME = libmlos_my_plugin.so
SOURCES = my_plugin.c

$(PLUGIN_NAME): $(SOURCES)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

clean:
	rm -f $(PLUGIN_NAME)

install: $(PLUGIN_NAME)
	cp $(PLUGIN_NAME) /usr/local/lib/mlos/plugins/

.PHONY: clean install
```

## Python Plugin Development

### 1. Python Wrapper

```c
// python_plugin_wrapper.c
#include "mlos/smi_spec.h"
#include <Python.h>
#include <stdio.h>

static PyObject* g_python_plugin = NULL;

static smi_status_t python_initialize(const char* config) {
    Py_Initialize();
    
    // Import Python plugin module
    PyObject* module_name = PyUnicode_FromString("my_python_plugin");
    PyObject* module = PyImport_Import(module_name);
    Py_DECREF(module_name);
    
    if (!module) {
        PyErr_Print();
        return SMI_ERROR_RUNTIME;
    }
    
    // Get plugin class
    PyObject* plugin_class = PyObject_GetAttrString(module, "MyPythonPlugin");
    if (!plugin_class) {
        Py_DECREF(module);
        return SMI_ERROR_RUNTIME;
    }
    
    // Create plugin instance
    g_python_plugin = PyObject_CallObject(plugin_class, NULL);
    Py_DECREF(plugin_class);
    Py_DECREF(module);
    
    if (!g_python_plugin) {
        PyErr_Print();
        return SMI_ERROR_RUNTIME;
    }
    
    // Call initialize method
    PyObject* config_str = config ? PyUnicode_FromString(config) : Py_None;
    PyObject* result = PyObject_CallMethod(g_python_plugin, "initialize", "O", config_str);
    
    if (config_str != Py_None) {
        Py_DECREF(config_str);
    }
    
    if (!result) {
        PyErr_Print();
        return SMI_ERROR_RUNTIME;
    }
    
    Py_DECREF(result);
    return SMI_SUCCESS;
}

static smi_status_t python_inference(smi_model_handle_t handle, 
                                     const void* input, size_t input_size,
                                     void* output, size_t* output_size) {
    if (!g_python_plugin) {
        return SMI_ERROR_INVALID_PARAM;
    }
    
    // Convert input to Python bytes
    PyObject* input_bytes = PyBytes_FromStringAndSize((const char*)input, input_size);
    
    // Call inference method
    PyObject* result = PyObject_CallMethod(g_python_plugin, "inference", "KO", 
                                          (unsigned long long)handle, input_bytes);
    Py_DECREF(input_bytes);
    
    if (!result) {
        PyErr_Print();
        return SMI_ERROR_RUNTIME;
    }
    
    // Extract output
    if (PyBytes_Check(result)) {
        Py_ssize_t result_size = PyBytes_Size(result);
        if ((size_t)result_size <= *output_size) {
            memcpy(output, PyBytes_AsString(result), result_size);
            *output_size = result_size;
        } else {
            Py_DECREF(result);
            return SMI_ERROR_OUT_OF_MEMORY;
        }
    }
    
    Py_DECREF(result);
    return SMI_SUCCESS;
}

// ... implement other interface functions

static smi_plugin_interface_t python_interface = {
    .initialize = python_initialize,
    .inference = python_inference,
    // ... other functions
};

static smi_plugin_t python_plugin = {
    .interface = python_interface,
    .plugin_id = "python-ml-plugin",
    .smi_version = (SMI_VERSION_MAJOR << 16) | (SMI_VERSION_MINOR << 8) | SMI_VERSION_PATCH
};

smi_plugin_t* smi_plugin_init(void) {
    return &python_plugin;
}
```

### 2. Python Implementation

```python
# my_python_plugin.py
import numpy as np
import torch
import logging

class MyPythonPlugin:
    def __init__(self):
        self.models = {}
        self.device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
        self.logger = logging.getLogger('MyPythonPlugin')
    
    def initialize(self, config=None):
        """Initialize the plugin"""
        self.logger.info(f"Initializing Python plugin with config: {config}")
        
        # Parse configuration
        if config:
            # Parse JSON config, set device, etc.
            pass
            
        return 0  # SMI_SUCCESS
    
    def register_model(self, handle, metadata):
        """Register a new model"""
        self.logger.info(f"Registering model: {metadata['name']}")
        
        # Store model metadata
        self.models[handle] = {
            'metadata': metadata,
            'model': None,
            'loaded': False
        }
        
        return 0  # SMI_SUCCESS
    
    def load_model(self, handle, model_path):
        """Load model from file"""
        if handle not in self.models:
            return -3  # SMI_ERROR_NOT_FOUND
        
        try:
            # Load PyTorch model
            model = torch.load(model_path, map_location=self.device)
            model.eval()
            
            self.models[handle]['model'] = model
            self.models[handle]['loaded'] = True
            
            self.logger.info(f"Model loaded: {model_path}")
            return 0  # SMI_SUCCESS
            
        except Exception as e:
            self.logger.error(f"Failed to load model: {e}")
            return -5  # SMI_ERROR_RUNTIME
    
    def inference(self, handle, input_data):
        """Run inference on model"""
        if handle not in self.models:
            return None, -3  # SMI_ERROR_NOT_FOUND
        
        model_info = self.models[handle]
        if not model_info['loaded']:
            return None, -3  # SMI_ERROR_NOT_FOUND
        
        try:
            # Convert input to tensor
            if isinstance(input_data, bytes):
                # Assume input is serialized numpy array
                input_array = np.frombuffer(input_data, dtype=np.float32)
                input_tensor = torch.from_numpy(input_array).to(self.device)
            else:
                input_tensor = torch.tensor(input_data).to(self.device)
            
            # Run inference
            with torch.no_grad():
                output = model_info['model'](input_tensor)
            
            # Convert output to bytes
            output_array = output.cpu().numpy()
            output_bytes = output_array.tobytes()
            
            return output_bytes, 0  # SMI_SUCCESS
            
        except Exception as e:
            self.logger.error(f"Inference failed: {e}")
            return None, -5  # SMI_ERROR_RUNTIME
    
    def cleanup(self):
        """Cleanup plugin resources"""
        self.logger.info("Cleaning up Python plugin")
        
        # Clear models
        self.models.clear()
        
        # Clear CUDA cache if using GPU
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
        
        return 0  # SMI_SUCCESS
    
    def get_plugin_name(self):
        return "My Python ML Plugin"
    
    def get_plugin_version(self):
        return "1.0.0"
    
    def get_supported_frameworks(self):
        return "pytorch,numpy"
```

## Go Plugin Development

### 1. Go Plugin Implementation

```go
// my_go_plugin.go
package main

import "C"

import (
    "fmt"
    "unsafe"
    "encoding/json"
)

// Plugin state
type PluginState struct {
    Initialized bool
    Models      map[uintptr]*ModelInfo
}

type ModelInfo struct {
    Name      string
    Framework string
    Loaded    bool
    Model     interface{}
}

var pluginState = &PluginState{
    Models: make(map[uintptr]*ModelInfo),
}

//export smi_plugin_init
func smi_plugin_init() unsafe.Pointer {
    // Return plugin descriptor
    // Note: This is a simplified version
    // Real implementation would return proper C struct
    return unsafe.Pointer(uintptr(0x87654321))
}

//export go_initialize
func go_initialize(config *C.char) C.int {
    configStr := C.GoString(config)
    fmt.Printf("Initializing Go plugin with config: %s\n", configStr)
    
    // Parse configuration
    if configStr != "" {
        var configMap map[string]interface{}
        if err := json.Unmarshal([]byte(configStr), &configMap); err != nil {
            fmt.Printf("Failed to parse config: %v\n", err)
            return -1 // SMI_ERROR_INVALID_PARAM
        }
    }
    
    pluginState.Initialized = true
    return 0 // SMI_SUCCESS
}

//export go_register_model
func go_register_model(handle C.uintptr_t, name *C.char, framework *C.char) C.int {
    modelName := C.GoString(name)
    modelFramework := C.GoString(framework)
    
    fmt.Printf("Registering Go model: %s (framework: %s)\n", modelName, modelFramework)
    
    pluginState.Models[uintptr(handle)] = &ModelInfo{
        Name:      modelName,
        Framework: modelFramework,
        Loaded:    false,
    }
    
    return 0 // SMI_SUCCESS
}

//export go_inference
func go_inference(handle C.uintptr_t, input unsafe.Pointer, inputSize C.size_t, 
                  output unsafe.Pointer, outputSize *C.size_t) C.int {
    
    modelInfo, exists := pluginState.Models[uintptr(handle)]
    if !exists {
        return -3 // SMI_ERROR_NOT_FOUND
    }
    
    if !modelInfo.Loaded {
        return -3 // SMI_ERROR_NOT_FOUND
    }
    
    // Convert input
    inputData := C.GoBytes(input, C.int(inputSize))
    fmt.Printf("Running Go inference (input size: %d)\n", len(inputData))
    
    // Mock inference - just copy input to output
    outputData := make([]byte, len(inputData))
    copy(outputData, inputData)
    
    // Copy to output buffer
    if uintptr(*outputSize) >= uintptr(len(outputData)) {
        C.memcpy(output, unsafe.Pointer(&outputData[0]), C.size_t(len(outputData)))
        *outputSize = C.size_t(len(outputData))
    } else {
        return -2 // SMI_ERROR_OUT_OF_MEMORY
    }
    
    return 0 // SMI_SUCCESS
}

//export go_cleanup
func go_cleanup() C.int {
    fmt.Println("Cleaning up Go plugin")
    
    // Clear models
    for k := range pluginState.Models {
        delete(pluginState.Models, k)
    }
    
    pluginState.Initialized = false
    return 0 // SMI_SUCCESS
}

//export go_get_plugin_name
func go_get_plugin_name() *C.char {
    return C.CString("My Go ML Plugin")
}

//export go_get_plugin_version
func go_get_plugin_version() *C.char {
    return C.CString("1.0.0")
}

func main() {
    // Required for Go plugins
}
```

### 2. Go Plugin Build

```makefile
# Makefile for Go plugin
GO_PLUGIN = libmlos_go_plugin.so

$(GO_PLUGIN): my_go_plugin.go
	go build -buildmode=c-shared -o $@ $<

clean:
	rm -f $(GO_PLUGIN) libmlos_go_plugin.h

install: $(GO_PLUGIN)
	cp $(GO_PLUGIN) /usr/local/lib/mlos/plugins/

.PHONY: clean install
```

## Testing Plugins

### 1. Unit Testing

```c
// test_plugin.c
#include "mlos/smi_spec.h"
#include <assert.h>
#include <dlfcn.h>

void test_plugin_loading(const char* plugin_path) {
    // Load plugin
    void* handle = dlopen(plugin_path, RTLD_LAZY);
    assert(handle != NULL);
    
    // Get init function
    smi_plugin_init_func_t init_func = dlsym(handle, "smi_plugin_init");
    assert(init_func != NULL);
    
    // Initialize plugin
    smi_plugin_t* plugin = init_func();
    assert(plugin != NULL);
    assert(plugin->interface.initialize != NULL);
    
    // Test initialization
    int result = plugin->interface.initialize("test-config");
    assert(result == SMI_SUCCESS);
    
    // Test plugin info
    const char* name = plugin->interface.get_plugin_name();
    assert(name != NULL);
    printf("Plugin name: %s\n", name);
    
    // Cleanup
    if (plugin->interface.cleanup) {
        plugin->interface.cleanup();
    }
    dlclose(handle);
    
    printf("✅ Plugin loading test passed\n");
}

int main(int argc, char* argv[]) {
    if (argc != 2) {
        printf("Usage: %s <plugin-path>\n", argv[0]);
        return 1;
    }
    
    test_plugin_loading(argv[1]);
    return 0;
}
```

### 2. Integration Testing

```bash
#!/bin/bash
# test_plugin_integration.sh

echo "Testing plugin integration..."

# Start MLOS Core
./build/mlos_core &
MLOS_PID=$!
sleep 3

# Register plugin
curl -X POST http://localhost:8080/plugins/register \
    -H "Content-Type: application/json" \
    -d '{
        "id": "test-plugin",
        "name": "Test Plugin",
        "version": "1.0.0",
        "endpoint": "file://./plugins/libtest_plugin.so"
    }'

# Register model
curl -X POST http://localhost:8080/models/register \
    -H "Content-Type: application/json" \
    -d '{
        "model_id": "test-model",
        "plugin_id": "test-plugin",
        "name": "Test Model",
        "path": "./models/test_model.bin"
    }'

# Run inference
curl -X POST http://localhost:8080/models/test-model/inference \
    -H "Content-Type: application/json" \
    -d '{"input": "test data"}'

# Cleanup
kill $MLOS_PID
echo "Integration test completed"
```

## Best Practices

### 1. Error Handling
- Always return appropriate SMI status codes
- Log errors with sufficient detail
- Handle resource cleanup in error paths
- Validate all input parameters

### 2. Resource Management
- Implement proper resource cleanup
- Monitor memory usage
- Use GPU memory efficiently
- Handle device allocation failures

### 3. Thread Safety
- Make all interface functions thread-safe
- Use appropriate synchronization primitives
- Avoid global state when possible
- Document thread safety guarantees

### 4. Performance
- Minimize data copying
- Use efficient serialization formats
- Implement batch processing
- Profile critical paths

### 5. Testing
- Write comprehensive unit tests
- Test error conditions
- Validate with real models
- Performance benchmark
