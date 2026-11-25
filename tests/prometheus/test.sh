#!/usr/bin/env bash
# Copyright (c) 2026, Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at
# https://oss.oracle.com/licenses/upl.

# Installs and validates Prometheus in the cluster supplied by the resource wrapper.
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLUSTER_NAME="ocne-prometheus"
CONTROL_PLANE_NODES="1"
WORKER_NODES="1"
KUBECONFIG_PATH="${KUBECONFIG:-}"

CATALOG_NAME="${CATALOG_TEST_NAME:-}"
PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-}"
PROMETHEUS_NAMESPACE="prometheus"
PROMETHEUS_RELEASE="prometheus"
PROMETHEUS_CHART_NAME="prometheus"

NODE_READY_TIMEOUT_SECONDS="1200"
PROMETHEUS_READY_TIMEOUT_SECONDS="600"
CHECK_ONLY="false"
TMP_DIR=""
PROMETHEUS_VALUES_FILE=""

OCNE_BIN="${OCNE_BIN:-ocne}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} --kubeconfig PATH [options]

Install and validate Prometheus in the cluster supplied by the resource wrapper.
Run tests/runner/run-tests.sh prometheus for provisioning and cleanup.
KUBECONFIG may supply the existing kubeconfig instead of --kubeconfig.
OCNE_BIN and KUBECTL_BIN select CLI executables (defaults: ocne, kubectl).

  --kubeconfig PATH               Existing kubeconfig. Default: KUBECONFIG environment.
  --prometheus-version VERSION    Prometheus chart version. Default: catalog default.
  --prometheus-namespace NAME     Installation namespace. Default: ${PROMETHEUS_NAMESPACE}
  --prometheus-release NAME       OCNE application release. Default: ${PROMETHEUS_RELEASE}
  --node-ready-timeout SECONDS    Timeout for Kubernetes nodes. Default: ${NODE_READY_TIMEOUT_SECONDS}
  --prometheus-ready-timeout SECONDS
                                  Timeout for prometheus-server rollout. Default: ${PROMETHEUS_READY_TIMEOUT_SECONDS}
  --check-only                    Validate local inputs only; make no cluster changes.
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

run_ocne() {
  log_command "KUBECONFIG=${KUBECONFIG_PATH}" "$OCNE_BIN" "$@"
  KUBECONFIG="$KUBECONFIG_PATH" "$OCNE_BIN" "$@"
}

run_kubectl() {
  run "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" "$@"
}

need_arg() {
  [[ -n "${2:-}" ]] || die "$1 requires a value"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kubeconfig) need_arg "$1" "${2:-}"; KUBECONFIG_PATH="$2"; shift 2 ;;
      --kubeconfig=*) KUBECONFIG_PATH="${1#*=}"; shift ;;
      --prometheus-version) need_arg "$1" "${2:-}"; PROMETHEUS_VERSION="$2"; shift 2 ;;
      --prometheus-version=*) PROMETHEUS_VERSION="${1#*=}"; shift ;;
      --prometheus-namespace) need_arg "$1" "${2:-}"; PROMETHEUS_NAMESPACE="$2"; shift 2 ;;
      --prometheus-namespace=*) PROMETHEUS_NAMESPACE="${1#*=}"; shift ;;
      --prometheus-release) need_arg "$1" "${2:-}"; PROMETHEUS_RELEASE="$2"; shift 2 ;;
      --prometheus-release=*) PROMETHEUS_RELEASE="${1#*=}"; shift ;;
      --node-ready-timeout) need_arg "$1" "${2:-}"; NODE_READY_TIMEOUT_SECONDS="$2"; shift 2 ;;
      --node-ready-timeout=*) NODE_READY_TIMEOUT_SECONDS="${1#*=}"; shift ;;
      --prometheus-ready-timeout) need_arg "$1" "${2:-}"; PROMETHEUS_READY_TIMEOUT_SECONDS="$2"; shift 2 ;;
      --prometheus-ready-timeout=*) PROMETHEUS_READY_TIMEOUT_SECONDS="${1#*=}"; shift ;;
      --check-only) CHECK_ONLY="true"; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

