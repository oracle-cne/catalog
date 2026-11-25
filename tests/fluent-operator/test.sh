#!/usr/bin/env bash
# Copyright (c) 2026, Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at
# https://oss.oracle.com/licenses/upl.

# Installs Fluent Operator into an externally provisioned OCNE cluster
# from an OCNE catalog. The readiness checks make this suitable as the
# deployment phase of an integration test.
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLUSTER_NAME="ocne-fluent-operator"
CONTROL_PLANE_NODES="1"
WORKER_NODES="3"
KUBECONFIG_PATH="${KUBECONFIG:-}"
CHECK_ONLY="false"

CATALOG_NAME="${CATALOG_TEST_NAME:-}"
FLUENT_OPERATOR_CHART_NAME="fluent-operator"
FLUENT_OPERATOR_VERSION="${FLUENT_OPERATOR_VERSION:-}"
FLUENT_OPERATOR_NAMESPACE="fluent"
FLUENT_OPERATOR_RELEASE="fluent-operator"
LOG_TEST_DEPLOYMENT="fluent-operator-log-test"
LOG_TEST_MARKER="OCNE_FLUENT_OPERATOR_LOG_TEST_MARKER"
ORACLE_REGISTRY_PREFIX="container-registry.oracle.com/"

NODE_READY_TIMEOUT_SECONDS="1200"
FLUENT_OPERATOR_READY_TIMEOUT_SECONDS="600"
LOG_TEST_READY_TIMEOUT_SECONDS="300"
TMP_DIR=""
FLUENT_OPERATOR_VALUES_FILE=""

OCNE_BIN="${OCNE_BIN:-ocne}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} --kubeconfig PATH [options]

Install and validate applications in an existing cluster.
The caller provisions cluster.yaml and owns cluster cleanup.
KUBECONFIG may supply the existing kubeconfig instead of --kubeconfig.
OCNE_BIN and KUBECTL_BIN select CLI executables (defaults: ocne, kubectl).

  --kubeconfig PATH               Existing kubeconfig. Default: KUBECONFIG environment.
  --fluent-operator-version VERSION
                                  Chart version. Default: catalog default.
  --fluent-operator-namespace NAME
                                  Installation namespace. Default: ${FLUENT_OPERATOR_NAMESPACE}
  --fluent-operator-release NAME  OCNE application release. Default: ${FLUENT_OPERATOR_RELEASE}
  --node-ready-timeout SECONDS    Timeout waiting for Kubernetes nodes. Default: ${NODE_READY_TIMEOUT_SECONDS}
  --fluent-operator-ready-timeout SECONDS
                                  Timeout waiting for the Fluent Operator Deployment. Default: ${FLUENT_OPERATOR_READY_TIMEOUT_SECONDS}
  --log-test-ready-timeout SECONDS
                                  Timeout waiting for the log-source test and host-log read. Default: ${LOG_TEST_READY_TIMEOUT_SECONDS}
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
      --fluent-operator-version) need_arg "$1" "${2:-}"; FLUENT_OPERATOR_VERSION="$2"; shift 2 ;;
      --fluent-operator-version=*) FLUENT_OPERATOR_VERSION="${1#*=}"; shift ;;
      --fluent-operator-namespace) need_arg "$1" "${2:-}"; FLUENT_OPERATOR_NAMESPACE="$2"; shift 2 ;;
      --fluent-operator-namespace=*) FLUENT_OPERATOR_NAMESPACE="${1#*=}"; shift ;;
      --fluent-operator-release) need_arg "$1" "${2:-}"; FLUENT_OPERATOR_RELEASE="$2"; shift 2 ;;
      --fluent-operator-release=*) FLUENT_OPERATOR_RELEASE="${1#*=}"; shift ;;
      --node-ready-timeout) need_arg "$1" "${2:-}"; NODE_READY_TIMEOUT_SECONDS="$2"; shift 2 ;;
      --node-ready-timeout=*) NODE_READY_TIMEOUT_SECONDS="${1#*=}"; shift ;;
      --fluent-operator-ready-timeout) need_arg "$1" "${2:-}"; FLUENT_OPERATOR_READY_TIMEOUT_SECONDS="$2"; shift 2 ;;
      --fluent-operator-ready-timeout=*) FLUENT_OPERATOR_READY_TIMEOUT_SECONDS="${1#*=}"; shift ;;
      --log-test-ready-timeout) need_arg "$1" "${2:-}"; LOG_TEST_READY_TIMEOUT_SECONDS="$2"; shift 2 ;;
      --log-test-ready-timeout=*) LOG_TEST_READY_TIMEOUT_SECONDS="${1#*=}"; shift ;;
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
  log "Validating inputs for a cluster with ${WORKER_NODES} worker nodes"
  validate_dns_label "candidate catalog" "$CATALOG_NAME"
  validate_dns_label "--fluent-operator-namespace" "$FLUENT_OPERATOR_NAMESPACE"
  validate_dns_label "--fluent-operator-release" "$FLUENT_OPERATOR_RELEASE"
  validate_positive_integer "--control-plane-nodes" "$CONTROL_PLANE_NODES"
  validate_positive_integer "--node-ready-timeout" "$NODE_READY_TIMEOUT_SECONDS"
  validate_positive_integer "--fluent-operator-ready-timeout" "$FLUENT_OPERATOR_READY_TIMEOUT_SECONDS"
  validate_positive_integer "--log-test-ready-timeout" "$LOG_TEST_READY_TIMEOUT_SECONDS"
  [[ "$FLUENT_OPERATOR_VERSION" != *$'\n'* ]] || die "--fluent-operator-version must be a single-line value"
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
  [[ "$CHECK_ONLY" == "true" ]] || check_executable "mktemp" "mktemp"
}

