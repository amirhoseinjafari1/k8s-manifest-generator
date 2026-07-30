#!/usr/bin/env bash
#=============================================================
#  Kubernetes Manifest Generator — v2.0
#  Quality core: securityContext (PSS restricted), resources,
#  probes (+startupProbe), imagePullPolicy, env/envFrom,
#  imagePullSecrets. Extras: Kustomization, --stdout, output
#  validation, PodDisruptionBudget. kubectl is now OPTIONAL.
#=============================================================

set -euo pipefail

# ──────────────── Constants ────────────────
readonly VERSION="2.0.0"
readonly AUTHOR="amirhoseinjafari1"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/tmp/k8s-gen-$(date +%Y%m%d-%H%M%S).log"

# ──────────────── Colors ────────────────
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly GRAY='\033[90m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ──────────────── Global Flags ────────────────
NON_INTERACTIVE=false
FORCE_OVERWRITE=false
STDOUT_MODE=false
SECURITY=true            # emit PSS-restricted securityContext
VALIDATE="auto"          # auto | on | off
OUTPUT_DIR="."
DEBUG=${DEBUG:-false}

# ──────────────── CLI Variables ────────────────
CLI_TYPE=""
CLI_NAME=""
CLI_IMAGE=""
CLI_REPLICAS=""
CLI_PORT=""
CLI_NAMESPACE=""
CLI_PROFILE=""

# tracks files written this run (for kustomize auto-detect)
declare -a GENERATED_FILES=()

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
    [[ "$STDOUT_MODE" == "true" ]] && return
    echo -e "${GRAY}────────────────────────────────────${NC}" >&2
    echo -e "${BOLD}${CYAN}☸ K8s Manifest Generator${NC}  ${YELLOW}v${VERSION}${NC}" >&2
    echo -e "${MAGENTA}Author:${NC} ${AUTHOR} ${GRAY}(github)${NC}" >&2
    echo -e "${GRAY}────────────────────────────────────${NC}" >&2
}

# ──────────────── Logging ────────────────
_log() {
    local level="$1" color="$2" msg="$3" ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${color}[${level}]${NC} ${msg}" >&2
    echo "[${ts}] [${level}] ${msg}" >> "$LOG_FILE"
}
log_info()  { _log "INFO"  "$GREEN"  "$1"; }
log_warn()  { _log "WARN"  "$YELLOW" "$1"; }
log_error() { _log "ERROR" "$RED"    "$1"; }
log_debug() { [[ "$DEBUG" == "true" ]] && _log "DEBUG" "$BLUE" "$1" || true; }

# ──────────────── Help / Version ────────────────
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
      --profile N          Resource profile: 1=low 2=medium 3=high (default: 2)
      --output-dir DIR     Output directory (default: .)
      --stdout             Print manifest to stdout (no file written)
      --no-security        Do NOT emit securityContext (for images needing root)
      --validate MODE      auto | on | off  (default: auto)
      --non-interactive    No prompts
  -f, --force              Overwrite without asking
      --debug              Debug logging
  -h, --help               This help
  -v, --version            Version

Resource Types:
  pod, deployment, deployment-adv, service, configmap, secret,
  namespace, ingress, job, cronjob, pvc, hpa, statefulset,
  daemonset, serviceaccount, networkpolicy, pdb, kustomize, full-stack

Examples:
  ${SCRIPT_NAME} -t deployment-adv -n web -i nginx:1.25 -f
  ${SCRIPT_NAME} -t deployment -n api --stdout --non-interactive | kubectl apply -f -
  ${SCRIPT_NAME} -t full-stack -n myapp -f
  ${SCRIPT_NAME} -t kustomize --output-dir ./manifests
EOF
    exit 0
}
show_version() { echo "K8s Manifest Generator v${VERSION}"; exit 0; }

# ══════════════════════════════════════════════════
#  INPUT HELPERS
# ══════════════════════════════════════════════════
read_input() {
    local prompt="$1" default="${2:-}"
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        [[ -z "$default" && "$default" != "" ]] && { log_error "No default for '${prompt}'"; exit 1; }
        echo "$default"; return
    fi
    if [[ -n "$default" ]]; then
        echo -ne "${BLUE}[?]${NC} ${prompt} [${YELLOW}${default}${NC}]: " >&2
    else
        echo -ne "${BLUE}[?]${NC} ${prompt}: " >&2
    fi
    local value
    if ! IFS= read -r value; then value=""; fi   # EOF-safe
    echo "${value:-$default}"
}

read_yes_no() {
    local prompt="$1" default="${2:-n}"
    [[ "$NON_INTERACTIVE" == "true" ]] && { echo "$default"; return; }
    local answer
    answer=$(read_input "$prompt (y/n)" "$default")
    case "$answer" in y|Y|yes|Yes) echo "y" ;; *) echo "n" ;; esac
}

read_validated() {
    local prompt="$1" default="${2:-}" validator="$3" value
    while true; do
        value=$(read_input "$prompt" "$default")
        if $validator "$value"; then echo "$value"; return; fi
        [[ "$NON_INTERACTIVE" == "true" ]] && exit 1
        log_warn "Try again..."
    done
}

