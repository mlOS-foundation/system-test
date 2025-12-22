#!/bin/bash
# =============================================================================
# MLOS Self-Hosted Runner Setup Script
# =============================================================================
# This script sets up a Linux machine as a GitHub Actions self-hosted runner
# capable of running E2E tests with the MLOS kernel module.
#
# Requirements:
#   - Ubuntu 22.04+ or similar Linux distribution
#   - Root access
#   - Internet connection
#   - At least 8GB RAM, 50GB disk
#
# Usage:
#   sudo ./setup-kernel-runner.sh
#
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root (sudo ./setup-kernel-runner.sh)"
    exit 1
fi

echo ""
echo "=================================================================="
echo "  MLOS Self-Hosted Runner Setup"
echo "=================================================================="
echo ""

# =============================================================================
# Step 1: System Update
# =============================================================================
log_info "Step 1: Updating system packages..."

apt-get update
apt-get upgrade -y

log_success "System updated"

# =============================================================================
# Step 2: Install Build Dependencies
# =============================================================================
log_info "Step 2: Installing build dependencies..."

apt-get install -y \
    build-essential \
    linux-headers-$(uname -r) \
    git \
    curl \
    wget \
    jq \
    python3 \
    python3-pip \
    python3-venv \
    docker.io \
    kmod

# Enable Docker
systemctl enable docker
systemctl start docker

log_success "Build dependencies installed"

# =============================================================================
# Step 3: Clone Core Repository and Build Kernel Module
# =============================================================================
log_info "Step 3: Building MLOS kernel module..."

MLOS_DIR="/opt/mlos"
mkdir -p "$MLOS_DIR"
cd "$MLOS_DIR"

# Clone core repository (if not exists)
if [ ! -d "$MLOS_DIR/core" ]; then
    log_info "Cloning core repository..."
    git clone https://github.com/mlOS-foundation/core.git 2>/dev/null || \
    git clone git@github.com:mlOS-foundation/core.git
fi

cd "$MLOS_DIR/core/kernel"

# Build kernel module
log_info "Building kernel module for kernel $(uname -r)..."
make clean 2>/dev/null || true
make all

# Install kernel module
log_info "Installing kernel module..."
make install

# Verify installation
if [ -f "/lib/modules/$(uname -r)/extra/mlos-ml.ko" ]; then
    log_success "Kernel module installed at /lib/modules/$(uname -r)/extra/mlos-ml.ko"
else
    # Copy to /opt/mlos as fallback
    cp mlos-ml.ko /opt/mlos/kernel/
    log_success "Kernel module installed at /opt/mlos/kernel/mlos-ml.ko"
fi

# =============================================================================
# Step 4: Test Kernel Module Loading
# =============================================================================
log_info "Step 4: Testing kernel module..."

# Unload if already loaded
rmmod mlos_ml 2>/dev/null || rmmod mlos-ml 2>/dev/null || true

# Load module with debug
if modprobe mlos_ml debug_level=3 2>/dev/null || \
   insmod /opt/mlos/kernel/mlos-ml.ko debug_level=3 2>/dev/null; then
    log_success "Kernel module loaded successfully"

    # Verify device file
    if [ -c /dev/mlos-ml ]; then
        log_success "Device file /dev/mlos-ml created"
    else
        log_warn "Device file not created (may require udev rules)"
    fi

    # Show module info
    lsmod | grep mlos
    dmesg | tail -10

    # Unload for now (will be loaded during tests)
    rmmod mlos_ml 2>/dev/null || rmmod mlos-ml 2>/dev/null || true
else
    log_error "Failed to load kernel module"
    dmesg | tail -20
    exit 1
fi

# =============================================================================
# Step 5: Create GitHub Actions Runner User
# =============================================================================
log_info "Step 5: Setting up runner user..."

RUNNER_USER="github-runner"
RUNNER_HOME="/home/$RUNNER_USER"

# Create user if not exists
if ! id "$RUNNER_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$RUNNER_USER"
    log_success "Created user: $RUNNER_USER"
