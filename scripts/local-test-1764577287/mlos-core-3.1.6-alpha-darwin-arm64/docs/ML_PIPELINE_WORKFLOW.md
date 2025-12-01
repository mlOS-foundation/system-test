# ML Pipeline Workflow: Development to Production

## Overview

The recommended architecture uses a **dual-storage model** that aligns with standard ML pipeline workflows, providing clear separation between development and production environments.

## Architecture: Dev → Prod Promotion

```
┌─────────────────────────────────────────────────────────────┐
│              Development Environment                         │
│  ~/.axon/cache/  (User-writable, no root needed)            │
│  ├── hf/bert-base-uncased/latest/                           │
│  │   ├── manifest.yaml                                      │
│  │   └── model files...                                     │
│  └── (Scientists/ML engineers test, tune, validate here)     │
└─────────────────────────────────────────────────────────────┘
                         │
                         │ axon publish (explicit promotion)
                         │ (requires permissions)
                         ▼
┌─────────────────────────────────────────────────────────────┐
│              Production Environment                          │
│  /var/lib/mlos/models/  (OS-managed, mlos:mlos group)       │
│  ├── hf/bert-base-uncased/latest/                          │
│  │   ├── manifest.yaml                                      │
│  │   └── model files...                                    │
│  └── (MLOS Core reads from here for inference)              │
└─────────────────────────────────────────────────────────────┘
```

## Workflow Stages

### Stage 1: Development (Local Cache)

**Location:** `~/.axon/cache/`  
**Access:** User-writable, no root needed  
**Purpose:** Model development, testing, tuning

```bash
# Scientist/ML engineer installs model
axon install hf/bert-base-uncased@latest
# → ~/.axon/cache/hf/bert-base-uncased/latest/

# Test and validate model
axon test hf/bert-base-uncased@latest
# → Run validation tests
# → Check performance metrics
# → Verify resource requirements

# Optional: Local inference testing
axon run hf/bert-base-uncased@latest --input "test data"
```

**Benefits:**
- ✅ Fast iteration (no root/sudo needed)
- ✅ Isolated from production
- ✅ Can test multiple versions
- ✅ No impact on production systems

### Stage 2: Validation & Testing

**Location:** `~/.axon/cache/` (or test environment)  
**Purpose:** Validate model before production

```bash
# Run comprehensive tests
axon validate hf/bert-base-uncased@latest
# → Performance benchmarks
# → Accuracy validation
# → Resource requirement verification
# → Compatibility checks

# Integration testing
axon test-integration hf/bert-base-uncased@latest
# → Test with MLOS Core (if accessible)
# → Verify inference works
# → Check API compatibility
```

### Stage 3: Production Promotion (Publish)

**Location:** `/var/lib/mlos/models/`  
**Access:** Requires permissions (mlos group or sudo)  
**Purpose:** Production-ready models

```bash
# Publish model to production repository
axon publish hf/bert-base-uncased@latest
# → Copies from ~/.axon/cache/ to /var/lib/mlos/models/
# → Sets proper permissions (mlos:mlos)
# → Validates model integrity
# → Notifies MLOS Core (via API)
# → Model is now available for production inference
```

**Security Benefits:**
- ✅ Explicit promotion (no accidental production deployment)
- ✅ Permission check (requires mlos group or sudo)
- ✅ Validation step before production
- ✅ Clear audit trail

### Stage 4: Production Registration

**Location:** `/var/lib/mlos/models/`  
**Purpose:** Register published model with MLOS Core

```bash
# Register published model with MLOS Core
axon register hf/bert-base-uncased@latest
# → Reads from /var/lib/mlos/models/ (published location)
# → Sends manifest path to MLOS Core API
# → MLOS Core validates path is in repository
# → Model registered and ready for inference
```

## Implementation

### Axon Configuration

```yaml
# ~/.axon/config.yaml
cache_dir: ~/.axon/cache  # Development cache
publish_dir: /var/lib/mlos/models  # Production repository

# Optional: Auto-publish on validation success
auto_publish_on_validation: false  # Explicit publish is safer
```

### Axon Publish Command

```go
func publishCmd() *cobra.Command {
    return &cobra.Command{
        Use:   "publish [namespace/name[@version]]",
        Short: "Publish model to MLOS Core production repository",
        Long: `Promotes a model from development cache to production repository.
        
This command:
1. Validates the model (optional but recommended)
2. Copies model from ~/.axon/cache/ to /var/lib/mlos/models/
3. Sets proper permissions (mlos:mlos)
4. Notifies MLOS Core that model is available

