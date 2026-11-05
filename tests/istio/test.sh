#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_LOCAL_BOOKINFO_MANIFEST="${SCRIPT_DIR}/bookinfo.yaml"
DEFAULT_BOOKINFO_REF="${DEFAULT_BOOKINFO_REF:-master}"
BOOKINFO_INSTALL_SCRIPT="${SCRIPT_DIR}/istio-bookinfo-install.sh"

MODE="sidecar"
ROUTE_API="istio-api"
CLUSTER_NAME="ocne-bookinfo"
BOOKINFO_NAMESPACE="bookinfo"
CONTROL_PLANE_NODES="1"
WORKER_NODES="3"
ISTIO_VERSION="${ISTIO_VERSION:-}"
GATEWAY_API_CRDS_VERSION="1.4.0"
BOOKINFO_REF=""
BOOKINFO_MANIFEST=""
BOOKINFO_IMAGE_REGISTRY="registry.istio.io/release"
ISTIO_IMAGE_HUB="olcne"
ISTIO_IMAGE_TAG=""
ISTIO_IMAGE_TAG_EXPLICIT="false"
IMAGE_PULL_SECRET=""
KUBECONFIG_PATH="${KUBECONFIG:-}"
OCNE_BIN="${OCNE_BIN:-ocne}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
CATALOG_NAME="${CATALOG_TEST_NAME:-}"
CHECK_ONLY="false"
KEEP_PORT_FORWARD="false"
LOCAL_PORT="8080"
NODE_READY_TIMEOUT_SECONDS="1200"
ROLLOUT_TIMEOUT="600s"
TMP_DIR=""
INSTALLED_ISTIO_APP_VERSION=""
ISTIO_IMAGE_REPORT=""
ISTIO_IMAGE_MISMATCHES=""

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} --kubeconfig PATH [options]

Install and validate applications in an existing cluster.
The caller provisions cluster.yaml and owns cluster cleanup.
KUBECONFIG may supply the existing kubeconfig instead of --kubeconfig.
OCNE_BIN and KUBECTL_BIN select CLI executables (defaults: ocne, kubectl).

  --mode sidecar|ambient
      sidecar: enables automatic sidecar injection in the Bookinfo namespace.
      ambient: enables ambient dataplane enrollment and installs CNI + ztunnel.
  --route-api istio-api|gateway-api
      istio-api: installs the Istio ingress gateway app and applies the
                 Bookinfo Gateway/VirtualService sample.
      gateway-api: installs Kubernetes Gateway API CRDs via OCNE and applies
                   the Bookinfo Gateway/HTTPRoute sample.
  --namespace NAME                Bookinfo namespace. Default: ${BOOKINFO_NAMESPACE}
  --istio-version VERSION         Candidate catalog Istio chart version.
                                  Default: OCNE application catalog default.
  --gateway-api-crds-version VER  Gateway API CRDs chart version. Default: ${GATEWAY_API_CRDS_VERSION}
  --bookinfo-ref REF              Istio git ref for sample manifests.
                                  Default: --istio-version when specified,
                                  otherwise installed istiod APPVERSION.
  --bookinfo-manifest PATH_OR_URL Bookinfo app manifest. Default: ${DEFAULT_LOCAL_BOOKINFO_MANIFEST}
                                  when present, otherwise the upstream sample
                                  from --bookinfo-ref.
  --bookinfo-image-registry REG   Registry used for Bookinfo app images.
                                  Default: ${BOOKINFO_IMAGE_REGISTRY}
  --istio-image-hub HUB           Registry/repository hub for Istio chart images.
                                  Default: ${ISTIO_IMAGE_HUB}
  --istio-image-tag TAG           Image tag for Istio chart images.
                                  Default: --istio-version when specified;
                                  otherwise the chart default tag is used.
  --image-pull-secret NAME        Existing Kubernetes image pull secret used
                                  for Istio apps and Bookinfo workloads.
  --kubeconfig PATH               Existing kubeconfig. Default: KUBECONFIG environment.
  --check-only                    Validate local inputs and catalog versions, then exit.
  --keep-port-forward             Keep kubectl port-forward running in the foreground.
  --local-port PORT               Local verification and port-forward port. Default: ${LOCAL_PORT}
  --help                          Show this help.
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

