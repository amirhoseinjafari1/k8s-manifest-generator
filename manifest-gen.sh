#!/usr/bin/env bash

#=============================================================
#  Kubernetes Manifest Generator — v3.3
#  Phase 1: Secret, CronJob/Job, PVC
#  Phase 2: HPA, Resource Limits, Probes (enhanced Deployment)
#  Phase 3: StatefulSet, DaemonSet, ServiceAccount+RBAC, NetworkPolicy
#=============================================================

set -euo pipefail

# ──────────────── Constants ────────────────
readonly VERSION="3.3"
readonly LOG_FILE="/tmp/k8s-gen-$(date +%Y%m%d-%H%M%S).log"
readonly SCRIPT_NAME="$(basename "$0")"

# ──────────────── Colors ────────────────
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ──────────────── Global Flags ────────────────
NON_INTERACTIVE=false
FORCE_OVERWRITE=false
OUTPUT_DIR="."
DEBUG=${DEBUG:-false}

# ──────────────── CLI Variables ────────────────
CLI_TYPE=""
CLI_NAME=""
CLI_IMAGE=""
CLI_REPLICAS=""
CLI_PORT=""
CLI_NAMESPACE=""

# ──────────────── Trap / Cleanup ────────────────
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script exited with code: $exit_code"
        log_error "Check log: $LOG_FILE"
    fi
}
trap cleanup EXIT INT TERM

# ──────────────── Banner ────────────────
banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
╔══════════════════════════════════════════════════╗
║       ☸  K8s Manifest Generator  v3.3  ☸        ║
║          Phase 1-3 : Full Coverage              ║
╚══════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# ──────────────── Logging ────────────────
_log() {
    local level="$1" color="$2" msg="$3"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${color}[${level}]${NC} ${msg}" >&2
    echo "[${ts}] [${level}] ${msg}" >> "$LOG_FILE"
}

log_info()  { _log "INFO"  "$GREEN"  "$1"; }
log_warn()  { _log "WARN"  "$YELLOW" "$1"; }
log_error() { _log "ERROR" "$RED"    "$1"; }
log_debug() { [[ "$DEBUG" == "true" ]] && _log "DEBUG" "$BLUE" "$1" || true; }

# ──────────────── Help ────────────────
show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Options:
  -t, --type TYPE          Resource type (see list below)
  -n, --name NAME          Resource name
  -i, --image IMAGE        Container image (default: nginx:latest)
  -r, --replicas NUM       Replicas (default: 3)
  -p, --port PORT          Port (default: 80)
      --namespace NS       Namespace (default: default)
      --output-dir DIR     Output directory (default: .)
      --non-interactive    No prompts
  -f, --force              Overwrite without asking
      --debug              Debug logging
  -h, --help               This help
  -v, --version            Version

Resource Types:
  pod, deployment, deployment-adv, service, configmap, secret,
  namespace, ingress, job, cronjob, pvc, hpa, statefulset,
  daemonset, serviceaccount, networkpolicy, full-stack

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} -t deployment-adv -n web -i nginx:1.25 -f
  ${SCRIPT_NAME} -t secret -n db-creds --non-interactive
  ${SCRIPT_NAME} -t full-stack -n myapp -f

EOF
    exit 0
}

show_version() {
    echo "K8s Manifest Generator v${VERSION}"
    exit 0
}

# ══════════════════════════════════════════════════
#  INPUT HELPERS
# ══════════════════════════════════════════════════
read_input() {
    local prompt="$1"
    local default="${2:-}"

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        [[ -z "$default" ]] && { log_error "No default for '${prompt}' in non-interactive mode"; exit 1; }
        echo "$default"
        return
    fi

    if [[ -n "$default" ]]; then
        echo -ne "${BLUE}[?]${NC} ${prompt} [${YELLOW}${default}${NC}]: " >&2
    else
        echo -ne "${BLUE}[?]${NC} ${prompt}: " >&2
    fi

    local value
    read -r value
    echo "${value:-$default}"
}