create_fluent_operator_values_file() {
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCRIPT_NAME%.sh}.XXXXXX")"
  FLUENT_OPERATOR_VALUES_FILE="${TMP_DIR}/fluent-operator-values.yaml"
  log "Writing Fluent Bit stdout verification sink values to ${FLUENT_OPERATOR_VALUES_FILE}"
  cat >"$FLUENT_OPERATOR_VALUES_FILE" <<'EOF_VALUES'
fluentbit:
  output:
    stdout:
      enable: true
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

  log "Waiting for ${expected_nodes} Kubernetes nodes to report Ready"
  local deadline=$((SECONDS + NODE_READY_TIMEOUT_SECONDS))
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

verify_catalog() {
  log "Checking catalog ${CATALOG_NAME} for ${FLUENT_OPERATOR_CHART_NAME}"
  local output
  output="$(KUBECONFIG="$KUBECONFIG_PATH" "$OCNE_BIN" catalog search --name "$CATALOG_NAME" --pattern "^${FLUENT_OPERATOR_CHART_NAME}$")"
  printf '%s\n' "$output" >&2
  if [[ -n "$FLUENT_OPERATOR_VERSION" ]]; then
    awk -v chart="$FLUENT_OPERATOR_CHART_NAME" -v version="$FLUENT_OPERATOR_VERSION" 'NR > 1 && $1 == chart && $2 == version { found = 1 } END { exit !found }' <<<"$output" || die "catalog ${CATALOG_NAME} does not contain ${FLUENT_OPERATOR_CHART_NAME} ${FLUENT_OPERATOR_VERSION}"
  else
    awk -v chart="$FLUENT_OPERATOR_CHART_NAME" '$1 == chart { found = 1 } END { exit !found }' <<<"$output" || die "catalog ${CATALOG_NAME} does not contain ${FLUENT_OPERATOR_CHART_NAME}"
  fi
}

release_installed() {
  KUBECONFIG="$KUBECONFIG_PATH" "$OCNE_BIN" application show --namespace "$FLUENT_OPERATOR_NAMESPACE" --release "$FLUENT_OPERATOR_RELEASE" >/dev/null 2>&1
}

