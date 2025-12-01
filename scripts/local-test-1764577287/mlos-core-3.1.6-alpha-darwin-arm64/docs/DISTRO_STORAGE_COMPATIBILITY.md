# Storage Architecture: Ubuntu vs Flatcar Linux Compatibility

## Overview

The shared model repository architecture (`/var/lib/mlos/models/`) works on **both Ubuntu and Flatcar Linux** with proper configuration. This document explains the compatibility and implementation details for each distribution.

## Filesystem Architecture Comparison

### Ubuntu (Traditional Linux)

**Filesystem Structure:**
```
/ (root)
├── /usr/          # System programs (writable, managed by package manager)
├── /etc/          # Configuration files (writable)
├── /var/          # Variable data (writable, persistent)
│   └── /var/lib/  # Application data (writable)
│       └── /var/lib/mlos/models/  ✅ Our model repository
└── /home/         # User home directories (writable)
```

**Characteristics:**
- ✅ Fully writable filesystem
- ✅ Standard Linux permissions
- ✅ Package manager manages `/usr` and `/etc`
- ✅ `/var/lib` is for application data (per FHS)
- ✅ No special considerations needed

### Flatcar Linux (Immutable Filesystem)

**Filesystem Structure:**
```
/ (root) - Immutable (OSTree-based)
├── /usr/          # System programs (read-only, updated atomically)
├── /etc/          # Configuration (read-only, updated atomically)
├── /var/          # Variable data (WRITABLE, persistent)
│   └── /var/lib/  # Application data (WRITABLE)
│       └── /var/lib/mlos/models/  ✅ Our model repository
└── /home/         # User home directories (writable)
```

**Characteristics:**
- ✅ Immutable root (`/usr`, `/etc`) - updated atomically
- ✅ `/var` is **always writable** (persistent data)
- ✅ `/var/lib` is for application data (per FHS)
- ✅ Data in `/var` survives OS updates
- ✅ Container deployments use bind mounts

**Key Insight:** Flatcar's "immutable filesystem" only affects the root OS (`/usr`, `/etc`). User data and application data in `/var` are fully writable and persistent.

## Shared Model Repository: `/var/lib/mlos/models/`

### Why This Works on Both

**Filesystem Hierarchy Standard (FHS):**
- `/var/lib` is designated for **persistent application data**
- Both Ubuntu and Flatcar follow FHS
- `/var/lib/mlos/models/` is the correct location per FHS

**Ubuntu:**
- Standard writable filesystem
- No restrictions on `/var/lib/mlos/models/`
- Works with systemd services
- Standard permissions model

**Flatcar:**
- `/var` is writable (even with immutable root)
- `/var/lib/mlos/models/` is persistent across OS updates
- Works with systemd services
- Works with containers (bind mount)

## Implementation Details

### Ubuntu Setup

**1. Create Directory (Package Installation):**
```bash
# In .deb package postinst script
mkdir -p /var/lib/mlos/models
chown mlos:mlos /var/lib/mlos/models
chmod 775 /var/lib/mlos/models
```

**2. systemd Service:**
```ini
[Unit]
Description=MLOS Core
After=network.target

[Service]
Type=simple
User=mlos
Group=mlos
ExecStart=/usr/bin/mlos_core
Environment="MLOS_MODEL_REPOSITORY=/var/lib/mlos/models"

[Install]
WantedBy=multi-user.target
```

**3. Axon Configuration:**
```yaml
# /etc/axon/config.yaml (system-wide)
cache_dir: /var/lib/mlos/models
```

### Flatcar Linux Setup

**1. Create Directory (Ignition Config):**
```yaml
# ignition.yaml
storage:
  filesystems:
    - name: "var"
      mount:
        device: "/dev/disk/by-label/var"
        format: "ext4"
  directories:
    - path: /var/lib/mlos/models
      mode: 0775
      user:
        name: mlos
      group:
        name: mlos
```

**2. systemd Service (Same as Ubuntu):**
```ini
[Unit]
Description=MLOS Core
After=network.target

[Service]
Type=simple
User=mlos
Group=mlos
ExecStart=/usr/bin/mlos_core
Environment="MLOS_MODEL_REPOSITORY=/var/lib/mlos/models"

[Install]
WantedBy=multi-user.target
```

**3. Axon Configuration (Same as Ubuntu):**
```yaml
# /etc/axon/config.yaml (system-wide)
cache_dir: /var/lib/mlos/models
```