read_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    [[ "$NON_INTERACTIVE" == "true" ]] && { echo "$default"; return; }
    local answer
    answer=$(read_input "$prompt (y/n)" "$default")
    echo "$answer"
}

# ══════════════════════════════════════════════════
#  VALIDATORS
# ══════════════════════════════════════════════════
validate_k8s_name() {
    local n="$1"
    if [[ ! "$n" =~ ^[a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?$ ]]; then
        log_error "Invalid K8s name '${n}'"
        return 1
    fi
}

validate_port() {
    local p="$1"
    if [[ ! "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
        log_error "Invalid port '${p}'"
        return 1
    fi
}

validate_replicas() {
    local r="$1"
    if [[ ! "$r" =~ ^[0-9]+$ ]] || (( r < 1 || r > 100 )); then
        log_error "Invalid replicas '${r}'"
        return 1
    fi
}

validate_namespace() { validate_k8s_name "$1"; }

validate_filepath() {
    local p="$1"
    if [[ "$p" == *".."* ]]; then
        log_error "Path traversal in '${p}'"
        return 1
    fi
}

validate_cpu() {
    local c="$1"
    if [[ ! "$c" =~ ^[0-9]+(m)?$ ]]; then
        log_error "Invalid CPU '${c}' — e.g. 100m, 500m, 1"
        return 1
    fi
}

validate_memory() {
    local m="$1"
    if [[ ! "$m" =~ ^[0-9]+(Mi|Gi|Ki)$ ]]; then
        log_error "Invalid memory '${m}' — e.g. 128Mi, 1Gi"
        return 1
    fi
}

validate_storage() {
    local s="$1"
    if [[ ! "$s" =~ ^[0-9]+(Mi|Gi|Ti)$ ]]; then
        log_error "Invalid storage '${s}' — e.g. 1Gi, 10Gi"
        return 1
    fi
}

validate_cron_schedule() {
    local s="$1"
    local fields
    fields=$(echo "$s" | awk '{print NF}')
    if [[ "$fields" -ne 5 ]]; then
        log_error "Invalid cron '${s}' — need 5 fields"
        return 1
    fi
}

validate_positive_int() {
    local n="$1"
    if [[ ! "$n" =~ ^[0-9]+$ ]] || (( n < 1 )); then
        log_error "Invalid number '${n}'"
        return 1
    fi
}

validate_percentage() {
    local p="$1"
    if [[ ! "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 100 )); then
        log_error "Invalid percentage '${p}'"
        return 1
    fi
}

# Loop until valid
read_validated() {
    local prompt="$1" default="${2:-}" validator="$3"
    while true; do
        local value
        value=$(read_input "$prompt" "$default")
        if $validator "$value"; then
            echo "$value"
            return
        fi
        [[ "$NON_INTERACTIVE" == "true" ]] && exit 1
        log_warn "Try again..."
    done
}

# ══════════════════════════════════════════════════
#  SAFE WRITE
# ══════════════════════════════════════════════════
safe_write() {
    local output_file="$1" content="$2"
    validate_filepath "$output_file" || return 1

    local dir
    dir="$(dirname "$output_file")"
    [[ ! -d "$dir" ]] && mkdir -p "$dir" && log_info "Created dir: ${dir}"

    if [[ -f "$output_file" && "$FORCE_OVERWRITE" != "true" ]]; then
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            log_error "File '${output_file}' exists. Use --force."
            return 1
        fi
        local ans
        ans=$(read_yes_no "File '${output_file}' exists. Overwrite?" "n")
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            log_info "Skipped: ${output_file}"
            return 0
        fi
    fi

    echo "$content" > "$output_file"
    log_info "✅ Saved: ${output_file}"
    echo ""
    echo "$content"
}

safe_write_kubectl() {
    local output_file="$1"
    shift
    local content tmp_err
    tmp_err="$(mktemp)"
    if content=$("$@" 2>"$tmp_err"); then
        safe_write "$output_file" "$content"
    else
        log_error "kubectl failed"
        [[ -s "$tmp_err" ]] && log_error "$(cat "$tmp_err")"
        rm -f "$tmp_err"
        return 1
    fi
    rm -f "$tmp_err"
}

# ──────────────── Prerequisites ────────────────
check_prerequisites() {
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not found"
        exit 1
    fi
    local ver
    ver="$(kubectl version --client -o yaml 2>/dev/null | grep gitVersion | head -1 || echo 'unknown')"
    log_info "kubectl: ${ver}"
}

# ══════════════════════════════════════════════════
#  PHASE 0 — BASE GENERATORS
# ══════════════════════════════════════════════════

generate_pod() {
    log_info "── Pod ──"
    local name namespace image port
    name="${CLI_NAME:-$(read_validated "Pod name" "my-pod" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    image="${CLI_IMAGE:-$(read_input "Image" "nginx:latest")}"
    port="${CLI_PORT:-$(read_validated "Port" "80" validate_port)}"

    local out="${OUTPUT_DIR}/${name}-pod.yaml"
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    safe_write_kubectl "$out" \
        kubectl run "$name" --image="$image" --port="$port" \
        --namespace="$namespace" --labels="app=${name}" \
        --dry-run=client -o yaml
}

generate_deployment() {
    log_info "── Deployment ──"
    local name namespace image replicas port
    name="${CLI_NAME:-$(read_validated "Deployment name" "my-deployment" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    image="${CLI_IMAGE:-$(read_input "Image" "nginx:latest")}"
    replicas="${CLI_REPLICAS:-$(read_validated "Replicas" "3" validate_replicas)}"
    port="${CLI_PORT:-$(read_validated "Port" "80" validate_port)}"

    local out="${OUTPUT_DIR}/${name}-deployment.yaml"
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    safe_write_kubectl "$out" \
        kubectl create deployment "$name" --image="$image" \
        --replicas="$replicas" --port="$port" \
        --namespace="$namespace" --dry-run=client -o yaml
}

generate_service() {
    log_info "── Service ──"
    local name namespace port target_port svc_type
    name="${CLI_NAME:-$(read_validated "Service name" "my-service" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        svc_type="clusterip"
    else
        echo -e "  1) ClusterIP   2) NodePort   3) LoadBalancer" >&2
        local tc
        tc=$(read_input "Type (1-3)" "1")
        case "$tc" in
            1) svc_type="clusterip" ;; 2) svc_type="nodeport" ;; 3) svc_type="loadbalancer" ;; *) svc_type="clusterip" ;;
        esac
    fi

    port="${CLI_PORT:-$(read_validated "Service port" "80" validate_port)}"
    target_port=$(read_validated "Target port" "$port" validate_port)

    local out="${OUTPUT_DIR}/${name}-service.yaml"
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    safe_write_kubectl "$out" \
        kubectl create service "$svc_type" "$name" \
        --tcp="${port}:${target_port}" --namespace="$namespace" \
        --dry-run=client -o yaml
}

generate_configmap() {
    log_info "── ConfigMap ──"
    local name namespace
    name="${CLI_NAME:-$(read_validated "ConfigMap name" "my-config" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"

    declare -a literal_args=()
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        echo -e "${YELLOW}Key=value pairs (empty key = done):${NC}" >&2
        while true; do
            echo -ne "${BLUE}[?]${NC} Key: " >&2
            local key; read -r key
            [[ -z "$key" ]] && break
            [[ ! "$key" =~ ^[a-zA-Z0-9._-]+$ ]] && { log_error "Invalid key"; continue; }
            echo -ne "${BLUE}[?]${NC} Value: " >&2
            local val; read -r val
            literal_args+=("--from-literal=${key}=${val}")
        done
    fi
    [[ ${#literal_args[@]} -eq 0 ]] && literal_args+=("--from-literal=placeholder=changeme") && log_warn "Added placeholder"

    local out="${OUTPUT_DIR}/${name}-configmap.yaml"
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    safe_write_kubectl "$out" \
        kubectl create configmap "$name" "${literal_args[@]}" \
        --namespace="$namespace" --dry-run=client -o yaml
}

generate_namespace() {
    log_info "── Namespace ──"
    local name
    name="${CLI_NAME:-$(read_validated "Namespace name" "my-namespace" validate_k8s_name)}"

    local out="${OUTPUT_DIR}/${name}-namespace.yaml"
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    safe_write_kubectl "$out" \
        kubectl create namespace "$name" --dry-run=client -o yaml
}

generate_ingress() {
    log_info "── Ingress ──"
    local name namespace host svc_name svc_port
    name="${CLI_NAME:-$(read_validated "Ingress name" "my-ingress" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    host=$(read_input "Hostname" "example.com")
    svc_name=$(read_validated "Backend service" "my-service" validate_k8s_name)
    svc_port=$(read_validated "Service port" "80" validate_port)

    local out="${OUTPUT_DIR}/${name}-ingress.yaml"
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    safe_write_kubectl "$out" \
        kubectl create ingress "$name" \
        --rule="${host}/*=${svc_name}:${svc_port}" \
        --namespace="$namespace" --dry-run=client -o yaml
}

# ══════════════════════════════════════════════════
#  PHASE 1 — Secret, Job, CronJob, PVC
# ══════════════════════════════════════════════════

generate_secret() {
    log_info "── Secret ──"
    local name namespace
    name="${CLI_NAME:-$(read_validated "Secret name" "my-secret" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"

    local secret_type
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        secret_type="generic"
    else
        echo -e "  1) generic   2) docker-registry   3) tls" >&2
        local sc
        sc=$(read_input "Secret type (1-3)" "1")
        case "$sc" in
            1) secret_type="generic" ;; 2) secret_type="docker-registry" ;; 3) secret_type="tls" ;; *) secret_type="generic" ;;
        esac
    fi

    declare -a secret_args=()
    case "$secret_type" in
        generic)
            if [[ "$NON_INTERACTIVE" != "true" ]]; then
                echo -e "${YELLOW}Key=value pairs (empty = done):${NC}" >&2
                while true; do
                    echo -ne "${BLUE}[?]${NC} Key: " >&2
                    local key; read -r key
                    [[ -z "$key" ]] && break
                    [[ ! "$key" =~ ^[a-zA-Z0-9._-]+$ ]] && { log_error "Invalid key"; continue; }
                    echo -ne "${BLUE}[?]${NC} Value: " >&2
                    local val; read -r val
                    secret_args+=("--from-literal=${key}=${val}")
                done
            fi
            [[ ${#secret_args[@]} -eq 0 ]] && secret_args+=("--from-literal=password=changeme") && log_warn "Added placeholder"
            ;;
        docker-registry)
            local srv usr pw eml
            srv=$(read_input "Docker server" "https://index.docker.io/v1/")
            usr=$(read_input "Username" "myuser")
            pw=$(read_input "Password" "changeme")
            eml=$(read_input "Email" "user@example.com")
            secret_args+=("--docker-server=${srv}" "--docker-username=${usr}" "--docker-password=${pw}" "--docker-email=${eml}")
            ;;
        tls)
            local cf kf
            cf=$(read_input "Cert file" "./tls.crt")
            kf=$(read_input "Key file" "./tls.key")
            secret_args+=("--cert=${cf}" "--key=${kf}")
            ;;
    esac

    local out="${OUTPUT_DIR}/${name}-secret.yaml"
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    safe_write_kubectl "$out" \
        kubectl create secret "$secret_type" "$name" \
        "${secret_args[@]}" --namespace="$namespace" \
        --dry-run=client -o yaml
}