run_ocne() {
  log_command "KUBECONFIG=${KUBECONFIG_PATH}" "$OCNE_BIN" "$@"
  KUBECONFIG="$KUBECONFIG_PATH" "$OCNE_BIN" "$@"
}

run_kubectl() {
  run "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" "$@"
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
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
      --gateway-api-crds-version)
        need_arg "$1" "${2:-}"
        GATEWAY_API_CRDS_VERSION="$2"
        shift 2
        ;;
      --gateway-api-crds-version=*)
        GATEWAY_API_CRDS_VERSION="${1#*=}"
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
      --istio-image-hub)
        need_arg "$1" "${2:-}"
        ISTIO_IMAGE_HUB="$2"
        shift 2
        ;;
      --istio-image-hub=*)
        ISTIO_IMAGE_HUB="${1#*=}"
        shift
        ;;
      --istio-image-tag)
        need_arg "$1" "${2:-}"
        ISTIO_IMAGE_TAG="$2"
        ISTIO_IMAGE_TAG_EXPLICIT="true"
        shift 2
        ;;
      --istio-image-tag=*)
        ISTIO_IMAGE_TAG="${1#*=}"
        ISTIO_IMAGE_TAG_EXPLICIT="true"
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

validate_integer() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "${name} must be a non-negative integer"
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

validate_config() {
  validate_kubernetes_name "candidate catalog" "$CATALOG_NAME"
  case "$MODE" in
    sidecar|ambient) ;;
    *) die "--mode must be sidecar or ambient" ;;
  esac

  case "$ROUTE_API" in
    istio-api|gateway-api) ;;
    *) die "--route-api must be istio-api or gateway-api" ;;
  esac

  validate_integer "--control-plane-nodes" "$CONTROL_PLANE_NODES"
  validate_integer "--worker-nodes" "$WORKER_NODES"
  validate_port "$LOCAL_PORT"

  (( CONTROL_PLANE_NODES >= 1 )) || die "--control-plane-nodes must be at least 1"
  (( WORKER_NODES >= 3 )) || die "--worker-nodes must be at least 3 for this Bookinfo test cluster"

  if [[ -z "$ISTIO_IMAGE_TAG" && -n "$ISTIO_VERSION" ]]; then
    ISTIO_IMAGE_TAG="$ISTIO_VERSION"
  fi

  BOOKINFO_IMAGE_REGISTRY="$(trim_trailing_slashes "$BOOKINFO_IMAGE_REGISTRY")"
  ISTIO_IMAGE_HUB="$(trim_trailing_slashes "$ISTIO_IMAGE_HUB")"

  if [[ -z "$BOOKINFO_MANIFEST" ]]; then
    if [[ -f "$DEFAULT_LOCAL_BOOKINFO_MANIFEST" ]]; then
      BOOKINFO_MANIFEST="$DEFAULT_LOCAL_BOOKINFO_MANIFEST"
    fi
  fi

  if [[ -n "$BOOKINFO_MANIFEST" ]] && ! is_url "$BOOKINFO_MANIFEST" && [[ ! -f "$BOOKINFO_MANIFEST" ]]; then
    die "--bookinfo-manifest does not exist: ${BOOKINFO_MANIFEST}"
  fi

  if [[ -n "$IMAGE_PULL_SECRET" ]]; then
    validate_kubernetes_name "--image-pull-secret" "$IMAGE_PULL_SECRET"
  fi

  if [[ -z "$KUBECONFIG_PATH" ]]; then
    KUBECONFIG_PATH="${KUBECONFIG:-}"
  fi
}

check_prerequisites() {
  log "Preflight: checking local commands"
  command -v "$OCNE_BIN" >/dev/null 2>&1 || die "ocne binary not found: ${OCNE_BIN}"
  command -v "$KUBECTL_BIN" >/dev/null 2>&1 || die "kubectl binary not found: ${KUBECTL_BIN}"
  command -v curl >/dev/null 2>&1 || die "curl is required for Bookinfo verification"
  command -v awk >/dev/null 2>&1 || die "awk is required for catalog validation"
  command -v grep >/dev/null 2>&1 || die "grep is required for manifest validation"
  [[ -x "$BOOKINFO_INSTALL_SCRIPT" ]] || die "Bookinfo installer is missing or not executable: ${BOOKINFO_INSTALL_SCRIPT}"
}

