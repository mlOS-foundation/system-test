# Shared Storage Architecture: Axon + MLOS Core

## Problem Statement

**Critical Issue:** If MLOS Core runs as a separate OS/system, it cannot access Axon's local cache directory.

**Current Problem:**
```bash
# Axon installs to user cache
axon install hf/bert-base-uncased@latest
# → ~/.axon/cache/hf/bert-base-uncased/latest/

# MLOS Core runs as system service (different user/system)
./mlos_core
# → Cannot access ~/.axon/cache/ (user-specific, permission issues)
```

**This breaks the architecture if:**
- MLOS Core runs as system service (different user)
- MLOS Core runs in container (isolated filesystem)
- MLOS Core runs on different machine (no shared filesystem)
- MLOS Core runs with different permissions

## Solution: Shared Model Repository

**Per Patent US-63/861,527:** Models should be stored in OS-managed locations, not user-specific caches.

### Architecture Design

```
┌─────────────────────────────────────────────────────────────┐
│              Shared Model Repository (OS-Managed)            │
│  /var/lib/mlos/models/  (or /opt/mlos/models/)              │
│  ├── hf/                                                    │
│  │   └── bert-base-uncased/                                │
│  │       └── latest/                                       │
│  │           ├── manifest.yaml                             │
│  │           └── model files...                            │
│  └── pytorch/                                               │
│      └── resnet50/                                          │
│          └── latest/                                        │
└─────────────────────────────────────────────────────────────┘
         ▲                              ▲
         │                              │
         │                              │
┌────────┴────────┐          ┌──────────┴──────────┐
│   Axon Process   │          │   MLOS Core Process │
│                  │          │                     │
│  • Installs to    │          │  • Reads from       │
│    shared repo    │          │    shared repo     │
│  • Creates MPF    │          │  • Registers models │
│    packages       │          │  • Executes         │
│  • Manages cache │          │    inference        │
└──────────────────┘          └─────────────────────┘
```

## Implementation Strategy

### Option 1: Direct Install to OS Repository (Simple but Less Secure)

**Design:** Models stored in system-wide location accessible to both processes.

**Axon Configuration:**
```yaml
# axon config
cache_dir: /var/lib/mlos/models  # System-wide, not ~/.axon/cache
```

**MLOS Core Configuration:**
```c
// mlos_core config
model_repository: /var/lib/mlos/models  // Same location
```

**Permissions:**
- Directory owned by `mlos:mlos` group
- Both Axon and MLOS Core users in `mlos` group
- Read/write permissions for group

**Pros:**
- ✅ OS-managed location (per patent)
- ✅ Accessible to both processes
- ✅ Works with system services
- ✅ Works with containers (mounted volume)

**Cons:**
- ❌ Requires root/sudo for every install (development friction)
- ❌ No separation between dev and prod models
- ❌ All installed models immediately available to MLOS Core (security risk)
- ❌ No validation/testing step before production
- ❌ Doesn't match standard ML pipeline workflows

### Compatibility: Ubuntu vs Flatcar Linux

**Ubuntu (Traditional Linux):**
- ✅ `/var/lib/mlos/models/` is fully writable
- ✅ Standard filesystem permissions
- ✅ Works with systemd services
- ✅ No special considerations needed

**Flatcar Linux (Immutable Filesystem):**
- ✅ `/var/lib/mlos/models/` is writable (even with immutable root)
- ✅ Flatcar's immutable filesystem only affects `/usr` and `/etc`
- ✅ `/var` is always writable (persistent data)
- ✅ Works with systemd services
- ✅ Works with containers (bind mount `/var/lib/mlos/models`)

**Key Point:** Both distributions support `/var/lib/mlos/models/` because:
1. **FHS (Filesystem Hierarchy Standard)**: `/var/lib` is for persistent application data
2. **Ubuntu**: Standard writable filesystem
3. **Flatcar**: Immutable root (`/usr`, `/etc`) but `/var` is writable for data
4. **Both**: Use systemd, so service configuration is identical

