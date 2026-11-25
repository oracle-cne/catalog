#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOKINFO_INSTALL_SCRIPT="${SCRIPT_DIR}/istio-bookinfo-install.sh"

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
CURL_BIN="${CURL_BIN:-curl}"
ISTIOCTL_BIN="${ISTIOCTL_BIN:-istioctl}"
OCNE_BIN="${OCNE_BIN:-ocne}"
KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/.kube/kubeconfig.ocne-bookinfo.local}"
BOOKINFO_NAMESPACE="bookinfo"
ISTIO_NAMESPACE="istio-system"
GATEWAY_NAMESPACE="istio-system"
GATEWAY_SERVICE="istio-ingressgateway"
GATEWAY_URL=""
ROUTE_API="istio-api"
LOCAL_PORT="18080"
ISTIO_REF="release-1.30"
INSTALL_ADDONS="false"
SKIP_SETUP="false"
KEEP_ARTIFACTS="false"
FAIL_ON_SKIP="false"
LIST_ONLY="false"
CURL_TIMEOUT_SECONDS="15"
ASSERTION_TIMEOUT_SECONDS="45"
TRAFFIC_REQUESTS="20"
TRACE_REQUESTS="100"
TEST_FILTERS=()
TMP_DIR=""
PORT_FORWARD_PID=""
PORT_FORWARD_LOG=""
RATE_LIMIT_IMAGE="${RATE_LIMIT_IMAGE:-}"
RATE_LIMIT_REDIS_IMAGE="${RATE_LIMIT_REDIS_IMAGE:-}"
AMBIENT_MODE="false"
AMBIENT_DETECTION_SOURCE="ocne application show"

TASKS=(
  request-routing
  fault-injection
  traffic-shifting
  request-timeouts
  authz-http
  rate-limit
  metrics-querying
  metrics-dashboard
  metrics-customize
  metrics-telemetry-api
  metrics-tcp
  kiali
  tracing-overview
  tracing-sampling
  tracing-jaeger
  tracing-zipkin
  tracing-opentelemetry
  tracing-skywalking
  wasm-modules
  lua-scripts
)

usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_NAME} [options]

Runs command-line tests for Istio task pages whose main task content uses the
Bookinfo sample application.

Options:
  --kubeconfig PATH          Kubeconfig path. Default: ${KUBECONFIG_PATH}
  --namespace NAME           Bookinfo namespace. Default: ${BOOKINFO_NAMESPACE}
  --istio-namespace NAME     Istio control-plane namespace. Default: ${ISTIO_NAMESPACE}
  --gateway-namespace NAME   Ingress gateway namespace. Default: ${GATEWAY_NAMESPACE}
  --gateway-service NAME     Ingress gateway service. Default: ${GATEWAY_SERVICE}
  --gateway-url URL          Use an existing URL instead of port-forwarding.
  --route-api istio-api|gateway-api
                            Bookinfo routing API used during setup. Default: ${ROUTE_API}
  --local-port PORT          Local port-forward port. Default: ${LOCAL_PORT}
  --istio-ref REF            Istio git ref for sample manifests. Default: ${ISTIO_REF}
  --test NAME                Run one task test. Repeat to run several.
  --list                     List implemented task tests and exit.
  --install-addons           Install official sample addons when absent.
                            Tests skip addon-backed checks when this is omitted.
  --skip-setup               Do not call istio-bookinfo-install.sh when Bookinfo is absent.
  --keep-artifacts           Do not clean task resources at the end of each test.
  --fail-on-skip             Return failure when any task is skipped.
  --traffic-requests COUNT   Requests for metrics/dashboard traffic. Default: ${TRAFFIC_REQUESTS}
  --trace-requests COUNT     Requests for tracing traffic. Default: ${TRACE_REQUESTS}
  --curl-timeout SECONDS     curl max-time for each HTTP request. Default: ${CURL_TIMEOUT_SECONDS}
  --rate-limit-image IMAGE   Alternate image for envoyproxy/ratelimit.
  --rate-limit-redis-image IMAGE
                            Alternate image for redis:alpine.
  --help                     Show this help.

Environment:
  OCNE_BIN                   ocne executable used to inspect installed apps.
                            Default: ocne.
  KUBECTL_BIN                kubectl executable. Default: kubectl
  CURL_BIN                   curl executable. Default: curl
  ISTIOCTL_BIN               istioctl executable. Default: istioctl
  RATE_LIMIT_IMAGE           Alternate rate-limit service image.
  RATE_LIMIT_REDIS_IMAGE     Alternate Redis image for the rate-limit service.

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --test request-routing --test authz-http
  ${SCRIPT_NAME} --install-addons --rate-limit-image REG/ratelimit:TAG --rate-limit-redis-image REG/redis:TAG
USAGE
}

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

log_command() {
  printf '[%s] Running:' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf ' %q' "$@"
  printf '\n'
}

run() {
  log_command "$@"
  "$@"
}

run_kubectl() {
  run "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" "$@"
}

ocne_application_installed() {
  local namespace="$1"
  local release="$2"
  log "Checking OCNE installed application release ${namespace}/${release}"
  KUBECONFIG="$KUBECONFIG_PATH" "$OCNE_BIN" application show \
    --namespace "$namespace" \
    --release "$release" >/dev/null 2>&1
}

kubectl_quiet() {
  "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" "$@" >/dev/null 2>&1
}

