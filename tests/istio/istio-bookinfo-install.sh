#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_LOCAL_BOOKINFO_MANIFEST="${SCRIPT_DIR}/bookinfo.yaml"
DEFAULT_BOOKINFO_REF="${DEFAULT_BOOKINFO_REF:-master}"

MODE="sidecar"
ROUTE_API="istio-api"
BOOKINFO_NAMESPACE="bookinfo"
ISTIO_VERSION=""
BOOKINFO_REF=""
BOOKINFO_MANIFEST=""
BOOKINFO_IMAGE_REGISTRY="registry.istio.io/release"
IMAGE_PULL_SECRET=""
KUBECONFIG_PATH="${KUBECONFIG:-}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
CURL_BIN="${CURL_BIN:-curl}"
CHECK_ONLY="false"
KEEP_PORT_FORWARD="false"
SHOW_SUMMARY="true"
LOCAL_PORT="8080"
ROLLOUT_TIMEOUT="600s"
PORT_FORWARD_TIMEOUT_SECONDS="60"
TMP_DIR=""
PORT_FORWARD_PID=""
BOOKINFO_RENDERED_MANIFEST=""

usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_NAME} [options]

Installs the Istio Bookinfo sample into an existing Kubernetes cluster that
already has Istio installed, configures the Bookinfo namespace for the selected
dataplane mode, applies the matching gateway resources, and verifies access to
/productpage.

Options:
  --mode sidecar|ambient
      sidecar: enables automatic sidecar injection in the Bookinfo namespace.
      ambient: enables ambient dataplane enrollment.
  --route-api istio-api|gateway-api
      istio-api: applies the Bookinfo Gateway/VirtualService sample.
      gateway-api: applies the Bookinfo Gateway/HTTPRoute sample.
  --namespace NAME                Bookinfo namespace. Default: ${BOOKINFO_NAMESPACE}
  --istio-version VERSION         Used as the default Bookinfo sample ref when
                                  --bookinfo-ref is omitted.
  --bookinfo-ref REF              Istio git ref for sample manifests.
                                  Default: --istio-version when specified,
                                  otherwise ${DEFAULT_BOOKINFO_REF}.
  --bookinfo-manifest PATH_OR_URL Bookinfo app manifest. Default: ${DEFAULT_LOCAL_BOOKINFO_MANIFEST}
                                  when present, otherwise the upstream sample
                                  from --bookinfo-ref.
  --bookinfo-image-registry REG   Registry used for Bookinfo app images.
                                  Default: ${BOOKINFO_IMAGE_REGISTRY}
  --image-pull-secret NAME        Existing Kubernetes image pull secret used
                                  for Bookinfo workloads.
  --kubeconfig PATH               Kubeconfig path. Default: KUBECONFIG when set,
                                  otherwise ~/.kube/config.
  --check-only                    Validate local inputs and render the Bookinfo
                                  manifest, then exit.
  --keep-port-forward             Keep kubectl port-forward running in the foreground.
  --local-port PORT               Local verification and port-forward port. Default: ${LOCAL_PORT}
  --no-summary                    Do not print the final Bookinfo summary.
  --help                          Show this help.

Environment:
  DEFAULT_BOOKINFO_REF            Fallback upstream Istio git ref when
                                  --bookinfo-ref and --istio-version are omitted.
  KUBECTL_BIN                     Override the kubectl path. Default: ${KUBECTL_BIN}
  CURL_BIN                        Override the curl path. Default: ${CURL_BIN}

Examples:
  ${SCRIPT_NAME} --kubeconfig ~/.kube/config --mode sidecar
  ${SCRIPT_NAME} --kubeconfig ~/.kube/config --mode ambient --route-api gateway-api
  ${SCRIPT_NAME} --kubeconfig ~/.kube/config --bookinfo-ref 1.30.3
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