catalog_has_version() {
  local chart="$1"
  local version="$2"
  local output

  output="$("$OCNE_BIN" catalog search --name "$CATALOG_NAME" --pattern "^${chart}$")"
  awk -v chart="$chart" -v version="$version" 'NR > 1 && $1 == chart && $2 == version { found = 1 } END { exit found ? 0 : 1 }' <<<"$output"
}

require_catalog_version() {
  local chart="$1"
  local version="$2"

  log "Preflight: checking ${CATALOG_NAME} catalog for ${chart} ${version}"
  catalog_has_version "$chart" "$version" || die "OCNE catalog ${CATALOG_NAME} does not contain ${chart} ${version}; set OCNE_BIN or choose a supported version"
}

check_catalog_versions() {
  if [[ -n "$ISTIO_VERSION" ]]; then
    require_catalog_version "istio-base" "$ISTIO_VERSION"
    require_catalog_version "istiod" "$ISTIO_VERSION"

    if [[ "$MODE" == "ambient" ]]; then
      require_catalog_version "istio-cni" "$ISTIO_VERSION"
      require_catalog_version "istio-ztunnel" "$ISTIO_VERSION"
    fi

    if [[ "$ROUTE_API" == "istio-api" ]]; then
      require_catalog_version "istio-gateway" "$ISTIO_VERSION"
    fi
  else
    log "Preflight: no Istio version specified; OCNE application commands will use the catalog default version"
  fi

  if [[ "$ROUTE_API" == "gateway-api" ]]; then
    require_catalog_version "kubernetes-gateway-api-crds" "$GATEWAY_API_CRDS_VERSION"
  fi
}

create_values_files() {
  TMP_DIR="$(mktemp -d)"
  log "Writing temporary OCNE application values under ${TMP_DIR}"

  cat >"${TMP_DIR}/istiod-sidecar-values.yaml" <<EOF_VALUES
hub: $(yaml_quote "$ISTIO_IMAGE_HUB")
$(istio_image_tag_yaml "")
autoscaleEnabled: false
replicaCount: 1
traceSampling: 100
meshConfig:
  accessLogFile: /dev/stdout
resources:
  requests:
    cpu: 100m
    memory: 256Mi
global:
  hub: $(yaml_quote "$ISTIO_IMAGE_HUB")
$(istio_image_tag_yaml "  ")
$(image_pull_secrets_yaml "  ")
  proxy:
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 2000m
        memory: 1024Mi
EOF_VALUES

  cat >"${TMP_DIR}/istiod-ambient-values.yaml" <<EOF_VALUES
hub: $(yaml_quote "$ISTIO_IMAGE_HUB")
$(istio_image_tag_yaml "")
autoscaleEnabled: false
replicaCount: 1
traceSampling: 100
env:
  PILOT_ENABLE_AMBIENT: "true"
meshConfig:
  accessLogFile: /dev/stdout
  defaultConfig:
    proxyMetadata:
      ISTIO_META_ENABLE_HBONE: "true"
resources:
  requests:
    cpu: 100m
    memory: 256Mi
global:
  hub: $(yaml_quote "$ISTIO_IMAGE_HUB")
$(istio_image_tag_yaml "  ")
$(image_pull_secrets_yaml "  ")
  proxy:
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 2000m
        memory: 1024Mi
EOF_VALUES

  cat >"${TMP_DIR}/istio-cni-ambient-values.yaml" <<EOF_VALUES
hub: $(yaml_quote "$ISTIO_IMAGE_HUB")
$(istio_image_tag_yaml "")
ambient:
  enabled: true
resources:
  requests:
    cpu: 50m
    memory: 64Mi
global:
  hub: $(yaml_quote "$ISTIO_IMAGE_HUB")
$(istio_image_tag_yaml "  ")
$(image_pull_secrets_yaml "  ")
  defaultResources:
    requests:
      cpu: 50m
      memory: 64Mi
EOF_VALUES

  cat >"${TMP_DIR}/ztunnel-values.yaml" <<EOF_VALUES
hub: $(yaml_quote "$ISTIO_IMAGE_HUB")
$(istio_image_tag_yaml "")
$(image_pull_secrets_yaml "")
resources:
  requests:
    cpu: 100m
    memory: 128Mi
EOF_VALUES

  cat >"${TMP_DIR}/istio-gateway-values.yaml" <<EOF_VALUES
global:
  hub: $(yaml_quote "$ISTIO_IMAGE_HUB")
$(istio_image_tag_yaml "  ")
$(image_pull_secret_refs_yaml "")
service:
  type: ClusterIP
  ports:
  - name: status-port
    port: 15021
    protocol: TCP
    targetPort: 15021
  - name: http2
    port: 80
    protocol: TCP
    targetPort: 8080
  - name: https
    port: 443
    protocol: TCP
    targetPort: 8443
autoscaling:
  enabled: false
replicaCount: 1
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 1000m
    memory: 512Mi
EOF_VALUES
}