fi

# Add to docker and kmod groups
usermod -aG docker "$RUNNER_USER"
usermod -aG sudo "$RUNNER_USER"

# Allow passwordless sudo for module loading
echo "$RUNNER_USER ALL=(ALL) NOPASSWD: /sbin/insmod, /sbin/rmmod, /sbin/modprobe, /bin/dmesg" > /etc/sudoers.d/github-runner-mlos
chmod 440 /etc/sudoers.d/github-runner-mlos

log_success "Runner user configured"

# =============================================================================
# Step 6: Download GitHub Actions Runner
# =============================================================================
log_info "Step 6: Downloading GitHub Actions Runner..."

RUNNER_DIR="$RUNNER_HOME/actions-runner"
mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"

# Get latest runner version
RUNNER_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/v//')
RUNNER_ARCH=$(uname -m)
[ "$RUNNER_ARCH" = "x86_64" ] && RUNNER_ARCH="x64"
[ "$RUNNER_ARCH" = "aarch64" ] && RUNNER_ARCH="arm64"

RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"

log_info "Downloading runner v${RUNNER_VERSION}..."
curl -L -o runner.tar.gz "$RUNNER_URL"
tar -xzf runner.tar.gz
rm runner.tar.gz

chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"

log_success "Runner downloaded to $RUNNER_DIR"

# =============================================================================
# Step 7: Install Python Dependencies
# =============================================================================
log_info "Step 7: Installing Python dependencies..."

pip3 install pyyaml pillow numpy transformers torch torchvision

log_success "Python dependencies installed"

# =============================================================================
# Step 8: Create Configuration Script
# =============================================================================
log_info "Step 8: Creating configuration script..."

cat > "$RUNNER_DIR/configure-mlos-runner.sh" << 'SCRIPT'
#!/bin/bash
# Configure the GitHub Actions runner for MLOS

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: ./configure-mlos-runner.sh <GITHUB_ORG> <RUNNER_TOKEN>"
    echo ""
    echo "Get your runner token from:"
    echo "  https://github.com/organizations/<ORG>/settings/actions/runners/new"
    echo "  or"
    echo "  https://github.com/<ORG>/<REPO>/settings/actions/runners/new"
    exit 1
fi

GITHUB_ORG=$1
RUNNER_TOKEN=$2

./config.sh \
    --url "https://github.com/${GITHUB_ORG}" \
    --token "$RUNNER_TOKEN" \
    --name "mlos-kernel-runner-$(hostname)" \
    --labels "self-hosted,linux,kernel-capable,mlos" \
    --work "_work" \
    --replace

echo ""
echo "Runner configured! Start with: ./run.sh"
echo "Or install as service: sudo ./svc.sh install && sudo ./svc.sh start"
SCRIPT

chmod +x "$RUNNER_DIR/configure-mlos-runner.sh"
chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR/configure-mlos-runner.sh"

# =============================================================================
# Print Summary
# =============================================================================
echo ""
echo "=================================================================="
echo "  Setup Complete!"
echo "=================================================================="
echo ""
echo "Kernel module: /opt/mlos/kernel/mlos-ml.ko (or system modules dir)"
echo "Runner directory: $RUNNER_DIR"
echo "Runner user: $RUNNER_USER"
echo ""
echo "Next steps:"
echo "  1. Get a runner registration token from GitHub:"
echo "     https://github.com/mlOS-foundation/system-test/settings/actions/runners/new"
echo ""
echo "  2. Configure the runner:"
echo "     su - $RUNNER_USER"
echo "     cd $RUNNER_DIR"
echo "     ./configure-mlos-runner.sh mlOS-foundation <TOKEN>"
echo ""
echo "  3. Start the runner:"
echo "     ./run.sh  # Interactive"
echo "     # OR install as service:"
echo "     sudo ./svc.sh install"
echo "     sudo ./svc.sh start"
echo ""
echo "  4. Trigger the kernel E2E workflow from GitHub Actions"
echo ""
echo "=================================================================="
