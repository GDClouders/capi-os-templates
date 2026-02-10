#!/bin/bash
# Works on:
# - Fedora-Cloud-Base-AmazonEC2-42-1.1.x86_64.raw
# - Fedora-Cloud-Base-AmazonEC2-43-1.6.x86_64.raw

set -euo pipefail

echo "[INFO] Updating packages..."
dnf -y update

echo "[INFO] Installing base packages..."
dnf -y install \
  curl wget vim tar socat conntrack iptables iproute nvme-cli \
  chrony e2fsprogs cloud-init

# Pin qemu-guest-agent version for stability
echo "[INFO] Installing qemu-guest-agent..."
dnf -y install qemu-guest-agent-2:10.1.0-7.fc43.x86_64

echo "[INFO] Enabling base services..."
systemctl enable chronyd
systemctl enable qemu-guest-agent
systemctl enable cloud-init

echo "[INFO] Installing containerd..."
dnf -y install containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
# Configure SystemdCgroup for kubelet
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

echo "[INFO] Disabling swap and ZRAM..."
swapoff -a || true
sed -i '/swap/d' /etc/fstab
# Remove ZRAM if present
if systemctl is-active --quiet swap-create@zram0 2>/dev/null; then
    systemctl stop swap-create@zram0
fi
if rpm -q zram-generator-defaults &>/dev/null; then
    dnf -y remove zram-generator-defaults
fi

echo "[INFO] Configuring kernel modules and sysctl..."
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
nvme_tcp
EOF

# Load modules immediately
modprobe overlay
modprobe br_netfilter
modprobe nvme_tcp

cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

# Apply sysctl settings
sysctl --system

# Enable NVMe multipath for remote storage
grubby --update-kernel=ALL --args="nvme_core.multipath=Y"

echo "[INFO] Adding Kubernetes repository..."
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

echo "[INFO] Installing kubeadm, kubelet, kubectl (version 1.34.0)..."
dnf -y install --disableexcludes=kubernetes \
  kubelet-1.34.0-1.1 \
  kubeadm-1.34.0-1.1 \
  kubectl-1.34.0-1.1
systemctl enable kubelet

echo "[INFO] Setting SELinux to permissive mode..."
# Simple and effective approach for Kubernetes
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
setenforce 0 || true

echo "[INFO] Cleaning image for template..."
dnf -y clean all
rm -rf /var/cache/dnf/*
rm -f /etc/ssh/ssh_host_*
rm -f /root/.bash_history
cloud-init clean --logs --seed

# Clean logs
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true
journalctl --rotate
journalctl --vacuum-time=1s

# Remove temporary files
rm -rf /tmp/* /var/tmp/*

# Reset machine-id (will be regenerated on first boot)
truncate -s 0 /etc/machine-id

echo "[SUCCESS] Preparation completed!"
echo "[INFO] Shutting down in 5 seconds..."
sleep 5

history -c && history -w
shutdown -h now