# ══════════════════════════════════════════════════
#  VALIDATORS
# ══════════════════════════════════════════════════
validate_k8s_name() {
    [[ "$1" =~ ^[a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?$ ]] && return 0
    log_error "Invalid K8s name '$1'"; return 1
}
validate_namespace() { validate_k8s_name "$1"; }

validate_port() {
    local p="$1"
    { [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); } && return 0
    log_error "Invalid port '$p'"; return 1
}
# port that may be 0 / empty (means "no port")
validate_port_optional() {
    local p="$1"
    [[ -z "$p" || "$p" == "0" ]] && return 0
    validate_port "$p"
}
validate_replicas() {
    local r="$1"
    { [[ "$r" =~ ^[0-9]+$ ]] && (( r >= 1 && r <= 100 )); } && return 0
    log_error "Invalid replicas '$r'"; return 1
}
validate_positive_int() {
    local n="$1"
    { [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 )); } && return 0
    log_error "Invalid number '$n'"; return 1
}
validate_percentage() {
    local p="$1"
    { [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 100 )); } && return 0
    log_error "Invalid percentage '$p'"; return 1
}
validate_cpu() {
    [[ "$1" =~ ^[0-9]+(m)?$ ]] && return 0
    log_error "Invalid CPU '$1' — e.g. 100m, 500m, 1"; return 1
}
validate_memory() {
    [[ "$1" =~ ^[0-9]+(Mi|Gi|Ki)$ ]] && return 0
    log_error "Invalid memory '$1' — e.g. 128Mi, 1Gi"; return 1
}
validate_storage() {
    [[ "$1" =~ ^[0-9]+(Mi|Gi|Ti)$ ]] && return 0
    log_error "Invalid storage '$1' — e.g. 1Gi, 10Gi"; return 1
}
# image ref: registry/repo:tag or repo@sha256:...  — no whitespace/quotes/newlines
validate_image() {
    local i="$1"
    if [[ "$i" =~ [[:space:]\"\'\`] || -z "$i" ]]; then
        log_error "Invalid image '$i'"; return 1
    fi
    [[ "$i" =~ ^[A-Za-z0-9._:/@-]+$ ]] && return 0
    log_error "Invalid image '$i'"; return 1
}
# absolute URL path for probes: starts with /, no whitespace/quotes/shell-breakers
validate_path() {
    local p="$1"
    if [[ "$p" != /* ]] || [[ "$p" =~ [[:space:]\"\'\`\$\\] ]]; then
        log_error "Invalid path '$p' — must start with / and contain no spaces/quotes"; return 1
    fi
    return 0
}
# DNS hostname
validate_host() {
    [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$ ]] && return 0
    log_error "Invalid host '$1'"; return 1
}
# reject shell/YAML breakers in free text (command args, env values)
validate_safe_text() {
    if [[ "$1" =~ [\"\`$\\] || "$1" == *$'\n'* ]]; then
        log_error "Illegal characters in '$1' (no \" \$ \\ backtick newline)"; return 1
    fi
    return 0
}
validate_cron_schedule() {
    local s="$1"
    [[ "$s" =~ ^@(yearly|annually|monthly|weekly|daily|hourly)$ ]] && return 0
    local fields; fields=$(awk '{print NF}' <<<"$s")
    [[ "$fields" -eq 5 ]] && return 0
    log_error "Invalid cron '$s' — 5 fields or @daily/@hourly/..."; return 1
}
validate_filepath() {
    [[ "$1" == *".."* ]] && { log_error "Path traversal in '$1'"; return 1; }
    return 0
}

# ══════════════════════════════════════════════════
#  RESOURCE PROFILES
# ══════════════════════════════════════════════════
get_resource_profile_defaults() {
    case "$1" in
        1|low|Low)     echo "50m|64Mi|200m|128Mi" ;;
        3|high|High)   echo "250m|256Mi|1000m|512Mi" ;;
        *)             echo "100m|128Mi|500m|256Mi" ;;   # 2 / medium / default
    esac
}

# ══════════════════════════════════════════════════
#  YAML BUILDING BLOCKS  (emitted at zero indent, then
#  piped through `indent N` when composed)
# ══════════════════════════════════════════════════
indent() { local pad; pad="$(printf '%*s' "${1:-0}" '')"; sed "s/^/${pad}/"; }

pod_security_context() {
    [[ "$SECURITY" != "true" ]] && return 0
    cat <<'EOF'
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 3000
  fsGroup: 2000
  seccompProfile:
    type: RuntimeDefault
EOF
}
container_security_context() {
    [[ "$SECURITY" != "true" ]] && return 0
    cat <<'EOF'
securityContext:
  allowPrivilegeEscalation: false
  privileged: false
  runAsNonRoot: true
  capabilities:
    drop:
      - ALL
  seccompProfile:
    type: RuntimeDefault
EOF
}
resources_block() { # req_cpu req_mem lim_cpu lim_mem
    cat <<EOF
resources:
  requests:
    cpu: $1
    memory: $2
  limits:
    cpu: $3
    memory: $4
EOF
}
# tcpSocket probes — safe default that works with any TCP service
tcp_probes_block() { # port
    cat <<EOF
livenessProbe:
  tcpSocket:
    port: $1
  initialDelaySeconds: 15
  periodSeconds: 20
readinessProbe:
  tcpSocket:
    port: $1
  initialDelaySeconds: 5
  periodSeconds: 10
startupProbe:
  tcpSocket:
    port: $1
  failureThreshold: 30
  periodSeconds: 5
EOF
}
http_probes_block() { # path port live_delay live_period read_delay read_period
    cat <<EOF
livenessProbe:
  httpGet:
    path: $1
    port: $2
  initialDelaySeconds: $3
  periodSeconds: $4
readinessProbe:
  httpGet:
    path: $1
    port: $2
  initialDelaySeconds: $5
  periodSeconds: $6
startupProbe:
  httpGet:
    path: $1
    port: $2
  failureThreshold: 30
  periodSeconds: 5
EOF
}

# optional block builder: prepend newline only when content is non-empty,
# indenting content to the requested column. Prints nothing if empty.
opt_block() { # indent  content
    local n="$1" content="$2"
    [[ -z "$content" ]] && return 0
    printf '\n%s' "$(printf '%s\n' "$content" | indent "$n")"
}

# ── interactive helper: collect key=value pairs into a caller array ──
collect_kv() { # array_name  label
    local -n _arr="$1"; local label="$2"
    [[ "$NON_INTERACTIVE" == "true" ]] && return 0
    echo -e "${YELLOW}${label} (empty key = done):${NC}" >&2
    while true; do
        echo -ne "${BLUE}[?]${NC} Key: " >&2; local key; IFS= read -r key || break
        [[ -z "$key" ]] && break
        [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && { log_error "Invalid key '$key'"; continue; }
        echo -ne "${BLUE}[?]${NC} Value: " >&2; local val; IFS= read -r val || val=""
        validate_safe_text "$val" || continue
        _arr+=("${key}=${val}")
    done
}

# ══════════════════════════════════════════════════
#  SAFE WRITE + VALIDATION
# ══════════════════════════════════════════════════
validate_manifest() { # file
    local f="$1"
    [[ "$VALIDATE" == "off" ]] && return 0
    if command -v kubeconform &>/dev/null; then
        if kubeconform -strict -summary "$f" >/dev/null 2>&1; then
            log_info "✔ kubeconform: valid"
        else
            log_warn "kubeconform reported issues:"; kubeconform -strict "$f" 2>&1 | head -5 >&2
            [[ "$VALIDATE" == "on" ]] && return 1
        fi
    elif command -v kubectl &>/dev/null; then
        if kubectl apply --dry-run=client -f "$f" >/dev/null 2>&1; then
            log_info "✔ kubectl client dry-run: ok"
        else
            log_warn "kubectl client dry-run failed:"; kubectl apply --dry-run=client -f "$f" 2>&1 | head -5 >&2
            [[ "$VALIDATE" == "on" ]] && return 1
        fi
    else
        [[ "$VALIDATE" == "on" ]] && { log_error "No validator (kubeconform/kubectl) found"; return 1; }
        log_debug "No validator available; skipping validation"
    fi
    return 0
}

safe_write() {
    local output_file="$1" content="$2"

    if [[ "$STDOUT_MODE" == "true" ]]; then
        printf '%s\n' "$content"
        return 0
    fi

    validate_filepath "$output_file" || return 1
    local dir; dir="$(dirname "$output_file")"
    [[ ! -d "$dir" ]] && mkdir -p "$dir" && log_info "Created dir: ${dir}"

    if [[ -f "$output_file" && "$FORCE_OVERWRITE" != "true" ]]; then
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            log_error "File '${output_file}' exists. Use --force."; return 1
        fi
        local ans; ans=$(read_yes_no "File '${output_file}' exists. Overwrite?" "n")
        [[ "$ans" != "y" ]] && { log_info "Skipped: ${output_file}"; return 0; }
    fi

    printf '%s\n' "$content" > "$output_file"
    log_info "✅ Saved: ${output_file}"
    GENERATED_FILES+=("$output_file")
    validate_manifest "$output_file" || log_warn "Validation flagged ${output_file}"
}

resolve_out() { # default_path
    local out="$1"
    [[ "$STDOUT_MODE" == "true" ]] && { echo "$out"; return; }
    [[ "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")
    echo "$out"
}

# pick a resource profile → sets globals REQ_CPU REQ_MEM LIM_CPU LIM_MEM
pick_profile() {
    local profile defaults
    if [[ -n "$CLI_PROFILE" ]]; then
        profile="$CLI_PROFILE"
    elif [[ "$NON_INTERACTIVE" == "true" ]]; then
        profile="2"
    else
        echo -e "  1) Low (dev/test)  2) Medium (typical)  3) High (heavy)" >&2
        profile=$(read_input "Resource profile (1-3)" "2")
    fi
    defaults="$(get_resource_profile_defaults "$profile")"
    IFS='|' read -r REQ_CPU REQ_MEM LIM_CPU LIM_MEM <<< "$defaults"
    if [[ "$NON_INTERACTIVE" != "true" && "$STDOUT_MODE" != "true" ]]; then
        REQ_CPU=$(read_validated "CPU request" "$REQ_CPU" validate_cpu)
        REQ_MEM=$(read_validated "Memory request" "$REQ_MEM" validate_memory)
        LIM_CPU=$(read_validated "CPU limit" "$LIM_CPU" validate_cpu)
        LIM_MEM=$(read_validated "Memory limit" "$LIM_MEM" validate_memory)
    fi
}

# ══════════════════════════════════════════════════
#  PREREQUISITES  (kubectl is optional now)
# ══════════════════════════════════════════════════
check_prerequisites() {
    if command -v kubectl &>/dev/null; then
        local ver
        ver="$(kubectl version --client -o yaml 2>/dev/null | awk '/gitVersion/{print $2; exit}')"
        log_debug "kubectl: ${ver:-found}"
    else
        log_debug "kubectl not found — generation works, validation limited"
    fi
    if command -v kubeconform &>/dev/null; then log_debug "kubeconform: found"; fi
    return 0
}

# ══════════════════════════════════════════════════
#  WORKLOAD CONTAINER BUILDER
# ══════════════════════════════════════════════════
# Builds a single container entry (list item) at 8-space base indent
# (fits Deployment/StatefulSet/DaemonSet template.spec.containers).
# Args: name image port(optional/0) probes_kind(tcp|http|none) [http probe args...]
# Uses globals REQ_* LIM_* and optional ENV_YAML ENVFROM_YAML
build_container() {
    local name="$1" image="$2" port="$3" probes_kind="$4"; shift 4
    local body probes_yaml=""

    case "$probes_kind" in
        tcp)  [[ -n "$port" && "$port" != "0" ]] && probes_yaml="$(tcp_probes_block "$port")" ;;
        http) probes_yaml="$(http_probes_block "$@")" ;;
        none) : ;;
    esac

    body="- name: ${name}
  image: ${image}
  imagePullPolicy: IfNotPresent"
    [[ -n "$port" && "$port" != "0" ]] && \
        body+="$(opt_block 2 "$(printf 'ports:\n  - containerPort: %s' "$port")")"
    [[ -n "${ENV_YAML:-}" ]]     && body+="$(opt_block 2 "$ENV_YAML")"
    [[ -n "${ENVFROM_YAML:-}" ]] && body+="$(opt_block 2 "$ENVFROM_YAML")"
    body+="$(opt_block 2 "$(resources_block "$REQ_CPU" "$REQ_MEM" "$LIM_CPU" "$LIM_MEM")")"
    [[ -n "$probes_yaml" ]] && body+="$(opt_block 2 "$probes_yaml")"
    body+="$(opt_block 2 "$(container_security_context)")"

    printf '%s\n' "$body" | indent 8
}

# ══════════════════════════════════════════════════
#  GENERATORS — simple resources
# ══════════════════════════════════════════════════
generate_pod() {
    log_info "── Pod ──"
    local name namespace image port
    name="${CLI_NAME:-$(read_validated "Pod name" "my-pod" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    image="${CLI_IMAGE:-$(read_validated "Image" "nginx:latest" validate_image)}"
    port="${CLI_PORT:-$(read_validated "Port" "80" validate_port)}"
    pick_profile

    local podsec=""; podsec="$(opt_block 2 "$(pod_security_context)")"
    local container; container="$(build_container "$name" "$image" "$port" tcp)"

    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-pod.yaml")"
    safe_write "$out" "apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    app: ${name}
spec:${podsec}
  containers:
$(printf '%s' "$container" | indent 0)"
}

generate_deployment() {
    log_info "── Deployment ──"
    local name namespace image replicas port
    name="${CLI_NAME:-$(read_validated "Deployment name" "my-deployment" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    image="${CLI_IMAGE:-$(read_validated "Image" "nginx:latest" validate_image)}"
    replicas="${CLI_REPLICAS:-$(read_validated "Replicas" "3" validate_replicas)}"
    port="${CLI_PORT:-$(read_validated "Port" "80" validate_port)}"
    pick_profile

    local podsec; podsec="$(opt_block 6 "$(pod_security_context)")"
    local container; container="$(build_container "$name" "$image" "$port" tcp)"

    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-deployment.yaml")"
    safe_write "$out" "apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    app: ${name}
spec:
  replicas: ${replicas}
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:${podsec}
      containers:
$(printf '%s' "$container")"
}

generate_deployment_advanced() {
    log_info "── Advanced Deployment ──"
    local name namespace image replicas port
    name="${CLI_NAME:-$(read_validated "Deployment name" "my-app" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    image="${CLI_IMAGE:-$(read_validated "Image" "nginx:latest" validate_image)}"
    replicas="${CLI_REPLICAS:-$(read_validated "Replicas" "3" validate_replicas)}"
    port="${CLI_PORT:-$(read_validated "Port" "80" validate_port)}"
    pick_profile

    # probes
    local probe_kind="tcp" phttp=()
    if [[ "$NON_INTERACTIVE" != "true" && "$STDOUT_MODE" != "true" ]]; then
        echo -e "  1) tcpSocket (any TCP)   2) httpGet (HTTP endpoint)" >&2
        local pc; pc=$(read_input "Probe type (1-2)" "1")
        if [[ "$pc" == "2" ]]; then
            probe_kind="http"
            local ppath ld lp rd rp
            ppath=$(read_validated "Health check path" "/healthz" validate_path)
            ld=$(read_validated "Liveness initial delay" "15" validate_positive_int)
            lp=$(read_validated "Liveness period" "20" validate_positive_int)
            rd=$(read_validated "Readiness initial delay" "5" validate_positive_int)
            rp=$(read_validated "Readiness period" "10" validate_positive_int)
            phttp=("$ppath" "$port" "$ld" "$lp" "$rd" "$rp")
        fi
    fi

    # env vars
    local -a envs=(); collect_kv envs "Environment variables"
    ENV_YAML=""
    if [[ ${#envs[@]} -gt 0 ]]; then
        ENV_YAML="env:"
        local kv; for kv in "${envs[@]}"; do
            ENV_YAML+=$'\n'"  - name: ${kv%%=*}"$'\n'"    value: \"${kv#*=}\""
        done
    fi

    # envFrom
    ENVFROM_YAML=""
    local cm_ref sec_ref
    cm_ref=$(read_input "envFrom ConfigMap name (empty=none)" "")
    sec_ref=$(read_input "envFrom Secret name (empty=none)" "")
    if [[ -n "$cm_ref" || -n "$sec_ref" ]]; then
        ENVFROM_YAML="envFrom:"
        [[ -n "$cm_ref" ]]  && ENVFROM_YAML+=$'\n'"  - configMapRef:"$'\n'"      name: ${cm_ref}"
        [[ -n "$sec_ref" ]] && ENVFROM_YAML+=$'\n'"  - secretRef:"$'\n'"      name: ${sec_ref}"
    fi

    # imagePullSecrets
    local pull_secret ips_block=""
    pull_secret=$(read_input "imagePullSecret name (empty=none)" "")
    [[ -n "$pull_secret" ]] && ips_block=$'\n'"$(printf 'imagePullSecrets:\n  - name: %s' "$pull_secret" | indent 6)"

    # strategy
    local strategy="RollingUpdate" strat_block max_u="25%" max_s="25%"
    if [[ "$NON_INTERACTIVE" != "true" && "$STDOUT_MODE" != "true" ]]; then
        echo -e "  1) RollingUpdate   2) Recreate" >&2
        local sc; sc=$(read_input "Strategy (1-2)" "1")
        [[ "$sc" == "2" ]] && strategy="Recreate"
        if [[ "$strategy" == "RollingUpdate" ]]; then
            max_u=$(read_input "Max unavailable" "25%")
            max_s=$(read_input "Max surge" "25%")
        fi
    fi
    if [[ "$strategy" == "RollingUpdate" ]]; then
        strat_block="  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: ${max_u}
      maxSurge: ${max_s}"
    else
        strat_block="  strategy:
    type: Recreate"
    fi

    local podsec; podsec="$(opt_block 6 "$(pod_security_context)")"
    local container
    if [[ "$probe_kind" == "http" ]]; then
        container="$(build_container "$name" "$image" "$port" http "${phttp[@]}")"
    else
        container="$(build_container "$name" "$image" "$port" tcp)"
    fi
    unset ENV_YAML ENVFROM_YAML

    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-deployment-adv.yaml")"
    safe_write "$out" "apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    app: ${name}
spec:
  replicas: ${replicas}
  revisionHistoryLimit: 5
${strat_block}
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:${podsec}${ips_block}
      containers:
$(printf '%s' "$container")"
}

generate_service() {
    log_info "── Service ──"
    local name namespace port target_port svc_type
    name="${CLI_NAME:-$(read_validated "Service name" "my-service" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    if [[ "$NON_INTERACTIVE" == "true" ]]; then svc_type="ClusterIP"
    else
        echo -e "  1) ClusterIP  2) NodePort  3) LoadBalancer" >&2
        case "$(read_input "Type (1-3)" "1")" in
            2) svc_type="NodePort" ;; 3) svc_type="LoadBalancer" ;; *) svc_type="ClusterIP" ;;
        esac
    fi
    port="${CLI_PORT:-$(read_validated "Service port" "80" validate_port)}"
    target_port=$(read_validated "Target port" "$port" validate_port)

    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-service.yaml")"
    safe_write "$out" "apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    app: ${name}
spec:
  type: ${svc_type}
  selector:
    app: ${name}
  ports:
    - port: ${port}
      targetPort: ${target_port}
      protocol: TCP"
}

generate_configmap() {
    log_info "── ConfigMap ──"
    local name namespace
    name="${CLI_NAME:-$(read_validated "ConfigMap name" "my-config" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    local -a kv=(); collect_kv kv "Key=value pairs"
    [[ ${#kv[@]} -eq 0 ]] && { kv+=("placeholder=changeme"); log_warn "Added placeholder"; }

    local data=""
    local pair; for pair in "${kv[@]}"; do data+=$'\n'"  ${pair%%=*}: \"${pair#*=}\""; done

    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-configmap.yaml")"
    safe_write "$out" "apiVersion: v1
kind: ConfigMap
metadata:
  name: ${name}
  namespace: ${namespace}
data:${data}"
}

generate_namespace() {
    log_info "── Namespace ──"
    local name
    name="${CLI_NAME:-$(read_validated "Namespace name" "my-namespace" validate_k8s_name)}"
    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-namespace.yaml")"
    safe_write "$out" "apiVersion: v1
kind: Namespace
metadata:
  name: ${name}
  labels:
    kubernetes.io/metadata.name: ${name}"
}

generate_ingress() {
    log_info "── Ingress ──"
    local name namespace host svc_name svc_port ing_class
    name="${CLI_NAME:-$(read_validated "Ingress name" "my-ingress" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    host=$(read_validated "Hostname" "example.com" validate_host)
    svc_name=$(read_validated "Backend service" "my-service" validate_k8s_name)
    svc_port=$(read_validated "Service port" "80" validate_port)
    ing_class=$(read_input "IngressClassName" "nginx")

    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-ingress.yaml")"
    safe_write "$out" "apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${name}
  namespace: ${namespace}
spec:
  ingressClassName: ${ing_class}
  rules:
    - host: ${host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${svc_name}
                port:
                  number: ${svc_port}"
}

generate_secret() {
    log_info "── Secret ──"
    local name namespace
    name="${CLI_NAME:-$(read_validated "Secret name" "my-secret" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    local -a kv=(); collect_kv kv "Key=value pairs"
    [[ ${#kv[@]} -eq 0 ]] && { kv+=("password=changeme"); log_warn "Added placeholder"; }

    local data=""
    local pair; for pair in "${kv[@]}"; do data+=$'\n'"  ${pair%%=*}: \"${pair#*=}\""; done

    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-secret.yaml")"
    safe_write "$out" "apiVersion: v1
kind: Secret
metadata:
  name: ${name}
  namespace: ${namespace}
type: Opaque
stringData:${data}"
}

generate_job() {
    log_info "── Job ──"
    local name namespace image cmd_str backoff completions parallelism
    name="${CLI_NAME:-$(read_validated "Job name" "my-job" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    image="${CLI_IMAGE:-$(read_validated "Image" "busybox:latest" validate_image)}"
    cmd_str=$(read_validated "Command" "echo hello" validate_safe_text)
    backoff=$(read_validated "Backoff limit" "3" validate_positive_int)
    completions=$(read_validated "Completions" "1" validate_positive_int)
    parallelism=$(read_validated "Parallelism" "1" validate_positive_int)
    pick_profile

    local csec; csec="$(opt_block 10 "$(container_security_context)")"
    local psec; psec="$(opt_block 6 "$(pod_security_context)")"
    local res;  res="$(printf '%s' "$(resources_block "$REQ_CPU" "$REQ_MEM" "$LIM_CPU" "$LIM_MEM")" | indent 10)"

    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-job.yaml")"
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
    spec:${psec}
      restartPolicy: Never
      containers:
        - name: ${name}
          image: ${image}
          imagePullPolicy: IfNotPresent
          command: [\"/bin/sh\", \"-c\"]
          args:
            - ${cmd_str}
${res}${csec}"
}

generate_cronjob() {
    log_info "── CronJob ──"
    local name namespace image schedule cmd_str concurrency
    name="${CLI_NAME:-$(read_validated "CronJob name" "my-cronjob" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    image="${CLI_IMAGE:-$(read_validated "Image" "busybox:latest" validate_image)}"
    schedule=$(read_validated "Cron schedule" "*/5 * * * *" validate_cron_schedule)
    cmd_str=$(read_validated "Command" "echo hello" validate_safe_text)
    if [[ "$NON_INTERACTIVE" == "true" ]]; then concurrency="Forbid"
    else
        echo -e "  1) Allow  2) Forbid  3) Replace" >&2
        case "$(read_input "Concurrency (1-3)" "2")" in
            1) concurrency="Allow" ;; 3) concurrency="Replace" ;; *) concurrency="Forbid" ;;
        esac
    fi
    pick_profile
    local csec; csec="$(opt_block 14 "$(container_security_context)")"
    local psec; psec="$(opt_block 10 "$(pod_security_context)")"
    local res;  res="$(printf '%s' "$(resources_block "$REQ_CPU" "$REQ_MEM" "$LIM_CPU" "$LIM_MEM")" | indent 14)"

    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-cronjob.yaml")"
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
        spec:${psec}
          restartPolicy: OnFailure
          containers:
            - name: ${name}
              image: ${image}
              imagePullPolicy: IfNotPresent
              command: [\"/bin/sh\", \"-c\"]
              args:
                - ${cmd_str}
${res}${csec}"
}

generate_pvc() {
    log_info "── PVC ──"
    local name namespace storage access_mode storage_class
    name="${CLI_NAME:-$(read_validated "PVC name" "my-pvc" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    storage=$(read_validated "Storage size" "1Gi" validate_storage)
    if [[ "$NON_INTERACTIVE" == "true" ]]; then access_mode="ReadWriteOnce"
    else
        echo -e "  1) ReadWriteOnce  2) ReadOnlyMany  3) ReadWriteMany" >&2
        case "$(read_input "Access mode (1-3)" "1")" in
            2) access_mode="ReadOnlyMany" ;; 3) access_mode="ReadWriteMany" ;; *) access_mode="ReadWriteOnce" ;;
        esac
    fi
    storage_class=$(read_input "StorageClass (empty=default)" "")
    local sc_line=""; [[ -n "$storage_class" ]] && sc_line=$'\n'"  storageClassName: ${storage_class}"

    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-pvc.yaml")"
    safe_write "$out" "apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    app: ${name}
spec:${sc_line}
  accessModes:
    - ${access_mode}
  resources:
    requests:
      storage: ${storage}"
}