cleanup() {
  if [[ -n "$PORT_FORWARD_PID" ]]; then
    log "Stopping temporary port-forward process ${PORT_FORWARD_PID}"
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    log "Removing temporary directory ${TMP_DIR}"
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT

need_arg() {
  local flag="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || die "${flag} requires a value"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        need_arg "$1" "${2:-}"
        MODE="$2"
        shift 2
        ;;
      --mode=*)
        MODE="${1#*=}"
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
      --namespace)
        need_arg "$1" "${2:-}"
        BOOKINFO_NAMESPACE="$2"
        shift 2
        ;;
      --namespace=*)
        BOOKINFO_NAMESPACE="${1#*=}"
        shift
        ;;
      --istio-version)
        need_arg "$1" "${2:-}"
        ISTIO_VERSION="$2"
        shift 2
        ;;
      --istio-version=*)
        ISTIO_VERSION="${1#*=}"
        shift
        ;;
      --bookinfo-ref)
        need_arg "$1" "${2:-}"
        BOOKINFO_REF="$2"
        shift 2
        ;;
      --bookinfo-ref=*)
        BOOKINFO_REF="${1#*=}"
        shift
        ;;
      --bookinfo-manifest)
        need_arg "$1" "${2:-}"
        BOOKINFO_MANIFEST="$2"
        shift 2
        ;;
      --bookinfo-manifest=*)
        BOOKINFO_MANIFEST="${1#*=}"
        shift
        ;;
      --bookinfo-image-registry)
        need_arg "$1" "${2:-}"
        BOOKINFO_IMAGE_REGISTRY="$2"
        shift 2
        ;;
      --bookinfo-image-registry=*)
        BOOKINFO_IMAGE_REGISTRY="${1#*=}"
        shift
        ;;
      --image-pull-secret)
        need_arg "$1" "${2:-}"
        IMAGE_PULL_SECRET="$2"
        shift 2
        ;;
      --image-pull-secret=*)
        IMAGE_PULL_SECRET="${1#*=}"
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
      --check-only)
        CHECK_ONLY="true"
        shift
        ;;
      --keep-port-forward)
        KEEP_PORT_FORWARD="true"
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
      --no-summary)
        SHOW_SUMMARY="false"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

validate_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || die "--local-port must be an integer"
  (( value >= 1 && value <= 65535 )) || die "--local-port must be between 1 and 65535"
}

validate_kubernetes_name() {
  local flag="$1"
  local value="$2"
  [[ "$value" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || die "${flag} must be a valid lowercase Kubernetes object name"
}

is_url() {
  case "$1" in
    http://*|https://*) return 0 ;;
    *) return 1 ;;
  esac
}

trim_trailing_slashes() {
  local value="$1"
  while [[ "$value" == */ ]]; do
    value="${value%/}"
  done
  printf '%s\n' "$value"
}

check_prerequisites() {
  log "Preflight: checking local commands"
  command -v "$KUBECTL_BIN" >/dev/null 2>&1 || die "kubectl binary not found: ${KUBECTL_BIN}"
  command -v "$CURL_BIN" >/dev/null 2>&1 || die "curl is required for Bookinfo manifest downloads and verification"
  command -v awk >/dev/null 2>&1 || die "awk is required for manifest rendering"
  command -v grep >/dev/null 2>&1 || die "grep is required for manifest validation"
}

validate_config() {
  case "$MODE" in
    sidecar|ambient) ;;
    *) die "--mode must be sidecar or ambient" ;;
  esac

  case "$ROUTE_API" in
    istio-api|gateway-api) ;;
    *) die "--route-api must be istio-api or gateway-api" ;;
  esac

  validate_kubernetes_name "--namespace" "$BOOKINFO_NAMESPACE"
  validate_port "$LOCAL_PORT"

  BOOKINFO_IMAGE_REGISTRY="$(trim_trailing_slashes "$BOOKINFO_IMAGE_REGISTRY")"

  if [[ -z "$BOOKINFO_MANIFEST" && -f "$DEFAULT_LOCAL_BOOKINFO_MANIFEST" ]]; then
    BOOKINFO_MANIFEST="$DEFAULT_LOCAL_BOOKINFO_MANIFEST"
  fi

  if [[ -n "$BOOKINFO_MANIFEST" ]] && ! is_url "$BOOKINFO_MANIFEST" && [[ ! -f "$BOOKINFO_MANIFEST" ]]; then
    die "--bookinfo-manifest does not exist: ${BOOKINFO_MANIFEST}"
  fi

  if [[ -n "$IMAGE_PULL_SECRET" ]]; then
    validate_kubernetes_name "--image-pull-secret" "$IMAGE_PULL_SECRET"
  fi

  if [[ -z "$KUBECONFIG_PATH" ]]; then
    KUBECONFIG_PATH="${HOME}/.kube/config"
  fi
}

resolve_bookinfo_ref() {
  if [[ -n "$BOOKINFO_REF" ]]; then
    log "Using requested Bookinfo sample ref ${BOOKINFO_REF}"
  elif [[ -n "$ISTIO_VERSION" ]]; then
    BOOKINFO_REF="$ISTIO_VERSION"
    log "Using requested Istio version ${BOOKINFO_REF} as Bookinfo sample ref"
  else
    BOOKINFO_REF="$DEFAULT_BOOKINFO_REF"
    log "Using fallback Bookinfo sample ref ${BOOKINFO_REF}"
  fi
}

