# Axon Integration Architecture: Production Design

## Problem Statement

**Current Development Setup:**
```bash
# Terminal 1: MLOS Core as separate process
./mlos_core

# Terminal 2: Axon CLI as separate tool making HTTP requests
axon register hf/bert-base-uncased@latest
```

**Analysis:**
Per patent US-63/861,527, Layer 1 (Application Layer) specifies:
- **API Gateway**: RESTful and gRPC interfaces for programmatic system interaction
- **CLI Tools**: Command-line utilities for model installation, deployment, and management operations

**The current architecture is actually CORRECT per patent:**
1. ✅ MLOS Core exposes API layer (HTTP/gRPC/IPC) - per patent specification
2. ✅ Tools (like Axon) call these APIs programmatically - per patent specification
3. ✅ This enables external tools and services to interact with MLOS Core

**However, there are two valid production architectures:**

## Two Valid Production Architectures

**Per Patent US-63/861,527:**
- **Layer 1 (Application Layer)**: 
  - **API Gateway**: RESTful and gRPC interfaces for programmatic system interaction
  - **CLI Tools**: Command-line utilities for model installation, deployment, and management operations

Both architectures are valid per patent:

### Architecture Option A: Separate Process (Current - Valid)

**Design:** Axon as separate process/service calling MLOS Core APIs

```
┌─────────────────────────────────────────────────────────────┐
│                    MLOS Core Process                         │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────────────────────────────────────────────────┐  │
│  │  API Gateway (Layer 1 - per patent)                  │  │
│  │  • HTTP REST API                                     │  │
│  │  • gRPC API                                          │  │
│  │  • IPC API                                           │  │
│  └──────────────────────┬───────────────────────────────┘  │
│                         │                                   │
│  ┌──────────────────────▼───────────────────────────────┐  │
│  │  Model Registry Service (Layer 2)                     │  │
│  │  • Model lifecycle management                         │  │
│  │  • Metadata storage                                   │  │
│  │  • Plugin routing                                     │  │
│  └──────────────────────┬───────────────────────────────┘  │
│                         │                                   │
│  ┌──────────────────────▼───────────────────────────────┐  │
│  │  Plugin Registry                                     │  │
│  │  • Framework plugins                                 │  │
│  │  • Inference execution                               │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                         ▲
                         │ HTTP/gRPC/IPC API calls
                         │ (per patent: programmatic interaction)
                         │
┌────────────────────────┴────────────────────────────────────┐
│                    Axon Process/Service                      │
│  • Model installation from repositories                     │
│  • Package management (MPF)                                 │
│  • Manifest generation                                      │
│  • Calls MLOS Core APIs for registration                    │
└─────────────────────────────────────────────────────────────┘
```

**Pros:**
- ✅ Aligns with patent: API Gateway for programmatic interaction
- ✅ Separation of concerns: Delivery (Axon) vs Execution (MLOS Core)
- ✅ Scalable: Axon can be distributed/containerized separately
- ✅ Flexible: Other tools can also call MLOS Core APIs
- ✅ Current setup is correct!

**Cons:**
- Requires two processes
- Network overhead (though minimal for localhost)

### Architecture Option B: Integrated Service (Alternative)

**Design:** Axon integrated into MLOS Core but still uses API layer internally

## Implementation Strategy

### Option 1: CGO Wrapper (Recommended)

**Approach:** Create a C API wrapper around Axon's Go library using CGO.

**Structure:**
```
core/
├── src/
│   ├── mlos_core.c
│   └── axon_service.c          # CGO wrapper for Axon
├── include/
│   └── axon_service.h          # C API for Axon
└── axon/
    └── cgo/                     # CGO bindings
        └── axon_cgo.go         # Go code with C exports
```

**C API Design:**
```c
// core/include/axon_service.h
typedef struct axon_service_t axon_service_t;

// Initialize Axon service (internal to MLOS Core)
axon_service_t* axon_service_init(const char* cache_dir);

// Install model from repository (internal call)
int axon_service_install(axon_service_t* service, 
                         const char* model_spec,  // e.g., "hf/bert-base-uncased@latest"
                         char* manifest_path,     // output: path to manifest.yaml
                         size_t manifest_path_size);

// Register model (internal call - no HTTP)
int axon_service_register(axon_service_t* service,
                          const char* model_spec,
                          char* model_id,         // output: canonical model_id
                          size_t model_id_size);

// Cleanup
void axon_service_cleanup(axon_service_t* service);
```

**Usage in MLOS Core:**
```c
// In mlos_core_init()
core->axon_service = axon_service_init("/var/lib/mlos/cache");

// In CLI command handler
int mlos_install_model(mlos_core_t* core, const char* model_spec) {
    char manifest_path[512];
    if (axon_service_install(core->axon_service, model_spec, 
                             manifest_path, sizeof(manifest_path)) == 0) {
        // Model installed, now register it
        char model_id[256];
        axon_service_register(core->axon_service, model_spec, 
                             model_id, sizeof(model_id));
        return mlos_register_model(core, NULL, &metadata, model_id);
    }
    return -1;
}
```

### Option 2: Embedded Go Runtime

**Approach:** Embed Go runtime in MLOS Core and call Axon directly.

**Pros:**
- Direct access to Axon functionality
- No CGO overhead

**Cons:**
- Complex build system (C + Go)
- Larger binary size
- Runtime overhead

### Option 3: Process Communication (Current - NOT for production)

**Approach:** Keep Axon as separate process, communicate via IPC.

**Pros:**
- Simple separation
- Easy to develop

**Cons:**
- ❌ Not production-ready
- ❌ Extra process overhead
- ❌ Doesn't match patent architecture

## Migration Path

### Phase 1: Add Internal Axon Service
1. Create CGO wrapper for Axon
2. Add `axon_service_t` to `mlos_core_t` structure
3. Initialize Axon service in `mlos_core_init()`

### Phase 2: Add CLI Commands
1. Add `mlos install <model-spec>` command
2. Add `mlos register <model-spec>` command
3. These use internal Axon service (no HTTP)

### Phase 3: Deprecate External Axon CLI
1. Keep `axon` CLI for development/testing
2. Document that production uses `mlos` commands
3. Eventually remove external `axon register` dependency

## Updated User Experience

### Development (Current - Temporary)
```bash
# Terminal 1
./mlos_core

# Terminal 2
axon install hf/bert-base-uncased@latest
axon register hf/bert-base-uncased@latest
```

### Production (Target)
```bash
# Single command - everything integrated
mlos install hf/bert-base-uncased@latest
# Automatically:
# 1. Installs model via internal Axon service
# 2. Registers with MLOS Core
# 3. Ready for inference

# Run inference
mlos inference hf/bert-base-uncased@latest --input "Hello world"
```

## Benefits

1. **✅ Patent Alignment**: Axon is part of MLOS Core OS
2. **✅ Single Process**: No separate tools needed
3. **✅ Better Performance**: No HTTP/IPC overhead
4. **✅ Simpler UX**: One command does everything
5. **✅ Production Ready**: Matches intended architecture

## Implementation Priority

**High Priority:**
- CGO wrapper for Axon (Option 1)
- Internal Axon service initialization
- `mlos install` command

**Medium Priority:**
- `mlos register` command (can auto-register on install)
- Remove HTTP dependency for registration

**Low Priority:**
- Deprecate external `axon` CLI
- Full migration to internal service

---

**Next Steps:**
1. Design CGO wrapper API
2. Implement `axon_service.c` with CGO bindings
3. Integrate into `mlos_core_init()`
4. Add CLI commands
5. Test end-to-end

