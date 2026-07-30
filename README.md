# Kubernetes Manifest Generator

**v2.0** — A Bash CLI that generates production-grade Kubernetes YAML manifests.

This tool helps developers and DevOps engineers quickly create valid, security-hardened Kubernetes resource manifests without hand-writing YAML. Workload manifests come with sensible defaults baked in — `securityContext` (Pod Security Standard *restricted*), resource requests/limits, health probes, and `imagePullPolicy` — so the output is closer to what you'd actually ship, not just a bare skeleton.

---

## Overview

Writing Kubernetes manifests by hand is repetitive and error-prone. This script guides you through a resource's configuration and generates the corresponding YAML automatically, applying opinionated best-practice defaults to every workload.

Unlike the previous version, manifests are now built from **internal templates** rather than from `kubectl` imperative commands. This gives full control over the output quality and means **`kubectl` is no longer required to generate manifests** — it is used only, and optionally, to validate them.

The generated YAML can be printed to stdout, saved to a file, versioned, or applied to a cluster.

---

## Features

- Interactive **and** non-interactive (scriptable) manifest generation
- Template-based, deterministic output — no hard dependency on a cluster or `kubectl`
- Security-hardened workloads by default:
  - Pod & container `securityContext` compliant with Pod Security Standard **restricted**
  - `runAsNonRoot`, dropped capabilities, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`
- Resource `requests`/`limits` on every workload, via selectable profiles (low / medium / high)
- Liveness, readiness **and** `startupProbe` (TCP by default, HTTP optional)
- `imagePullPolicy`, `revisionHistoryLimit`, and configurable rollout strategy
- Environment variables (`env` / `envFrom`) and `imagePullSecrets` (advanced deployment & full stack)
- **Kustomization** generation that auto-collects the files you just produced
- Optional output **validation** via `kubeconform` or `kubectl` client dry-run
- Input validation that rejects unsafe values before they reach the manifest
- `--stdout` mode for piping straight into `kubectl apply -f -`
- Prevents accidental file overwrites

---

## Requirements

| Tool          | Required | Purpose                                  |
|---------------|----------|------------------------------------------|
| `bash`        | ✅ Yes   | Runs the generator                       |
| `kubectl`     | ⬜ No    | Optional — client-side manifest validation |
| `kubeconform` | ⬜ No    | Optional — preferred schema validation    |

If neither `kubectl` nor `kubeconform` is present, generation still works; only the validation step is skipped.

---

## Installation

Clone the repository:

```bash
git clone https://github.com/amirhoseinjafari1/k8s-manifest-generator.git
cd k8s-manifest-generator
```

Make the script executable:

```bash
chmod +x manifest-gen.sh
```

---

## Usage

Run interactively:

```bash
./manifest-gen.sh
```

The script guides you through prompts (resource name, namespace, image, ports, replicas, resource profile, probes, storage, schedule, etc.) and then writes the manifest.

### Command-line options

```
-t, --type TYPE          Resource type (see list below)
-n, --name NAME          Resource name
-i, --image IMAGE        Container image (default: nginx:latest)
-r, --replicas NUM       Replicas (default: 3)
-p, --port PORT          Port (default: 80)
    --namespace NS       Namespace (default: default)
    --profile N          Resource profile: 1=low 2=medium 3=high (default: 2)
    --output-dir DIR     Output directory (default: .)
    --stdout             Print manifest to stdout (no file written)
    --no-security        Do NOT emit securityContext (for images needing root)
    --validate MODE      auto | on | off  (default: auto)
    --non-interactive    No prompts (uses defaults / CLI flags)
-f, --force              Overwrite existing files without asking
    --debug              Verbose debug logging
