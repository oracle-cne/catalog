#!/usr/bin/env bash
# Copyright (c) 2026, Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at
# https://oss.oracle.com/licenses/upl.

# Verifies that the Prometheus chart deployed by test.sh
# discovers a pod annotation, reads the workload's /metrics endpoint, and
# exposes the workload metric through the Prometheus query API.
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

KUBECONFIG_PATH=""
PROMETHEUS_NAMESPACE="prometheus"
PROMETHEUS_SERVICE="prometheus-server"
PROMETHEUS_SERVICE_PORT="80"
TEST_NAMESPACE="prometheus-metrics-test"
TEST_WORKLOAD="metrics-workload"
TEST_IMAGE="${PROMETHEUS_TEST_IMAGE:-olcne/prometheus:v3.13.1}"
METRIC_NAME="prometheus_build_info"
LOCAL_PORT="19090"
QUERY_TIMEOUT_SECONDS="180"
PORT_FORWARD_TIMEOUT_SECONDS="45"
KEEP_TEST_ARTIFACTS="false"
CHECK_ONLY="false"

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
CURL_BIN="${CURL_BIN:-curl}"
TMP_DIR=""
PORT_FORWARD_PID=""
PORT_FORWARD_LOG=""
WORKLOAD_APPLIED="false"

usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_NAME} [options]

Deploys an annotated Prometheus workload, then verifies that Prometheus reads
the workload's prometheus_build_info metric and returns it from /api/v1/query.
Prometheus must already be installed by test.sh or
an equivalent deployment.

Options:
  --kubeconfig PATH               Kubeconfig path. Default: current kubectl context.
  --prometheus-namespace NAME     Prometheus namespace. Default: ${PROMETHEUS_NAMESPACE}
  --prometheus-service NAME       Prometheus Service name. Default: ${PROMETHEUS_SERVICE}
  --prometheus-service-port PORT  Prometheus Service port. Default: ${PROMETHEUS_SERVICE_PORT}
  --test-namespace NAME           Temporary workload namespace. Default: ${TEST_NAMESPACE}
  --test-workload NAME            Deployment and ConfigMap name. Default: ${TEST_WORKLOAD}
  --test-image IMAGE              Prometheus-compatible workload image. Default: ${TEST_IMAGE}
  --local-port PORT               Local port used for the temporary API tunnel. Default: ${LOCAL_PORT}
  --query-timeout SECONDS         Maximum time waiting for the scraped series. Default: ${QUERY_TIMEOUT_SECONDS}
  --port-forward-timeout SECONDS  Timeout for the temporary API tunnel. Default: ${PORT_FORWARD_TIMEOUT_SECONDS}
  --keep-test-artifacts           Preserve the test namespace after success.
  --check-only                    Validate local inputs only; make no cluster changes.
  --help                          Show this help.

Environment:
  KUBECTL_BIN                     kubectl path. Default: kubectl.
  CURL_BIN                        curl path. Default: curl.
  PROMETHEUS_TEST_IMAGE           Default workload image.

Examples:
  ${SCRIPT_NAME} --kubeconfig ~/.kube/kubeconfig.ocne-prometheus.local
  ${SCRIPT_NAME} --keep-test-artifacts
  ${SCRIPT_NAME} --test-image registry.example.test/busybox:tag
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