generate_job() {
    log_info "── Job ──"
    local name namespace image
    name="${CLI_NAME:-$(read_validated "Job name" "my-job" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    image="${CLI_IMAGE:-$(read_input "Image" "busybox:latest")}"

    local cmd_str backoff completions parallelism
    cmd_str=$(read_input "Command" "echo hello")
    backoff=$(read_validated "Backoff limit" "3" validate_positive_int)
    completions=$(read_validated "Completions" "1" validate_positive_int)
    parallelism=$(read_validated "Parallelism" "1" validate_positive_int)

    local out="${OUTPUT_DIR}/${name}-job.yaml"
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    safe_write "$out" "apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    app: ${name}
spec:
  backoffLimit: ${backoff}
  completions: ${completions}
  parallelism: ${parallelism}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      restartPolicy: Never
      containers:
        - name: ${name}
          image: ${image}
          command: [\"/bin/sh\", \"-c\"]
          args: [\"${cmd_str}\"]"
}

generate_cronjob() {
    log_info "── CronJob ──"
    local name namespace image
    name="${CLI_NAME:-$(read_validated "CronJob name" "my-cronjob" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    image="${CLI_IMAGE:-$(read_input "Image" "busybox:latest")}"

    local schedule cmd_str concurrency
    schedule=$(read_validated "Cron schedule" "*/5 * * * *" validate_cron_schedule)
    cmd_str=$(read_input "Command" "echo hello")

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        concurrency="Forbid"
    else
        echo -e "  1) Allow   2) Forbid   3) Replace" >&2
        local cc
        cc=$(read_input "Concurrency (1-3)" "2")
        case "$cc" in
            1) concurrency="Allow" ;; 2) concurrency="Forbid" ;; 3) concurrency="Replace" ;; *) concurrency="Forbid" ;;
        esac
    fi

    local out="${OUTPUT_DIR}/${name}-cronjob.yaml"
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    safe_write "$out" "apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    app: ${name}
spec:
  schedule: \"${schedule}\"
  concurrencyPolicy: ${concurrency}
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 3
      template:
        metadata:
          labels:
            app: ${name}
        spec:
          restartPolicy: OnFailure
          containers:
            - name: ${name}
              image: ${image}
              command: [\"/bin/sh\", \"-c\"]
              args: [\"${cmd_str}\"]"
}

generate_pvc() {
    log_info "── PVC ──"
    local name namespace
    name="${CLI_NAME:-$(read_validated "PVC name" "my-pvc" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"

    local storage access_mode storage_class
    storage=$(read_validated "Storage size" "1Gi" validate_storage)

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        access_mode="ReadWriteOnce"
    else
        echo -e "  1) ReadWriteOnce   2) ReadOnlyMany   3) ReadWriteMany" >&2
        local am
        am=$(read_input "Access mode (1-3)" "1")
        case "$am" in
            1) access_mode="ReadWriteOnce" ;; 2) access_mode="ReadOnlyMany" ;; 3) access_mode="ReadWriteMany" ;; *) access_mode="ReadWriteOnce" ;;
        esac
    fi

    storage_class=$(read_input "StorageClass (empty=default)" "")

    local sc_line=""
    [[ -n "$storage_class" ]] && sc_line="  storageClassName: ${storage_class}"

    local out="${OUTPUT_DIR}/${name}-pvc.yaml"
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    safe_write "$out" "apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    app: ${name}
spec:
${sc_line}
  accessModes:
    - ${access_mode}
  resources:
    requests:
      storage: ${storage}"
}

