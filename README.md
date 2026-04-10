# Kubernetes Manifest Generator

A Bash CLI tool that generates Kubernetes YAML manifests using `kubectl` imperative commands.

This tool helps developers and DevOps engineers quickly create valid Kubernetes resource manifests without manually writing YAML files.

Instead of crafting manifests from scratch, the script converts `kubectl` commands into reusable YAML definitions.

---

## Overview

Writing Kubernetes manifests manually can be repetitive and error‑prone.  
This script simplifies the process by guiding the user through resource configuration and generating the corresponding YAML manifest automatically.

It internally relies on the Kubernetes CLI to ensure the generated manifests follow Kubernetes standards.

```
kubectl create <resource> ... --dry-run=client -o yaml
```

The generated YAML can then be stored, modified, versioned, or applied to a cluster.

---

## Features

- Interactive manifest generation
- Converts **imperative kubectl commands → declarative YAML**
- Supports multiple Kubernetes resource types
- Basic input validation
- Prevents accidental file overwrites
- Structured output manifests
- Simple Bash implementation (no external dependencies besides kubectl)

---

## Requirements

The following tools must be installed:

- **bash**
- **kubectl**

Verify kubectl installation:

```
kubectl version --client
```

---

## Installation

Clone the repository:

```
git clone https://github.com/amirhoseinjafari1/k8s-manifest-generator.git
cd k8s-manifest-generator
```

Make the script executable:

```
chmod +x manifest-gen.sh
```

---

## Usage

Run the generator:

```
./manifest-gen.sh
```

The script will guide you through a series of prompts to collect information about the Kubernetes resource.

Example prompts may include:

- Resource name
- Namespace
- Container image
- Ports
- Replica count
- Storage configuration
- Scheduling configuration (CronJob)

After collecting the required information, the script generates a YAML manifest file.

---

## Supported Resources

The generator can create manifests for common Kubernetes resources such as:

- Pod
- Deployment
- Service
- ConfigMap
- Secret
- Namespace
- Ingress
- Job
- CronJob
- PersistentVolumeClaim
- StatefulSet
- DaemonSet
- HorizontalPodAutoscaler
- ServiceAccount
- NetworkPolicy

---

## Example Workflow

Typical workflow when using this tool:

1. Run the generator
2. Provide resource configuration through prompts
3. Generate the YAML manifest
4. Review or modify the file
5. Apply it to a cluster

```
kubectl apply -f deployment.yaml
```

---

## How It Works

The script generates Kubernetes manifests using the Kubernetes CLI with the following pattern:

```
kubectl create <resource> --dry-run=client -o yaml
```

This approach ensures that:

- generated manifests follow Kubernetes schema
- resource definitions remain compatible with kubectl
- users can easily modify the generated YAML

---

## Project Structure

```
.
├── manifest-gen.sh
├── README.md
└── LICENSE
```

---

## Use Cases

This tool can be useful for:

- Learning Kubernetes manifests
- Quickly generating YAML templates
- Bootstrapping Kubernetes resources
- DevOps automation workflows

---

## License

MIT License