need_arg() {
  [[ -n "${2:-}" ]] || die "$1 requires a value"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kubeconfig) need_arg "$1" "${2:-}"; KUBECONFIG_PATH="$2"; shift 2 ;;
      --kubeconfig=*) KUBECONFIG_PATH="${1#*=}"; shift ;;
      --prometheus-namespace) need_arg "$1" "${2:-}"; PROMETHEUS_NAMESPACE="$2"; shift 2 ;;
      --prometheus-namespace=*) PROMETHEUS_NAMESPACE="${1#*=}"; shift ;;
      --prometheus-service) need_arg "$1" "${2:-}"; PROMETHEUS_SERVICE="$2"; shift 2 ;;
      --prometheus-service=*) PROMETHEUS_SERVICE="${1#*=}"; shift ;;
      --prometheus-service-port) need_arg "$1" "${2:-}"; PROMETHEUS_SERVICE_PORT="$2"; shift 2 ;;
      --prometheus-service-port=*) PROMETHEUS_SERVICE_PORT="${1#*=}"; shift ;;
      --test-namespace) need_arg "$1" "${2:-}"; TEST_NAMESPACE="$2"; shift 2 ;;
      --test-namespace=*) TEST_NAMESPACE="${1#*=}"; shift ;;
      --test-workload) need_arg "$1" "${2:-}"; TEST_WORKLOAD="$2"; shift 2 ;;
      --test-workload=*) TEST_WORKLOAD="${1#*=}"; shift ;;
      --test-image) need_arg "$1" "${2:-}"; TEST_IMAGE="$2"; shift 2 ;;
      --test-image=*) TEST_IMAGE="${1#*=}"; shift ;;
      --local-port) need_arg "$1" "${2:-}"; LOCAL_PORT="$2"; shift 2 ;;
      --local-port=*) LOCAL_PORT="${1#*=}"; shift ;;
      --query-timeout) need_arg "$1" "${2:-}"; QUERY_TIMEOUT_SECONDS="$2"; shift 2 ;;
      --query-timeout=*) QUERY_TIMEOUT_SECONDS="${1#*=}"; shift ;;
      --port-forward-timeout) need_arg "$1" "${2:-}"; PORT_FORWARD_TIMEOUT_SECONDS="$2"; shift 2 ;;
      --port-forward-timeout=*) PORT_FORWARD_TIMEOUT_SECONDS="${1#*=}"; shift ;;
      --keep-test-artifacts) KEEP_TEST_ARTIFACTS="true"; shift ;;
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

validate_inputs() {
  log "Validating script inputs"
  validate_dns_label "--prometheus-namespace" "$PROMETHEUS_NAMESPACE"
  validate_dns_label "--prometheus-service" "$PROMETHEUS_SERVICE"
  validate_positive_integer "--prometheus-service-port" "$PROMETHEUS_SERVICE_PORT"
  (( PROMETHEUS_SERVICE_PORT <= 65535 )) || die "--prometheus-service-port must not exceed 65535: $PROMETHEUS_SERVICE_PORT"
  validate_dns_label "--test-namespace" "$TEST_NAMESPACE"
  validate_dns_label "--test-workload" "$TEST_WORKLOAD"
  validate_positive_integer "--local-port" "$LOCAL_PORT"
  (( LOCAL_PORT <= 65535 )) || die "--local-port must not exceed 65535: $LOCAL_PORT"
  validate_positive_integer "--query-timeout" "$QUERY_TIMEOUT_SECONDS"
  validate_positive_integer "--port-forward-timeout" "$PORT_FORWARD_TIMEOUT_SECONDS"
  [[ -n "$TEST_IMAGE" && "$TEST_IMAGE" != *$'\n'* ]] || die "--test-image must be a non-empty single-line value"
  [[ -z "$KUBECONFIG_PATH" || -f "$KUBECONFIG_PATH" ]] || die "--kubeconfig does not exist: $KUBECONFIG_PATH"
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
  check_executable "kubectl" "$KUBECTL_BIN"
  [[ "$CHECK_ONLY" == "true" ]] || check_executable "curl" "$CURL_BIN"
}

cleanup() {
  local exit_code="$?"
  if [[ -n "$PORT_FORWARD_PID" ]]; then
    log "Stopping temporary Prometheus port-forward process ${PORT_FORWARD_PID}"
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    log "Removing temporary local files from ${TMP_DIR}"
    rm -rf "$TMP_DIR"
  fi
  if [[ "$WORKLOAD_APPLIED" != "true" ]]; then
    return
  elif [[ "$KEEP_TEST_ARTIFACTS" == "true" ]]; then
    log "Keeping test namespace ${TEST_NAMESPACE} as requested"
  elif (( exit_code == 0 )); then
    log "Removing successful test workload namespace ${TEST_NAMESPACE}"
    run_kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found=true --wait=false || true
  else
    log "Preserving failed test workload namespace ${TEST_NAMESPACE} for diagnosis"
  fi
}

trap cleanup EXIT

verify_prometheus_service() {
  log "Verifying Prometheus Service ${PROMETHEUS_NAMESPACE}/${PROMETHEUS_SERVICE}"
  run_kubectl -n "$PROMETHEUS_NAMESPACE" get "service/${PROMETHEUS_SERVICE}"
}