generate_hpa() {
    log_info "── HPA ──"
    local name namespace target min_rep max_rep cpu_pct mem_pct
    name="${CLI_NAME:-$(read_validated "HPA name" "my-hpa" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    target=$(read_validated "Target Deployment name" "my-app" validate_k8s_name)
    min_rep=$(read_validated "Min replicas" "2" validate_replicas)
    max_rep=$(read_validated "Max replicas" "10" validate_replicas)
    cpu_pct=$(read_validated "Target CPU %" "70" validate_percentage)
    mem_pct=$(read_input "Target Memory % (empty=none)" "")

    local mem_metric=""
    if [[ -n "$mem_pct" ]]; then
        validate_percentage "$mem_pct" >/dev/null 2>&1 || mem_pct=""
    fi
    [[ -n "$mem_pct" ]] && mem_metric="
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: ${mem_pct}"

    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-hpa.yaml")"
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
    name: ${target}
  minReplicas: ${min_rep}
  maxReplicas: ${max_rep}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: ${cpu_pct}${mem_metric}"
}

generate_statefulset() {
    log_info "── StatefulSet ──"
    local name namespace image replicas port svc_name storage sc_name
    name="${CLI_NAME:-$(read_validated "StatefulSet name" "my-sts" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    image="${CLI_IMAGE:-$(read_validated "Image" "postgres:16" validate_image)}"
    replicas="${CLI_REPLICAS:-$(read_validated "Replicas" "3" validate_replicas)}"
    port="${CLI_PORT:-$(read_validated "Port" "5432" validate_port)}"
    svc_name=$(read_validated "Headless Service name" "${name}-headless" validate_k8s_name)
    storage=$(read_validated "Storage per pod" "10Gi" validate_storage)
    sc_name=$(read_input "StorageClass (empty=default)" "")
    pick_profile

    # storageClassName at 8 spaces (child of volumeClaimTemplates[].spec)  ← bug fixed
    local sc_line=""; [[ -n "$sc_name" ]] && sc_line=$'\n'"        storageClassName: ${sc_name}"
    local podsec; podsec="$(opt_block 6 "$(pod_security_context)")"
    local container; container="$(build_container "$name" "$image" "$port" tcp)"

    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-statefulset.yaml")"
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
    spec:${podsec}
      containers:
$(printf '%s' "$container" | sed 's/^        - name:/        - name:/')
          volumeMounts:
            - name: data
              mountPath: /var/lib/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:${sc_line}
        accessModes: [\"ReadWriteOnce\"]
        resources:
          requests:
            storage: ${storage}"
}

generate_daemonset() {
    log_info "── DaemonSet ──"
    local name namespace image port tolerate
    name="${CLI_NAME:-$(read_validated "DaemonSet name" "my-ds" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    image="${CLI_IMAGE:-$(read_validated "Image" "fluentd:latest" validate_image)}"
    # port is optional now (0/empty = none) ← bug fixed
    port="${CLI_PORT:-$(read_validated "Port (0=none)" "0" validate_port_optional)}"
    pick_profile

    tolerate=$(read_yes_no "Tolerate all taints (control-plane)?" "y")
    local tol_block=""
    [[ "$tolerate" == "y" ]] && tol_block=$'\n'"$(printf 'tolerations:\n  - operator: Exists' | indent 6)"

    local podsec; podsec="$(opt_block 6 "$(pod_security_context)")"
    local probes="none"; [[ "$port" != "0" && -n "$port" ]] && probes="tcp"
    local container; container="$(build_container "$name" "$image" "$port" "$probes")"

    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-daemonset.yaml")"
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
    spec:${podsec}${tol_block}
      containers:
$(printf '%s' "$container")"
}

generate_serviceaccount() {
    log_info "── ServiceAccount + RBAC ──"
    local name namespace api_groups resources verbs
    name="${CLI_NAME:-$(read_validated "ServiceAccount name" "my-sa" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    api_groups=$(read_input "API groups (comma-sep, empty=core)" "")
    resources=$(read_input "Resources (comma-sep)" "pods,services")
    verbs=$(read_input "Verbs (comma-sep)" "get,list,watch")

    local ag_yaml="" res_yaml="" verb_yaml="" x
    if [[ -z "$api_groups" ]]; then ag_yaml="      - \"\""
    else IFS=',' read -ra A <<< "$api_groups"; for x in "${A[@]}"; do ag_yaml+=$'\n'"      - \"${x}\""; done; ag_yaml="${ag_yaml#$'\n'}"; fi
    IFS=',' read -ra R <<< "$resources"; for x in "${R[@]}"; do res_yaml+=$'\n'"      - ${x}"; done; res_yaml="${res_yaml#$'\n'}"
    IFS=',' read -ra V <<< "$verbs"; for x in "${V[@]}"; do verb_yaml+=$'\n'"      - ${x}"; done; verb_yaml="${verb_yaml#$'\n'}"

    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-serviceaccount-rbac.yaml")"
    safe_write "$out" "apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${name}
  namespace: ${namespace}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${name}-role
  namespace: ${namespace}
rules:
  - apiGroups:
${ag_yaml}
    resources:
${res_yaml}
    verbs:
${verb_yaml}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${name}-rolebinding
  namespace: ${namespace}
subjects:
  - kind: ServiceAccount
    name: ${name}
    namespace: ${namespace}
roleRef:
  kind: Role
  name: ${name}-role
  apiGroup: rbac.authorization.k8s.io"
}

generate_networkpolicy() {
    log_info "── NetworkPolicy ──"
    local name namespace pod_selector port key value
    name="${CLI_NAME:-$(read_validated "NetworkPolicy name" "allow-app" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    pod_selector=$(read_input "Pod selector label (app=myapp)" "app=myapp")
    port=$(read_validated "Allow port" "80" validate_port)
    key="${pod_selector%%=*}"; value="${pod_selector##*=}"

    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-networkpolicy.yaml")"
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

generate_pdb() {
    log_info "── PodDisruptionBudget ──"
    local name namespace selector mode value key val
    name="${CLI_NAME:-$(read_validated "PDB name" "my-pdb" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "default" validate_namespace)}"
    selector=$(read_input "Pod selector label (app=myapp)" "app=myapp")
    key="${selector%%=*}"; val="${selector##*=}"
    if [[ "$NON_INTERACTIVE" == "true" ]]; then mode="minAvailable"; value="1"
    else
        echo -e "  1) minAvailable   2) maxUnavailable" >&2
        case "$(read_input "Constraint (1-2)" "1")" in
            2) mode="maxUnavailable" ;; *) mode="minAvailable" ;;
        esac
        value=$(read_input "Value (number or %)" "1")
    fi
    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-pdb.yaml")"
    safe_write "$out" "apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ${name}
  namespace: ${namespace}
spec:
  ${mode}: ${value}
  selector:
    matchLabels:
      ${key}: ${val}"
}

