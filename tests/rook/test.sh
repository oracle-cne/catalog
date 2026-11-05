#!/usr/bin/env bash
# Copyright (c) 2026, Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at
# https://oss.oracle.com/licenses/upl.

# Install Rook-Ceph in an externally provisioned cluster from the candidate
# OCNE catalog. Each VM has a large thin-provisioned disk with a dedicated
# /dev/sda4 partition for Rook-Ceph OSDs; the operating system remains on the
# root partition.
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLUSTER_NAME="ocne-rook"
CONTROL_PLANE_NODES="1"
WORKER_NODES="3"
KUBECONFIG_PATH="${KUBECONFIG:-}"

CATALOG_NAME="${CATALOG_TEST_NAME:-}"
ROOK_CHART_NAME="rook"
ROOK_NAMESPACE="rook-ceph"
ROOK_RELEASE="rook-ceph"
ROOK_VERSION="${ROOK_VERSION:-}"

NODE_READY_TIMEOUT_SECONDS="1200"
ROOK_READY_TIMEOUT_SECONDS="900"
CHECK_ONLY="false"
KEEP_GENERATED_FILES="false"

OCNE_BIN="${OCNE_BIN:-ocne}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

TMP_DIR=""
ROOK_VALUES_CONFIG=""

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} --kubeconfig PATH [options]

Install and validate applications in an existing cluster.
The caller provisions cluster.yaml and owns cluster cleanup.
KUBECONFIG may supply the existing kubeconfig instead of --kubeconfig.
OCNE_BIN and KUBECTL_BIN select CLI executables (defaults: ocne, kubectl).

  --kubeconfig PATH               Existing kubeconfig. Default: KUBECONFIG environment.
  --rook-version VERSION          Rook chart version. By default, OCNE
                                  selects the catalog default.
  --rook-namespace NAME           Rook-Ceph namespace. Default: ${ROOK_NAMESPACE}
  --rook-release NAME             OCNE application release. Default: ${ROOK_RELEASE}
  --rook-ready-timeout SECONDS    Timeout waiting for the Rook operator.
                                  Default: ${ROOK_READY_TIMEOUT_SECONDS}
  --node-ready-timeout SECONDS    Timeout waiting for Kubernetes nodes.
                                  Default: ${NODE_READY_TIMEOUT_SECONDS}
  --check-only                    Validate local inputs and generate configuration,
                                  but do not install Rook.
  --keep-generated-files          Preserve generated configuration after the run.
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

need_arg() {
  [[ -n "${2:-}" ]] || die "$1 requires a value"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kubeconfig) need_arg "$1" "${2:-}"; KUBECONFIG_PATH="$2"; shift 2 ;;
      --kubeconfig=*) KUBECONFIG_PATH="${1#*=}"; shift ;;
      --rook-version) need_arg "$1" "${2:-}"; ROOK_VERSION="$2"; shift 2 ;;
      --rook-version=*) ROOK_VERSION="${1#*=}"; shift ;;
      --rook-namespace) need_arg "$1" "${2:-}"; ROOK_NAMESPACE="$2"; shift 2 ;;
      --rook-namespace=*) ROOK_NAMESPACE="${1#*=}"; shift ;;
      --rook-release) need_arg "$1" "${2:-}"; ROOK_RELEASE="$2"; shift 2 ;;
      --rook-release=*) ROOK_RELEASE="${1#*=}"; shift ;;
      --rook-ready-timeout) need_arg "$1" "${2:-}"; ROOK_READY_TIMEOUT_SECONDS="$2"; shift 2 ;;
      --rook-ready-timeout=*) ROOK_READY_TIMEOUT_SECONDS="${1#*=}"; shift ;;
      --node-ready-timeout) need_arg "$1" "${2:-}"; NODE_READY_TIMEOUT_SECONDS="$2"; shift 2 ;;
      --node-ready-timeout=*) NODE_READY_TIMEOUT_SECONDS="${1#*=}"; shift ;;
      --check-only) CHECK_ONLY="true"; shift ;;
      --keep-generated-files) KEEP_GENERATED_FILES="true"; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