-h, --help               Show help
-v, --version            Show version
```

### Examples

Generate a hardened deployment to a file:

```bash
./manifest-gen.sh -t deployment-adv -n web -i nginx:1.27 -f
```

Generate non-interactively and apply in one line:

```bash
./manifest-gen.sh -t deployment -n api --stdout --non-interactive | kubectl apply -f -
```

Generate a full microservice stack:

```bash
./manifest-gen.sh -t full-stack -n myapp -f
```

Build a set of manifests, then a Kustomization referencing them:

```bash
./manifest-gen.sh -t deployment -n web --output-dir ./manifests -f
./manifest-gen.sh -t service    -n web --output-dir ./manifests -f
./manifest-gen.sh -t kustomize        --output-dir ./manifests
kubectl apply -k ./manifests
```

---

## Supported Resources

| # | Type (`--type`)      | Notes                                         |
|---|----------------------|-----------------------------------------------|
| 1 | `pod`                | Hardened Pod                                  |
| 2 | `deployment`         | Hardened Deployment                           |
| 3 | `service`            | ClusterIP / NodePort / LoadBalancer           |
| 4 | `configmap`          |                                               |
| 5 | `namespace`          |                                               |
| 6 | `ingress`            | networking.k8s.io/v1                          |
| 7 | `secret`             | generic / opaque                              |
| 8 | `job`                |                                               |
| 9 | `cronjob`            | batch/v1, supports `@daily` shorthand         |
| 10| `pvc`                |                                               |
| 11| `deployment-adv`     | + probes (HTTP/TCP), env, strategy, pull secrets |
| 12| `hpa`                | autoscaling/v2, CPU and optional memory target |
| 13| `statefulset`        | + headless Service and volumeClaimTemplates   |
| 14| `daemonset`          | optional port, tolerations                    |
| 15| `serviceaccount`     | + Role and RoleBinding (RBAC)                 |
| 16| `networkpolicy`      |                                               |
| 17| `pdb`                | PodDisruptionBudget                           |
| 18| `kustomize`          | kustomization.yaml from generated files       |
| 19| `full-stack`         | Namespace + SA + ConfigMap + Secret + Deployment + Service + NetworkPolicy (+ optional HPA/Ingress) |

---

## Security Defaults

Every workload is generated with a `securityContext` that satisfies the Kubernetes **Pod Security Standard: restricted** profile:

**Pod level**

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 3000
  fsGroup: 2000
  seccompProfile:
    type: RuntimeDefault
```

**Container level**

```yaml
securityContext:
  allowPrivilegeEscalation: false
  privileged: false
  runAsNonRoot: true
  capabilities:
    drop:
      - ALL
  seccompProfile:
    type: RuntimeDefault
```

> **Note:** `runAsNonRoot: true` means images that require root will not start. The stock `nginx:latest` image, for example, binds port 80 as root and won't run under these defaults — use a rootless image such as `nginxinc/nginx-unprivileged`, or pass `--no-security` to omit the `securityContext` for that resource.
>
> `readOnlyRootFilesystem` is intentionally **not** set, since it is not required by the *restricted* profile and breaks many common images.

---

## Validation

When `--validate` is `auto` (default) or `on`, each generated file is checked:

1. If `kubeconform` is installed, it runs `kubeconform -strict`.
2. Otherwise, if `kubectl` is installed, it runs `kubectl apply --dry-run=client`.
3. If neither is available, validation is skipped (and, under `--validate on`, treated as an error).

Set `--validate off` to skip validation entirely.

---

## How It Works

Manifests are assembled from internal Bash templates. Shared building blocks (security context, resources, probes) are composed and indented into each resource, so output is consistent and controllable. This approach ensures that:

- generated manifests follow the Kubernetes schema and current API versions
- workloads ship with production-grade defaults, not bare skeletons
- generation has no runtime dependency on a cluster or on `kubectl`
- output is easy to review, diff, and modify

Every run also writes a timestamped log to `/tmp/k8s-gen-*.log` for debugging.

---

## Example Workflow

1. Run the generator (interactively or with flags)
2. Provide/confirm resource configuration
3. Review the generated YAML (optionally validated automatically)
4. Commit it to version control
5. Apply it to a cluster:

```bash
kubectl apply -f web-deployment.yaml
# or, for a Kustomize directory:
kubectl apply -k ./manifests
```

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

- Learning what a well-formed, hardened Kubernetes manifest looks like
- Quickly generating YAML templates with sane defaults
- Bootstrapping Kubernetes resources for a new service
- DevOps automation and CI workflows (`--non-interactive`, `--stdout`)

---

## License

MIT License
