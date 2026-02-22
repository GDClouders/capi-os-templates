#!/bin/bash
# Works on:
# - Arch Linux Cloud Images (es. Amazon EC2 / KVM)

set -euo pipefail

echo "[INFO] Updating packages..."
pacman -Syu --noconfirm # <-- Aggiunto --noconfirm

# pacman-key --populate archlinux
# pacman-key --refresh-keys
# pacman -Sy --noconfirm archlinux-keyring

echo "[INFO] Installing base packages..."
pacman -S --needed --noconfirm --ask 4 \
  curl wget vim tar socat conntrack-tools iptables-nft iproute2 nvme-cli \
  chrony e2fsprogs cloud-init

# Pin qemu-guest-agent version for stability
echo "[INFO] Installing qemu-guest-agent..."
wget https://archive.archlinux.org/packages/q/qemu-guest-agent/qemu-guest-agent-10.0.0-7-x86_64.pkg.tar.zst
pacman -U  --needed --noconfirm qemu-guest-agent-10.0.0-7-x86_64.pkg.tar.zst
rm qemu-guest-agent*.zst

echo "[INFO] Enabling base services..."
systemctl enable chronyd
systemctl daemon-reload
systemctl enable cloud-init-local.service \
                 cloud-init-main.service \
                 cloud-config.service \
                 cloud-final.service

echo "[INFO] Installing containerd..."
pacman -S --needed --noconfirm containerd runc
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
# Configure SystemdCgroup for kubelet
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

echo "[INFO] Disabling swap and ZRAM..."
swapoff -a || true
sed -i '/swap/d' /etc/fstab
# Remove ZRAM if present
if systemctl is-active --quiet systemd-zram-setup@zram0.service 2>/dev/null; then
    systemctl stop systemd-zram-setup@zram0.service
fi
if pacman -Qs zram-generator > /dev/null; then
    pacman -Rs --noconfirm zram-generator
fi

echo "[INFO] Configuring kernel modules and sysctl..."
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
nvme_tcp
EOF

# # Load modules immediately
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
if [ -f /etc/default/grub ]; then
    GRUB_CMDLINE_PARAM="nvme_core.multipath=Y"
    sed -i "s/\(GRUB_CMDLINE_LINUX_DEFAULT=['\"]\)/\1$GRUB_CMDLINE_PARAM /" /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg
else
    echo "[WARNING] /etc/default/grub not found. If using systemd-boot, update kernel args manually."
fi

echo "[INFO] Installing kubeadm, kubelet, kubectl (version 1.34.0)..."
wget https://archive.archlinux.org/packages/k/kubelet/kubelet-1.34.0-1-x86_64.pkg.tar.zst
wget https://archive.archlinux.org/packages/k/kubeadm/kubeadm-1.34.0-1-x86_64.pkg.tar.zst
wget https://archive.archlinux.org/packages/k/kubectl/kubectl-1.34.0-1-x86_64.pkg.tar.zst
pacman -U --needed --noconfirm --ask 4 \
  kubelet-1.34.0-1-x86_64.pkg.tar.zst \
  kubeadm-1.34.0-1-x86_64.pkg.tar.zst \
  kubectl-1.34.0-1-x86_64.pkg.tar.zst
rm kube*.zst # <-- Reso il rm più specifico
systemctl enable kubelet

echo "[INFO] Pinning versions in pacman.conf..."
sed -i 's/^#IgnorePkg.*/IgnorePkg = kubelet kubeadm kubectl qemu-guest-agent/' /etc/pacman.conf

echo "[INFO] Cleaning image for template..."
rm -rf /var/cache/pacman/pkg/*

yes | pacman -Scc || true

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

shutdown -h now