validate_integer() {
  [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be a non-negative integer: $2"
}

validate_dns_label() {
  [[ "$2" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "$1 must be a DNS label: $2"
}


finalize_defaults() {
  if [[ -z "$KUBECONFIG_PATH" ]]; then
    KUBECONFIG_PATH="${KUBECONFIG:-}"
  fi
}

validate_inputs() {
  log "Validating script inputs"
  validate_dns_label "--rook-namespace" "$ROOK_NAMESPACE"
  validate_dns_label "--rook-release" "$ROOK_RELEASE"
  validate_dns_label "candidate catalog" "$CATALOG_NAME"
  validate_integer "--control-plane-nodes" "$CONTROL_PLANE_NODES"
  validate_integer "--worker-nodes" "$WORKER_NODES"
  validate_integer "--node-ready-timeout" "$NODE_READY_TIMEOUT_SECONDS"
  validate_integer "--rook-ready-timeout" "$ROOK_READY_TIMEOUT_SECONDS"
  (( CONTROL_PLANE_NODES >= 1 )) || die "--control-plane-nodes must be at least 1"
  (( WORKER_NODES >= 3 )) || die "--worker-nodes must be at least 3 for Rook-Ceph"
  (( NODE_READY_TIMEOUT_SECONDS > 0 )) || die "--node-ready-timeout must be greater than zero"
  (( ROOK_READY_TIMEOUT_SECONDS > 0 )) || die "--rook-ready-timeout must be greater than zero"
  [[ "$ROOK_VERSION" != *$'\n'* ]] || die "--rook-version must be one line"
}

check_executable() {
  if [[ "$2" == */* ]]; then
    [[ -x "$2" ]] || die "$1 is not executable: $2"
  else
    command -v -- "$2" >/dev/null 2>&1 || die "$1 was not found in PATH: $2"
  fi
}

check_required_tools() {
  log "Checking required local tools"
  check_executable "OCNE CLI" "$OCNE_BIN"
  if [[ "$CHECK_ONLY" != "true" ]]; then
    check_executable "kubectl" "$KUBECTL_BIN"
  fi
  check_executable "mktemp" "mktemp"
  check_executable "awk" "awk"
}

create_workspace() {
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCRIPT_NAME%.sh}.XXXXXX")"
  ROOK_VALUES_CONFIG="${TMP_DIR}/rook-values.yaml"
  log "Generated files directory: ${TMP_DIR}"
}

cleanup() {
  if [[ "$KEEP_GENERATED_FILES" == "true" && -n "$TMP_DIR" ]]; then
    log "Keeping generated files in ${TMP_DIR}"
  elif [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    log "Removing generated files from ${TMP_DIR}"
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT


write_rook_values_config() {
  log "Writing the Rook-Ceph deployment values from the simple Rook configuration"
  cat >"$ROOK_VALUES_CONFIG" <<'EOF_ROOK_VALUES'
# Required for Ceph pods that mount the host data directory and /dev/sda4.
hostpathRequiresPrivileged: true
EOF_ROOK_VALUES
  log "Rook values config path: ${ROOK_VALUES_CONFIG}"
}

run_ocne() {
  log_command "KUBECONFIG=${KUBECONFIG_PATH}" "$OCNE_BIN" "$@"
  KUBECONFIG="$KUBECONFIG_PATH" "$OCNE_BIN" "$@"
}


wait_for_nodes() {
  local expected_nodes=$((CONTROL_PLANE_NODES + WORKER_NODES))
  local deadline=$((SECONDS + NODE_READY_TIMEOUT_SECONDS))
  log "Waiting for ${expected_nodes} Ready Kubernetes nodes"
  while (( SECONDS < deadline )); do
    local ready_nodes
    ready_nodes="$("$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" { count++ } END { print count + 0 }')"
    if [[ "$ready_nodes" == "$expected_nodes" ]]; then
      log "All ${ready_nodes} Kubernetes nodes are Ready"
      return
    fi
    log "Detected ${ready_nodes}/${expected_nodes} Ready nodes; waiting"
    sleep 10
  done
  die "timed out waiting for ${expected_nodes} Ready Kubernetes nodes"
}

release_installed() {
  KUBECONFIG="$KUBECONFIG_PATH" "$OCNE_BIN" application show --namespace "$ROOK_NAMESPACE" --release "$ROOK_RELEASE" >/dev/null 2>&1
}

verify_rook_chart() {
  log "Checking catalog ${CATALOG_NAME} for ${ROOK_CHART_NAME}"
  local catalog_output
  catalog_output="$(KUBECONFIG="$KUBECONFIG_PATH" "$OCNE_BIN" catalog search --name "$CATALOG_NAME" --pattern "^${ROOK_CHART_NAME}$")"
  printf '%s\n' "$catalog_output" >&2
  awk -v chart="$ROOK_CHART_NAME" '$1 == chart { found = 1 } END { exit !found }' <<<"$catalog_output" || \
    die "catalog ${CATALOG_NAME} does not contain ${ROOK_CHART_NAME}"
}

install_rook() {
  local version_arg=()
  [[ -z "$ROOK_VERSION" ]] || version_arg=(--version "$ROOK_VERSION")
  if release_installed; then
    log "Updating existing Rook-Ceph release ${ROOK_NAMESPACE}/${ROOK_RELEASE}"
    run_ocne application update --catalog "$CATALOG_NAME" --release "$ROOK_RELEASE" --namespace "$ROOK_NAMESPACE" --reset-values --values "$ROOK_VALUES_CONFIG" "${version_arg[@]}"
    return
  fi
  log "Installing Rook from OCNE catalog ${CATALOG_NAME}"
  run_ocne application install --catalog "$CATALOG_NAME" --name "$ROOK_CHART_NAME" --release "$ROOK_RELEASE" --namespace "$ROOK_NAMESPACE" --values "$ROOK_VALUES_CONFIG" "${version_arg[@]}"
}

wait_for_rook_crd_api() {
  local deadline=$((SECONDS + ROOK_READY_TIMEOUT_SECONDS))

  log "Waiting for the Rook-Ceph CRD API endpoint"
  while (( SECONDS < deadline )); do
    # Do not use `kubectl wait --for=condition=Established` here. Immediately
    # after CRD creation, Kubernetes can omit status.conditions, which makes
    # kubectl wait fail rather than wait. A successful API discovery request
    # proves that ceph.rook.io/v1 is served and the CRDs are usable.
    if "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" get --raw /apis/ceph.rook.io/v1 >/dev/null 2>&1; then
      log "Rook-Ceph CRD API endpoint is available"
      return
    fi
    log "Rook-Ceph CRD API endpoint is not available yet; waiting"
    sleep 10
  done

  die "timed out waiting for the Rook-Ceph CRD API endpoint"
}

wait_for_rook() {
  log "Waiting for the Rook-Ceph operator"
  wait_for_rook_crd_api
  run "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$ROOK_NAMESPACE" rollout status deployment/rook-ceph-operator --timeout "${ROOK_READY_TIMEOUT_SECONDS}s"
}

main() {
  parse_args "$@"
  [[ -n "$CATALOG_NAME" ]] || die "Run tests/run-changed.sh to build and register this checkout catalog"
  log "Using an externally provisioned cluster; cluster lifecycle belongs to the caller"
  [[ -n "$KUBECONFIG_PATH" && -s "$KUBECONFIG_PATH" ]] || die "Supply an existing kubeconfig with --kubeconfig or KUBECONFIG"
  finalize_defaults
  validate_inputs
  check_required_tools
  create_workspace
  write_rook_values_config
  if [[ "$CHECK_ONLY" == "true" ]]; then
    log "Validation complete; Rook installation was skipped"
    return
  fi
  wait_for_nodes
  verify_rook_chart
  install_rook
  wait_for_rook
  log "Rook-Ceph installation completed successfully"
}

main "$@"