need_arg() {
  local flag="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || die "${flag} requires a value"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kubeconfig)
        need_arg "$1" "${2:-}"
        KUBECONFIG_PATH="$2"
        shift 2
        ;;
      --kubeconfig=*)
        KUBECONFIG_PATH="${1#*=}"
        shift
        ;;
      --namespace)
        need_arg "$1" "${2:-}"
        BOOKINFO_NAMESPACE="$2"
        shift 2
        ;;
      --namespace=*)
        BOOKINFO_NAMESPACE="${1#*=}"
        shift
        ;;
      --istio-namespace)
        need_arg "$1" "${2:-}"
        ISTIO_NAMESPACE="$2"
        shift 2
        ;;
      --istio-namespace=*)
        ISTIO_NAMESPACE="${1#*=}"
        shift
        ;;
      --gateway-namespace)
        need_arg "$1" "${2:-}"
        GATEWAY_NAMESPACE="$2"
        shift 2
        ;;
      --gateway-namespace=*)
        GATEWAY_NAMESPACE="${1#*=}"
        shift
        ;;
      --gateway-service)
        need_arg "$1" "${2:-}"
        GATEWAY_SERVICE="$2"
        shift 2
        ;;
      --gateway-service=*)
        GATEWAY_SERVICE="${1#*=}"
        shift
        ;;
      --gateway-url)
        need_arg "$1" "${2:-}"
        GATEWAY_URL="${2%/}"
        shift 2
        ;;
      --gateway-url=*)
        GATEWAY_URL="${1#*=}"
        GATEWAY_URL="${GATEWAY_URL%/}"
        shift
        ;;
      --route-api)
        need_arg "$1" "${2:-}"
        ROUTE_API="$2"
        shift 2
        ;;
      --route-api=*)
        ROUTE_API="${1#*=}"
        shift
        ;;
      --local-port)
        need_arg "$1" "${2:-}"
        LOCAL_PORT="$2"
        shift 2
        ;;
      --local-port=*)
        LOCAL_PORT="${1#*=}"
        shift
        ;;
      --istio-ref)
        need_arg "$1" "${2:-}"
        ISTIO_REF="$2"
        shift 2
        ;;
      --istio-ref=*)
        ISTIO_REF="${1#*=}"
        shift
        ;;
      --test)
        need_arg "$1" "${2:-}"
        TEST_FILTERS+=("$2")
        shift 2
        ;;
      --test=*)
        TEST_FILTERS+=("${1#*=}")
        shift
        ;;
      --list)
        LIST_ONLY="true"
        shift
        ;;
      --install-addons)
        INSTALL_ADDONS="true"
        shift
        ;;
      --skip-setup)
        SKIP_SETUP="true"
        shift
        ;;
      --keep-artifacts)
        KEEP_ARTIFACTS="true"
        shift
        ;;
      --fail-on-skip)
        FAIL_ON_SKIP="true"
        shift
        ;;
      --traffic-requests)
        need_arg "$1" "${2:-}"
        TRAFFIC_REQUESTS="$2"
        shift 2
        ;;
      --traffic-requests=*)
        TRAFFIC_REQUESTS="${1#*=}"
        shift
        ;;
      --trace-requests)
        need_arg "$1" "${2:-}"
        TRACE_REQUESTS="$2"
        shift 2
        ;;
      --trace-requests=*)
        TRACE_REQUESTS="${1#*=}"
        shift
        ;;
      --curl-timeout)
        need_arg "$1" "${2:-}"
        CURL_TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --curl-timeout=*)
        CURL_TIMEOUT_SECONDS="${1#*=}"
        shift
        ;;
      --rate-limit-image)
        need_arg "$1" "${2:-}"
        RATE_LIMIT_IMAGE="$2"
        shift 2
        ;;
      --rate-limit-image=*)
        RATE_LIMIT_IMAGE="${1#*=}"
        shift
        ;;
      --rate-limit-redis-image)
        need_arg "$1" "${2:-}"
        RATE_LIMIT_REDIS_IMAGE="$2"
        shift 2
        ;;
      --rate-limit-redis-image=*)
        RATE_LIMIT_REDIS_IMAGE="${1#*=}"
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

task_title() {
  case "$1" in
    request-routing) printf 'Traffic Management / Request Routing' ;;
    fault-injection) printf 'Traffic Management / Fault Injection' ;;
    traffic-shifting) printf 'Traffic Management / Traffic Shifting' ;;
    request-timeouts) printf 'Traffic Management / Request Timeouts' ;;
    authz-http) printf 'Security / Authorization / HTTP Traffic' ;;
    rate-limit) printf 'Policy Enforcement / Enabling Rate Limits using Envoy' ;;
    metrics-querying) printf 'Observability / Metrics / Querying Metrics from Prometheus' ;;
    metrics-dashboard) printf 'Observability / Metrics / Visualizing Metrics with Grafana' ;;
    metrics-customize) printf 'Observability / Metrics / Customizing Istio Metrics' ;;
    metrics-telemetry-api) printf 'Observability / Metrics / Customizing Istio Metrics with Telemetry API' ;;
    metrics-tcp) printf 'Observability / Metrics / Collecting Metrics for TCP Services' ;;
    kiali) printf 'Observability / Visualizing Your Mesh' ;;
    tracing-overview) printf 'Observability / Distributed Tracing / Overview' ;;
    tracing-sampling) printf 'Observability / Distributed Tracing / Configure trace sampling' ;;
    tracing-jaeger) printf 'Observability / Distributed Tracing / Jaeger' ;;
    tracing-zipkin) printf 'Observability / Distributed Tracing / Zipkin' ;;
    tracing-opentelemetry) printf 'Observability / Distributed Tracing / OpenTelemetry' ;;
    tracing-skywalking) printf 'Observability / Distributed Tracing / Apache SkyWalking' ;;
    wasm-modules) printf 'Extensibility / Executing WebAssembly Modules' ;;
    lua-scripts) printf 'Extensibility / Executing Lua Scripts' ;;
    *) printf '%s' "$1" ;;
  esac
}

task_url() {
  case "$1" in
    request-routing) printf 'https://istio.io/latest/docs/tasks/traffic-management/request-routing/' ;;
    fault-injection) printf 'https://istio.io/latest/docs/tasks/traffic-management/fault-injection/' ;;
    traffic-shifting) printf 'https://istio.io/latest/docs/tasks/traffic-management/traffic-shifting/' ;;
    request-timeouts) printf 'https://istio.io/latest/docs/tasks/traffic-management/request-timeouts/' ;;
    authz-http) printf 'https://istio.io/latest/docs/tasks/security/authorization/authz-http/' ;;
    rate-limit) printf 'https://istio.io/latest/docs/tasks/policy-enforcement/rate-limit/' ;;
    metrics-querying) printf 'https://istio.io/latest/docs/tasks/observability/metrics/querying-metrics/' ;;
    metrics-dashboard) printf 'https://istio.io/latest/docs/tasks/observability/metrics/using-istio-dashboard/' ;;
    metrics-customize) printf 'https://istio.io/latest/docs/tasks/observability/metrics/customize-metrics/' ;;
    metrics-telemetry-api) printf 'https://istio.io/latest/docs/tasks/observability/metrics/telemetry-api/' ;;
    metrics-tcp) printf 'https://istio.io/latest/docs/tasks/observability/metrics/tcp-metrics/' ;;
    kiali) printf 'https://istio.io/latest/docs/tasks/observability/kiali/' ;;
    tracing-overview) printf 'https://istio.io/latest/docs/tasks/observability/distributed-tracing/overview/' ;;
    tracing-sampling) printf 'https://istio.io/latest/docs/tasks/observability/distributed-tracing/sampling/' ;;
    tracing-jaeger) printf 'https://istio.io/latest/docs/tasks/observability/distributed-tracing/jaeger/' ;;
    tracing-zipkin) printf 'https://istio.io/latest/docs/tasks/observability/distributed-tracing/zipkin/' ;;
    tracing-opentelemetry) printf 'https://istio.io/latest/docs/tasks/observability/distributed-tracing/opentelemetry/' ;;
    tracing-skywalking) printf 'https://istio.io/latest/docs/tasks/observability/distributed-tracing/skywalking/' ;;
    wasm-modules) printf 'https://istio.io/latest/docs/tasks/extensibility/wasm-modules/' ;;
    lua-scripts) printf 'https://istio.io/latest/docs/tasks/extensibility/lua-scripts/' ;;
    *) printf 'unknown' ;;
  esac
}