validate_dns_label() {
  [[ "$2" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "$1 must be a DNS label: $2"
}

validate_positive_integer() {
  [[ "$2" =~ ^[0-9]+$ ]] && (( 10#$2 > 0 )) || die "$1 must be a positive integer: $2"
}

validate_one_line() {
  [[ -n "$2" && "$2" != *$'\n'* ]] || die "$1 must be a non-empty single-line value"
}

finalize_defaults() {
  if [[ -z "$KUBECONFIG_PATH" ]]; then
    KUBECONFIG_PATH="${KUBECONFIG:-}"
  fi
}

validate_inputs() {
  log "Validating script inputs"
  validate_dns_label "candidate catalog" "$CATALOG_NAME"
  validate_dns_label "--prometheus-namespace" "$PROMETHEUS_NAMESPACE"
  validate_dns_label "--prometheus-release" "$PROMETHEUS_RELEASE"
  validate_positive_integer "--control-plane-nodes" "$CONTROL_PLANE_NODES"
  validate_positive_integer "--worker-nodes" "$WORKER_NODES"
  validate_positive_integer "--node-ready-timeout" "$NODE_READY_TIMEOUT_SECONDS"
  validate_positive_integer "--prometheus-ready-timeout" "$PROMETHEUS_READY_TIMEOUT_SECONDS"
  [[ "$PROMETHEUS_VERSION" != *$'\n'* ]] || die "--prometheus-version must be a single-line value"
}

check_executable() {
  if [[ "$2" == */* ]]; then
    [[ -x "$2" ]] || die "$1 is not executable: $2"
  else
    command -v -- "$2" >/dev/null 2>&1 || die "$1 was not found in PATH: $2"
  fi
}

check_prerequisites() {
  log "Checking required local tools"
  check_executable "OCNE CLI" "$OCNE_BIN"
  [[ "$CHECK_ONLY" == "true" ]] || check_executable "kubectl" "$KUBECTL_BIN"
  check_executable "mktemp" "mktemp"
}

create_prometheus_values_file() {
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCRIPT_NAME%.sh}.XXXXXX")"
  PROMETHEUS_VALUES_FILE="${TMP_DIR}/prometheus-values.yaml"
  log "Writing test-cluster Prometheus values to ${PROMETHEUS_VALUES_FILE}"
  cat >"$PROMETHEUS_VALUES_FILE" <<'EOF_VALUES'
server:
  persistentVolume:
    enabled: false
configmapReload:
  prometheus:
    enabled: false
EOF_VALUES
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    log "Removing temporary files from ${TMP_DIR}"
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT


wait_for_nodes() {
  local expected_nodes=$((CONTROL_PLANE_NODES + WORKER_NODES))
  log "Waiting for ${expected_nodes} Kubernetes node(s) to report Ready"
  local deadline=$((SECONDS + NODE_READY_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    local ready_nodes
    ready_nodes="$("$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" { count++ } END { print count + 0 }')"
    if [[ "$ready_nodes" == "$expected_nodes" ]]; then
      log "All ${ready_nodes} Kubernetes node(s) are Ready"
      return
    fi
    log "Detected ${ready_nodes}/${expected_nodes} Ready node(s); waiting"
    sleep 10
  done
  die "timed out waiting for ${expected_nodes} Ready Kubernetes node(s)"
}

verify_catalog() {
  log "Checking catalog ${CATALOG_NAME} for ${PROMETHEUS_CHART_NAME}"
  local output
  output="$(KUBECONFIG="$KUBECONFIG_PATH" "$OCNE_BIN" catalog search --name "$CATALOG_NAME" --pattern "^${PROMETHEUS_CHART_NAME}$")"
  printf '%s\n' "$output" >&2
  if [[ -n "$PROMETHEUS_VERSION" ]]; then
    awk -v chart="$PROMETHEUS_CHART_NAME" -v version="$PROMETHEUS_VERSION" 'NR > 1 && $1 == chart && $2 == version { found = 1 } END { exit !found }' <<<"$output" || die "catalog ${CATALOG_NAME} does not contain ${PROMETHEUS_CHART_NAME} ${PROMETHEUS_VERSION}"
  else
    awk -v chart="$PROMETHEUS_CHART_NAME" '$1 == chart { found = 1 } END { exit !found }' <<<"$output" || die "catalog ${CATALOG_NAME} does not contain ${PROMETHEUS_CHART_NAME}"
  fi
}

release_installed() {
  KUBECONFIG="$KUBECONFIG_PATH" "$OCNE_BIN" application show --namespace "$PROMETHEUS_NAMESPACE" --release "$PROMETHEUS_RELEASE" >/dev/null 2>&1
}

install_prometheus() {
  local version_arg=()
  [[ -z "$PROMETHEUS_VERSION" ]] || version_arg=(--version "$PROMETHEUS_VERSION")
  if release_installed; then
    log "Updating existing Prometheus release ${PROMETHEUS_NAMESPACE}/${PROMETHEUS_RELEASE}"
    run_ocne application update --catalog "$CATALOG_NAME" --release "$PROMETHEUS_RELEASE" --namespace "$PROMETHEUS_NAMESPACE" --reset-values --values "$PROMETHEUS_VALUES_FILE" "${version_arg[@]}"
    return
  fi
  log "Installing Prometheus from OCNE catalog ${CATALOG_NAME}"
  run_ocne application install --catalog "$CATALOG_NAME" --name "$PROMETHEUS_CHART_NAME" --release "$PROMETHEUS_RELEASE" --namespace "$PROMETHEUS_NAMESPACE" --values "$PROMETHEUS_VALUES_FILE" "${version_arg[@]}"
}

wait_for_prometheus() {
  log "Waiting for the ${PROMETHEUS_NAMESPACE}/prometheus-server Deployment"
  run_kubectl -n "$PROMETHEUS_NAMESPACE" rollout status deployment/prometheus-server --timeout="${PROMETHEUS_READY_TIMEOUT_SECONDS}s"
  log "Prometheus deployment is available"
  run_kubectl -n "$PROMETHEUS_NAMESPACE" get pods -o wide
}

main() {
  parse_args "$@"
  [[ -n "$CATALOG_NAME" ]] || die "Run tests/run-changed.sh to build and register this checkout catalog"
  log 'Using the selected test cluster and this checkout catalog'
  [[ -n "$KUBECONFIG_PATH" && -s "$KUBECONFIG_PATH" ]] || die "Supply an existing kubeconfig with --kubeconfig or KUBECONFIG"
  finalize_defaults
  validate_inputs
  check_prerequisites
  create_prometheus_values_file
  if [[ "$CHECK_ONLY" == "true" ]]; then
    log "Validation complete; Prometheus installation was skipped"
    return
  fi
  wait_for_nodes
  verify_catalog
  install_prometheus
  wait_for_prometheus
  log "Prometheus catalog deployment completed successfully"
}

main "$@"