apply_test_workload() {
  log "Applying the annotated metrics workload in namespace ${TEST_NAMESPACE}"
  # Mark before applying: a partial apply can create the namespace and should
  # remain available for diagnosis if kubectl reports an error afterwards.
  WORKLOAD_APPLIED="true"
  run_kubectl apply -f - <<EOF_MANIFEST
apiVersion: v1
kind: Namespace
metadata:
  name: ${TEST_NAMESPACE}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${TEST_WORKLOAD}
  namespace: ${TEST_NAMESPACE}
data:
  prometheus.yml: |
    global:
      scrape_interval: 1h
    scrape_configs: []
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${TEST_WORKLOAD}
  namespace: ${TEST_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ${TEST_WORKLOAD}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${TEST_WORKLOAD}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/path: /metrics
        prometheus.io/port: "9090"
    spec:
      containers:
      - name: metrics-server
        image: ${TEST_IMAGE}
        securityContext:
          runAsUser: 65534
        args:
        - --config.file=/etc/prometheus/prometheus.yml
        - --storage.tsdb.path=/tmp/prometheus
        ports:
        - name: metrics
          containerPort: 9090
        volumeMounts:
        - name: metrics
          mountPath: /etc/prometheus
          readOnly: true
      volumes:
      - name: metrics
        configMap:
          name: ${TEST_WORKLOAD}
EOF_MANIFEST
  log "Waiting for the metrics workload rollout"
  run_kubectl -n "$TEST_NAMESPACE" rollout status "deployment/${TEST_WORKLOAD}" --timeout="${QUERY_TIMEOUT_SECONDS}s"
}

start_port_forward() {
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCRIPT_NAME%.sh}.XXXXXX")"
  PORT_FORWARD_LOG="${TMP_DIR}/prometheus-port-forward.log"
  local args=()
  mapfile -t args < <(kubectl_args)
  log "Starting temporary Prometheus API port-forward on 127.0.0.1:${LOCAL_PORT}"
  "$KUBECTL_BIN" "${args[@]}" -n "$PROMETHEUS_NAMESPACE" port-forward --address 127.0.0.1 \
    "service/${PROMETHEUS_SERVICE}" "${LOCAL_PORT}:${PROMETHEUS_SERVICE_PORT}" >"$PORT_FORWARD_LOG" 2>&1 &
  PORT_FORWARD_PID="$!"
  local deadline=$((SECONDS + PORT_FORWARD_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if grep -q 'Forwarding from' "$PORT_FORWARD_LOG"; then
      log "Prometheus API port-forward is ready"
      return
    fi
    if ! kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
      sed -n '1,120p' "$PORT_FORWARD_LOG" >&2 || true
      die "Prometheus API port-forward exited before becoming ready"
    fi
    sleep 1
  done
  sed -n '1,120p' "$PORT_FORWARD_LOG" >&2 || true
  die "timed out waiting for Prometheus API port-forward"
}

query_for_metric() {
  local query="${METRIC_NAME}{namespace=\"${TEST_NAMESPACE}\"}"
  local deadline=$((SECONDS + QUERY_TIMEOUT_SECONDS))
  log "Querying Prometheus for ${query}"
  while (( SECONDS < deadline )); do
    local response
    response="$("$CURL_BIN" -fsS --max-time 15 --get --data-urlencode "query=${query}" "http://127.0.0.1:${LOCAL_PORT}/api/v1/query" || true)"
    if grep -q '"status":"success"' <<<"$response" && grep -q "\"__name__\":\"${METRIC_NAME}\"" <<<"$response"; then
      log "Prometheus read and exposed ${METRIC_NAME} from ${TEST_NAMESPACE}/${TEST_WORKLOAD}"
      printf '%s\n' "$response"
      return
    fi
    log "Metric has not been returned yet; waiting for the next Prometheus scrape"
    sleep 5
  done
  log "Prometheus did not return ${METRIC_NAME}; test workload state follows"
  run_kubectl -n "$TEST_NAMESPACE" get pods -o wide || true
  run_kubectl -n "$TEST_NAMESPACE" describe "deployment/${TEST_WORKLOAD}" || true
  die "timed out waiting for Prometheus to expose ${METRIC_NAME}"
}

main() {
  parse_args "$@"
  validate_inputs
  check_prerequisites
  if [[ "$CHECK_ONLY" == "true" ]]; then
    log "Validation complete; no workload was deployed and no query was run"
    return
  fi
  verify_prometheus_service
  apply_test_workload
  start_port_forward
  query_for_metric
  log "Prometheus workload metrics test completed successfully"
}

main "$@"