# ══════════════════════════════════════════════════
#  KUSTOMIZATION
# ══════════════════════════════════════════════════
generate_kustomization() {
    log_info "── Kustomization ──"
    local namespace prefix suffix
    namespace=$(read_input "Namespace (empty=none)" "")
    prefix=$(read_input "namePrefix (empty=none)" "")
    suffix=$(read_input "nameSuffix (empty=none)" "")

    # gather resources: files created this run, else all *.yaml in OUTPUT_DIR
    local -a files=()
    if [[ ${#GENERATED_FILES[@]} -gt 0 ]]; then
        local f; for f in "${GENERATED_FILES[@]}"; do files+=("$(basename "$f")"); done
    else
        local f
        while IFS= read -r f; do files+=("$(basename "$f")"); done < <(find "$OUTPUT_DIR" -maxdepth 1 -name '*.yaml' ! -name 'kustomization.yaml' 2>/dev/null | sort)
    fi
    if [[ ${#files[@]} -eq 0 ]]; then
        log_warn "No resource files found in ${OUTPUT_DIR}; add resources manually."
        files=("# add your manifests here")
    fi

    local res_yaml=""; local f
    for f in "${files[@]}"; do res_yaml+=$'\n'"  - ${f}"; done

    local meta=""
    [[ -n "$namespace" ]] && meta+=$'\n'"namespace: ${namespace}"
    [[ -n "$prefix" ]]    && meta+=$'\n'"namePrefix: ${prefix}"
    [[ -n "$suffix" ]]    && meta+=$'\n'"nameSuffix: ${suffix}"

    local out="${OUTPUT_DIR}/kustomization.yaml"
    [[ "$STDOUT_MODE" != "true" && "$NON_INTERACTIVE" != "true" ]] && out=$(read_input "Output file" "$out")

    # kustomization.yaml is not a k8s API object → skip schema validation
    local _v="$VALIDATE"; VALIDATE="off"
    safe_write "$out" "apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization${meta}
resources:${res_yaml}"
    VALIDATE="$_v"
}

# ══════════════════════════════════════════════════
#  FULL STACK
# ══════════════════════════════════════════════════
generate_full_stack() {
    log_info "── Full Microservice Stack ──"
    local name namespace image replicas port
    name="${CLI_NAME:-$(read_validated "App name" "myapp" validate_k8s_name)}"
    namespace="${CLI_NAMESPACE:-$(read_validated "Namespace" "${name}-ns" validate_namespace)}"
    image="${CLI_IMAGE:-$(read_validated "Image" "nginx:latest" validate_image)}"
    replicas="${CLI_REPLICAS:-$(read_validated "Replicas" "3" validate_replicas)}"
    port="${CLI_PORT:-$(read_validated "Port" "80" validate_port)}"
    pick_profile

    # optional HPA
    local hpa_block="" enable_hpa min_rep max_rep cpu_pct
    enable_hpa=$(read_yes_no "Enable HPA?" "n")
    if [[ "$enable_hpa" == "y" ]]; then
        min_rep=$(read_validated "HPA min replicas" "2" validate_replicas)
        max_rep=$(read_validated "HPA max replicas" "10" validate_replicas)
        cpu_pct=$(read_validated "HPA target CPU %" "80" validate_percentage)
        hpa_block="
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${name}-hpa
  namespace: ${namespace}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${name}
  minReplicas: ${min_rep}
  maxReplicas: ${max_rep}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: ${cpu_pct}"
    fi

    # optional Ingress
    local ing_block="" host ing_class
    host=$(read_input "Ingress host (empty=disable)" "")
    if [[ -n "$host" ]]; then
        validate_host "$host" >/dev/null 2>&1 || host=""
    fi
    if [[ -n "$host" ]]; then
        ing_class=$(read_input "IngressClassName" "nginx")
        ing_block="
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${name}-ing
  namespace: ${namespace}
spec:
  ingressClassName: ${ing_class}
  rules:
    - host: ${host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${name}-svc
                port:
                  number: ${port}"
    fi

    ENVFROM_YAML="envFrom:
  - configMapRef:
      name: ${name}-config
  - secretRef:
      name: ${name}-secret"
    local podsec; podsec="$(opt_block 6 "$(pod_security_context)")"
    local container; container="$(build_container "$name" "$image" "$port" tcp)"
    unset ENVFROM_YAML

    local out; out="$(resolve_out "${OUTPUT_DIR}/${name}-full-stack.yaml")"
    safe_write "$out" "apiVersion: v1
kind: Namespace
metadata:
  name: ${namespace}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${name}-sa
  namespace: ${namespace}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${name}-config
  namespace: ${namespace}
data:
  APP_NAME: \"${name}\"
  APP_ENV: \"production\"
---
apiVersion: v1
kind: Secret
metadata:
  name: ${name}-secret
  namespace: ${namespace}
type: Opaque
stringData:
  APP_SECRET: \"change-me\"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    app: ${name}
spec:
  replicas: ${replicas}
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      serviceAccountName: ${name}-sa${podsec}
      containers:
$(printf '%s' "$container")
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}-svc
  namespace: ${namespace}
spec:
  type: ClusterIP
  selector:
    app: ${name}
  ports:
    - port: ${port}
      targetPort: ${port}
      protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${name}-allow-svc-port
  namespace: ${namespace}
spec:
  podSelector:
    matchLabels:
      app: ${name}
  policyTypes:
    - Ingress
  ingress:
    - ports:
        - protocol: TCP
          port: ${port}${hpa_block}${ing_block}"
}

# ══════════════════════════════════════════════════
#  MENU / DISPATCH / ARGS / MAIN
# ══════════════════════════════════════════════════
show_menu() {
    cat >&2 <<'EOF'

Choose resource type:
 1) Pod                 10) PVC
 2) Deployment          11) Deployment Advanced
 3) Service             12) HPA
 4) ConfigMap           13) StatefulSet
 5) Namespace           14) DaemonSet
 6) Ingress             15) ServiceAccount + RBAC
 7) Secret              16) NetworkPolicy
 8) Job                 17) PodDisruptionBudget
 9) CronJob             18) Kustomization
                        19) Full Stack