wait_for_nodes() {
  local expected_nodes=$((CONTROL_PLANE_NODES + WORKER_NODES))
  local deadline=$((SECONDS + NODE_READY_TIMEOUT_SECONDS))
  local count="0"

  log "Waiting for ${expected_nodes} Kubernetes node(s) to appear"
  while (( SECONDS < deadline )); do
    count="$("$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" get nodes --no-headers 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ' || true)"
    if [[ "$count" == "$expected_nodes" ]]; then
      log "Detected ${count}/${expected_nodes} Kubernetes node(s)"
      break
    fi
    log "Detected ${count}/${expected_nodes} Kubernetes node(s); waiting"
    sleep 10
  done

  [[ "$count" == "$expected_nodes" ]] || die "timed out waiting for ${expected_nodes} nodes"
  run_kubectl wait --for=condition=Ready nodes --all --timeout="${NODE_READY_TIMEOUT_SECONDS}s"
}

release_installed() {
  local namespace="$1"
  local release="$2"
  KUBECONFIG="$KUBECONFIG_PATH" "$OCNE_BIN" application show --namespace "$namespace" --release "$release" >/dev/null 2>&1
}

install_application() {
  local chart="$1"
  local release="$2"
  local namespace="$3"
  local version="$4"
  local values_file="${5:-}"

  if release_installed "$namespace" "$release"; then
    log "OCNE application ${release} already exists in namespace ${namespace}; updating release"
    local update_args=(
      application update
      --catalog "$CATALOG_NAME"
      --release "$release"
      --namespace "$namespace"
      --reset-values
    )
    if [[ -n "$version" ]]; then
      update_args+=(--version "$version")
    fi
    if [[ -n "$values_file" ]]; then
      update_args+=(--values "$values_file")
    fi

    run_ocne "${update_args[@]}"
    return
  fi

  log "Installing OCNE application ${chart} as release ${release} in namespace ${namespace}"
  local args=(
    application install
    --catalog "$CATALOG_NAME"
    --name "$chart"
    --release "$release"
    --namespace "$namespace"
  )
  if [[ -n "$version" ]]; then
    args+=(--version "$version")
  fi
  if [[ -n "$values_file" ]]; then
    args+=(--values "$values_file")
  fi

  run_ocne "${args[@]}"
}

istio_version_label() {
  if [[ -n "$ISTIO_VERSION" ]]; then
    printf '%s\n' "$ISTIO_VERSION"
  else
    printf 'catalog default\n'
  fi
}