# ══════════════════════════════════════════════════
#  PHASE 2 — Advanced Deployment, HPA
# ══════════════════════════════════════════════════

generate_deployment_advanced() {
    log_info "── Advanced Deployment (resources + probes) ──"
    local name namespace image replicas port
    name="${CLI_NAME:-$(read_validated "Deployment name" "my-app" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    image="${CLI_IMAGE:-$(read_input "Image" "nginx:latest")}"
    replicas="${CLI_REPLICAS:-$(read_validated "Replicas" "3" validate_replicas)}"
    port="${CLI_PORT:-$(read_validated "Port" "80" validate_port)}"

    echo -e "\n${BOLD}── Resource Limits ──${NC}" >&2
    local req_cpu req_mem lim_cpu lim_mem
    req_cpu=$(read_validated "CPU request" "100m" validate_cpu)
    req_mem=$(read_validated "Memory request" "128Mi" validate_memory)
    lim_cpu=$(read_validated "CPU limit" "500m" validate_cpu)
    lim_mem=$(read_validated "Memory limit" "256Mi" validate_memory)

    echo -e "\n${BOLD}── Health Probes ──${NC}" >&2
    local probe_path liveness_delay liveness_period readiness_delay readiness_period
    probe_path=$(read_input "Health check path" "/healthz")
    liveness_delay=$(read_validated "Liveness initial delay (sec)" "15" validate_positive_int)
    liveness_period=$(read_validated "Liveness period (sec)" "20" validate_positive_int)
    readiness_delay=$(read_validated "Readiness initial delay (sec)" "5" validate_positive_int)
    readiness_period=$(read_validated "Readiness period (sec)" "10" validate_positive_int)

    echo -e "\n${BOLD}── Strategy ──${NC}" >&2
    local strategy max_unavail max_surge
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        strategy="RollingUpdate"
        max_unavail="25%"
        max_surge="25%"
    else
        echo -e "  1) RollingUpdate   2) Recreate" >&2
        local sc
        sc=$(read_input "Strategy (1-2)" "1")
        case "$sc" in
            1) strategy="RollingUpdate" ;;
            2) strategy="Recreate" ;;
            *) strategy="RollingUpdate" ;;
        esac
        if [[ "$strategy" == "RollingUpdate" ]]; then
            max_unavail=$(read_input "Max unavailable" "25%")
            max_surge=$(read_input "Max surge" "25%")
        else
            max_unavail=""
            max_surge=""
        fi
    fi

    local strategy_block=""
    if [[ "$strategy" == "RollingUpdate" ]]; then
        strategy_block="  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: ${max_unavail}
      maxSurge: ${max_surge}"
    else
        strategy_block="  strategy:
    type: Recreate"
    fi

    local out="${OUTPUT_DIR}/${name}-deployment-adv.yaml"
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    safe_write "$out" "apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    app: ${name}
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: ${name}
${strategy_block}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      containers:
        - name: ${name}
          image: ${image}
          ports:
            - containerPort: ${port}
          resources:
            requests:
              cpu: ${req_cpu}
              memory: ${req_mem}
            limits:
              cpu: ${lim_cpu}
              memory: ${lim_mem}
          livenessProbe:
            httpGet:
              path: ${probe_path}
              port: ${port}
            initialDelaySeconds: ${liveness_delay}
            periodSeconds: ${liveness_period}
          readinessProbe:
            httpGet:
              path: ${probe_path}
              port: ${port}
            initialDelaySeconds: ${readiness_delay}
            periodSeconds: ${readiness_period}"
}

