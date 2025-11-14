# kubeseries-os-templating

Scripts and configurations for preparing operating system images to be used as templates for Kubernetes and ClusterAPI.

This repository contains per-OS setup scripts (Fedora, Ubuntu, Arch, etc.) designed to produce VM templates that are ready for Kubernetes workloads.

## Repository Structure

``` bash
.
├── Fedora
│   └── ProxMox
│       └── kube1-34-1.sh
├── LICENSE
└── README.MD
```
## Key Features

- Automated installation and configuration of containerd  
- Setup for kubeadm, kubelet, and kubectl  
- cloud-init and hypervisor agent specific
- Kernel, modules, and sysctl configuration for Kubernetes  
- Final cleanup to produce reusable VM templates

## Usage

Run the script for the target operating system on the template VM you plan to use. 

## Tips and Tricks

in ProxMox, you can create a VM from GUI, then you need to import the raw image, then add the disk from gui (you will see an unused disk after the import)
import cloud image into Proxmox from shell:  
``` bash
qm disk import ${vm_id}$ ${raw_image_file} ${storage_id}
```


## Recommended Commit Types

| Type    | Content                                   | Example Commit                                  |
|---------|-----------------------------------------------|------------------------------------------------|
| `feat`  | Adding a new plugin or snippet                | `feat: add kubevip daemonset`          |
| `fix`   | Fixing an existing plugin or snippet          | `fix: correct args or files`  |
| `docs`  | Updating documentation                         | `docs: add usage instructions`  |
| `chore` | Repo cleanup, folder reorganization, config   | `chore: reorganize folders`           |