install_istio() {
  log "Installing Istio $(istio_version_label) for ${MODE} mode through the candidate catalog"
  install_application "istio-base" "istio-base" "istio-system" "$ISTIO_VERSION"

  if [[ "$ROUTE_API" == "gateway-api" ]]; then
    install_application "kubernetes-gateway-api-crds" "kubernetes-gateway-api-crds" "istio-system" "$GATEWAY_API_CRDS_VERSION"
  fi

  if [[ "$MODE" == "ambient" ]]; then
    install_application "istiod" "istiod" "istio-system" "$ISTIO_VERSION" "${TMP_DIR}/istiod-ambient-values.yaml"
    install_application "istio-cni" "istio-cni" "istio-system" "$ISTIO_VERSION" "${TMP_DIR}/istio-cni-ambient-values.yaml"
    install_application "istio-ztunnel" "ztunnel" "istio-system" "$ISTIO_VERSION" "${TMP_DIR}/ztunnel-values.yaml"
  else
    install_application "istiod" "istiod" "istio-system" "$ISTIO_VERSION" "${TMP_DIR}/istiod-sidecar-values.yaml"
  fi

  if [[ "$ROUTE_API" == "istio-api" ]]; then
    install_application "istio-gateway" "istio-ingressgateway" "istio-system" "$ISTIO_VERSION" "${TMP_DIR}/istio-gateway-values.yaml"
  fi
}

wait_for_istio() {
  log "Waiting for Istio control plane and data plane components"
  run_kubectl -n istio-system rollout status deployment/istiod --timeout "$ROLLOUT_TIMEOUT"

  if [[ "$MODE" == "ambient" ]]; then
    run_kubectl -n istio-system rollout status daemonset/istio-cni-node --timeout "$ROLLOUT_TIMEOUT"
    run_kubectl -n istio-system rollout status daemonset/ztunnel --timeout "$ROLLOUT_TIMEOUT"
  fi

  if [[ "$ROUTE_API" == "istio-api" ]]; then
    run_kubectl -n istio-system rollout status deployment/istio-ingressgateway --timeout "$ROLLOUT_TIMEOUT"
  fi
}

get_application_app_version() {
  local namespace="$1"
  local release="$2"
  local output
  local version

  log_command "KUBECONFIG=${KUBECONFIG_PATH}" "$OCNE_BIN" application show --namespace "$namespace" --release "$release" >&2
  output="$(KUBECONFIG="$KUBECONFIG_PATH" "$OCNE_BIN" application show --namespace "$namespace" --release "$release")" || return 1
  version="$(awk -F': ' '$1 == "APPVERSION" { print $2; found = 1; exit } END { if (!found) exit 1 }' <<<"$output")" || {
    log "Unable to parse APPVERSION from ${release} release metadata; application show output follows" >&2
    printf '%s\n' "$output" >&2
    return 1
  }

  [[ -n "$version" ]] || return 1
  printf '%s\n' "$version"
}

get_installed_istiod_app_version() {
  if [[ -z "$INSTALLED_ISTIO_APP_VERSION" ]]; then
    INSTALLED_ISTIO_APP_VERSION="$(get_application_app_version "istio-system" "istiod")" || return 1
  fi

  printf '%s\n' "$INSTALLED_ISTIO_APP_VERSION"
}

expected_istio_image_tag_for_release() {
  local namespace="$1"
  local release="$2"

  if [[ "$ISTIO_IMAGE_TAG_EXPLICIT" == "true" ]]; then
    log "Image validation: using custom Istio image tag ${ISTIO_IMAGE_TAG} for ${namespace}/${release}" >&2
    printf '%s\n' "$ISTIO_IMAGE_TAG"
    return
  fi

  local app_version
  app_version="$(get_application_app_version "$namespace" "$release")" || return 1
  log "Image validation: using ${namespace}/${release} APPVERSION ${app_version} as expected image tag" >&2
  printf '%s\n' "$app_version"
}

expected_istio_image_tag_from_istiod() {
  if [[ "$ISTIO_IMAGE_TAG_EXPLICIT" == "true" ]]; then
    log "Image validation: using custom Istio image tag ${ISTIO_IMAGE_TAG} for generated gateway workloads" >&2
    printf '%s\n' "$ISTIO_IMAGE_TAG"
    return
  fi

  local app_version
  app_version="$(get_installed_istiod_app_version)" || return 1
  log "Image validation: using istiod APPVERSION ${app_version} as expected image tag for generated gateway workloads" >&2
  printf '%s\n' "$app_version"
}