**Flatcar-Specific Considerations:**
- Models stored in `/var/lib/mlos/models/` persist across updates (immutable root updates don't affect `/var`)
- Container deployments: Bind mount `/var/lib/mlos/models` to container
- Ignition config: Create directory during provisioning
- Atomic updates: Model data survives OS updates (stored in `/var`)

### Option 2: Targeted Publish to MLOS Core Instance/Cluster (RECOMMENDED)

**Design:** Axon installs to user cache for development/testing, then "publishes" to specific MLOS Core instance(s) or cluster(s).

**Why This Is The Best Approach:**
- ✅ **Model Development Workflow**: Scientists/ML engineers can test/tune models in local cache before production
- ✅ **Explicit Promotion**: Clear elevation path from dev → test → production
- ✅ **Targeted Deployment**: Publish to specific MLOS Core instance or cluster
- ✅ **Multi-Instance Support**: Different models on different instances/clusters
- ✅ **Security Boundary**: MLOS Core only sees validated, published models
- ✅ **Separation of Environments**: Development vs Production clearly separated
- ✅ **Matches ML Pipeline**: Aligns with standard ML workflows (dev → staging → prod)
- ✅ **Model Validation**: Allows testing, tuning, validation before production deployment
- ✅ **Distributed Architecture**: Supports multi-node, multi-tenant deployments

**Flow:**
```bash
# 1. Development: Install to local cache (no root needed)
axon install hf/bert-base-uncased@latest
# → ~/.axon/cache/hf/bert-base-uncased/latest/
# → Scientist/ML engineer can test, tune, validate

# 2. Testing: Validate model works correctly
axon test hf/bert-base-uncased@latest
# → Run validation tests
# → Check performance metrics
# → Verify resource requirements

# 3. Production: Publish to specific MLOS Core instance/cluster
axon publish hf/bert-base-uncased@latest --target mlos-core-1
# → Copies to /var/lib/mlos/models/hf/bert-base-uncased/latest/ (on mlos-core-1)
# → Sets proper permissions (mlos:mlos)
# → Notifies MLOS Core instance (via API) that model is available
# → Model is now available for production inference on that instance

# Or publish to cluster:
axon publish hf/bert-base-uncased@latest --target mlos-cluster-prod
# → Publishes to all instances in cluster
# → Each instance gets model in its /var/lib/mlos/models/
# → All instances notified via API
```

**Target Options:**
- **Single Instance**: `--target mlos-core-1` or `--target http://mlos-core-1:8080`
- **Cluster/Group**: `--target mlos-cluster-prod` (publishes to all instances in cluster)
- **Default**: `--target localhost` (local MLOS Core instance)
- **Network Storage**: `--target nfs://mlos-repo/models` (shared network location)

**Implementation:**
```go
// axon publish command with target support
func publishCmd() *cobra.Command {
    cmd := &cobra.Command{
        Use:   "publish [namespace/name[@version]]",
        Short: "Publish model to MLOS Core instance or cluster",
        Long: `Promotes a model from development cache to production repository.
        
Can target:
- Single MLOS Core instance: --target mlos-core-1
- MLOS Core cluster: --target mlos-cluster-prod
- Network storage: --target nfs://mlos-repo/models
- Default: localhost (local MLOS Core instance)`,
        Args: cobra.ExactArgs(1),
        RunE: func(cmd *cobra.Command, args []string) error {
            modelSpec := args[0]
            namespace, name, version := parseModelSpec(modelSpec)
            
            // Get target (instance, cluster, or network storage)
            target, _ := cmd.Flags().GetString("target")
            if target == "" {
                target = "localhost" // Default to local instance
            }
            
            // 1. Read from user cache
            cacheMgr := cache.NewManager(cfg.CacheDir) // ~/.axon/cache
            modelPath := cacheMgr.GetModelPath(namespace, name, version)
            
            if !cacheMgr.IsModelCached(namespace, name, version) {
                return fmt.Errorf("model %s not found in cache. Install it first with 'axon install'", modelSpec)
            }
            
            // 2. Validate model (optional but recommended)
            validate, _ := cmd.Flags().GetBool("validate")
            if validate {
                if err := validateModel(modelPath); err != nil {
                    return fmt.Errorf("model validation failed: %w", err)
                }
            }
            
            // 3. Determine target type and publish
            if isClusterTarget(target) {
                // Publish to cluster (all instances)
                return publishToCluster(modelSpec, modelPath, target)
            } else if isNetworkStorage(target) {
                // Publish to network storage (NFS/S3)
                return publishToNetworkStorage(modelSpec, modelPath, target)
            } else {
                // Publish to single instance
                return publishToInstance(modelSpec, modelPath, target)
            }
        },
    }
    
    cmd.Flags().String("target", "localhost", "Target MLOS Core instance, cluster, or network storage")
    cmd.Flags().Bool("validate", true, "Validate model before publishing")
    cmd.Flags().Bool("notify", true, "Notify MLOS Core after publishing")
    
    return cmd
}

// Publish to single MLOS Core instance
func publishToInstance(modelSpec, sourcePath, target string) error {
    // Resolve target (could be hostname, IP, or service name)
    mlosEndpoint := resolveMLOSEndpoint(target)
    
    // Option A: Direct file copy (if same filesystem/SSH access)
    if canAccessFilesystem(mlosEndpoint) {
        targetPath := filepath.Join("/var/lib/mlos/models", namespace, name, version)
        if err := copyModelToRemote(sourcePath, mlosEndpoint, targetPath); err != nil {
            return fmt.Errorf("failed to copy model: %w", err)
        }
    } else {
        // Option B: Upload via API (if no filesystem access)
        if err := uploadModelViaAPI(sourcePath, mlosEndpoint, modelSpec); err != nil {
            return fmt.Errorf("failed to upload model: %w", err)
        }
    }
    
    // Notify MLOS Core
    if err := notifyMLOSCore(mlosEndpoint, modelSpec); err != nil {
        return fmt.Errorf("failed to notify MLOS Core: %w", err)
    }
    
    fmt.Printf("✅ Model published to MLOS Core instance: %s\n", target)
    return nil
}

// Publish to cluster (all instances)
func publishToCluster(modelSpec, sourcePath, clusterName string) error {
    // Get cluster members (from config, service discovery, or API)
    instances, err := getClusterInstances(clusterName)
    if err != nil {
        return fmt.Errorf("failed to get cluster instances: %w", err)
    }
    
    fmt.Printf("Publishing to cluster '%s' (%d instances)...\n", clusterName, len(instances))
    
    var errors []error
    for _, instance := range instances {
        if err := publishToInstance(modelSpec, sourcePath, instance); err != nil {
            errors = append(errors, fmt.Errorf("instance %s: %w", instance, err))
        } else {
            fmt.Printf("  ✅ Published to %s\n", instance)
        }
    }
    
    if len(errors) > 0 {
        return fmt.Errorf("failed to publish to some instances: %v", errors)
    }
    
    fmt.Printf("✅ Model published to all instances in cluster '%s'\n", clusterName)
    return nil
}

// Publish to network storage (shared location)
func publishToNetworkStorage(modelSpec, sourcePath, storageURL string) error {
    // Parse storage URL (nfs://, s3://, etc.)
    storageType, storagePath := parseStorageURL(storageURL)
    
    targetPath := filepath.Join(storagePath, namespace, name, version)
    
    switch storageType {
    case "nfs":
        // Mount NFS and copy
        if err := copyToNFS(sourcePath, storagePath, targetPath); err != nil {
            return fmt.Errorf("failed to copy to NFS: %w", err)
        }
    case "s3":
        // Upload to S3
        if err := uploadToS3(sourcePath, storagePath, targetPath); err != nil {
            return fmt.Errorf("failed to upload to S3: %w", err)
        }
    default:
        return fmt.Errorf("unsupported storage type: %s", storageType)
    }
    
    fmt.Printf("✅ Model published to network storage: %s\n", storageURL)
    return nil
}
```

**Pros:**
- ✅ **Best Practice**: Matches standard ML pipeline workflows
- ✅ **Security**: Explicit promotion (no accidental production deployment)
- ✅ **Development Friendly**: Scientists can work without root/sudo
- ✅ **Validation**: Model can be tested before production
- ✅ **Separation**: Clear dev vs prod boundaries
- ✅ **MLOS Core Safety**: Only sees validated, published models
- ✅ **Audit Trail**: Clear record of what's in production

**Cons:**
- Extra step (install + publish) - but this is a feature, not a bug!
- Duplicate storage (cache + repository) - acceptable trade-off for security/workflow

### Option 3: MLOS Core Pulls from Axon Cache

**Design:** MLOS Core reads from Axon's cache location (if accessible).

**Configuration:**
```c
// mlos_core config
axon_cache_dir: /home/user/.axon/cache  // Or via environment variable
```

**Implementation:**
```c
// MLOS Core scans Axon cache on startup
void mlos_scan_axon_cache(mlos_core_t* core, const char* axon_cache_dir) {
    // Scan for manifest.yaml files
    // Auto-register available models
}
```

**Pros:**
- ✅ No duplication
- ✅ Simple (direct access)

**Cons:**
- ❌ Only works if same filesystem
- ❌ Permission issues (user cache vs system service)
- ❌ Doesn't work with containers/remote systems

### Option 4: Network Model Repository

**Design:** Models stored in network-accessible location (NFS, S3, etc.).

**Architecture:**
```
┌─────────────────────────────────────────────────────────────┐
│         Network Model Repository (NFS/S3/Object Store)       │
│  nfs://mlos-repo/models/  or  s3://mlos-models/             │
└─────────────────────────────────────────────────────────────┘
         ▲                              ▲
         │                              │
         │                              │
┌────────┴────────┐          ┌──────────┴──────────┐
│   Axon Process   │          │   MLOS Core Process │
│  (any machine)    │          │  (any machine)     │
│                  │          │                     │
│  • Installs to    │          │  • Reads from       │
│    network repo   │          │    network repo     │
└──────────────────┘          └─────────────────────┘
```

**Pros:**
- ✅ Works across machines
- ✅ Centralized model management
- ✅ Scalable (multiple MLOS Core instances)

**Cons:**
- Network latency
- Requires network storage setup
- More complex

## Recommended Solution: Option 2 (Publish Workflow)

**Recommended Architecture:**
- **Development**: Axon installs to user cache (`~/.axon/cache`)
  - Scientists/ML engineers test, tune, validate models
  - No root/sudo required
  - Fast iteration cycle

- **Production**: Axon publishes to OS repository (`/var/lib/mlos/models`)
  - Explicit promotion step (security boundary)
  - Only validated models reach production
  - MLOS Core only sees published models

- **Distributed**: Network repository (NFS/S3) for multi-node
  - Shared repository across machines
  - Works with Kubernetes/containers

**Why Option 2 Is Best:**
1. ✅ **Matches ML Pipeline**: Dev → Test → Staging → Production
2. ✅ **Security**: Explicit promotion prevents accidental production deployment
3. ✅ **Developer Experience**: No root needed for development
4. ✅ **Validation**: Models can be tested before production
5. ✅ **Separation**: Clear boundaries between environments
6. ✅ **Audit Trail**: Clear record of what's in production

## Implementation Plan

### Phase 1: Dual-Storage Architecture

1. **Create shared repository directory:**
```bash
sudo mkdir -p /var/lib/mlos/models
sudo chown mlos:mlos /var/lib/mlos/models
sudo chmod 775 /var/lib/mlos/models
```

2. **Axon Configuration (Dual Storage):**
```yaml
# ~/.axon/config.yaml
cache_dir: ~/.axon/cache  # Development cache (user-writable)
publish_dir: /var/lib/mlos/models  # Production repository (requires permissions)
```

3. **MLOS Core Configuration:**
```c
// mlos_core config
model_repository: /var/lib/mlos/models  // Only reads from production repo
```

4. **Implement Axon Publish Command:**
```go
// axon publish command
// 1. Reads from user cache (~/.axon/cache)
// 2. Validates model (optional)
// 3. Copies to /var/lib/mlos/models/
// 4. Sets permissions
// 5. Notifies MLOS Core
```

5. **Update Axon Register Command:**
```go
// axon register checks both locations:
// 1. First check: /var/lib/mlos/models/ (published models)
// 2. Fallback: ~/.axon/cache/ (development models, if accessible)
// 3. Register with MLOS Core via API
```

### Phase 2: Auto-Discovery (Production Models Only)

MLOS Core should auto-discover **published** models in repository:

```c
// On startup, scan production repository for models
void mlos_scan_model_repository(mlos_core_t* core) {
    const char* repo_path = core->config.model_repository; // /var/lib/mlos/models
    // Scan for manifest.yaml files
    // Auto-register available models
    // Note: Only scans production repo, not user caches
}
```

**Why Only Production Repo:**
- ✅ Security: MLOS Core only sees validated, published models
- ✅ Separation: Development models stay in user cache
- ✅ Performance: Faster startup (smaller scan scope)
- ✅ Clarity: Clear distinction between dev and prod

### Phase 3: Model Registration API Enhancement

**Two Registration Paths:**

1. **Development Registration** (from user cache):
   - Axon registers model from `~/.axon/cache/`
   - MLOS Core validates path (if accessible)
   - Useful for local development/testing
   - ⚠️ Not recommended for production

2. **Production Registration** (from published repo):
   - Axon registers model from `/var/lib/mlos/models/`
   - MLOS Core validates path is in repository
   - ✅ Recommended for production
   - ✅ Only published models reach production

**Registration Flow:**
```go
// axon register command
func registerCmd() {
    // Check if model is published first
    if isPublished(namespace, name, version) {
        // Use published path
        modelPath := filepath.Join("/var/lib/mlos/models", namespace, name, version)
        registerWithMLOSCore(modelPath)
    } else {
        // Use cache path (development)
        modelPath := filepath.Join(cacheDir, namespace, name, version)
        if isAccessible(modelPath) {
            registerWithMLOSCore(modelPath)
        } else {
            return error("Model not published and cache not accessible. Run 'axon publish' first.")
        }
    }
}
```

## Path Resolution

**Problem:** Axon sends relative paths, MLOS Core needs absolute paths.

**Solution:** Always use absolute paths from shared repository:

```go
// Axon register command
func registerCmd() {
    // Use absolute path from shared repository
    modelPath := filepath.Join("/var/lib/mlos/models", 
        namespace, name, version)
    manifestPath := filepath.Join(modelPath, "manifest.yaml")
    
    // Send absolute paths to MLOS Core
    payload := fmt.Sprintf(`{
        "model_id": "%s/%s@%s",
        "path": "%s",           // Absolute path
        "manifest_path": "%s"   // Absolute path
    }`, namespace, name, version, modelPath, manifestPath)
}
```

## Security Considerations

1. **Repository Permissions:**
   - Only `mlos` group can write
   - MLOS Core service user in `mlos` group
   - Users who run Axon in `mlos` group

2. **Path Validation:**
   - MLOS Core validates all paths are within repository
   - Prevents path traversal attacks
   - Rejects paths outside `/var/lib/mlos/models`

3. **Model Verification:**
   - Verify manifest.yaml exists
   - Verify model files exist
   - Verify checksums match

## Migration Path

1. **Keep current behavior for development** (user cache)
2. **Add shared repository support** (configurable)
3. **Default to shared repository in production**
4. **Deprecate user cache for production use**

---

**Key Insight:** Models must be in a location accessible to both Axon and MLOS Core. The OS-managed repository (`/var/lib/mlos/models`) is the correct solution per patent architecture.