install_fluent_operator() {
  local version_arg=()
  [[ -z "$FLUENT_OPERATOR_VERSION" ]] || version_arg=(--version "$FLUENT_OPERATOR_VERSION")
  if release_installed; then
    log "Updating existing Fluent Operator release ${FLUENT_OPERATOR_NAMESPACE}/${FLUENT_OPERATOR_RELEASE}"
    run_ocne application update --catalog "$CATALOG_NAME" --release "$FLUENT_OPERATOR_RELEASE" --namespace "$FLUENT_OPERATOR_NAMESPACE" --reset-values --values "$FLUENT_OPERATOR_VALUES_FILE" "${version_arg[@]}"
    return
  fi
  log "Installing Fluent Operator from OCNE catalog ${CATALOG_NAME}"
  run_ocne application install --catalog "$CATALOG_NAME" --name "$FLUENT_OPERATOR_CHART_NAME" --release "$FLUENT_OPERATOR_RELEASE" --namespace "$FLUENT_OPERATOR_NAMESPACE" --values "$FLUENT_OPERATOR_VALUES_FILE" "${version_arg[@]}"
}

wait_for_fluent_operator() {
  log "Waiting for the ${FLUENT_OPERATOR_NAMESPACE}/fluent-operator Deployment"
  run_kubectl -n "$FLUENT_OPERATOR_NAMESPACE" rollout status deployment/fluent-operator --timeout="${FLUENT_OPERATOR_READY_TIMEOUT_SECONDS}s"
  log "Fluent Operator Deployment is available"
  run_kubectl -n "$FLUENT_OPERATOR_NAMESPACE" get deployment/fluent-operator
  log "Waiting for the Fluent Bit DaemonSet created by Fluent Operator"
  run_kubectl -n "$FLUENT_OPERATOR_NAMESPACE" rollout status daemonset/fluent-bit --timeout="${FLUENT_OPERATOR_READY_TIMEOUT_SECONDS}s"
  log "Fluent Bit DaemonSet is available"
  run_kubectl -n "$FLUENT_OPERATOR_NAMESPACE" get daemonset/fluent-bit
  run_kubectl -n "$FLUENT_OPERATOR_NAMESPACE" get pods -o wide
}

deploy_log_test() {
  local manifest_path="${SCRIPT_DIR}/fluent-operator-log-test.yaml"
  [[ -f "$manifest_path" ]] || die "log test manifest was not found: ${manifest_path}"
  log "Deploying log-source test ${FLUENT_OPERATOR_NAMESPACE}/${LOG_TEST_DEPLOYMENT}"
  run_kubectl -n "$FLUENT_OPERATOR_NAMESPACE" apply -f "$manifest_path"
  run_kubectl -n "$FLUENT_OPERATOR_NAMESPACE" rollout status "deployment/${LOG_TEST_DEPLOYMENT}" --timeout="${LOG_TEST_READY_TIMEOUT_SECONDS}s"
}

