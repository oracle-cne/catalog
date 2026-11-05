#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLUSTER_NAME="ocne-calico"
CONTROL_PLANE_NODES="1"
WORKER_NODES="3"
POD_SUBNET="10.244.0.0/16"
KUBECONFIG_PATH="${KUBECONFIG:-}"

CALICO_NAMESPACE="tigera-operator"
CALICO_RELEASE="calico"
CALICO_CHART_NAME="tigera-operator"
TIGERA_OPERATOR_VERSION=""
CALICO_IP_POOL_CIDR=""
CALICO_LINUX_DATAPLANE="Iptables"
CALICO_ENCAPSULATION=""
CALICO_NAT_OUTGOING="Enabled"
CALICO_VALUES_FILE=""
CATALOG_NAME="${CATALOG_TEST_NAME:-}"

NODE_REGISTRATION_TIMEOUT_SECONDS="900"
NODE_READY_TIMEOUT_SECONDS="1200"
CALICO_READY_TIMEOUT_SECONDS="900"
CHECK_ONLY="false"
KEEP_GENERATED_FILES="false"

REGISTRY="${REGISTRY:-container-registry.oracle.com}"
IMAGEPATH="${IMAGEPATH:-olcne}"

OCNE_BIN="${OCNE_BIN:-ocne}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

TMP_DIR=""
GENERATED_CALICO_VALUES=""

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} --kubeconfig PATH [options]

Install and validate applications in an existing cluster.
The caller provisions cluster.yaml and owns cluster cleanup.
KUBECONFIG may supply the existing kubeconfig instead of --kubeconfig.
OCNE_BIN and KUBECTL_BIN select CLI executables (defaults: ocne, kubectl).

  --pod-subnet CIDR               Kubernetes pod subnet. Default: ${POD_SUBNET}
  --kubeconfig PATH               Existing kubeconfig. Default: KUBECONFIG environment.
  --tigera-operator-version VER   Candidate catalog tigera-operator version.
                                  Use --tigera-operator-version= to let OCNE
                                  select the catalog default. Default:
                                  ${TIGERA_OPERATOR_VERSION}
  --calico-release NAME           OCNE application release name. Default: ${CALICO_RELEASE}
  --calico-namespace NAME         OCNE application namespace. Default: ${CALICO_NAMESPACE}
  --calico-ip-pool-cidr CIDR      Calico IP pool CIDR. Default: --pod-subnet
  --calico-linux-dataplane MODE   Iptables, Nftables, or BPF. Nftables requires
                                  kube-proxy in nftables mode. Default: ${CALICO_LINUX_DATAPLANE}
  --calico-encapsulation MODE     IPIP, VXLAN, IPIPCrossSubnet,
                                  VXLANCrossSubnet, or None. Default: IPIP for Iptables;
                                  VXLAN for Nftables and BPF.
  --calico-nat-outgoing MODE      Enabled or Disabled. Default: ${CALICO_NAT_OUTGOING}
  --calico-values PATH            Use an existing Tigera operator values file
                                  instead of generated Calico values.
  --node-registration-timeout SEC Wait for expected nodes to register.
                                  Default: ${NODE_REGISTRATION_TIMEOUT_SECONDS}
  --node-ready-timeout SEC        Wait for nodes to become Ready after Calico.
                                  Default: ${NODE_READY_TIMEOUT_SECONDS}
  --calico-ready-timeout SEC      Wait for Calico resources. Default:
                                  ${CALICO_READY_TIMEOUT_SECONDS}
  --check-only                    Validate local inputs and candidate catalog,
                                  generate application values, then exit.
  --keep-generated-files          Keep generated application values files.
  --help                          Show this help.
USAGE
}

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

log_command() {
  printf '[%s] Running:' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
}

run() {
  log_command "$@"
  "$@"
}

kubectl_args() {
  if [[ -n "$KUBECONFIG_PATH" ]]; then
    printf '%s\n' --kubeconfig "$KUBECONFIG_PATH"
  fi
}

run_kubectl() {
  local args=()
  mapfile -t args < <(kubectl_args)
  run "$KUBECTL_BIN" "${args[@]}" "$@"
}

kubectl_quiet() {
  local args=()
  mapfile -t args < <(kubectl_args)
  "$KUBECTL_BIN" "${args[@]}" "$@" >/dev/null 2>&1
}

