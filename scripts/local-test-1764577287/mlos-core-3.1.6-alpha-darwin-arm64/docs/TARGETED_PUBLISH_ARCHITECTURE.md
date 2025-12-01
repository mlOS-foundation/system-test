# Targeted Publish Architecture: Multi-Instance & Cluster Support

## Overview

Enhanced publish workflow that supports targeted publishing to specific MLOS Core instances, clusters, or network storage. This enables:
- **Multi-Instance Deployments**: Different models on different instances
- **Cluster Publishing**: Publish to all instances in a cluster
- **Network Storage**: Shared model repository across instances
- **Multi-Tenant Support**: Isolated model deployments per tenant

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│              Development Environment                         │
│  ~/.axon/cache/  (User-writable)                           │
│  ├── hf/bert-base-uncased/latest/                          │
│  └── (Scientists test, tune, validate)                     │
└─────────────────────────────────────────────────────────────┘
                         │
                         │ axon publish --target <instance/cluster>
                         ▼
┌─────────────────────────────────────────────────────────────┐
│              Production Environment                          │
│                                                               │
│  Option A: Direct Instance Publishing                        │
│  ┌──────────────────┐  ┌──────────────────┐              │
│  │ MLOS Core #1     │  │ MLOS Core #2     │              │
│  │ /var/lib/mlos/   │  │ /var/lib/mlos/   │              │
│  │   models/        │  │   models/        │              │
│  └──────────────────┘  └──────────────────┘              │
│                                                               │
│  Option B: Network Storage (Shared)                         │
│  ┌─────────────────────────────────────────┐              │
│  │ Network Storage (NFS/S3/Object Store)  │              │
│  │ /shared/mlos/models/                    │              │
│  └──────────┬──────────────┬────────────────┘              │
│             │              │                               │
│  ┌──────────▼──────┐  ┌────▼────────────────┐              │
│  │ MLOS Core #1    │  │ MLOS Core #2       │              │
│  │ (mounts shared) │  │ (mounts shared)    │              │
│  └─────────────────┘  └────────────────────┘              │
│                                                               │
│  Option C: Cluster Publishing                                │
│  ┌─────────────────────────────────────────┐              │
│  │ MLOS Cluster: mlos-cluster-prod          │              │
│  │ ├── mlos-core-1 (instance)              │              │
│  │ ├── mlos-core-2 (instance)              │              │
│  │ └── mlos-core-3 (instance)              │              │
│  │ axon publish --target mlos-cluster-prod │              │
│  │ → Publishes to all instances            │              │
│  └─────────────────────────────────────────┘              │
└─────────────────────────────────────────────────────────────┘
```

## Publish Target Types

### 1. Single Instance

**Target:** Specific MLOS Core instance

```bash
# By hostname
axon publish hf/bert-base-uncased@latest --target mlos-core-1

# By IP address
axon publish hf/bert-base-uncased@latest --target 192.168.1.100

# By endpoint URL
axon publish hf/bert-base-uncased@latest --target http://mlos-core-1:8080

# Local instance (default)
axon publish hf/bert-base-uncased@latest --target localhost
```

**Implementation:**
- Direct file copy (if filesystem accessible via SSH/NFS)
- Or upload via API (if no filesystem access)

### 2. Cluster/Group

**Target:** All instances in a cluster

```bash
# Publish to cluster
axon publish hf/bert-base-uncased@latest --target mlos-cluster-prod

# Cluster configuration
# ~/.axon/config.yaml
clusters:
  mlos-cluster-prod:
    instances:
      - mlos-core-1:8080
      - mlos-core-2:8080
      - mlos-core-3:8080
    strategy: all  # or: first-available, round-robin
```

**Implementation:**
- Resolve cluster members (from config, service discovery, or API)
- Publish to each instance in cluster
- Report success/failure per instance

### 3. Network Storage

**Target:** Shared network location (accessible by multiple instances)

```bash
# NFS mount
axon publish hf/bert-base-uncased@latest --target nfs://mlos-repo/models

