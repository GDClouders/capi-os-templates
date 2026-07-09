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
dnf install -y qemu-guest-agent-2:10.2.2-1.fc44.x86_64 

echo "[INFO] Disabling firewalld to let Kubernetes handle iptables..."
if systemctl is-enabled firewalld &>/dev/null; then
    systemctl disable --now firewalld
    systemctl mask firewalld
fi

echo "[INFO] Enabling base services..."
systemctl enable chronyd
systemctl enable qemu-guest-agent
systemctl enable cloud-final        
systemctl enable cloud-init-local   
systemctl enable cloud-init-network 

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



cat <<EOF >> /etc/sysctl.d/k8s.conf
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=1048576
fs.inotify.max_queued_events=32768
net.netfilter.nf_conntrack_max = 524288
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 1024 65535
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.vm.overcommit_memory = 1
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
vm.min_free_kbytes = 131072
vm.max_map_count = 262144
fs.file-max = 2097152
kernel.pid_max = 4194303
EOF

# Apply sysctl settings
sysctl --system

# Enable NVMe multipath for remote storage
grubby --update-kernel=ALL --args="nvme_core.multipath=Y elevator=none transparent_hugepage=never"
echo "[INFO] Adding Kubernetes repository..."
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.36/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.36/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

echo "[INFO] Installing kubeadm, kubelet, kubectl (version 1.36.0)..."
dnf -y install --disableexcludes=kubernetes \
  kubelet-1.36.2\
  kubeadm-1.36.2 \
  kubectl-1.36.2

systemctl enable kubelet

echo "[INFO] Pre-pulling Kubernetes control plane images..."
kubeadm config images pull --kubernetes-version=v1.36.2

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


echo "[INFO] Writing CAPI metadata..."
mkdir -p /etc/kubernetes/
cat <<EOF > /etc/kubernetes/metadata.json
{
  "kubernetes_version": "v1.36.2",
  "container_runtime": "containerd",
  "os_name": "fedora",
  "os_version": "44"
}
EOF


echo "[SUCCESS] Preparation completed!"
echo "[INFO] Shutting down in 5 seconds..."
sleep 5

history -c && history -w
shutdown -h now