run_ocne() {
  if [[ -n "$KUBECONFIG_PATH" ]]; then
    log_command "KUBECONFIG=${KUBECONFIG_PATH}" "$OCNE_BIN" "$@"
    KUBECONFIG="$KUBECONFIG_PATH" "$OCNE_BIN" "$@"
    return
  fi

  run "$OCNE_BIN" "$@"
}

need_arg() {
  local flag="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || die "${flag} requires a value"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pod-subnet)
        need_arg "$1" "${2:-}"
        POD_SUBNET="$2"
        shift 2
        ;;
      --pod-subnet=*)
        POD_SUBNET="${1#*=}"
        shift
        ;;
      --kubeconfig)
        need_arg "$1" "${2:-}"
        KUBECONFIG_PATH="$2"
        shift 2
        ;;
      --kubeconfig=*)
        KUBECONFIG_PATH="${1#*=}"
        shift
        ;;
      --tigera-operator-version)
        [[ $# -ge 2 ]] || die "${1} requires a value"
        TIGERA_OPERATOR_VERSION="$2"
        shift 2
        ;;
      --tigera-operator-version=*)
        TIGERA_OPERATOR_VERSION="${1#*=}"
        shift
        ;;
      --calico-release)
        need_arg "$1" "${2:-}"
        CALICO_RELEASE="$2"
        shift 2
        ;;
      --calico-release=*)
        CALICO_RELEASE="${1#*=}"
        shift
        ;;
      --calico-namespace)
        need_arg "$1" "${2:-}"
        CALICO_NAMESPACE="$2"
        shift 2
        ;;
      --calico-namespace=*)
        CALICO_NAMESPACE="${1#*=}"
        shift
        ;;
      --calico-ip-pool-cidr)
        need_arg "$1" "${2:-}"
        CALICO_IP_POOL_CIDR="$2"
        shift 2
        ;;
      --calico-ip-pool-cidr=*)
        CALICO_IP_POOL_CIDR="${1#*=}"
        shift
        ;;
      --calico-linux-dataplane)
        need_arg "$1" "${2:-}"
        CALICO_LINUX_DATAPLANE="$2"
        shift 2
        ;;
      --calico-linux-dataplane=*)
        CALICO_LINUX_DATAPLANE="${1#*=}"
        shift
        ;;
      --calico-encapsulation)
        need_arg "$1" "${2:-}"
        CALICO_ENCAPSULATION="$2"
        shift 2
        ;;
      --calico-encapsulation=*)
        CALICO_ENCAPSULATION="${1#*=}"
        shift
        ;;
      --calico-nat-outgoing)
        need_arg "$1" "${2:-}"
        CALICO_NAT_OUTGOING="$2"
        shift 2
        ;;
      --calico-nat-outgoing=*)
        CALICO_NAT_OUTGOING="${1#*=}"
        shift
        ;;
      --calico-values)
        need_arg "$1" "${2:-}"
        CALICO_VALUES_FILE="$2"
        shift 2
        ;;
      --calico-values=*)
        CALICO_VALUES_FILE="${1#*=}"
        shift
        ;;
      --node-registration-timeout)
        need_arg "$1" "${2:-}"
        NODE_REGISTRATION_TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --node-registration-timeout=*)
        NODE_REGISTRATION_TIMEOUT_SECONDS="${1#*=}"
        shift
        ;;
      --node-ready-timeout)
        need_arg "$1" "${2:-}"
        NODE_READY_TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --node-ready-timeout=*)
        NODE_READY_TIMEOUT_SECONDS="${1#*=}"
        shift
        ;;
      --calico-ready-timeout)
        need_arg "$1" "${2:-}"
        CALICO_READY_TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --calico-ready-timeout=*)
        CALICO_READY_TIMEOUT_SECONDS="${1#*=}"
        shift
        ;;
      --check-only)
        CHECK_ONLY="true"
        shift
        ;;
      --keep-generated-files)
        KEEP_GENERATED_FILES="true"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

validate_integer() {
  local field="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "${field} must be a non-negative integer"
}