# S3/Object Store
axon publish hf/bert-base-uncased@latest --target s3://mlos-models/models

# Shared filesystem
axon publish hf/bert-base-uncased@latest --target /mnt/shared/mlos/models
```

**Implementation:**
- Copy to network storage
- MLOS Core instances mount/access shared location
- All instances can access same models

## Implementation Details

### Axon Configuration

```yaml
# ~/.axon/config.yaml
cache_dir: ~/.axon/cache  # Development cache

# MLOS Core targets
mlos_targets:
  # Single instances
  mlos-core-1:
    endpoint: http://mlos-core-1:8080
    storage_type: filesystem  # or: api, nfs, s3
    storage_path: /var/lib/mlos/models
    access_method: ssh  # or: api, nfs
    
  mlos-core-2:
    endpoint: http://mlos-core-2:8080
    storage_type: api
    # No filesystem access, upload via API
    
  # Clusters
  mlos-cluster-prod:
    instances:
      - mlos-core-1:8080
      - mlos-core-2:8080
      - mlos-core-3:8080
    storage_type: filesystem
    storage_path: /var/lib/mlos/models
    
  # Network storage
  mlos-shared-repo:
    storage_type: nfs
    storage_path: nfs://mlos-repo/models
    # All instances mount this location
```

### Publish Command Implementation

```go
func publishCmd() *cobra.Command {
    cmd := &cobra.Command{
        Use:   "publish [namespace/name[@version]]",
        Short: "Publish model to MLOS Core instance, cluster, or network storage",
        Long: `Publishes a model from development cache to production.
        
Targets:
  - Single instance: --target mlos-core-1
  - Cluster: --target mlos-cluster-prod
  - Network storage: --target nfs://mlos-repo/models
  - Default: localhost`,
        Args: cobra.ExactArgs(1),
        RunE: func(cmd *cobra.Command, args []string) error {
            modelSpec := args[0]
            target, _ := cmd.Flags().GetString("target")
            validate, _ := cmd.Flags().GetBool("validate")
            notify, _ := cmd.Flags().GetBool("notify")
            
            // Load target configuration
            targetConfig, err := getTargetConfig(target)
            if err != nil {
                return fmt.Errorf("invalid target: %w", err)
            }
            
            // Publish based on target type
            switch targetConfig.Type {
            case "instance":
                return publishToInstance(modelSpec, targetConfig, validate, notify)
            case "cluster":
                return publishToCluster(modelSpec, targetConfig, validate, notify)
            case "network_storage":
                return publishToNetworkStorage(modelSpec, targetConfig, validate, notify)
            default:
                return fmt.Errorf("unsupported target type: %s", targetConfig.Type)
            }
        },
    }
    
    cmd.Flags().String("target", "localhost", "Target MLOS Core instance, cluster, or network storage")
    cmd.Flags().Bool("validate", true, "Validate model before publishing")
    cmd.Flags().Bool("notify", true, "Notify MLOS Core after publishing")
    
    return cmd
}
```

### Publish to Single Instance

```go
func publishToInstance(modelSpec string, target *TargetConfig, validate, notify bool) error {
    // 1. Read from cache
    sourcePath := getCachePath(modelSpec)
    
    // 2. Validate (if requested)
    if validate {
        if err := validateModel(sourcePath); err != nil {
            return fmt.Errorf("validation failed: %w", err)
        }
    }
    
    // 3. Publish based on access method
    switch target.AccessMethod {
    case "filesystem":
        // Direct file copy (SSH, NFS, local)
        targetPath := filepath.Join(target.StoragePath, modelSpec)
        if err := copyModelFiles(sourcePath, targetPath, target); err != nil {
            return fmt.Errorf("failed to copy files: %w", err)
        }
        setPermissions(targetPath, target)
        
    case "api":
        // Upload via MLOS Core API
        if err := uploadModelViaAPI(sourcePath, target.Endpoint, modelSpec); err != nil {
            return fmt.Errorf("failed to upload via API: %w", err)
        }
        
    default:
        return fmt.Errorf("unsupported access method: %s", target.AccessMethod)
    }
    
    // 4. Notify MLOS Core (if requested)
    if notify {
        if err := notifyMLOSCore(target.Endpoint, modelSpec); err != nil {
            return fmt.Errorf("failed to notify: %w", err)
        }
    }
    
    fmt.Printf("✅ Model published to: %s\n", target.Name)
    return nil
}
```

### Publish to Cluster

```go
func publishToCluster(modelSpec string, target *TargetConfig, validate, notify bool) error {
    // Get cluster instances
    instances := target.Instances
    if len(instances) == 0 {
        return fmt.Errorf("cluster has no instances")
    }
    
    fmt.Printf("Publishing to cluster '%s' (%d instances)...\n", target.Name, len(instances))
    
    var errors []error
    successCount := 0
    
    for _, instance := range instances {
        instanceConfig := &TargetConfig{
            Name:         instance,
            Endpoint:     fmt.Sprintf("http://%s", instance),
            StorageType:  target.StorageType,
            StoragePath:  target.StoragePath,
            AccessMethod: target.AccessMethod,
        }
        
        if err := publishToInstance(modelSpec, instanceConfig, validate, notify); err != nil {
            errors = append(errors, fmt.Errorf("%s: %w", instance, err))
            fmt.Printf("  ❌ Failed: %s\n", instance)
        } else {
            successCount++
            fmt.Printf("  ✅ Published: %s\n", instance)
        }
    }
    
    fmt.Printf("\n📊 Cluster Publish Summary:\n")
    fmt.Printf("  ✅ Success: %d/%d instances\n", successCount, len(instances))
    if len(errors) > 0 {
        fmt.Printf("  ❌ Failed: %d instances\n", len(errors))
        return fmt.Errorf("some instances failed: %v", errors)
    }
    
    return nil
}
```

### Publish to Network Storage

```go
func publishToNetworkStorage(modelSpec string, target *TargetConfig, validate, notify bool) error {
    // Parse storage URL
    storageType, storagePath := parseStorageURL(target.StoragePath)
    
    sourcePath := getCachePath(modelSpec)
    targetPath := filepath.Join(storagePath, modelSpec)
    
    // Copy to network storage
    switch storageType {
    case "nfs":
        if err := copyToNFS(sourcePath, storagePath, targetPath); err != nil {
            return fmt.Errorf("NFS copy failed: %w", err)
        }
        
    case "s3":
        if err := uploadToS3(sourcePath, storagePath, targetPath); err != nil {
            return fmt.Errorf("S3 upload failed: %w", err)
        }
        
    case "filesystem":
        if err := copyModelFiles(sourcePath, targetPath, target); err != nil {
            return fmt.Errorf("copy failed: %w", err)
        }
        
    default:
        return fmt.Errorf("unsupported storage type: %s", storageType)
    }
    
    // Notify all instances that use this storage (if configured)
    if notify && target.NotifyInstances != nil {
        for _, instance := range target.NotifyInstances {
            notifyMLOSCore(instance, modelSpec)
        }
    }
    
    fmt.Printf("✅ Model published to network storage: %s\n", target.StoragePath)
    return nil
}
```

## MLOS Core API Enhancement

### Model Upload Endpoint

```c
// New API endpoint: POST /models/upload
// Allows uploading model files directly to MLOS Core
// Useful when filesystem access is not available