image_tag_from_reference() {
  local image="$1"
  local image_without_digest
  local last_component

  image_without_digest="${image%%@*}"
  last_component="${image_without_digest##*/}"
  if [[ "$last_component" == *:* ]]; then
    printf '%s\n' "${last_component##*:}"
  fi
  return 0
}

record_istio_image() {
  local namespace="$1"
  local workload="$2"
  local container="$3"
  local image="$4"
  local expected_tag="$5"
  local actual_tag="$6"
  local line

  printf -v line '  namespace=%s workload=%s container=%s image=%s expectedTag=%s actualTag=%s' \
    "$namespace" "$workload" "$container" "$image" "$expected_tag" "${actual_tag:-<missing>}"
  ISTIO_IMAGE_REPORT+="${line}"$'\n'
}

record_istio_image_mismatch() {
  local namespace="$1"
  local workload="$2"
  local container="$3"
  local image="$4"
  local expected_tag="$5"
  local actual_tag="$6"
  local line

  printf -v line '  namespace=%s workload=%s container=%s expectedTag=%s actualTag=%s image=%s' \
    "$namespace" "$workload" "$container" "$expected_tag" "${actual_tag:-<missing>}" "$image"
  ISTIO_IMAGE_MISMATCHES+="${line}"$'\n'
}

report_deployed_istio_images() {
  if [[ -z "$ISTIO_IMAGE_REPORT" ]]; then
    log "Deployed Istio images: none recorded"
    return
  fi

  printf '\nDeployed Istio images:\n%s' "$ISTIO_IMAGE_REPORT"
}

validate_istio_workload_images() {
  local namespace="$1"
  local workload="$2"
  local expected_tag="$3"
  local output
  local container
  local image
  local actual_tag
  local image_count=0

  log "Image validation: inspecting ${namespace}/${workload}; expected tag ${expected_tag}"
  output="$("$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$namespace" get "$workload" -o jsonpath='{range .spec.template.spec.initContainers[*]}init/{.name}{"\t"}{.image}{"\n"}{end}{range .spec.template.spec.containers[*]}container/{.name}{"\t"}{.image}{"\n"}{end}')" || die "failed to read container images for ${namespace}/${workload}"

  while IFS=$'\t' read -r container image; do
    [[ -n "$container" && -n "$image" ]] || continue
    image_count=$((image_count + 1))
    actual_tag="$(image_tag_from_reference "$image")"
    log "Image validation: ${namespace}/${workload} ${container} uses ${image} with tag ${actual_tag:-<missing>}"
    record_istio_image "$namespace" "$workload" "$container" "$image" "$expected_tag" "$actual_tag"
    if [[ "$actual_tag" != "$expected_tag" ]]; then
      record_istio_image_mismatch "$namespace" "$workload" "$container" "$image" "$expected_tag" "$actual_tag"
    fi
  done <<<"$output"

  (( image_count > 0 )) || die "no container images found for ${namespace}/${workload}"
}

fail_on_istio_image_mismatches() {
  if [[ -z "$ISTIO_IMAGE_MISMATCHES" ]]; then
    return
  fi

  report_deployed_istio_images
  printf '\nIstio image tag mismatches:\n%s' "$ISTIO_IMAGE_MISMATCHES" >&2
  die "one or more deployed Istio image tags did not match the expected tag"
}

validate_installed_istio_image_tags() {
  local expected_tag

  log "Image validation: validating installed Istio release workloads"

  expected_tag="$(expected_istio_image_tag_for_release "istio-system" "istiod")" || die "failed to determine expected image tag for istiod"
  validate_istio_workload_images "istio-system" "deployment/istiod" "$expected_tag"

  if [[ "$MODE" == "ambient" ]]; then
    expected_tag="$(expected_istio_image_tag_for_release "istio-system" "istio-cni")" || die "failed to determine expected image tag for istio-cni"
    validate_istio_workload_images "istio-system" "daemonset/istio-cni-node" "$expected_tag"

    expected_tag="$(expected_istio_image_tag_for_release "istio-system" "ztunnel")" || die "failed to determine expected image tag for ztunnel"
    validate_istio_workload_images "istio-system" "daemonset/ztunnel" "$expected_tag"
  fi

  if [[ "$ROUTE_API" == "istio-api" ]]; then
    expected_tag="$(expected_istio_image_tag_for_release "istio-system" "istio-ingressgateway")" || die "failed to determine expected image tag for istio-ingressgateway"
    validate_istio_workload_images "istio-system" "deployment/istio-ingressgateway" "$expected_tag"
  fi

  fail_on_istio_image_mismatches
  log "Image validation: installed Istio release workloads use the expected image tags"
}