ensure_cluster_access() {
  [[ -f "$KUBECONFIG_PATH" ]] || die "kubeconfig does not exist: ${KUBECONFIG_PATH}"
  log "Checking Kubernetes API access using kubeconfig ${KUBECONFIG_PATH}"
  run_kubectl version --client=true
  run_kubectl get namespace default
}

ensure_istio_ready() {
  log "Checking for an existing Istio control plane in namespace istio-system"
  run_kubectl -n istio-system rollout status deployment/istiod --timeout "$ROLLOUT_TIMEOUT"

  if [[ "$MODE" == "ambient" ]]; then
    log "Checking ambient Istio data plane components"
    run_kubectl -n istio-system rollout status daemonset/istio-cni-node --timeout "$ROLLOUT_TIMEOUT"
    run_kubectl -n istio-system rollout status daemonset/ztunnel --timeout "$ROLLOUT_TIMEOUT"
  fi

  if [[ "$ROUTE_API" == "istio-api" ]]; then
    log "Checking existing Istio ingress gateway service for Istio API routing"
    run_kubectl -n istio-system get service istio-ingressgateway
  else
    log "Checking Gateway API CRDs for Gateway API routing"
    run_kubectl get crd gateways.gateway.networking.k8s.io
    run_kubectl get crd httproutes.gateway.networking.k8s.io
  fi
}

ensure_bookinfo_namespace() {
  if "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" get namespace "$BOOKINFO_NAMESPACE" >/dev/null 2>&1; then
    log "Namespace ${BOOKINFO_NAMESPACE} already exists"
  else
    run_kubectl create namespace "$BOOKINFO_NAMESPACE"
  fi

  if [[ "$MODE" == "ambient" ]]; then
    log "Configuring ${BOOKINFO_NAMESPACE} for ambient dataplane enrollment"
    "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" label namespace "$BOOKINFO_NAMESPACE" istio-injection- --overwrite >/dev/null 2>&1 || true
    run_kubectl label namespace "$BOOKINFO_NAMESPACE" istio.io/dataplane-mode=ambient --overwrite
  else
    log "Configuring ${BOOKINFO_NAMESPACE} for automatic sidecar injection"
    "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" label namespace "$BOOKINFO_NAMESPACE" istio.io/dataplane-mode- --overwrite >/dev/null 2>&1 || true
    run_kubectl label namespace "$BOOKINFO_NAMESPACE" istio-injection=enabled --overwrite
  fi
}

bookinfo_url() {
  local path="$1"
  printf 'https://raw.githubusercontent.com/istio/istio/%s/%s\n' "$BOOKINFO_REF" "$path"
}