**4. Container Deployment (Optional):**
```yaml
# Kubernetes/Container deployment
volumes:
  - name: mlos-models
    hostPath:
      path: /var/lib/mlos/models
      type: Directory
containers:
  - name: mlos-core
    volumeMounts:
      - name: mlos-models
        mountPath: /var/lib/mlos/models
```

## Key Differences & Considerations

### Ubuntu

**Advantages:**
- ✅ Standard Linux, familiar to most users
- ✅ Full package manager (apt) for dependencies
- ✅ Easy development and testing
- ✅ No special filesystem considerations

**Considerations:**
- Standard filesystem permissions
- Package manager handles directory creation
- Systemd service standard configuration

### Flatcar Linux

**Advantages:**
- ✅ Immutable OS (security, reliability)
- ✅ Atomic updates (A/B partitions)
- ✅ Container-optimized
- ✅ Minimal attack surface

**Considerations:**
- ✅ `/var/lib/mlos/models/` is writable (no issue)
- ✅ Directory created via Ignition (provisioning)
- ✅ Data persists across OS updates (stored in `/var`)
- ✅ Container deployments use bind mounts
- ⚠️ No package manager (uses containers or ebuild)

**Important:** Flatcar's immutable filesystem does NOT prevent writing to `/var/lib/mlos/models/`. The immutability only affects the OS root (`/usr`, `/etc`), not application data in `/var`.

## Path Validation

**Both Distributions:**

MLOS Core should validate that all model paths are within the repository:

```c
// Path validation (works on both Ubuntu and Flatcar)
int validate_model_path(const char* path, const char* repository_root) {
    char resolved_path[PATH_MAX];
    char resolved_root[PATH_MAX];
    
    // Resolve absolute paths
    if (realpath(path, resolved_path) == NULL) return -1;
    if (realpath(repository_root, resolved_root) == NULL) return -1;
    
    // Check if path is within repository
    if (strncmp(resolved_path, resolved_root, strlen(resolved_root)) != 0) {
        return -1; // Path outside repository
    }
    
    return 0; // Valid
}
```

## Container Deployment (Flatcar)

**Flatcar is container-optimized**, so models can be in:

1. **Host Path (Recommended):**
   ```yaml
   # Bind mount from host
   volumes:
     - /var/lib/mlos/models:/var/lib/mlos/models
   ```
   - Models on host filesystem
   - Accessible to both Axon and MLOS Core containers
   - Persists across container restarts

2. **Container Volume:**
   ```yaml
   # Named volume
   volumes:
     - mlos-models:/var/lib/mlos/models
   ```
   - Models in container volume
   - Managed by container runtime
   - Shared between containers

3. **Network Storage:**
   ```yaml
   # NFS or object storage
   volumes:
     - nfs://mlos-repo/models:/var/lib/mlos/models
   ```
   - Models on network storage
   - Works across nodes
   - Scalable

## Testing on Both Distributions

### Ubuntu Test
```bash
# Create directory
sudo mkdir -p /var/lib/mlos/models
sudo chown mlos:mlos /var/lib/mlos/models
sudo chmod 775 /var/lib/mlos/models

# Test write access
echo "test" | sudo -u mlos tee /var/lib/mlos/models/test.txt
# ✅ Should succeed
```

### Flatcar Test
```bash
# Create directory (via Ignition or manually)
sudo mkdir -p /var/lib/mlos/models
sudo chown mlos:mlos /var/lib/mlos/models
sudo chmod 775 /var/lib/mlos/models

# Test write access
echo "test" | sudo -u mlos tee /var/lib/mlos/models/test.txt
# ✅ Should succeed (even with immutable root)
```

## Conclusion

**✅ `/var/lib/mlos/models/` works on BOTH Ubuntu and Flatcar Linux:**

1. **Ubuntu**: Standard writable filesystem - no issues
2. **Flatcar**: `/var` is writable (immutability only affects `/usr`, `/etc`)
3. **Both**: Follow FHS standard for `/var/lib`
4. **Both**: Use systemd (same service configuration)
5. **Both**: Support container deployments

**The shared model repository architecture is compatible with both distributions!**

---

**Next Steps:**
1. Update Axon config to use `/var/lib/mlos/models/` by default
2. Update MLOS Core config to use `/var/lib/mlos/models/`
3. Create Ignition config for Flatcar
4. Test on both distributions