void mlos_http_handle_model_upload(int client_socket, mlos_api_server_t* server, const char* request_body) {
    // Parse upload request
    // - model_id
    // - manifest (JSON)
    // - model_files (multipart/form-data or base64)
    
    // Save to /var/lib/mlos/models/
    // Register model
    // Return success
}
```

### Service Discovery Support

```c
// MLOS Core can register with service discovery
// Allows Axon to discover available instances

// Service discovery integration (Consul, etcd, Kubernetes)
typedef struct {
    char instance_id[128];
    char endpoint[512];
    char cluster_name[128];
    char storage_path[512];
} mlos_instance_info_t;

int mlos_register_with_discovery(mlos_core_t* core, const char* discovery_endpoint);
int mlos_discover_instances(const char* cluster_name, mlos_instance_info_t* instances, size_t max_instances);
```

## Use Cases

### Use Case 1: Single Instance Deployment

```bash
# Development
axon install hf/bert-base-uncased@latest

# Publish to single instance
axon publish hf/bert-base-uncased@latest --target mlos-core-1

# Result: Model available only on mlos-core-1
```

### Use Case 2: Cluster Deployment

```bash
# Publish to entire cluster
axon publish hf/bert-base-uncased@latest --target mlos-cluster-prod

# Result: Model available on all instances in cluster
# - mlos-core-1 ✅
# - mlos-core-2 ✅
# - mlos-core-3 ✅
```

### Use Case 3: Multi-Tenant (Different Models per Instance)

```bash
# Tenant A model on instance 1
axon publish tenant-a/model@latest --target mlos-core-1