render_bookinfo_manifest() {
  local source="$1"
  local destination="$2"

  log "Rendering Bookinfo manifest with image registry ${BOOKINFO_IMAGE_REGISTRY}"
  awk -v registry="$BOOKINFO_IMAGE_REGISTRY" -v pull_secret="$IMAGE_PULL_SECRET" '
    function emit_pending_pull_secret() {
      if (pending_pull_secret && pull_secret != "") {
        print pending_indent "imagePullSecrets:"
        print pending_indent "- name: " pull_secret
      }
      pending_pull_secret = 0
    }

    {
      if (pending_pull_secret) {
        if ($0 ~ /^[[:space:]]*imagePullSecrets:/) {
          pending_pull_secret = 0
        } else {
          emit_pending_pull_secret()
        }
      }

      if (registry != "" && $0 ~ /^[[:space:]]*image:[[:space:]]*.*examples-bookinfo-/) {
        image = $0
        sub(/^[[:space:]]*image:[[:space:]]*/, "", image)
        gsub(/"/, "", image)
        gsub(/\047/, "", image)
        split(image, parts, "/")
        image_name = parts[length(parts)]
        printf "%simage: %s/%s\n", substr($0, 1, index($0, "image:") - 1), registry, image_name
        next
      }

      print

      if (pull_secret != "" && $0 ~ /^[[:space:]]*serviceAccountName:[[:space:]]*bookinfo-/) {
        pending_pull_secret = 1
        pending_indent = substr($0, 1, index($0, "serviceAccountName:") - 1)
      }
    }

    END {
      emit_pending_pull_secret()
    }
  ' "$source" >"$destination"
}

validate_bookinfo_manifest_images() {
  local manifest="$1"
  local image_count

  if grep -En "^[[:space:]]*image:[[:space:]]*['\"]?((docker\.io|index\.docker\.io)/|istio/examples-bookinfo)" "$manifest"; then
    die "Bookinfo manifest still contains Docker Hub image references after rendering"
  fi

  image_count="$(awk '/^[[:space:]]*image:[[:space:]]*.*examples-bookinfo-/ { count++ } END { print count + 0 }' "$manifest")"
  (( image_count >= 6 )) || die "Bookinfo manifest should contain at least six examples-bookinfo image references; found ${image_count}"
}

prepare_bookinfo_manifest() {
  local downloaded_manifest="${TMP_DIR}/bookinfo-source.yaml"
  local rendered_manifest="${TMP_DIR}/bookinfo-rendered.yaml"

  if [[ -z "$BOOKINFO_MANIFEST" ]]; then
    BOOKINFO_MANIFEST="$(bookinfo_url "samples/bookinfo/platform/kube/bookinfo.yaml")"
  fi

  if is_url "$BOOKINFO_MANIFEST"; then
    log "Downloading Bookinfo application manifest from ${BOOKINFO_MANIFEST}"
    run "$CURL_BIN" -fsSL "$BOOKINFO_MANIFEST" -o "$downloaded_manifest"
  else
    log "Using local Bookinfo application manifest ${BOOKINFO_MANIFEST}"
    run cp "$BOOKINFO_MANIFEST" "$downloaded_manifest"
  fi

  render_bookinfo_manifest "$downloaded_manifest" "$rendered_manifest"
  validate_bookinfo_manifest_images "$rendered_manifest"
  BOOKINFO_RENDERED_MANIFEST="$rendered_manifest"
}

apply_bookinfo() {
  local bookinfo_manifest
  local route_manifest
  local versions_manifest

  bookinfo_manifest="$BOOKINFO_RENDERED_MANIFEST"
  [[ -n "$bookinfo_manifest" && -f "$bookinfo_manifest" ]] || die "rendered Bookinfo manifest is missing"
  log "Applying Bookinfo application manifest from ${bookinfo_manifest}"
  run_kubectl -n "$BOOKINFO_NAMESPACE" apply -f "$bookinfo_manifest"

  log "Waiting for Bookinfo deployments in namespace ${BOOKINFO_NAMESPACE}"
  run_kubectl -n "$BOOKINFO_NAMESPACE" wait --for=condition=Available deployment --all --timeout "$ROLLOUT_TIMEOUT"

  if [[ "$ROUTE_API" == "gateway-api" ]]; then
    route_manifest="$(bookinfo_url "samples/bookinfo/gateway-api/bookinfo-gateway.yaml")"
    versions_manifest="$(bookinfo_url "samples/bookinfo/platform/kube/bookinfo-versions.yaml")"

    log "Applying Bookinfo Gateway API resources from ${route_manifest}"
    run_kubectl -n "$BOOKINFO_NAMESPACE" apply -f "$route_manifest"
    run_kubectl -n "$BOOKINFO_NAMESPACE" annotate gateway bookinfo-gateway networking.istio.io/service-type=ClusterIP --overwrite
    run_kubectl -n "$BOOKINFO_NAMESPACE" wait --for=condition=programmed gateway/bookinfo-gateway --timeout "$ROLLOUT_TIMEOUT"

    log "Applying Bookinfo version service resources from ${versions_manifest}"
    run_kubectl -n "$BOOKINFO_NAMESPACE" apply -f "$versions_manifest"
  else
    route_manifest="$(bookinfo_url "samples/bookinfo/networking/bookinfo-gateway.yaml")"
    versions_manifest="$(bookinfo_url "samples/bookinfo/networking/destination-rule-all.yaml")"

    log "Applying Bookinfo Istio API gateway resources from ${route_manifest}"
    run_kubectl -n "$BOOKINFO_NAMESPACE" apply -f "$route_manifest"

    log "Applying Bookinfo destination rules from ${versions_manifest}"
    run_kubectl -n "$BOOKINFO_NAMESPACE" apply -f "$versions_manifest"
  fi
}

verify_inside_cluster() {
  log "Verifying Bookinfo from inside the cluster through the ratings deployment"
  local deadline=$((SECONDS + 120))
  local response

  while (( SECONDS < deadline )); do
    response="$("$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$BOOKINFO_NAMESPACE" exec deploy/ratings-v1 -c ratings -- curl -sS productpage:9080/productpage 2>/dev/null || true)"
    case "$response" in
      *"<title>Simple Bookstore App</title>"*)
        log "In-cluster Bookinfo verification succeeded"
        return
        ;;
    esac
    log "Bookinfo in-cluster verification is not ready yet; waiting"
    sleep 5
  done

  die "Bookinfo in-cluster verification did not return the expected title"
}