validate_dns_label() {
  local field="$1"
  local value="$2"
  [[ ${#value} -le 63 ]] || die "${field} must be 63 characters or fewer: ${value}"
  [[ "$value" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || \
    die "${field} must be a Kubernetes DNS label: ${value}"
}

validate_no_newline() {
  local field="$1"
  local value="$2"
  [[ "$value" != *$'\n'* ]] || die "${field} cannot contain a newline"
  [[ "$value" != *$'\r'* ]] || die "${field} cannot contain a carriage return"
}

validate_no_shell_whitespace() {
  local field="$1"
  local value="$2"
  [[ "$value" != *[[:space:]]* ]] || die "${field} cannot contain whitespace: ${value}"
}

validate_enum() {
  local field="$1"
  local value="$2"
  shift 2
  local allowed=("$@")
  local candidate=""

  for candidate in "${allowed[@]}"; do
    if [[ "$value" == "$candidate" ]]; then
      return
    fi
  done

  die "${field} must be one of: ${allowed[*]}"
}

finalize_defaults() {
  log "Resolving defaults"
  if [[ -z "$KUBECONFIG_PATH" ]]; then
    KUBECONFIG_PATH="${KUBECONFIG:-}"
  fi
  if [[ -z "$CALICO_IP_POOL_CIDR" ]]; then
    CALICO_IP_POOL_CIDR="$POD_SUBNET"
  fi
  if [[ -z "$CALICO_ENCAPSULATION" ]]; then
    case "$CALICO_LINUX_DATAPLANE" in
      BPF|Nftables)
        CALICO_ENCAPSULATION="VXLAN"
        ;;
      Iptables)
        CALICO_ENCAPSULATION="IPIP"
        ;;
    esac
  fi
}

validate_inputs() {
  log "Validating script inputs"
  validate_dns_label "candidate catalog" "$CATALOG_NAME"
  validate_dns_label "--calico-release" "$CALICO_RELEASE"
  validate_dns_label "--calico-namespace" "$CALICO_NAMESPACE"
  validate_integer "--control-plane-nodes" "$CONTROL_PLANE_NODES"
  validate_integer "--worker-nodes" "$WORKER_NODES"
  validate_integer "--node-registration-timeout" "$NODE_REGISTRATION_TIMEOUT_SECONDS"
  validate_integer "--node-ready-timeout" "$NODE_READY_TIMEOUT_SECONDS"
  validate_integer "--calico-ready-timeout" "$CALICO_READY_TIMEOUT_SECONDS"
  (( CONTROL_PLANE_NODES >= 1 )) || die "--control-plane-nodes must be at least 1"
  (( WORKER_NODES >= 3 )) || die "--worker-nodes must be at least 3 for this Calico test cluster"

  validate_no_newline "--pod-subnet" "$POD_SUBNET"
  validate_no_shell_whitespace "--pod-subnet" "$POD_SUBNET"
  validate_no_newline "--kubeconfig" "$KUBECONFIG_PATH"
  validate_no_newline "--tigera-operator-version" "$TIGERA_OPERATOR_VERSION"
  validate_no_shell_whitespace "--tigera-operator-version" "$TIGERA_OPERATOR_VERSION"
  validate_no_newline "--calico-ip-pool-cidr" "$CALICO_IP_POOL_CIDR"
  validate_no_shell_whitespace "--calico-ip-pool-cidr" "$CALICO_IP_POOL_CIDR"
  validate_no_newline "--calico-values" "$CALICO_VALUES_FILE"
  validate_enum "--calico-linux-dataplane" "$CALICO_LINUX_DATAPLANE" \
    Iptables Nftables BPF
  validate_enum "--calico-encapsulation" "$CALICO_ENCAPSULATION" \
    IPIP VXLAN IPIPCrossSubnet VXLANCrossSubnet None
  validate_enum "--calico-nat-outgoing" "$CALICO_NAT_OUTGOING" Enabled Disabled

  if [[ "$CALICO_LINUX_DATAPLANE" == "BPF" && \
    ( "$CALICO_ENCAPSULATION" == "IPIP" || "$CALICO_ENCAPSULATION" == "IPIPCrossSubnet" ) ]]; then
    die "--calico-linux-dataplane BPF does not support IPIP encapsulation; use VXLAN, VXLANCrossSubnet, or None"
  fi

  if [[ -n "$CALICO_VALUES_FILE" && ! -f "$CALICO_VALUES_FILE" ]]; then
    die "--calico-values must point to an existing file: ${CALICO_VALUES_FILE}"
  fi
}

check_executable() {
  local label="$1"
  local executable="$2"

  if [[ "$executable" == */* ]]; then
    [[ -x "$executable" ]] || die "${label} is not executable: ${executable}"
    return
  fi

  command -v -- "$executable" >/dev/null 2>&1 || die "${label} was not found in PATH: ${executable}"
}

check_required_tools() {
  log "Checking required local tools"
  check_executable "OCNE CLI" "$OCNE_BIN"
  check_executable "kubectl" "$KUBECTL_BIN"
  check_executable "awk" "awk"
  check_executable "mktemp" "mktemp"
}

create_workspace() {
  log "Creating generated-file workspace"
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCRIPT_NAME%.sh}.XXXXXX")"
  GENERATED_CALICO_VALUES="${TMP_DIR}/calico-values.yaml"
  log "Generated files directory: ${TMP_DIR}"
}

cleanup() {
  if [[ "$KEEP_GENERATED_FILES" == "true" ]]; then
    if [[ -n "$TMP_DIR" ]]; then
      log "Keeping generated files in ${TMP_DIR}"
    fi
    return
  fi

  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    log "Removing generated files from ${TMP_DIR}"
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT


write_calico_values() {
  if [[ -n "$CALICO_VALUES_FILE" ]]; then
    log "Using caller-provided Calico values: ${CALICO_VALUES_FILE}"
    return
  fi

  log "Writing generated Calico values"
  cat >"$GENERATED_CALICO_VALUES" <<EOF_VALUES
installation:
  registry: "${REGISTRY}"
  imagePath: "${IMAGEPATH}"
  flexVolumePath: /var/lib/kubelet/volumeplugins/
  calicoNetwork:
    linuxDataplane: ${CALICO_LINUX_DATAPLANE}
    ipPools:
      - cidr: ${CALICO_IP_POOL_CIDR}
        encapsulation: ${CALICO_ENCAPSULATION}
        natOutgoing: ${CALICO_NAT_OUTGOING}
        nodeSelector: "all()"
apiServer:
  enabled: true
tigeraOperator:
  registry: olcne
  image: tigera-operator
calicoctl:
  image: olcne/ctl
EOF_VALUES
  CALICO_VALUES_FILE="$GENERATED_CALICO_VALUES"
  log "Calico values path: ${CALICO_VALUES_FILE}"
}

check_candidate_catalog() {
  log "Checking candidate catalog for ${CALICO_CHART_NAME}"
  local catalog_output=""
  log_command "$OCNE_BIN" catalog search --name "$CATALOG_NAME" --pattern "^${CALICO_CHART_NAME}$"
  catalog_output="$("$OCNE_BIN" catalog search --name "$CATALOG_NAME" --pattern "^${CALICO_CHART_NAME}$")"
  printf '%s\n' "$catalog_output" >&2

  if [[ -z "$TIGERA_OPERATOR_VERSION" ]]; then
    log "No explicit tigera-operator version requested; OCNE will select the catalog default"
    return
  fi

  if ! awk -v chart="$CALICO_CHART_NAME" -v version="$TIGERA_OPERATOR_VERSION" \
    '$1 == chart && $2 == version { found = 1 } END { exit !found }' <<<"$catalog_output"; then
    die "candidate catalog does not list ${CALICO_CHART_NAME} ${TIGERA_OPERATOR_VERSION}"
  fi
}

log_configuration() {
  log "Configuration summary"
  log "  cluster: ${CLUSTER_NAME}"
  log "  control plane nodes: ${CONTROL_PLANE_NODES}"
  log "  worker nodes: ${WORKER_NODES}"
  log "  pod subnet: ${POD_SUBNET}"
  log "  kubeconfig: ${KUBECONFIG_PATH}"
  log "  Calico release: ${CALICO_NAMESPACE}/${CALICO_RELEASE}"
  log "  tigera-operator version: ${TIGERA_OPERATOR_VERSION:-catalog default}"
  log "  Calico Linux dataplane: ${CALICO_LINUX_DATAPLANE}"
  log "  Calico encapsulation: ${CALICO_ENCAPSULATION}"
  log "  Calico values: ${CALICO_VALUES_FILE}"
}


node_count() {
  local args=()
  mapfile -t args < <(kubectl_args)
  "$KUBECTL_BIN" "${args[@]}" get nodes --no-headers 2>/dev/null | \
    awk 'NF { count++ } END { print count + 0 }'
}

wait_for_api() {
  local deadline=$((SECONDS + NODE_REGISTRATION_TIMEOUT_SECONDS))
  log "Waiting for Kubernetes API access"

  while (( SECONDS < deadline )); do
    if kubectl_quiet get nodes; then
      log "Kubernetes API is reachable"
      return
    fi
    log "Kubernetes API is not reachable yet; waiting"
    sleep 10
  done

  die "timed out waiting for Kubernetes API access"
}

wait_for_node_registration() {

  local expected_nodes=$((CONTROL_PLANE_NODES + WORKER_NODES))
  local deadline=$((SECONDS + NODE_REGISTRATION_TIMEOUT_SECONDS))
  local count="0"

  log "Waiting for ${expected_nodes} Kubernetes nodes to register"
  while (( SECONDS < deadline )); do
    count="$(node_count || true)"
    if [[ "$count" == "$expected_nodes" ]]; then
      log "Detected ${count}/${expected_nodes} registered nodes"
      return
    fi
    log "Detected ${count}/${expected_nodes} registered nodes; waiting"
    sleep 10
  done

  die "timed out waiting for ${expected_nodes} registered nodes"
}

verify_kube_proxy_dataplane_compatibility() {
  if [[ "$CALICO_LINUX_DATAPLANE" != "Nftables" ]]; then
    log "Calico ${CALICO_LINUX_DATAPLANE} dataplane does not require a kube-proxy mode check"
    return
  fi

  log "Verifying kube-proxy uses nftables mode for the Calico Nftables dataplane"
  wait_for_get "$NODE_REGISTRATION_TIMEOUT_SECONDS" -n kube-system configmap/kube-proxy

  local config=""
  local args=()
  mapfile -t args < <(kubectl_args)
  config="$("$KUBECTL_BIN" "${args[@]}" -n kube-system get configmap kube-proxy \
    -o jsonpath='{.data.config\\.conf}')"

  if ! awk '
    /^[[:space:]]*mode:[[:space:]]*nftables[[:space:]]*$/ { found = 1 }
    END { exit !found }
  ' <<<"$config"; then
    die "Calico Nftables requires kube-proxy mode nftables; configure kube-system/configmap kube-proxy in the externally provisioned cluster"
  fi

  log "kube-proxy is configured for nftables mode"
}

release_installed() {
  KUBECONFIG="$KUBECONFIG_PATH" "$OCNE_BIN" application show \
    --namespace "$CALICO_NAMESPACE" \
    --release "$CALICO_RELEASE" >/dev/null 2>&1
}

install_calico() {
  local values_arg=()
  local version_arg=()

  if [[ -n "$CALICO_VALUES_FILE" ]]; then
    values_arg=(--values "$CALICO_VALUES_FILE")
  fi
  if [[ -n "$TIGERA_OPERATOR_VERSION" ]]; then
    version_arg=(--version "$TIGERA_OPERATOR_VERSION")
  fi

  if release_installed; then
    log "Updating existing Calico OCNE application release ${CALICO_NAMESPACE}/${CALICO_RELEASE}"
    run_ocne application update \
      --catalog "$CATALOG_NAME" \
      --release "$CALICO_RELEASE" \
      --namespace "$CALICO_NAMESPACE" \
      --reset-values \
      "${version_arg[@]}" \
      "${values_arg[@]}"
    return
  fi

  log "Installing Calico through OCNE application management"
  run_ocne application install \
    --catalog "$CATALOG_NAME" \
    --name "$CALICO_CHART_NAME" \
    --release "$CALICO_RELEASE" \
    --namespace "$CALICO_NAMESPACE" \
    "${version_arg[@]}" \
    "${values_arg[@]}"
}

wait_for_get() {
  local timeout_seconds="$1"
  shift
  local deadline=$((SECONDS + timeout_seconds))
  local resource_label="$*"

  log "Waiting for resource: ${resource_label}"
  while (( SECONDS < deadline )); do
    if kubectl_quiet get "$@"; then
      log "Found resource: ${resource_label}"
      return
    fi
    log "Resource not present yet: ${resource_label}; waiting"
    sleep 10
  done

  die "timed out waiting for resource: ${resource_label}"
}

rollout_if_present() {
  local namespace="$1"
  local resource="$2"
  local timeout_seconds="$3"

  if kubectl_quiet -n "$namespace" get "$resource"; then
    run_kubectl -n "$namespace" rollout status "$resource" --timeout "${timeout_seconds}s"
  else
    log "Skipping rollout wait for absent resource ${namespace}/${resource}"
  fi
}

wait_for_calico() {
  log "Waiting for Calico operator and dataplane resources"
  wait_for_get "$CALICO_READY_TIMEOUT_SECONDS" crd installations.operator.tigera.io
  wait_for_get "$CALICO_READY_TIMEOUT_SECONDS" crd tigerastatuses.operator.tigera.io
  wait_for_get "$CALICO_READY_TIMEOUT_SECONDS" crd ippools.crd.projectcalico.org

  wait_for_get "$CALICO_READY_TIMEOUT_SECONDS" -n "$CALICO_NAMESPACE" deployment/tigera-operator
  run_kubectl -n "$CALICO_NAMESPACE" rollout status deployment/tigera-operator --timeout "${CALICO_READY_TIMEOUT_SECONDS}s"

  wait_for_get "$CALICO_READY_TIMEOUT_SECONDS" -n calico-system daemonset/calico-node
  run_kubectl -n calico-system rollout status daemonset/calico-node --timeout "${CALICO_READY_TIMEOUT_SECONDS}s"
  rollout_if_present calico-system deployment/calico-typha "$CALICO_READY_TIMEOUT_SECONDS"
  rollout_if_present calico-system deployment/calico-kube-controllers "$CALICO_READY_TIMEOUT_SECONDS"
  rollout_if_present calico-apiserver deployment/calico-apiserver "$CALICO_READY_TIMEOUT_SECONDS"

  if kubectl_quiet get tigerastatuses.operator.tigera.io/calico; then
    run_kubectl wait --for=condition=Available tigerastatuses.operator.tigera.io/calico \
      --timeout "${CALICO_READY_TIMEOUT_SECONDS}s"
  fi
  if kubectl_quiet get tigerastatuses.operator.tigera.io/apiserver; then
    run_kubectl wait --for=condition=Available tigerastatuses.operator.tigera.io/apiserver \
      --timeout "${CALICO_READY_TIMEOUT_SECONDS}s"
  fi
}

wait_for_nodes_ready() {
  log "Waiting for all Kubernetes nodes to report Ready"
  run_kubectl wait --for=condition=Ready nodes --all --timeout "${NODE_READY_TIMEOUT_SECONDS}s"
}

show_result() {
  log "Showing resulting OCNE cluster and Calico application state"
  run_ocne cluster info
  run_ocne application show --namespace "$CALICO_NAMESPACE" --release "$CALICO_RELEASE"
  run_kubectl get nodes -o wide
  run_kubectl -n "$CALICO_NAMESPACE" get pods -o wide
  if kubectl_quiet get namespace calico-system; then
    run_kubectl -n calico-system get pods -o wide
  fi

  log "Calico test cluster is ready"
  log "KUBECONFIG=${KUBECONFIG_PATH}"
}

main() {
  parse_args "$@"
  [[ -n "$CATALOG_NAME" ]] || die "Run tests/run-changed.sh to build and register this checkout catalog"
  log "Using an externally provisioned cluster; cluster lifecycle belongs to the caller"
  [[ -n "$KUBECONFIG_PATH" && -s "$KUBECONFIG_PATH" ]] || die "Supply an existing kubeconfig with --kubeconfig or KUBECONFIG"
  log "Starting ${SCRIPT_NAME}"
  finalize_defaults
  validate_inputs
  check_required_tools
  create_workspace
  write_calico_values
  check_candidate_catalog
  log_configuration

  if [[ "$CHECK_ONLY" == "true" ]]; then
    log "Check-only mode complete"
    return
  fi

  wait_for_api
  wait_for_node_registration
  verify_kube_proxy_dataplane_compatibility
  install_calico
  wait_for_calico
  wait_for_nodes_ready
  show_result
}

main "$@"