# Tenant B model on instance 2
axon publish tenant-b/model@latest --target mlos-core-2

# Result: Isolated model deployments per tenant
```

### Use Case 4: Network Storage (Shared Repository)

```bash
# Publish to shared NFS location
axon publish hf/bert-base-uncased@latest --target nfs://mlos-repo/models

# All MLOS Core instances mount nfs://mlos-repo/models
# All instances can access the model
```

### Use Case 5: Staging → Production Promotion

```bash
# Publish to staging cluster
axon publish hf/bert-base-uncased@latest --target mlos-cluster-staging

# After validation, promote to production
axon publish hf/bert-base-uncased@latest --target mlos-cluster-prod
```

### Use Case 6: Federated Learning/Evaluation

```bash
# Distribute initial model to all participants
axon publish federated-model@v1.0 --target mlos-federated-cluster

# After federated learning round, distribute updated model
axon publish federated-model@v1.1 --target mlos-federated-cluster

# Federated evaluation across distributed datasets
mlos federated evaluate federated-model@v1.1 --target mlos-federated-cluster
```

**See [FEDERATED_LEARNING_ARCHITECTURE.md](FEDERATED_LEARNING_ARCHITECTURE.md) for complete federated learning design.**

## Benefits

1. ✅ **Flexible Deployment**: Target specific instances or clusters
2. ✅ **Multi-Tenant Support**: Different models on different instances
3. ✅ **Scalability**: Publish to multiple instances simultaneously
4. ✅ **Network Storage**: Shared repository across instances
5. ✅ **Service Discovery**: Automatic instance discovery
6. ✅ **Rollout Control**: Gradual deployment across cluster
7. ✅ **Isolation**: Tenant-specific model deployments
8. ✅ **Federated Learning Ready**: Foundation for federated learning/evaluation (see [FEDERATED_LEARNING_ARCHITECTURE.md](FEDERATED_LEARNING_ARCHITECTURE.md))

## Configuration Examples

### Single Instance
```yaml
mlos_targets:
  mlos-core-1:
    endpoint: http://mlos-core-1:8080
    storage_type: filesystem
    storage_path: /var/lib/mlos/models
    access_method: ssh
    ssh_host: mlos-core-1
    ssh_user: mlos
```

### Cluster
```yaml
mlos_targets:
  mlos-cluster-prod:
    type: cluster
    instances:
      - mlos-core-1:8080
      - mlos-core-2:8080
      - mlos-core-3:8080
    storage_type: filesystem
    storage_path: /var/lib/mlos/models
    access_method: ssh
```

### Network Storage
```yaml
mlos_targets:
  mlos-shared-repo:
    type: network_storage
    storage_type: nfs
    storage_path: nfs://mlos-repo/models
    notify_instances:
      - http://mlos-core-1:8080
      - http://mlos-core-2:8080
```

---

**This architecture enables flexible, targeted model deployment across single instances, clusters, or shared network storage!**

