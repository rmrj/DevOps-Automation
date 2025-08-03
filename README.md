# DevOps-Automation

# DevOps Automation

This repository is a curated collection of real-world DevOps automation scripts, infrastructure-as-code (IaC) patterns, and migration blueprints designed to streamline Kubernetes, Terraform, CI/CD, cloud provisioning, and more.

These tools are built for production-grade use, tested in real environments like Google Kubernetes Engine (GKE), AWS, and GitHub Actions, and structured to help teams accelerate their platform engineering efforts with confidence.

---

## 🔧 Current Solutions

### 1. **GKE C4 Node Upgrade + Hyperdisk StatefulSet Migration**

A fully automated and zero-downtime approach to migrate your GKE workloads to:
- C4 confidential VMs
- Hyperdisk-balanced persistent volumes
- Terraform `google-beta` provider compatibility

Includes:
- Automation scripts (`migrate_and_recreate_all_volumes.sh`)
- Helper scripts (`cordon.sh`, `drain.sh`, `delete.sh`)
- Dynamic PVC patching logic
- Terraform snippets for official GKE module

📖 **Full documentation:** [Read the upgrade strategy here](https://github.com/rmrj/DevOps-Automation/blob/main/docs/gke-c4-upgrade.md)

---

## 🚀 Upcoming Additions

- Secure secret sync across Kubernetes namespaces using Vault Secrets Operator
- GitHub Actions runners on Kubernetes with auto-scaling
- Terraform module documentation automation
- Cloud-native alerting integration with Squadcast and New Relic
- Dev environment containers for VS Code
- Kubernetes image digest scanners for ECR/GCR validation

---

## 🧠 Who Is This For?

- **DevOps Engineers** managing GKE, EKS, or Terraform workflows
- **Platform Engineers** building automation for scale and safety
- **Site Reliability Engineers** focused on zero-downtime migrations and reproducible infra
- **Cloud Architects** designing secure, high-performance environments

---

## 🛠️ Tools & Technologies

- Terraform (including `google-beta`, AWS modules)
- Kubernetes (StatefulSets, StorageClass, PV/PVC)
- GCP: GKE, Hyperdisk, IAM
- Bash, `jq`, `kubectl`, `gcloud`
- GitHub Actions
- Vault / VSO / Argo CD

---

## 📂 Repository Structure

```plaintext
.
├── scripts/                    # All automation scripts
│   ├── migrate_and_recreate_all_volumes.sh
│   ├── cordon.sh
│   ├── drain.sh
│   └── delete.sh
├── terraform/                 # Terraform snippets and modules
│   └── gke-c4-nodepool.tf
├── docs/                      # Markdown-based guides
│   └── gke-c4-upgrade.md
└── README.md