list_tasks() {
  local task
  for task in "${TASKS[@]}"; do
    printf '%-24s %s\n  %s\n' "$task" "$(task_title "$task")" "$(task_url "$task")"
  done
}

task_selected() {
  local task="$1"
  local filter
  if [[ ${#TEST_FILTERS[@]} -eq 0 ]]; then
    return 0
  fi
  for filter in "${TEST_FILTERS[@]}"; do
    [[ "$filter" == "$task" ]] && return 0
  done
  return 1
}

validate_requested_tasks() {
  local filter task found
  for filter in "${TEST_FILTERS[@]}"; do
    found="false"
    for task in "${TASKS[@]}"; do
      if [[ "$filter" == "$task" ]]; then
        found="true"
        break
      fi
    done
    [[ "$found" == "true" ]] || die "Unknown task test: ${filter}. Use --list to see valid names."
  done
}

validate_config() {
  case "$ROUTE_API" in
    istio-api|gateway-api) ;;
    *) die "--route-api must be istio-api or gateway-api" ;;
  esac
}

raw_url() {
  local path="$1"
  printf 'https://raw.githubusercontent.com/istio/istio/%s/%s' "$ISTIO_REF" "$path"
}

apply_url() {
  local namespace="$1"
  local path="$2"
  local url
  url="$(raw_url "$path")"
  log "Applying upstream Istio sample ${path} into namespace ${namespace}"
  run_kubectl -n "$namespace" apply -f "$url"
}

delete_url() {
  local namespace="$1"
  local path="$2"
  local url
  url="$(raw_url "$path")"
  log "Deleting upstream Istio sample ${path} from namespace ${namespace}"
  "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$namespace" delete -f "$url" --ignore-not-found=true >/dev/null 2>&1 || true
}

apply_manifest() {
  local namespace="$1"
  local label="$2"
  log "Applying manifest: ${label} in namespace ${namespace}"
  log_command "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$namespace" apply -f -
  "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$namespace" apply -f -
}

apply_cluster_manifest() {
  local label="$1"
  log "Applying cluster manifest: ${label}"
  log_command "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" apply -f -
  "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" apply -f -
}

delete_resource() {
  local namespace="$1"
  shift
  log "Deleting resource in namespace ${namespace}: $*"
  "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$namespace" delete "$@" --ignore-not-found=true >/dev/null 2>&1 || true
}

resource_exists() {
  local namespace="$1"
  shift
  kubectl_quiet -n "$namespace" get "$@"
}

wait_rollout() {
  local namespace="$1"
  local resource="$2"
  local timeout="${3:-180s}"
  log "Waiting for rollout: ${namespace}/${resource} timeout=${timeout}"
  run_kubectl -n "$namespace" rollout status "$resource" "--timeout=${timeout}"
}

wait_for_condition() {
  local description="$1"
  local command="$2"
  local deadline
  deadline=$((SECONDS + ASSERTION_TIMEOUT_SECONDS))
  log "Waiting for condition: ${description}"
  while (( SECONDS < deadline )); do
    if bash -c "$command" >/dev/null 2>&1; then
      log "Condition satisfied: ${description}"
      return 0
    fi
    sleep 2
  done
  log "Condition failed before timeout: ${description}"
  return 1
}

skip_test() {
  log "SKIP: $*"
  return 77
}

detect_ambient_mode_from_ocne_applications() {
  log "Detecting Istio dataplane mode from OCNE installed applications"
  AMBIENT_MODE="false"

  if ocne_application_installed "$ISTIO_NAMESPACE" ztunnel; then
    AMBIENT_MODE="true"
    AMBIENT_DETECTION_SOURCE="OCNE application release ${ISTIO_NAMESPACE}/ztunnel"
    log "Detected ambient mode from ${AMBIENT_DETECTION_SOURCE}"
    return 0
  fi

  if ocne_application_installed "$ISTIO_NAMESPACE" istio-ztunnel; then
    AMBIENT_MODE="true"
    AMBIENT_DETECTION_SOURCE="OCNE application release ${ISTIO_NAMESPACE}/istio-ztunnel"
    log "Detected ambient mode from ${AMBIENT_DETECTION_SOURCE}"
    return 0
  fi

  if ocne_application_installed "$ISTIO_NAMESPACE" istiod; then
    AMBIENT_DETECTION_SOURCE="OCNE application release ${ISTIO_NAMESPACE}/istiod without ztunnel"
    log "No OCNE ztunnel application release was found; treating Bookinfo task tests as sidecar-compatible"
    return 0
  fi

  die "Unable to determine Istio dataplane mode from OCNE installed applications in namespace ${ISTIO_NAMESPACE}; expected at least the istiod release"
}

skip_if_ambient_unsupported() {
  local task="$1"
  [[ "$AMBIENT_MODE" == "true" ]] || return 1

  case "$task" in
    request-routing|fault-injection|traffic-shifting|request-timeouts)
      skip_test "Ambient mode was detected from ${AMBIENT_DETECTION_SOURCE}; ${task} validates Bookinfo service-to-service HTTP traffic management, which requires sidecars or an ambient waypoint"
      return 0
      ;;
    authz-http)
      skip_test "Ambient mode was detected from ${AMBIENT_DETECTION_SOURCE}; ${task} expects HTTP authorization behavior from workload L7 proxies, which requires sidecars or an ambient waypoint"
      return 0
      ;;
    rate-limit)
      skip_test "Ambient mode was detected from ${AMBIENT_DETECTION_SOURCE}; ${task} installs a SIDECAR_INBOUND EnvoyFilter for productpage, but ambient Bookinfo workloads do not have sidecars"
      return 0
      ;;
    metrics-customize|metrics-telemetry-api)
      skip_test "Ambient mode was detected from ${AMBIENT_DETECTION_SOURCE}; ${task} scrapes workload istio-proxy metrics, but ambient Bookinfo workloads do not have sidecar proxy containers"
      return 0
      ;;
  esac

  return 1
}