gateway_service_name() {
  if [[ "$ROUTE_API" == "gateway-api" ]]; then
    printf 'bookinfo-gateway-istio\n'
  else
    printf 'istio-ingressgateway\n'
  fi
}

gateway_service_namespace() {
  if [[ "$ROUTE_API" == "gateway-api" ]]; then
    printf '%s\n' "$BOOKINFO_NAMESPACE"
  else
    printf 'istio-system\n'
  fi
}

start_temporary_port_forward() {
  local svc_name="$1"
  local svc_namespace="$2"
  local log_file="${TMP_DIR}/port-forward.log"
  local deadline=$((SECONDS + PORT_FORWARD_TIMEOUT_SECONDS))

  log "Starting temporary port-forward from 127.0.0.1:${LOCAL_PORT} to ${svc_namespace}/${svc_name}:80"
  "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$svc_namespace" port-forward --address 127.0.0.1 "svc/${svc_name}" "${LOCAL_PORT}:80" >"$log_file" 2>&1 &
  PORT_FORWARD_PID="$!"

  while (( SECONDS < deadline )); do
    if ! kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
      log "Port-forward log follows:"
      sed -n '1,120p' "$log_file" >&2 || true
      die "kubectl port-forward exited before becoming ready"
    fi
    if "$CURL_BIN" -fsS "http://127.0.0.1:${LOCAL_PORT}/productpage" >/dev/null 2>&1; then
      log "Temporary port-forward is serving Bookinfo"
      return
    fi
    sleep 2
  done

  log "Port-forward log follows:"
  sed -n '1,120p' "$log_file" >&2 || true
  die "timed out waiting for Bookinfo through local port ${LOCAL_PORT}"
}

verify_gateway_access() {
  local svc_name
  local svc_namespace
  local response

  svc_name="$(gateway_service_name)"
  svc_namespace="$(gateway_service_namespace)"

  start_temporary_port_forward "$svc_name" "$svc_namespace"
  log "Verifying Bookinfo through http://127.0.0.1:${LOCAL_PORT}/productpage"
  response="$("$CURL_BIN" -fsS "http://127.0.0.1:${LOCAL_PORT}/productpage")"

  case "$response" in
    *"<title>Simple Bookstore App</title>"*)
      log "Gateway Bookinfo verification succeeded"
      ;;
    *)
      die "Gateway verification did not return the expected title"
      ;;
  esac

  if [[ "$KEEP_PORT_FORWARD" != "true" ]]; then
    cleanup
    PORT_FORWARD_PID=""
  fi
}

show_summary() {
  local svc_name
  local svc_namespace
  svc_name="$(gateway_service_name)"
  svc_namespace="$(gateway_service_namespace)"

  log "Bookinfo installation is ready"
  cat <<SUMMARY

Bookinfo:
  namespace: ${BOOKINFO_NAMESPACE}
  mode: ${MODE}
  route API: ${ROUTE_API}
  sample ref: ${BOOKINFO_REF}
  application manifest: ${BOOKINFO_MANIFEST}
  image registry: ${BOOKINFO_IMAGE_REGISTRY}
  local URL: http://127.0.0.1:${LOCAL_PORT}/productpage

Access command:
  ${KUBECTL_BIN} --kubeconfig ${KUBECONFIG_PATH} -n ${svc_namespace} port-forward svc/${svc_name} ${LOCAL_PORT}:80
SUMMARY
}

main() {
  parse_args "$@"
  check_prerequisites
  validate_config
  resolve_bookinfo_ref

  TMP_DIR="$(mktemp -d)"
  log "Temporary directory: ${TMP_DIR}"
  log "Execution plan: check existing Istio, enroll namespace, render Bookinfo manifest, deploy Bookinfo, apply routing resources, verify service access"
  log "Selected mode=${MODE}, route-api=${ROUTE_API}, namespace=${BOOKINFO_NAMESPACE}"

  prepare_bookinfo_manifest

  if [[ "$CHECK_ONLY" == "true" ]]; then
    log "Check-only mode completed; no Kubernetes resources were changed"
    return
  fi

  ensure_cluster_access
  ensure_istio_ready
  ensure_bookinfo_namespace
  apply_bookinfo
  verify_inside_cluster
  verify_gateway_access

  if [[ "$SHOW_SUMMARY" == "true" ]]; then
    show_summary
  fi

  if [[ "$KEEP_PORT_FORWARD" == "true" ]]; then
    log "Keeping port-forward in the foreground; press Ctrl-C to stop it"
    wait "$PORT_FORWARD_PID"
  fi
}

main "$@"