# ══════════════════════════════════════════════════
#  PHASE 2 — HPA
# ══════════════════════════════════════════════════

generate_hpa() {
    log_info "── HPA ──"
    local name namespace target_deploy min_rep max_rep cpu_pct
    name="${CLI_NAME:-$(read_validated "HPA name" "my-hpa" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    target_deploy=$(read_validated "Target Deployment name" "my-app" validate_k8s_name)
    min_rep=$(read_validated "Min replicas" "2" validate_replicas)
    max_rep=$(read_validated "Max replicas" "10" validate_replicas)
    cpu_pct=$(read_validated "Target CPU %" "70" validate_percentage)

    local out="${OUTPUT_DIR}/${name}-hpa.yaml"
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    safe_write "$out" "apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    app: ${name}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${target_deploy}
  minReplicas: ${min_rep}
  maxReplicas: ${max_rep}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: ${cpu_pct}"
}

# ══════════════════════════════════════════════════
#  PHASE 3 — StatefulSet, DaemonSet, SA, NetPol
# ══════════════════════════════════════════════════

generate_statefulset() {
    log_info "── StatefulSet ──"
    local name namespace image replicas port storage sc_name svc_name
    name="${CLI_NAME:-$(read_validated "StatefulSet name" "my-sts" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    image="${CLI_IMAGE:-$(read_input "Image" "postgres:16")}"
    replicas="${CLI_REPLICAS:-$(read_validated "Replicas" "3" validate_replicas)}"
    port="${CLI_PORT:-$(read_validated "Port" "5432" validate_port)}"
    svc_name=$(read_validated "Headless Service name" "${name}-headless" validate_k8s_name)
    storage=$(read_validated "Storage per pod" "10Gi" validate_storage)
    sc_name=$(read_input "StorageClass (empty=default)" "")

    local sc_line=""
    [[ -n "$sc_name" ]] && sc_line="      storageClassName: ${sc_name}"

    local out="${OUTPUT_DIR}/${name}-statefulset.yaml"
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    safe_write "$out" "apiVersion: v1
kind: Service
metadata:
  name: ${svc_name}
  namespace: ${namespace}
  labels:
    app: ${name}
spec:
  clusterIP: None
  selector:
    app: ${name}
  ports:
    - port: ${port}
      targetPort: ${port}
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    app: ${name}
spec:
  serviceName: ${svc_name}
  replicas: ${replicas}
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      containers:
        - name: ${name}
          image: ${image}
          ports:
            - containerPort: ${port}
          volumeMounts:
            - name: data
              mountPath: /var/lib/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
${sc_line}
        accessModes: [\"ReadWriteOnce\"]
        resources:
          requests:
            storage: ${storage}"
}

generate_daemonset() {
    log_info "── DaemonSet ──"
    local name namespace image port
    name="${CLI_NAME:-$(read_validated "DaemonSet name" "my-ds" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    image="${CLI_IMAGE:-$(read_input "Image" "fluentd:latest")}"
    port="${CLI_PORT:-$(read_validated "Port (0=none)" "0" validate_port)}"

    local port_block=""
    if [[ "$port" != "0" ]]; then
        port_block="          ports:
            - containerPort: ${port}"
    fi

    local tolerate_all
    tolerate_all=$(read_yes_no "Tolerate all taints (master/control-plane)?" "y")
    local toleration_block=""
    if [[ "$tolerate_all" == "y" || "$tolerate_all" == "Y" ]]; then
        toleration_block="      tolerations:
        - operator: Exists"
    fi

    local out="${OUTPUT_DIR}/${name}-daemonset.yaml"
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    safe_write "$out" "apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    app: ${name}
spec:
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
${toleration_block}
      containers:
        - name: ${name}
          image: ${image}
${port_block}"
}

generate_serviceaccount() {
    log_info "── ServiceAccount + RBAC ──"
    local name namespace
    name="${CLI_NAME:-$(read_validated "ServiceAccount name" "my-sa" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"

    local role_name="${name}-role"
    local binding_name="${name}-rolebinding"

    local api_groups resources verbs
    api_groups=$(read_input "API groups (comma-sep)" "\"\"")
    resources=$(read_input "Resources (comma-sep)" "pods,services")
    verbs=$(read_input "Verbs (comma-sep)" "get,list,watch")

    # Format arrays for YAML
    local res_yaml="" verb_yaml=""
    IFS=',' read -ra R_ARR <<< "$resources"
    for r in "${R_ARR[@]}"; do res_yaml+="
      - ${r}"; done
    IFS=',' read -ra V_ARR <<< "$verbs"
    for v in "${V_ARR[@]}"; do verb_yaml+="
      - ${v}"; done

    local out="${OUTPUT_DIR}/${name}-serviceaccount-rbac.yaml"
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    safe_write "$out" "apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${name}
  namespace: ${namespace}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${role_name}
  namespace: ${namespace}
rules:
  - apiGroups: [${api_groups}]
    resources:${res_yaml}
    verbs:${verb_yaml}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${binding_name}
  namespace: ${namespace}
subjects:
  - kind: ServiceAccount
    name: ${name}
    namespace: ${namespace}
roleRef:
  kind: Role
  name: ${role_name}
  apiGroup: rbac.authorization.k8s.io"
}

generate_networkpolicy() {
    log_info "── NetworkPolicy ──"
    local name namespace pod_selector port
    name="${CLI_NAME:-$(read_validated "NetworkPolicy name" "deny-all" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    pod_selector=$(read_input "Pod selector label (app=myapp)" "app=myapp")
    port=$(read_validated "Allow port" "80" validate_port)

    local key="${pod_selector%%=*}"
    local value="${pod_selector##*=}"

    local out="${OUTPUT_DIR}/${name}-networkpolicy.yaml"
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    safe_write "$out" "apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${name}
  namespace: ${namespace}
spec:
  podSelector:
    matchLabels:
      ${key}: ${value}
  policyTypes:
    - Ingress
  ingress:
    - ports:
        - protocol: TCP
          port: ${port}"
}

generate_full_stack() {
    log_info "── Full Stack (Namespace + Deployment + Service) ──"

    local name namespace image replicas port
    name="${CLI_NAME:-$(read_validated "App name" "myapp" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "${name}-ns" validate_namespace)}"
    image="${CLI_IMAGE:-$(read_input "Image" "nginx:latest")}"
    replicas="${CLI_REPLICAS:-$(read_validated "Replicas" "3" validate_replicas)}"
    port="${CLI_PORT:-$(read_validated "Port" "80" validate_port)}"

    local out="${OUTPUT_DIR}/${name}-full-stack.yaml"
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    safe_write "$out" "apiVersion: v1
kind: Namespace
metadata:
  name: ${namespace}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${namespace}
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      containers:
        - name: ${name}
          image: ${image}
          ports:
            - containerPort: ${port}
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}-svc
  namespace: ${namespace}
spec:
  selector:
    app: ${name}
  ports:
    - port: ${port}
      targetPort: ${port}
  type: ClusterIP"
}