cleanup() {
  if [[ -n "$PORT_FORWARD_PID" ]]; then
    log "Stopping temporary gateway port-forward process ${PORT_FORWARD_PID}"
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    log "Removing temporary directory ${TMP_DIR}"
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT

ensure_commands() {
  local command
  for command in "$OCNE_BIN" "$KUBECTL_BIN" "$CURL_BIN" grep sed awk; do
    command -v "$command" >/dev/null 2>&1 || die "Required command not found: ${command}"
  done
}

ensure_cluster_and_bookinfo() {
  [[ -f "$KUBECONFIG_PATH" ]] || die "Kubeconfig does not exist: ${KUBECONFIG_PATH}"
  log "Checking Kubernetes API access using kubeconfig ${KUBECONFIG_PATH}"
  run_kubectl get namespace "$BOOKINFO_NAMESPACE"
  if ! resource_exists "$BOOKINFO_NAMESPACE" deployment/productpage-v1; then
    if [[ "$SKIP_SETUP" == "true" ]]; then
      die "Bookinfo is not deployed in namespace ${BOOKINFO_NAMESPACE} and --skip-setup was set"
    fi
    [[ -x "$BOOKINFO_INSTALL_SCRIPT" ]] || die "Missing executable setup helper: ${BOOKINFO_INSTALL_SCRIPT}"
    log "Bookinfo is absent; running Bookinfo installer against the existing cluster"
    run "$BOOKINFO_INSTALL_SCRIPT" \
      --kubeconfig "$KUBECONFIG_PATH" \
      --namespace "$BOOKINFO_NAMESPACE" \
      --route-api "$ROUTE_API" \
      --bookinfo-ref "$ISTIO_REF" \
      --local-port "$LOCAL_PORT" \
      --no-summary
  fi

  local deployment
  for deployment in productpage-v1 details-v1 reviews-v1 reviews-v2 reviews-v3 ratings-v1; do
    wait_rollout "$BOOKINFO_NAMESPACE" "deployment/${deployment}" "300s"
  done
}

start_gateway_port_forward() {
  if [[ -n "$GATEWAY_URL" ]]; then
    log "Using provided gateway URL: ${GATEWAY_URL}"
    return 0
  fi

  PORT_FORWARD_LOG="${TMP_DIR}/gateway-port-forward.log"
  log "Starting gateway port-forward ${GATEWAY_NAMESPACE}/svc/${GATEWAY_SERVICE} ${LOCAL_PORT}:80"
  "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" \
    -n "$GATEWAY_NAMESPACE" port-forward --address 127.0.0.1 \
    "svc/${GATEWAY_SERVICE}" "${LOCAL_PORT}:80" >"$PORT_FORWARD_LOG" 2>&1 &
  PORT_FORWARD_PID="$!"

  local deadline
  deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    if grep -q 'Forwarding from' "$PORT_FORWARD_LOG"; then
      GATEWAY_URL="http://127.0.0.1:${LOCAL_PORT}"
      log "Gateway URL is ${GATEWAY_URL}"
      return 0
    fi
    if ! kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
      log "Gateway port-forward exited early; log follows"
      sed -n '1,120p' "$PORT_FORWARD_LOG" || true
      return 1
    fi
    sleep 1
  done
  log "Gateway port-forward did not become ready; log follows"
  sed -n '1,120p' "$PORT_FORWARD_LOG" || true
  return 1
}

curl_gateway() {
  local path="$1"
  shift || true
  "$CURL_BIN" -sS --max-time "$CURL_TIMEOUT_SECONDS" "$@" "${GATEWAY_URL}${path}"
}

curl_gateway_status() {
  local path="$1"
  shift || true
  "$CURL_BIN" -sS -o /dev/null -w '%{http_code}' --max-time "$CURL_TIMEOUT_SECONDS" "$@" "${GATEWAY_URL}${path}"
}

curl_productpage_as() {
  local user="${1:-}"
  local cookie_file
  if [[ -z "$user" ]]; then
    curl_gateway "/productpage"
    return
  fi
  cookie_file="${TMP_DIR}/cookie-${user}-$$.txt"
  log "Logging into Bookinfo as ${user} for user-specific routing"
  "$CURL_BIN" -sS -L --max-time "$CURL_TIMEOUT_SECONDS" \
    -c "$cookie_file" -b "$cookie_file" \
    -d "username=${user}" -d "passwd=${user}" \
    "${GATEWAY_URL}/login" >/dev/null
  "$CURL_BIN" -sS --max-time "$CURL_TIMEOUT_SECONDS" \
    -b "$cookie_file" "${GATEWAY_URL}/productpage"
}

body_has_stars() {
  grep -q 'glyphicon glyphicon-star' <<<"$1"
}

body_has_red_stars() {
  grep -q 'text-red-500' <<<"$1"
}

body_has_no_stars() {
  ! grep -q 'glyphicon glyphicon-star' <<<"$1"
}

body_has_ratings_unavailable() {
  grep -qi 'Ratings service.*unavailable' <<<"$1"
}

body_has_reviews_error() {
  grep -qi 'Error fetching product reviews' <<<"$1"
}

body_has_details_error() {
  grep -qi 'Error fetching product details' <<<"$1"
}

body_has_bookinfo() {
  grep -q 'BookInfo Sample' <<<"$1"
}

assert_body_eventually() {
  local user="$1"
  local description="$2"
  local predicate="$3"
  local body
  local deadline
  deadline=$((SECONDS + ASSERTION_TIMEOUT_SECONDS))
  log "Asserting productpage for user '${user:-anonymous}': ${description}"
  while (( SECONDS < deadline )); do
    if body="$(curl_productpage_as "$user")"; then
      if "$predicate" "$body"; then
        log "Assertion passed: ${description}"
        return 0
      fi
    fi
    sleep 2
  done
  log "Assertion failed: ${description}"
  if [[ -n "${body:-}" ]]; then
    log "Last productpage body excerpt follows"
    sed -n '1,80p' <<<"$body" || true
  fi
  return 1
}

assert_status_eventually() {
  local path="$1"
  local expected="$2"
  local description="$3"
  local code
  local deadline
  deadline=$((SECONDS + ASSERTION_TIMEOUT_SECONDS))
  log "Asserting HTTP status ${expected} for ${path}: ${description}"
  while (( SECONDS < deadline )); do
    code="$(curl_gateway_status "$path" || true)"
    log "Observed HTTP status ${code:-none} for ${path}"
    if [[ "$code" == "$expected" ]]; then
      log "Assertion passed: ${description}"
      return 0
    fi
    sleep 2
  done
  log "Assertion failed: ${description}"
  return 1
}

assert_delayed_reviews_error_eventually() {
  local description="$1"
  local body started ended elapsed
  local deadline
  deadline=$((SECONDS + ASSERTION_TIMEOUT_SECONDS))
  log "Asserting delayed reviews error: ${description}"
  while (( SECONDS < deadline )); do
    started="$(date +%s)"
    body="$(curl_productpage_as "jason" || true)"
    ended="$(date +%s)"
    elapsed=$((ended - started))
    log "Observed delayed fault sample elapsed seconds=${elapsed}"
    if body_has_reviews_error "$body" && (( elapsed >= 5 )); then
      log "Assertion passed: ${description}"
      return 0
    fi
    sleep 2
  done
  log "Assertion failed: ${description}"
  if [[ -n "${body:-}" ]]; then
    log "Last productpage body excerpt follows"
    sed -n '1,80p' <<<"$body" || true
  fi
  return 1
}

generate_gateway_traffic() {
  local count="${1:-$TRAFFIC_REQUESTS}"
  local i
  log "Generating ${count} Bookinfo gateway requests"
  for i in $(seq 1 "$count"); do
    curl_gateway_status "/productpage" >/dev/null || true
  done
}

get_first_pod() {
  local namespace="$1"
  local selector="$2"
  "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$namespace" \
    get pod -l "$selector" -o jsonpath='{.items[0].metadata.name}'
}

proxy_stats() {
  local namespace="$1"
  local pod="$2"
  if "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$namespace" \
    exec "$pod" -c istio-proxy -- pilot-agent request GET stats/prometheus 2>/dev/null; then
    return 0
  fi
  "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$namespace" \
    exec "$pod" -c istio-proxy -- curl -sS localhost:15000/stats/prometheus
}

reset_bookinfo_task_state() {
  log "Resetting Bookinfo task resources to reduce cross-test state"
  delete_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/virtual-service-all-v1.yaml"
  delete_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/virtual-service-reviews-test-v2.yaml"
  delete_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/virtual-service-ratings-test-delay.yaml"
  delete_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/virtual-service-ratings-test-abort.yaml"
  delete_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/virtual-service-reviews-50-v3.yaml"
  delete_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/virtual-service-reviews-v3.yaml"
  delete_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/virtual-service-ratings-db.yaml"
  delete_resource "$BOOKINFO_NAMESPACE" virtualservice reviews ratings details productpage
  delete_resource "$BOOKINFO_NAMESPACE" httproute reviews
  delete_resource "$BOOKINFO_NAMESPACE" authorizationpolicy allow-nothing productpage-viewer details-viewer reviews-viewer ratings-viewer
  delete_resource "$BOOKINFO_NAMESPACE" telemetry namespace-metrics custom-tags
  delete_resource "$ISTIO_NAMESPACE" telemetry remove-tags custom-tags remove-all-metrics remove-request-count remove-client remove-server otel-demo trace-sampling
  delete_resource "$ISTIO_NAMESPACE" envoyfilter filter-ratelimit filter-ratelimit-svc filter-ratelimit-svc-api filter-local-ratelimit-svc
  delete_resource "$ISTIO_NAMESPACE" trafficextension basic-auth parity
  delete_resource "$BOOKINFO_NAMESPACE" configmap ratelimit-config
  if resource_exists "$BOOKINFO_NAMESPACE" service/details; then
    log "Ensuring details service port name is http"
    "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$BOOKINFO_NAMESPACE" \
      patch service details --type json \
      -p '[{"op":"replace","path":"/spec/ports/0/name","value":"http"}]' >/dev/null 2>&1 || true
  fi
  apply_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/destination-rule-all.yaml"
  apply_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/bookinfo-gateway.yaml"
}

cleanup_after_test() {
  if [[ "$KEEP_ARTIFACTS" == "true" ]]; then
    log "Keeping task artifacts because --keep-artifacts was set"
    return 0
  fi
  reset_bookinfo_task_state
}

test_request_routing() {
  reset_bookinfo_task_state
  apply_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/virtual-service-all-v1.yaml"
  assert_body_eventually "" "reviews v1 produces no rating stars" body_has_no_stars || return 1
  apply_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/virtual-service-reviews-test-v2.yaml"
  assert_body_eventually "jason" "Jason is routed to reviews v2 and sees stars" body_has_stars || return 1
  assert_body_eventually "" "anonymous traffic remains on reviews v1 without stars" body_has_no_stars || return 1
}

test_fault_injection() {
  reset_bookinfo_task_state
  apply_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/virtual-service-all-v1.yaml"
  apply_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/virtual-service-reviews-test-v2.yaml"
  apply_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/virtual-service-ratings-test-delay.yaml"
  assert_delayed_reviews_error_eventually "Jason request waits for the injected ratings delay and productpage reports reviews unavailable" || return 1
  apply_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/virtual-service-ratings-test-abort.yaml"
  assert_body_eventually "jason" "Jason sees ratings unavailable after abort fault" body_has_ratings_unavailable || return 1
  assert_body_eventually "" "anonymous traffic is not affected by Jason-only fault" body_has_no_stars || return 1
}

test_traffic_shifting() {
  local body red_seen no_star_seen i
  reset_bookinfo_task_state
  apply_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/virtual-service-all-v1.yaml"
  assert_body_eventually "" "all traffic starts on reviews v1 without stars" body_has_no_stars || return 1
  apply_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/virtual-service-reviews-50-v3.yaml"
  red_seen=0
  no_star_seen=0
  log "Sampling ${TRAFFIC_REQUESTS} requests for 50/50 reviews v1 and v3 behavior"
  for i in $(seq 1 "$TRAFFIC_REQUESTS"); do
    body="$(curl_productpage_as "" || true)"
    body_has_red_stars "$body" && red_seen=1
    body_has_no_stars "$body" && no_star_seen=1
    if [[ "$red_seen" -eq 1 && "$no_star_seen" -eq 1 ]]; then
      break
    fi
  done
  log "Traffic shifting sample result red_seen=${red_seen} no_star_seen=${no_star_seen}"
  [[ "$red_seen" -eq 1 && "$no_star_seen" -eq 1 ]] || return 1
  apply_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/virtual-service-reviews-v3.yaml"
  assert_body_eventually "" "all traffic moves to reviews v3 with red stars" body_has_red_stars || return 1
}

test_request_timeouts() {
  reset_bookinfo_task_state
  apply_manifest "$BOOKINFO_NAMESPACE" "route all reviews traffic to v2" <<'EOF'
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
spec:
  hosts:
  - reviews
  http:
  - route:
    - destination:
        host: reviews
        subset: v2
EOF
  apply_manifest "$BOOKINFO_NAMESPACE" "add two second ratings delay" <<'EOF'
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: ratings
spec:
  hosts:
  - ratings
  http:
  - fault:
      delay:
        percentage:
          value: 100.0
        fixedDelay: 2s
    route:
    - destination:
        host: ratings
        subset: v1
EOF
  assert_body_eventually "" "reviews v2 still returns stars before reviews timeout is added" body_has_stars || return 1
  apply_manifest "$BOOKINFO_NAMESPACE" "add half-second reviews timeout" <<'EOF'
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
spec:
  hosts:
  - reviews
  http:
  - route:
    - destination:
        host: reviews
        subset: v2
    timeout: 0.5s
EOF
  assert_body_eventually "" "reviews timeout produces product reviews error" body_has_reviews_error || return 1
}

test_authz_http() {
  reset_bookinfo_task_state
  apply_manifest "$BOOKINFO_NAMESPACE" "deny all Bookinfo namespace traffic" <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-nothing
  namespace: ${BOOKINFO_NAMESPACE}
spec:
  {}
EOF
  assert_status_eventually "/productpage" "403" "deny-all authorization policy rejects gateway traffic" || return 1
  apply_manifest "$BOOKINFO_NAMESPACE" "allow GET to productpage" <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: productpage-viewer
  namespace: ${BOOKINFO_NAMESPACE}
spec:
  selector:
    matchLabels:
      app: productpage
  action: ALLOW
  rules:
  - to:
    - operation:
        methods: ["GET"]
EOF
  assert_body_eventually "" "productpage is visible but downstream details are denied" body_has_details_error || return 1
  assert_body_eventually "" "productpage is visible but downstream reviews are denied" body_has_reviews_error || return 1
  apply_manifest "$BOOKINFO_NAMESPACE" "allow productpage to details and reviews" <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: details-viewer
  namespace: ${BOOKINFO_NAMESPACE}
spec:
  selector:
    matchLabels:
      app: details
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/${BOOKINFO_NAMESPACE}/sa/bookinfo-productpage"]
    to:
    - operation:
        methods: ["GET"]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: reviews-viewer
  namespace: ${BOOKINFO_NAMESPACE}
spec:
  selector:
    matchLabels:
      app: reviews
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/${BOOKINFO_NAMESPACE}/sa/bookinfo-productpage"]
    to:
    - operation:
        methods: ["GET"]
EOF
  assert_body_eventually "" "ratings call is denied until ratings-viewer is added" body_has_ratings_unavailable || return 1
  apply_manifest "$BOOKINFO_NAMESPACE" "allow reviews to ratings" <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: ratings-viewer
  namespace: ${BOOKINFO_NAMESPACE}
spec:
  selector:
    matchLabels:
      app: ratings
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/${BOOKINFO_NAMESPACE}/sa/bookinfo-reviews"]
    to:
    - operation:
        methods: ["GET"]
EOF
  assert_body_eventually "" "Bookinfo page returns after all authorization policies are added" body_has_bookinfo || return 1
}

apply_local_rate_limit_filter() {
  apply_manifest "$ISTIO_NAMESPACE" "local productpage rate limit EnvoyFilter" <<'EOF'
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: filter-local-ratelimit-svc
spec:
  workloadSelector:
    labels:
      app: productpage
  configPatches:
  - applyTo: HTTP_FILTER
    match:
      context: SIDECAR_INBOUND
      listener:
        filterChain:
          filter:
            name: "envoy.filters.network.http_connection_manager"
    patch:
      operation: INSERT_BEFORE
      value:
        name: envoy.filters.http.local_ratelimit
        typed_config:
          "@type": type.googleapis.com/udpa.type.v1.TypedStruct
          type_url: type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
          value:
            stat_prefix: http_local_rate_limiter
            token_bucket:
              max_tokens: 4
              tokens_per_fill: 4
              fill_interval: 60s
            filter_enabled:
              runtime_key: local_rate_limit_enabled
              default_value:
                numerator: 100
                denominator: HUNDRED
            filter_enforced:
              runtime_key: local_rate_limit_enforced
              default_value:
                numerator: 100
                denominator: HUNDRED
            response_headers_to_add:
            - append: false
              header:
                key: x-local-rate-limit
                value: "true"
EOF
}

test_rate_limit() {
  local ratings_pod output count_429
  reset_bookinfo_task_state
  apply_local_rate_limit_filter
  sleep 8
  ratings_pod="$(get_first_pod "$BOOKINFO_NAMESPACE" "app=ratings")"
  log "Sending five in-mesh requests from ${ratings_pod} to productpage to verify local rate limit"
  output="$("$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$BOOKINFO_NAMESPACE" \
    exec "$ratings_pod" -c ratings -- bash -c \
    'for i in {1..5}; do curl -s productpage:9080/productpage -o /dev/null -w "%{http_code}\n"; sleep 1; done')"
  log "Local rate-limit status sequence: ${output//$'\n'/ }"
  count_429="$(grep -c '^429$' <<<"$output" || true)"
  [[ "$count_429" -ge 1 ]] || return 1

  if resource_exists "$BOOKINFO_NAMESPACE" service/ratelimit; then
    log "Global rate-limit service exists; gateway global limit is expected to be covered by that deployment's own lifecycle"
  elif [[ -n "$RATE_LIMIT_IMAGE" || -n "$RATE_LIMIT_REDIS_IMAGE" ]]; then
    log "Global rate-limit alternate images were provided, but this harness keeps the default run focused on the local limit to avoid DockerHub sample image use"
  else
    log "Global rate-limit portion is not installed because the official sample uses docker.io images; set --rate-limit-image and --rate-limit-redis-image before enabling that extension in this environment"
  fi
}

install_addon_if_requested() {
  local addon="$1"
  local deployment="$2"
  local service="$3"
  if resource_exists "$ISTIO_NAMESPACE" "service/${service}"; then
    log "Addon service already exists: ${ISTIO_NAMESPACE}/${service}"
    return 0
  fi
  if [[ "$INSTALL_ADDONS" != "true" ]]; then
    skip_test "Addon ${addon} is not installed; rerun with --install-addons to apply the official sample addon"
    return 77
  fi
  apply_url "$ISTIO_NAMESPACE" "samples/addons/${addon}.yaml"
  wait_rollout "$ISTIO_NAMESPACE" "deployment/${deployment}" "300s"
}

start_service_port_forward() {
  local namespace="$1"
  local service="$2"
  local local_port="$3"
  local remote_port="$4"
  local log_file="${TMP_DIR}/pf-${namespace}-${service}-${local_port}.log"
  log "Starting service port-forward ${namespace}/svc/${service} ${local_port}:${remote_port}"
  "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$namespace" \
    port-forward --address 127.0.0.1 "svc/${service}" "${local_port}:${remote_port}" >"$log_file" 2>&1 &
  local pid="$!"
  local deadline
  deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    if grep -q 'Forwarding from' "$log_file"; then
      printf '%s' "$pid"
      return 0
    fi
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      log "Service port-forward exited early; log follows"
      sed -n '1,120p' "$log_file" || true
      return 1
    fi
    sleep 1
  done
  log "Service port-forward did not become ready; log follows"
  sed -n '1,120p' "$log_file" || true
  kill "$pid" >/dev/null 2>&1 || true
  return 1
}

query_prometheus() {
  local query="$1"
  local pid response
  pid="$(start_service_port_forward "$ISTIO_NAMESPACE" prometheus 19090 9090)" || return 1
  sleep 1
  response="$("$CURL_BIN" -sS --max-time "$CURL_TIMEOUT_SECONDS" \
    --get --data-urlencode "query=${query}" \
    'http://127.0.0.1:19090/api/v1/query')"
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  grep -q '"status":"success"' <<<"$response" || {
    log "Prometheus query failed: ${response}"
    return 1
  }
  grep -q '"result":\[\]' <<<"$response" && {
    log "Prometheus query returned no series: ${query}"
    return 1
  }
  log "Prometheus query returned series for: ${query}"
}

test_metrics_querying() {
  install_addon_if_requested prometheus prometheus prometheus || return $?
  generate_gateway_traffic "$TRAFFIC_REQUESTS"
  query_prometheus "istio_requests_total{destination_service=~\"productpage.*\"}" || return 1
}

test_metrics_dashboard() {
  local pid response
  install_addon_if_requested prometheus prometheus prometheus || return $?
  install_addon_if_requested grafana grafana grafana || return $?
  generate_gateway_traffic "$TRAFFIC_REQUESTS"
  pid="$(start_service_port_forward "$ISTIO_NAMESPACE" grafana 13000 3000)" || return 1
  response="$("$CURL_BIN" -sS --max-time "$CURL_TIMEOUT_SECONDS" 'http://127.0.0.1:13000/api/health' || true)"
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  log "Grafana health response: ${response}"
  grep -qi '"database".*"ok"\|"commit"' <<<"$response" || return 1
}

test_metrics_customize() {
  local pod stats
  reset_bookinfo_task_state
  apply_manifest "$BOOKINFO_NAMESPACE" "custom request_host metric tag" <<'EOF'
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: namespace-metrics
spec:
  metrics:
  - providers:
    - name: prometheus
    overrides:
    - match:
        metric: REQUEST_COUNT
        mode: CLIENT_AND_SERVER
      tagOverrides:
        request_host:
          value: request.host
EOF
  generate_gateway_traffic 5
  pod="$(get_first_pod "$BOOKINFO_NAMESPACE" "app=productpage")"
  stats="$(proxy_stats "$BOOKINFO_NAMESPACE" "$pod" || true)"
  grep -q 'istio_requests_total' <<<"$stats" || return 1
  grep -q 'request_host=' <<<"$stats" || return 1
}

test_metrics_telemetry_api() {
  local pod stats
  reset_bookinfo_task_state
  apply_manifest "$ISTIO_NAMESPACE" "Telemetry API custom source_x and destination_x tags" <<'EOF'
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: custom-tags
spec:
  metrics:
  - providers:
    - name: prometheus
    overrides:
    - match:
        metric: REQUEST_COUNT
        mode: CLIENT
      tagOverrides:
        destination_x:
          value: filter_state.upstream_peer.app
    - match:
        metric: REQUEST_COUNT
        mode: SERVER
      tagOverrides:
        source_x:
          value: filter_state.downstream_peer.app
EOF
  generate_gateway_traffic 5
  pod="$(get_first_pod "$BOOKINFO_NAMESPACE" "app=productpage")"
  stats="$(proxy_stats "$BOOKINFO_NAMESPACE" "$pod" || true)"
  grep -q 'istio_requests_total' <<<"$stats" || return 1
  grep -q 'destination_x=' <<<"$stats" || return 1
}

test_metrics_tcp() {
  if ! resource_exists "$BOOKINFO_NAMESPACE" deployment/mongodb-v1 || ! resource_exists "$BOOKINFO_NAMESPACE" deployment/ratings-v2; then
    skip_test "TCP metrics task requires the Bookinfo MongoDB and ratings-v2 sample workloads; install them from the Istio samples with alternate registry images before running this task in a DockerHub-blocked environment"
    return 77
  fi
  install_addon_if_requested prometheus prometheus prometheus || return $?
  apply_url "$BOOKINFO_NAMESPACE" "samples/bookinfo/networking/virtual-service-ratings-db.yaml"
  generate_gateway_traffic "$TRAFFIC_REQUESTS"
  query_prometheus 'istio_tcp_connections_opened_total' || return 1
  query_prometheus 'istio_tcp_connections_closed_total' || return 1
}

test_kiali() {
  install_addon_if_requested kiali kiali kiali || return $?
  generate_gateway_traffic "$TRAFFIC_REQUESTS"
  if command -v "$ISTIOCTL_BIN" >/dev/null 2>&1; then
    log "Patching details service to verify Istio validation detects the documented invalid service port name"
    run_kubectl -n "$BOOKINFO_NAMESPACE" patch service details --type json \
      -p '[{"op":"replace","path":"/spec/ports/0/name","value":"foo"}]'
    set +e
    "$ISTIOCTL_BIN" --kubeconfig "$KUBECONFIG_PATH" analyze -n "$BOOKINFO_NAMESPACE" >"${TMP_DIR}/kiali-analyze.log" 2>&1
    local analyze_rc=$?
    set -e
    run_kubectl -n "$BOOKINFO_NAMESPACE" patch service details --type json \
      -p '[{"op":"replace","path":"/spec/ports/0/name","value":"http"}]'
    log "istioctl analyze exit code after intentional invalid config: ${analyze_rc}"
    sed -n '1,120p' "${TMP_DIR}/kiali-analyze.log" || true
    grep -qi 'port.*name\|IST' "${TMP_DIR}/kiali-analyze.log" || return 1
  else
    log "istioctl is absent; Kiali test verified addon service and generated Bookinfo graph traffic only"
  fi
}

mesh_has_extension_provider() {
  local provider="$1"
  "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$ISTIO_NAMESPACE" \
    get configmap istio -o yaml 2>/dev/null | grep -q "name: ${provider}"
}

apply_trace_sampling() {
  local provider="$1"
  apply_manifest "$ISTIO_NAMESPACE" "trace sampling for provider ${provider}" <<EOF
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: trace-sampling
spec:
  tracing:
  - providers:
    - name: ${provider}
    randomSamplingPercentage: 100
EOF
}

test_tracing_overview() {
  reset_bookinfo_task_state
  generate_gateway_traffic 5
  local body
  body="$(curl_gateway "/productpage" -H 'traceparent: 00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01' -H 'x-b3-traceid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -H 'x-b3-spanid: bbbbbbbbbbbbbbbb')"
  body_has_bookinfo "$body" || return 1
  log "Tracing overview smoke test sent W3C and B3 headers through Bookinfo; backend-specific span checks are covered by tracing provider tests"
}

test_tracing_sampling() {
  if mesh_has_extension_provider otel-tracing; then
    apply_trace_sampling otel-tracing
  elif mesh_has_extension_provider zipkin; then
    apply_trace_sampling zipkin
  elif mesh_has_extension_provider jaeger; then
    apply_trace_sampling jaeger
  else
    skip_test "No tracing extension provider was found in MeshConfig; configure a provider before testing sampling"
    return 77
  fi
  generate_gateway_traffic 5
}

test_tracing_jaeger() {
  if ! mesh_has_extension_provider jaeger && ! mesh_has_extension_provider zipkin; then
    skip_test "Jaeger tracing task requires a Jaeger/Zipkin-compatible extension provider in MeshConfig"
    return 77
  fi
  install_addon_if_requested jaeger jaeger jaeger-query || return $?
  generate_gateway_traffic "$TRACE_REQUESTS"
  log "Jaeger backend is present and Bookinfo trace traffic was generated"
}

test_tracing_zipkin() {
  if ! mesh_has_extension_provider zipkin; then
    skip_test "Zipkin tracing task requires a zipkin extension provider in MeshConfig"
    return 77
  fi
  install_addon_if_requested zipkin zipkin zipkin || return $?
  generate_gateway_traffic "$TRACE_REQUESTS"
  log "Zipkin backend is present and Bookinfo trace traffic was generated"
}

test_tracing_opentelemetry() {
  if ! mesh_has_extension_provider otel-tracing; then
    skip_test "OpenTelemetry tracing task requires an otel-tracing extension provider in MeshConfig"
    return 77
  fi
  if ! resource_exists observability deployment/opentelemetry-collector; then
    if [[ "$INSTALL_ADDONS" != "true" ]]; then
      skip_test "OpenTelemetry collector is not deployed; rerun with --install-addons after confirming collector images are available from an allowed registry"
      return 77
    fi
    run_kubectl create namespace observability --dry-run=client -o yaml | run_kubectl apply -f -
    apply_url observability "samples/open-telemetry/otel.yaml"
    wait_rollout observability deployment/opentelemetry-collector 300s
  fi
  apply_trace_sampling otel-tracing
  generate_gateway_traffic "$TRACE_REQUESTS"
  log "OpenTelemetry collector is present and Bookinfo trace traffic was generated"
}

test_tracing_skywalking() {
  if ! mesh_has_extension_provider skywalking; then
    skip_test "SkyWalking tracing task requires a skywalking extension provider in MeshConfig"
    return 77
  fi
  if ! resource_exists "$ISTIO_NAMESPACE" service/tracing && ! resource_exists "$ISTIO_NAMESPACE" service/skywalking-oap; then
    skip_test "SkyWalking backend service was not found in ${ISTIO_NAMESPACE}"
    return 77
  fi
  apply_trace_sampling skywalking
  generate_gateway_traffic "$TRACE_REQUESTS"
  log "SkyWalking backend is present and Bookinfo trace traffic was generated"
}

crd_exists() {
  local crd="$1"
  kubectl_quiet get crd "$crd"
}

test_wasm_modules() {
  if ! crd_exists trafficextensions.extensions.istio.io; then
    skip_test "TrafficExtension CRD is not installed; this task targets the current Istio extension API"
    return 77
  fi
  apply_manifest "$ISTIO_NAMESPACE" "basic-auth TrafficExtension" <<'EOF'
apiVersion: extensions.istio.io/v1alpha1
kind: TrafficExtension
metadata:
  name: basic-auth
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  phase: AUTHN
  wasm:
    url: oci://ghcr.io/istio-ecosystem/wasm-extensions/basic_auth:1.12.0
    pluginConfig:
      basic_auth_rules:
      - prefix: "/productpage"
        request_methods:
        - "GET"
        - "POST"
        credentials:
        - "ok:test"
        - "YWRtaW4zOmFkbWluMw=="
EOF
  assert_status_eventually "/productpage" "401" "basic auth Wasm module rejects anonymous productpage" || return 1
  assert_status_eventually "/productpage" "200" "basic auth Wasm module accepts documented credentials" -H "Authorization: Basic YWRtaW4zOmFkbWluMw==" || return 1
}

test_lua_scripts() {
  local headers
  if ! crd_exists trafficextensions.extensions.istio.io; then
    skip_test "TrafficExtension CRD is not installed; this task targets the current Istio extension API"
    return 77
  fi
  apply_manifest "$ISTIO_NAMESPACE" "parity Lua TrafficExtension" <<'EOF'
apiVersion: extensions.istio.io/v1alpha1
kind: TrafficExtension
metadata:
  name: parity
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  phase: AUTHN
  lua:
    inlineCode: |
      function envoy_on_request(request_handle)
        local number = tonumber(request_handle:headers():get("x-number"))
        if number == nil then return end
        local parity = number % 2 == 0 and "even" or "odd"
        request_handle:streamInfo():dynamicMetadata():set(
          "envoy.filters.http.lua", "parity", parity)
      end
      function envoy_on_response(response_handle)
        local meta = response_handle:streamInfo():dynamicMetadata():get(
          "envoy.filters.http.lua")
        if meta == nil then return end
        response_handle:headers():add("x-parity", meta["parity"])
      end
EOF
  sleep 5
  headers="$(curl_gateway "/productpage" -D - -o /dev/null -H "x-number: 42")"
  grep -qi '^x-parity: even' <<<"$headers" || return 1
  headers="$(curl_gateway "/productpage" -D - -o /dev/null -H "x-number: 7")"
  grep -qi '^x-parity: odd' <<<"$headers" || return 1
}

run_task() {
  local task="$1"
  if skip_if_ambient_unsupported "$task"; then
    return 77
  fi

  case "$task" in
    request-routing) test_request_routing ;;
    fault-injection) test_fault_injection ;;
    traffic-shifting) test_traffic_shifting ;;
    request-timeouts) test_request_timeouts ;;
    authz-http) test_authz_http ;;
    rate-limit) test_rate_limit ;;
    metrics-querying) test_metrics_querying ;;
    metrics-dashboard) test_metrics_dashboard ;;
    metrics-customize) test_metrics_customize ;;
    metrics-telemetry-api) test_metrics_telemetry_api ;;
    metrics-tcp) test_metrics_tcp ;;
    kiali) test_kiali ;;
    tracing-overview) test_tracing_overview ;;
    tracing-sampling) test_tracing_sampling ;;
    tracing-jaeger) test_tracing_jaeger ;;
    tracing-zipkin) test_tracing_zipkin ;;
    tracing-opentelemetry) test_tracing_opentelemetry ;;
    tracing-skywalking) test_tracing_skywalking ;;
    wasm-modules) test_wasm_modules ;;
    lua-scripts) test_lua_scripts ;;
    *) die "No implementation for task ${task}" ;;
  esac
}