validate_gateway_api_istio_image_tags() {
  local expected_tag
  local workload

  if [[ "$ROUTE_API" != "gateway-api" ]]; then
    return
  fi

  workload="deployment/$(gateway_service_name)"
  log "Image validation: waiting for generated Gateway API Istio workload ${BOOKINFO_NAMESPACE}/${workload}"
  run_kubectl -n "$BOOKINFO_NAMESPACE" rollout status "$workload" --timeout "$ROLLOUT_TIMEOUT"

  expected_tag="$(expected_istio_image_tag_from_istiod)" || die "failed to determine expected image tag for generated Gateway API workload"
  validate_istio_workload_images "$BOOKINFO_NAMESPACE" "$workload" "$expected_tag"

  fail_on_istio_image_mismatches
  log "Image validation: generated Gateway API Istio workload uses the expected image tag"
}

resolve_bookinfo_ref_for_check_only() {
  if [[ -n "$BOOKINFO_REF" ]]; then
    log "Preflight: using requested Bookinfo sample ref ${BOOKINFO_REF}"
  elif [[ -n "$ISTIO_VERSION" ]]; then
    BOOKINFO_REF="$ISTIO_VERSION"
    log "Preflight: using requested Istio version ${BOOKINFO_REF} as Bookinfo sample ref"
  else
    BOOKINFO_REF="$DEFAULT_BOOKINFO_REF"
    log "Preflight: using check-only fallback Bookinfo sample ref ${BOOKINFO_REF}"
  fi
}

resolve_bookinfo_ref_after_istio() {
  if [[ -n "$BOOKINFO_REF" ]]; then
    log "Using requested Bookinfo sample ref ${BOOKINFO_REF}"
  elif [[ -n "$ISTIO_VERSION" ]]; then
    BOOKINFO_REF="$ISTIO_VERSION"
    log "Using requested Istio version ${BOOKINFO_REF} as Bookinfo sample ref"
  else
    BOOKINFO_REF="$(get_installed_istiod_app_version)" || die "failed to determine installed Istio version from istiod release"
    log "Using installed istiod app version ${BOOKINFO_REF} as Bookinfo sample ref"
  fi
}

run_bookinfo_installer() {
  if [[ -z "$BOOKINFO_MANIFEST" ]]; then
    BOOKINFO_MANIFEST="$(bookinfo_url "samples/bookinfo/platform/kube/bookinfo.yaml")"
  fi

  local args=(
    --mode "$MODE"
    --route-api "$ROUTE_API"
    --namespace "$BOOKINFO_NAMESPACE"
    --kubeconfig "$KUBECONFIG_PATH"
    --bookinfo-image-registry "$BOOKINFO_IMAGE_REGISTRY"
    --local-port "$LOCAL_PORT"
  )

  if [[ -n "$BOOKINFO_REF" ]]; then
    args+=(--bookinfo-ref "$BOOKINFO_REF")
  fi
  if [[ -n "$BOOKINFO_MANIFEST" ]]; then
    args+=(--bookinfo-manifest "$BOOKINFO_MANIFEST")
  fi
  if [[ -n "$IMAGE_PULL_SECRET" ]]; then
    args+=(--image-pull-secret "$IMAGE_PULL_SECRET")
  fi
  if [[ "$CHECK_ONLY" == "true" ]]; then
    args+=(--check-only)
  fi
  if [[ "$KEEP_PORT_FORWARD" == "true" ]]; then
    args+=(--keep-port-forward)
  else
    args+=(--no-summary)
  fi

  log "Delegating Bookinfo installation to ${BOOKINFO_INSTALL_SCRIPT}"
  run "$BOOKINFO_INSTALL_SCRIPT" "${args[@]}"
}