EOF
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
        pdb|17) generate_pdb ;;
        kustomize|18) generate_kustomization ;;
        full-stack|19) generate_full_stack ;;
        *) log_error "Unknown type: $1"; exit 1 ;;
    esac
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--type) CLI_TYPE="$2"; shift 2 ;;
            -n|--name) CLI_NAME="$2"; shift 2 ;;
            -i|--image) CLI_IMAGE="$2"; shift 2 ;;
            -r|--replicas) CLI_REPLICAS="$2"; shift 2 ;;
            -p|--port) CLI_PORT="$2"; shift 2 ;;
            --namespace) CLI_NAMESPACE="$2"; shift 2 ;;
            --profile) CLI_PROFILE="$2"; shift 2 ;;
            --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
            --stdout) STDOUT_MODE=true; shift ;;
            --no-security) SECURITY=false; shift ;;
            --validate) VALIDATE="$2"; shift 2 ;;
            --non-interactive) NON_INTERACTIVE=true; shift ;;
            -f|--force) FORCE_OVERWRITE=true; shift ;;
            --debug) DEBUG=true; shift ;;
            -h|--help) show_help ;;
            -v|--version) show_version ;;
            *) log_error "Unknown arg: $1"; exit 1 ;;
        esac
    done
}

main() {
    parse_args "$@"
    banner
    check_prerequisites
    if [[ -n "$CLI_TYPE" ]]; then dispatch_choice "$CLI_TYPE"; exit 0; fi
    show_menu
    local choice; choice=$(read_input "Select option" "1")
    dispatch_choice "$choice"
}

main "$@"
