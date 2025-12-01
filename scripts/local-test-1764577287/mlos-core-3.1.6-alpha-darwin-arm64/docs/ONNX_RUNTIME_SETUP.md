# ONNX Runtime Setup Guide

## Overview

MLOS Core includes a built-in ONNX Runtime plugin that enables universal model inference. To use this feature, ONNX Runtime must be installed and linked during compilation.

## Installation Options

### Option 1: Download Pre-built ONNX Runtime (Recommended)

1. **Download ONNX Runtime**:
   - Visit: https://github.com/microsoft/onnxruntime/releases
   - Download the appropriate package for your platform:
     - **macOS**: `onnxruntime-osx-x64-<version>.tgz` or `onnxruntime-osx-arm64-<version>.tgz`
     - **Linux**: `onnxruntime-linux-x64-<version>.tgz` or `onnxruntime-linux-aarch64-<version>.tgz`

2. **Extract the package**:
   ```bash
   tar -xzf onnxruntime-*.tgz
   ```

3. **Set ONNX_RUNTIME_DIR**:
   ```bash
   export ONNX_RUNTIME_DIR=/path/to/onnxruntime
   # Example: export ONNX_RUNTIME_DIR=$HOME/onnxruntime
   ```

4. **Build MLOS Core with ONNX Runtime**:
   ```bash
   cd core
   make ONNX_RUNTIME_DIR=$ONNX_RUNTIME_DIR
   ```

### Option 2: Build from Source

1. **Clone ONNX Runtime**:
   ```bash
   git clone --recursive https://github.com/microsoft/onnxruntime.git
   cd onnxruntime
   ```

2. **Build ONNX Runtime** (CPU-only, minimal):
   ```bash
   ./build.sh --config Release --build_shared_lib --parallel
   ```

3. **Set ONNX_RUNTIME_DIR**:
   ```bash
   export ONNX_RUNTIME_DIR=$(pwd)
   ```

4. **Build MLOS Core**:
   ```bash
   cd /path/to/mlOS-foundation/core
   make ONNX_RUNTIME_DIR=$ONNX_RUNTIME_DIR
   ```

### Option 3: Use System Package Manager (if available)

Some distributions may have ONNX Runtime packages:

```bash
# Example for Ubuntu/Debian (if available)
sudo apt-get install libonnxruntime-dev

# Then set ONNX_RUNTIME_DIR to system location
export ONNX_RUNTIME_DIR=/usr
```

## Verification

After building with ONNX Runtime, verify it's linked:

```bash
# Check if ONNX Runtime is linked
ldd build/mlos_core | grep onnxruntime  # Linux
otool -L build/mlos_core | grep onnxruntime  # macOS

# Run MLOS Core and check startup logs
./build/mlos_core
# Should see: "✅ ONNX Runtime plugin initialized"
```

## Building Without ONNX Runtime

MLOS Core can be built without ONNX Runtime. The plugin will be available but inference will return an error indicating ONNX Runtime is required:

```bash
make clean
make
# Builds successfully, but inference requires ONNX Runtime
```

## Troubleshooting

### Issue: "ONNX Runtime header not found"

**Solution**: Ensure `ONNX_RUNTIME_DIR` points to the correct directory containing `include/onnxruntime_c_api.h`

```bash
ls $ONNX_RUNTIME_DIR/include/onnxruntime_c_api.h
```

### Issue: "Cannot find -lonnxruntime"

**Solution**: Ensure the library is in `$ONNX_RUNTIME_DIR/lib`:

```bash
ls $ONNX_RUNTIME_DIR/lib/libonnxruntime.*
```

### Issue: Runtime error "library not found"

**Solution**: Add the library path to your runtime library path:

```bash
# macOS
export DYLD_LIBRARY_PATH=$ONNX_RUNTIME_DIR/lib:$DYLD_LIBRARY_PATH

# Linux
export LD_LIBRARY_PATH=$ONNX_RUNTIME_DIR/lib:$LD_LIBRARY_PATH
```

Or use the rpath that's automatically added during build.

## Testing Inference

Once ONNX Runtime is linked, test inference:

```bash
# Start MLOS Core
./build/mlos_core &

# Register a model (with ONNX file)
curl -X POST http://localhost:8080/models/register \
  -H "Content-Type: application/json" \
  -d '{
    "model_id": "test/model@1.0",
    "name": "test",
    "framework": "ONNX",
    "path": "/path/to/model.onnx"
  }'

# Run inference
curl -X POST http://localhost:8080/models/test/model@1.0/inference \
  -H "Content-Type: application/json" \
  -d '{"input": [1.0, 2.0, 3.0]}'
```

## Next Steps

- See [ONNX_RUNTIME_INTEGRATION.md](./ONNX_RUNTIME_INTEGRATION.md) for usage details
- See [BUILTIN_ONNX_PLUGIN.md](./BUILTIN_ONNX_PLUGIN.md) for architecture details