bookinfo_url() {
  local path="$1"
  printf 'https://raw.githubusercontent.com/istio/istio/%s/%s\n' "$BOOKINFO_REF" "$path"
}

yaml_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

yaml_field_if_set() {
  local indent="$1"
  local key="$2"
  local value="$3"

  if [[ -n "$value" ]]; then
    printf '%s%s: %s\n' "$indent" "$key" "$(yaml_quote "$value")"
  fi
}

istio_image_tag_yaml() {
  local indent="$1"
  yaml_field_if_set "$indent" tag "$ISTIO_IMAGE_TAG"
}

image_pull_secrets_yaml() {
  local indent="$1"

  if [[ -n "$IMAGE_PULL_SECRET" ]]; then
    printf '%simagePullSecrets:\n%s- %s\n' "$indent" "$indent" "$(yaml_quote "$IMAGE_PULL_SECRET")"
  else
    printf '%simagePullSecrets: []\n' "$indent"
  fi
}

image_pull_secret_refs_yaml() {
  local indent="$1"

  if [[ -n "$IMAGE_PULL_SECRET" ]]; then
    printf '%simagePullSecrets:\n%s- name: %s\n' "$indent" "$indent" "$(yaml_quote "$IMAGE_PULL_SECRET")"
  else
    printf '%simagePullSecrets: []\n' "$indent"
  fi
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

show_summary() {
  local svc_name
  local svc_namespace
  svc_name="$(gateway_service_name)"
  svc_namespace="$(gateway_service_namespace)"

  log "Bookinfo test environment is ready"
  cat <<SUMMARY

Cluster:
  lifecycle: externally managed
  kubeconfig: ${KUBECONFIG_PATH}
  control plane nodes: ${CONTROL_PLANE_NODES}
  worker nodes: ${WORKER_NODES}

Istio:
  mode: ${MODE}
  route API: ${ROUTE_API}
  version: ${ISTIO_VERSION:-catalog default}
  namespace: istio-system

Bookinfo:
  namespace: ${BOOKINFO_NAMESPACE}
  sample ref: ${BOOKINFO_REF:-not set}
  application manifest: ${BOOKINFO_MANIFEST}
  image registry: ${BOOKINFO_IMAGE_REGISTRY}
  Istio image hub: ${ISTIO_IMAGE_HUB}
  Istio image tag: ${ISTIO_IMAGE_TAG:-chart default}
  local URL: http://127.0.0.1:${LOCAL_PORT}/productpage

Deployed Istio images:
${ISTIO_IMAGE_REPORT:-  none recorded}

Access command:
  ${KUBECTL_BIN} --kubeconfig ${KUBECONFIG_PATH} -n ${svc_namespace} port-forward svc/${svc_name} ${LOCAL_PORT}:80
SUMMARY
}

main() {
  parse_args "$@"
  [[ -n "$CATALOG_NAME" ]] || die "Run tests/run-changed.sh to build and register this checkout catalog"
  log "Using an externally provisioned cluster; cluster lifecycle belongs to the caller"
  [[ -n "$KUBECONFIG_PATH" && -s "$KUBECONFIG_PATH" ]] || die "Supply an existing kubeconfig with --kubeconfig or KUBECONFIG"
  check_prerequisites
  validate_config
  check_catalog_versions
  create_values_files

  log "Execution plan: use existing cluster, wait for nodes, install Istio, validate Istio image tags, delegate Bookinfo install, verify generated Gateway API image tags, report images"
  log "Selected mode=${MODE}, route-api=${ROUTE_API}, worker-nodes=${WORKER_NODES}"

  if [[ "$CHECK_ONLY" == "true" ]]; then
    resolve_bookinfo_ref_for_check_only
    run_bookinfo_installer
    log "Check-only mode completed; no cluster or Kubernetes resources were changed"
    return
  fi

  wait_for_nodes
  install_istio
  wait_for_istio
  validate_installed_istio_image_tags
  resolve_bookinfo_ref_after_istio
  run_bookinfo_installer
  validate_gateway_api_istio_image_tags
  show_summary

}

main "$@"