# ══════════════════════════════════════════════════
#  MAIN MENU
# ══════════════════════════════════════════════════

show_menu() {
    echo ""
    echo "Choose resource type:"
    echo "1) Pod"
    echo "2) Deployment"
    echo "3) Service"
    echo "4) ConfigMap"
    echo "5) Namespace"
    echo "6) Ingress"
    echo "7) Secret"
    echo "8) Job"
    echo "9) CronJob"
    echo "10) PVC"
    echo "11) Deployment Advanced"
    echo "12) HPA"
    echo "13) StatefulSet"
    echo "14) DaemonSet"
    echo "15) ServiceAccount + RBAC"
    echo "16) NetworkPolicy"
    echo "17) Full Stack"
}

dispatch_choice() {
    case "$1" in
        pod|1) generate_pod ;;
        deployment|2) generate_deployment ;;
        service|3) generate_service ;;
        configmap|4) generate_configmap ;;
        namespace|5) generate_namespace ;;
        ingress|6) generate_ingress ;;
        secret|7) generate_secret ;;
        job|8) generate_job ;;
        cronjob|9) generate_cronjob ;;
        pvc|10) generate_pvc ;;
        deployment-adv|11) generate_deployment_advanced ;;
        hpa|12) generate_hpa ;;
        statefulset|13) generate_statefulset ;;
        daemonset|14) generate_daemonset ;;
        serviceaccount|15) generate_serviceaccount ;;
        networkpolicy|16) generate_networkpolicy ;;
        full-stack|17) generate_full_stack ;;
        *) log_error "Unknown type: $1"; exit 1 ;;
    esac
}

# ══════════════════════════════════════════════════
#  ARG PARSER
# ══════════════════════════════════════════════════

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--type) CLI_TYPE="$2"; shift 2 ;;
            -n|--name) CLI_NAME="$2"; shift 2 ;;
            -i|--image) CLI_IMAGE="$2"; shift 2 ;;
            -r|--replicas) CLI_REPLICAS="$2"; shift 2 ;;
            -p|--port) CLI_PORT="$2"; shift 2 ;;
            --namespace) CLI_NAMESPACE="$2"; shift 2 ;;
            --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
            --non-interactive) NON_INTERACTIVE=true; shift ;;
            -f|--force) FORCE_OVERWRITE=true; shift ;;
            --debug) DEBUG=true; shift ;;
            -h|--help) show_help ;;
            -v|--version) show_version ;;
            *) log_error "Unknown arg: $1"; exit 1 ;;
        esac
    done
}

# ══════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════

main() {
    banner
    parse_args "$@"
    check_prerequisites

    if [[ -n "$CLI_TYPE" ]]; then
        dispatch_choice "$CLI_TYPE"
        exit 0
    fi

    show_menu
    local choice
    choice=$(read_input "Select option" "1")
    dispatch_choice "$choice"
}

main "$@"