verify_log_test() {
  log "Verifying marker ${LOG_TEST_MARKER} through the test pod and Fluent Bit host-log mount"
  local deadline=$((SECONDS + LOG_TEST_READY_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    local application_logs
    log_command "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$FLUENT_OPERATOR_NAMESPACE" logs "deployment/${LOG_TEST_DEPLOYMENT}" --tail=100
    application_logs="$("$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$FLUENT_OPERATOR_NAMESPACE" logs "deployment/${LOG_TEST_DEPLOYMENT}" --tail=100 2>/dev/null || true)"
    if ! grep -Fqx "$LOG_TEST_MARKER" <<<"$application_logs"; then
      log "Log marker is not yet available through Kubernetes; waiting"
      sleep 5
      continue
    fi

    local test_node fluent_bit_pod host_log_match fluent_bit_logs
    test_node="$("$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$FLUENT_OPERATOR_NAMESPACE" get "deployment/${LOG_TEST_DEPLOYMENT}" -o jsonpath='{.spec.template.spec.nodeName}' 2>/dev/null || true)"
    if [[ -z "$test_node" ]]; then
      test_node="$("$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$FLUENT_OPERATOR_NAMESPACE" get pods -l "app.kubernetes.io/name=${LOG_TEST_DEPLOYMENT}" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
    fi
    [[ -n "$test_node" ]] || { log "Log-source test has not been scheduled; waiting"; sleep 5; continue; }
    fluent_bit_pod="$("$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$FLUENT_OPERATOR_NAMESPACE" get pods -l app.kubernetes.io/name=fluent-bit --field-selector "spec.nodeName=${test_node}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "$fluent_bit_pod" ]] || { log "No Fluent Bit pod is scheduled on ${test_node}; waiting"; sleep 5; continue; }

    log_command "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$FLUENT_OPERATOR_NAMESPACE" exec "$fluent_bit_pod" -- sh -c "grep -F -m 1 '${LOG_TEST_MARKER}' /var/log/containers/*_${FLUENT_OPERATOR_NAMESPACE}_log-writer-*.log"
    host_log_match="$("$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$FLUENT_OPERATOR_NAMESPACE" exec "$fluent_bit_pod" -- sh -c "grep -F -m 1 '${LOG_TEST_MARKER}' /var/log/containers/*_${FLUENT_OPERATOR_NAMESPACE}_log-writer-*.log" 2>/dev/null || true)"
    if grep -Fq "$LOG_TEST_MARKER" <<<"$host_log_match"; then
      log "Log marker was read from host-level /var/log/containers by Fluent Bit pod ${fluent_bit_pod}"
    else
      log "Fluent Bit host-log mount does not yet contain the marker; waiting"
      sleep 5
      continue
    fi

    log_command "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$FLUENT_OPERATOR_NAMESPACE" logs "$fluent_bit_pod" --tail=500
    fluent_bit_logs="$("$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$FLUENT_OPERATOR_NAMESPACE" logs "$fluent_bit_pod" --tail=500 2>/dev/null || true)"
    if grep -Fq "$LOG_TEST_MARKER" <<<"$fluent_bit_logs"; then
      log "Log marker was emitted by Fluent Bit stdout output from pod ${fluent_bit_pod}"
      return
    fi
    log "Fluent Bit stdout output does not yet contain the marker; waiting"
    sleep 5
  done
  die "timed out verifying ${LOG_TEST_MARKER} through the Fluent Bit host-log mount"
}

verify_oracle_container_images() {
  log "Verifying every pod, init-container, and ephemeral-container image uses ${ORACLE_REGISTRY_PREFIX}"
  local images non_oracle_images image_count
  log_command "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" get pods --all-namespaces -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\\n"}{end}{range .spec.containers[*]}{.image}{"\\n"}{end}{range .spec.ephemeralContainers[*]}{.image}{"\\n"}{end}{end}'
  images="$("$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" get pods --all-namespaces -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.ephemeralContainers[*]}{.image}{"\n"}{end}{end}')"
  non_oracle_images="$(awk -v prefix="$ORACLE_REGISTRY_PREFIX" 'NF && index($0, prefix) != 1 { print }' <<<"$images" | sort -u)"
  [[ -z "$non_oracle_images" ]] || die "found non-Oracle container image URL(s): ${non_oracle_images}"
  image_count="$(awk 'NF { seen[$0] = 1 } END { print length(seen) }' <<<"$images")"
  log "All ${image_count} distinct pod images use ${ORACLE_REGISTRY_PREFIX}"
}

main() {
  log "Starting ${SCRIPT_NAME}"
  parse_args "$@"
  [[ -n "$CATALOG_NAME" ]] || die "Run tests/run-changed.sh to build and register this checkout catalog"
  log "Using an externally provisioned cluster; cluster lifecycle belongs to the caller"
  [[ -n "$KUBECONFIG_PATH" && -s "$KUBECONFIG_PATH" ]] || die "Supply an existing kubeconfig with --kubeconfig or KUBECONFIG"
  finalize_defaults
  validate_inputs
  check_prerequisites
  if [[ "$CHECK_ONLY" == "true" ]]; then
    log "Validation complete; Fluent Operator installation was skipped"
    return
  fi
  create_fluent_operator_values_file
  wait_for_nodes
  verify_catalog
  install_fluent_operator
  wait_for_fluent_operator
  deploy_log_test
  verify_log_test
  verify_oracle_container_images
  log "Fluent Operator catalog deployment completed successfully"
}

main "$@"