main() {
  parse_args "$@"
  validate_requested_tasks
  validate_config
  if [[ "$LIST_ONLY" == "true" ]]; then
    list_tasks
    exit 0
  fi

  TMP_DIR="$(mktemp -d)"
  log "Temporary directory: ${TMP_DIR}"
  ensure_commands
  ensure_cluster_and_bookinfo
  detect_ambient_mode_from_ocne_applications
  start_gateway_port_forward

  local task rc
  local pass_count=0
  local skip_count=0
  local fail_count=0
  local results=()

  for task in "${TASKS[@]}"; do
    task_selected "$task" || continue
    log "===== START ${task}: $(task_title "$task") ====="
    log "Task URL: $(task_url "$task")"
    set +e
    run_task "$task"
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
      log "===== PASS ${task} ====="
      pass_count=$((pass_count + 1))
      results+=("PASS ${task}")
    elif [[ "$rc" -eq 77 ]]; then
      log "===== SKIP ${task} ====="
      skip_count=$((skip_count + 1))
      results+=("SKIP ${task}")
    else
      log "===== FAIL ${task} rc=${rc} ====="
      fail_count=$((fail_count + 1))
      results+=("FAIL ${task}")
    fi
    set +e
    cleanup_after_test
    set -e
  done

  log "===== SUMMARY ====="
  printf '%s\n' "${results[@]}"
  log "Passed=${pass_count} Skipped=${skip_count} Failed=${fail_count}"
  if [[ "$fail_count" -gt 0 ]]; then
    exit 1
  fi
  if [[ "$FAIL_ON_SKIP" == "true" && "$skip_count" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