Requires: mlos group membership or sudo access`,
        Args: cobra.ExactArgs(1),
        RunE: func(cmd *cobra.Command, args []string) error {
            modelSpec := args[0]
            namespace, name, version := parseModelSpec(modelSpec)
            
            cfg, err := config.Load()
            if err != nil {
                return fmt.Errorf("failed to load config: %w", err)
            }
            
            // 1. Read from development cache
            cacheMgr := cache.NewManager(cfg.CacheDir)
            sourcePath := cacheMgr.GetModelPath(namespace, name, version)
            
            if !cacheMgr.IsModelCached(namespace, name, version) {
                return fmt.Errorf("model %s not found in cache. Install it first with 'axon install'", modelSpec)
            }
            
            // 2. Optional: Validate model
            validate, _ := cmd.Flags().GetBool("validate")
            if validate {
                fmt.Printf("Validating model before publishing...\n")
                if err := validateModel(sourcePath); err != nil {
                    return fmt.Errorf("model validation failed: %w\nRun 'axon validate %s' for details", err, modelSpec)
                }
                fmt.Printf("✅ Model validation passed\n")
            }
            
            // 3. Copy to production repository
            publishDir := cfg.PublishDir
            if publishDir == "" {
                publishDir = "/var/lib/mlos/models"  // Default
            }
            
            targetPath := filepath.Join(publishDir, namespace, name, version)
            
            fmt.Printf("Publishing model to production repository...\n")
            fmt.Printf("  Source: %s\n", sourcePath)
            fmt.Printf("  Target: %s\n", targetPath)
            
            // Copy model files
            if err := copyModelRecursive(sourcePath, targetPath); err != nil {
                return fmt.Errorf("failed to copy model: %w", err)
            }
            
            // 4. Set proper permissions
            if err := setModelPermissions(targetPath); err != nil {
                return fmt.Errorf("failed to set permissions: %w", err)
            }
            
            // 5. Verify integrity
            if err := verifyModelIntegrity(targetPath); err != nil {
                return fmt.Errorf("model integrity check failed: %w", err)
            }
            
            // 6. Notify MLOS Core (optional - can be done separately)
            notify, _ := cmd.Flags().GetBool("notify")
            if notify {
                if err := notifyMLOSCore(modelSpec, targetPath); err != nil {
                    fmt.Printf("⚠️  Warning: Failed to notify MLOS Core: %v\n", err)
                    fmt.Printf("   You can register manually with: axon register %s\n", modelSpec)
                } else {
                    fmt.Printf("✅ MLOS Core notified\n")
                }
            }
            
            fmt.Printf("\n✅ Model published successfully!\n")
            fmt.Printf("   Model: %s\n", modelSpec)
            fmt.Printf("   Location: %s\n", targetPath)
            fmt.Printf("   Status: Available for production inference\n")
            if !notify {
                fmt.Printf("\n   Next step: Register with MLOS Core\n")
                fmt.Printf("   Run: axon register %s\n", modelSpec)
            }
            
            return nil
        },
    }
}
```

### MLOS Core Path Validation

```c
// MLOS Core validates all paths are in production repository
int validate_model_path(const char* path, const char* repository_root) {
    char resolved_path[PATH_MAX];
    char resolved_root[PATH_MAX];
    
    // Resolve absolute paths
    if (realpath(path, resolved_path) == NULL) {
        printf("❌ Invalid model path: %s\n", path);
        return -1;
    }
    
    if (realpath(repository_root, resolved_root) == NULL) {
        printf("❌ Invalid repository root: %s\n", repository_root);
        return -1;
    }
    
    // Check if path is within repository
    if (strncmp(resolved_path, resolved_root, strlen(resolved_root)) != 0) {
        printf("❌ Model path outside repository: %s\n", resolved_path);
        printf("   Repository: %s\n", resolved_root);
        printf("   Security: MLOS Core only accepts models from production repository\n");
        return -1;
    }
    
    return 0; // Valid
}
```

## Benefits of This Architecture

### 1. Matches ML Pipeline Workflows ✅

**Standard ML Pipeline:**
```
Development → Testing → Staging → Production
```

**Our Architecture:**
```
~/.axon/cache/ → Validation → /var/lib/mlos/models/ → MLOS Core
```

### 2. Security & Safety ✅

- ✅ **Explicit Promotion**: No accidental production deployment
- ✅ **Permission Check**: Requires mlos group or sudo
- ✅ **Validation Step**: Models can be tested before production
- ✅ **Separation**: Development models never reach production

### 3. Developer Experience ✅

- ✅ **No Root for Development**: Scientists work without sudo
- ✅ **Fast Iteration**: Local cache for quick testing
- ✅ **Multiple Versions**: Can test multiple model versions
- ✅ **Isolation**: Development doesn't affect production

### 4. Production Safety ✅

- ✅ **Validated Models Only**: Only published models in production
- ✅ **Audit Trail**: Clear record of what's in production
- ✅ **Rollback Capability**: Can unpublish models
- ✅ **Version Control**: Multiple versions can coexist

## Example Workflow

```bash
# 1. Development: Install and test
axon install hf/bert-base-uncased@latest
axon test hf/bert-base-uncased@latest
axon validate hf/bert-base-uncased@latest

# 2. Production: Publish (requires permissions)
axon publish hf/bert-base-uncased@latest --validate
# → Validates model
# → Copies to /var/lib/mlos/models/
# → Sets permissions
# → Notifies MLOS Core

# 3. Production: Register (if not auto-notified)
axon register hf/bert-base-uncased@latest
# → Reads from /var/lib/mlos/models/
# → Registers with MLOS Core

# 4. Production: Inference
curl -X POST http://localhost:8080/models/hf/bert-base-uncased@latest/inference \
  -H "Content-Type: application/json" \
  -d '{"input": "Hello, MLOS!"}'
```

## Comparison: Option 1 vs Option 2

| Aspect | Option 1 (Direct Install) | Option 2 (Publish) ✅ |
|--------|---------------------------|----------------------|
| **Development** | ❌ Requires root/sudo | ✅ No root needed |
| **Security** | ❌ All models in production | ✅ Explicit promotion |
| **Workflow** | ❌ Doesn't match ML pipeline | ✅ Matches ML pipeline |
| **Validation** | ❌ No testing step | ✅ Validation before production |
| **Separation** | ❌ Dev/prod mixed | ✅ Clear separation |
| **Safety** | ❌ Accidental production | ✅ Explicit promotion |

## Conclusion

**Option 2 (Publish Workflow) is the recommended architecture** because it:
1. ✅ Matches standard ML pipeline workflows
2. ✅ Provides security boundaries
3. ✅ Enables fast development iteration
4. ✅ Ensures production safety
5. ✅ Supports model validation and testing

This architecture aligns with best practices for ML model deployment and provides a clear path from development to production.

