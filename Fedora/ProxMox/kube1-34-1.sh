#!/bin/bash
# works on 
# - Fedora-Cloud-Base-AmazonEC2-42-1.1.x86_64.raw
# - Fedora-Cloud-Base-AmazonEC2-43-1.6.x86_64.raw

set -euo pipefail


dnf -y update
dnf -y install \
  curl wget vim tar socat conntrack iptables iproute nvme-cli \
  chrony e2fsprogs cloud-init qemu-guest-agent

systemctl enable chronyd
systemctl enable qemu-guest-agent
systemctl enable cloud-init

dnf -y install containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]also
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/repodata/repomd.xml.key
EOF

sudo systemctl stop swap-create@zram0
sudo dnf remove zram-generator-defaults

dnf -y install kubelet kubeadm kubectl
systemctl enable kubelet

cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
nvme_tcp
EOF

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

grubby --update-kernel=ALL --args=nvme_core.multipath=Y

swapoff -a
sed -i '/swap/d' /etc/fstab


dnf -y clean all
rm -f /etc/ssh/ssh_host_*
cloud-init clean --logs --seed
truncate -s 0 /var/log/*log || true
journalctl --rotate
journalctl --vacuum-time=1s
sudo sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
history -c
