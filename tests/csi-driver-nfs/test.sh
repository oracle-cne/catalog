#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_NFS_SERVER_SCRIPT="${SCRIPT_DIR}/deploy-nfs-server.sh"

OCNE_BIN="${OCNE_BIN:-ocne}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

CLUSTER_NAME="ocne-nfs-csi"
CONTROL_PLANE_NODES="1"
WORKER_NODES="1"
KUBECONFIG_PATH="${KUBECONFIG:-}"
CATALOG_NAME="${CATALOG_TEST_NAME:-}"

NFS_CSI_VERSION="${NFS_CSI_VERSION:-4.13.4}"
NFS_CSI_NAMESPACE="kube-system"
NFS_CSI_RELEASE="csi-driver-nfs"
NFS_CSI_NFS_IMAGE_REPOSITORY="${NFS_CSI_NFS_IMAGE_REPOSITORY:-}"
NFS_CSI_NFS_IMAGE_TAG="${NFS_CSI_NFS_IMAGE_TAG:-}"
NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX="${NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX:-}"
NFS_SERVER_SCRIPT="${NFS_SERVER_SCRIPT:-$DEFAULT_NFS_SERVER_SCRIPT}"
NFS_NAMESPACE="default"
NFS_NAME="nfs-server"
NFS_IMAGE="${NFS_IMAGE:-registry.k8s.io/volume-nfs:0.8}"
NFS_HOST_PATH="${NFS_HOST_PATH:-/var/lib/nfs-vol}"
NFS_SHARED_DIRECTORY="${NFS_SHARED_DIRECTORY:-/exports}"
NFS_SERVICE_TYPE="${NFS_SERVICE_TYPE:-ClusterIP}"
STORAGE_CLASS_NAME="nfs-csi"

TEST_NAMESPACE="nfs-csi-test"
TEST_PVC_NAME="nfs-csi-smoke"
TEST_JOB_NAME="nfs-csi-smoke"
TEST_IMAGE="${TEST_IMAGE:-registry.k8s.io/volume-nfs:0.8}"
KEEP_TEST_ARTIFACTS="false"

NODE_READY_TIMEOUT_SECONDS="1200"
ROLLOUT_TIMEOUT="300s"
TEST_TIMEOUT_SECONDS="300"
TMP_DIR=""
NFS_CSI_VALUES_FILE=""

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} --kubeconfig PATH [options]

Install and validate applications in an existing cluster.
The caller provisions cluster.yaml and owns cluster cleanup.
KUBECONFIG may supply the existing kubeconfig instead of --kubeconfig.
OCNE_BIN and KUBECTL_BIN select CLI executables (defaults: ocne, kubectl).

  --kubeconfig PATH               Existing kubeconfig. Default: KUBECONFIG environment.
  --nfs-csi-version VERSION       csi-driver-nfs chart version. Default: ${NFS_CSI_VERSION}
  --nfs-csi-namespace NAME        Install namespace. Default: ${NFS_CSI_NAMESPACE}
  --nfs-csi-release NAME          Release name. Default: ${NFS_CSI_RELEASE}
  --nfs-csi-nfs-image-repository IMAGE
                                  Optional NFS CSI plugin image repository override.
  --nfs-csi-nfs-image-tag TAG     NFS CSI plugin image tag override.
                                  Default: v<--nfs-csi-version> when repository override is set.
  --nfs-csi-sidecars-from-container-registry
                                  Pull CSI sidecars, but not nfsplugin, from container-registry.oracle.com/olcne.
  --nfs-csi-sidecar-image-repository-prefix PREFIX
                                  Optional repository prefix for CSI sidecars except nfsplugin.
                                  Example: container-registry.oracle.com/olcne
  --nfs-server-script PATH        Script path. Default: ${NFS_SERVER_SCRIPT}
  --nfs-namespace NAME            NFS server namespace. Default: ${NFS_NAMESPACE}
  --nfs-name NAME                 NFS server Service and Deployment name. Default: ${NFS_NAME}
  --nfs-image IMAGE               NFS server image. Default: ${NFS_IMAGE}
  --nfs-host-path PATH            Node hostPath backing the export. Default: ${NFS_HOST_PATH}
  --nfs-shared-directory PATH     Container export directory. Default: ${NFS_SHARED_DIRECTORY}
  --nfs-service-type TYPE         ClusterIP, LoadBalancer, or NodePort. Default: ${NFS_SERVICE_TYPE}
  --storage-class NAME            StorageClass created by deploy-nfs-server.sh. Default: ${STORAGE_CLASS_NAME}
  --test-namespace NAME           Test namespace. Default: ${TEST_NAMESPACE}
  --test-image IMAGE              Image used by the PVC test Job. Default: ${TEST_IMAGE}
  --keep-test-artifacts           Leave the test namespace after a successful run.
  --node-ready-timeout SECONDS    Node readiness timeout. Default: ${NODE_READY_TIMEOUT_SECONDS}
  --rollout-timeout DURATION      Driver and NFS server rollout timeout. Default: ${ROLLOUT_TIMEOUT}
  --test-timeout SECONDS          PVC and Job timeout. Default: ${TEST_TIMEOUT_SECONDS}
  --help                          Show this help.
USAGE
}

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT

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
      --kubeconfig)
        need_arg "$1" "${2:-}"
        KUBECONFIG_PATH="$2"
        shift 2
        ;;
      --kubeconfig=*)
        KUBECONFIG_PATH="${1#*=}"
        shift
        ;;
      --nfs-csi-version)
        need_arg "$1" "${2:-}"
        NFS_CSI_VERSION="$2"
        shift 2
        ;;
      --nfs-csi-version=*)
        NFS_CSI_VERSION="${1#*=}"
        shift
        ;;
      --nfs-csi-namespace)
        need_arg "$1" "${2:-}"
        NFS_CSI_NAMESPACE="$2"
        shift 2
        ;;
      --nfs-csi-namespace=*)
        NFS_CSI_NAMESPACE="${1#*=}"
        shift
        ;;
      --nfs-csi-release)
        need_arg "$1" "${2:-}"
        NFS_CSI_RELEASE="$2"
        shift 2
        ;;
      --nfs-csi-release=*)
        NFS_CSI_RELEASE="${1#*=}"
        shift
        ;;
      --nfs-csi-nfs-image-repository)
        need_arg "$1" "${2:-}"
        NFS_CSI_NFS_IMAGE_REPOSITORY="$2"
        shift 2
        ;;
      --nfs-csi-nfs-image-repository=*)
        NFS_CSI_NFS_IMAGE_REPOSITORY="${1#*=}"
        shift
        ;;
      --nfs-csi-nfs-image-tag)
        need_arg "$1" "${2:-}"
        NFS_CSI_NFS_IMAGE_TAG="$2"
        shift 2
        ;;
      --nfs-csi-nfs-image-tag=*)
        NFS_CSI_NFS_IMAGE_TAG="${1#*=}"
        shift
        ;;
      --nfs-csi-sidecars-from-container-registry)
        NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX="container-registry.oracle.com/olcne"
        shift
        ;;
      --nfs-csi-sidecar-image-repository-prefix)
        need_arg "$1" "${2:-}"
        NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX="$2"
        shift 2
        ;;
      --nfs-csi-sidecar-image-repository-prefix=*)
        NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX="${1#*=}"
        shift
        ;;
      --nfs-server-script)
        need_arg "$1" "${2:-}"
        NFS_SERVER_SCRIPT="$2"
        shift 2
        ;;
      --nfs-server-script=*)
        NFS_SERVER_SCRIPT="${1#*=}"
        shift
        ;;
      --nfs-namespace)
        need_arg "$1" "${2:-}"
        NFS_NAMESPACE="$2"
        shift 2
        ;;
      --nfs-namespace=*)
        NFS_NAMESPACE="${1#*=}"
        shift
        ;;
      --nfs-name)
        need_arg "$1" "${2:-}"
        NFS_NAME="$2"
        shift 2
        ;;
      --nfs-name=*)
        NFS_NAME="${1#*=}"
        shift
        ;;
      --nfs-image)
        need_arg "$1" "${2:-}"
        NFS_IMAGE="$2"
        shift 2
        ;;
      --nfs-image=*)
        NFS_IMAGE="${1#*=}"
        shift
        ;;
      --nfs-host-path)
        need_arg "$1" "${2:-}"
        NFS_HOST_PATH="$2"
        shift 2
        ;;
      --nfs-host-path=*)
        NFS_HOST_PATH="${1#*=}"
        shift
        ;;
      --nfs-shared-directory)
        need_arg "$1" "${2:-}"
        NFS_SHARED_DIRECTORY="$2"
        shift 2
        ;;
      --nfs-shared-directory=*)
        NFS_SHARED_DIRECTORY="${1#*=}"
        shift
        ;;
      --nfs-service-type)
        need_arg "$1" "${2:-}"
        NFS_SERVICE_TYPE="$2"
        shift 2
        ;;
      --nfs-service-type=*)
        NFS_SERVICE_TYPE="${1#*=}"
        shift
        ;;
      --storage-class)
        need_arg "$1" "${2:-}"
        STORAGE_CLASS_NAME="$2"
        shift 2
        ;;
      --storage-class=*)
        STORAGE_CLASS_NAME="${1#*=}"
        shift
        ;;
      --test-namespace)
        need_arg "$1" "${2:-}"
        TEST_NAMESPACE="$2"
        shift 2
        ;;
      --test-namespace=*)
        TEST_NAMESPACE="${1#*=}"
        shift
        ;;
      --test-image)
        need_arg "$1" "${2:-}"
        TEST_IMAGE="$2"
        shift 2
        ;;
      --test-image=*)
        TEST_IMAGE="${1#*=}"
        shift
        ;;
      --keep-test-artifacts)
        KEEP_TEST_ARTIFACTS="true"
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
      --rollout-timeout)
        need_arg "$1" "${2:-}"
        ROLLOUT_TIMEOUT="$2"
        shift 2
        ;;
      --rollout-timeout=*)
        ROLLOUT_TIMEOUT="${1#*=}"
        shift
        ;;
      --test-timeout)
        need_arg "$1" "${2:-}"
        TEST_TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --test-timeout=*)
        TEST_TIMEOUT_SECONDS="${1#*=}"
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

validate_absolute_path() {
  local field="$1"
  local value="$2"
  validate_no_newline "$field" "$value"
  [[ "$value" == /* ]] || die "${field} must be an absolute path: ${value}"
}

validate_service_type() {
  case "$NFS_SERVICE_TYPE" in
    ClusterIP|LoadBalancer|NodePort)
      ;;
    *)
      die "--nfs-service-type must be ClusterIP, LoadBalancer, or NodePort"
      ;;
  esac
}

validate_inputs() {
  log "Validating script inputs"
  validate_dns_label "candidate catalog" "$CATALOG_NAME"
  validate_integer "--control-plane-nodes" "$CONTROL_PLANE_NODES"
  validate_integer "--worker-nodes" "$WORKER_NODES"
  validate_integer "--node-ready-timeout" "$NODE_READY_TIMEOUT_SECONDS"
  validate_integer "--test-timeout" "$TEST_TIMEOUT_SECONDS"
  (( CONTROL_PLANE_NODES >= 1 )) || die "--control-plane-nodes must be at least 1"
  (( WORKER_NODES >= 1 )) || die "--worker-nodes must be at least 1 so the NFS server and smoke-test pods can schedule"

  validate_no_newline "--kubeconfig" "$KUBECONFIG_PATH"

  validate_no_newline "--nfs-csi-version" "$NFS_CSI_VERSION"
  validate_no_shell_whitespace "--nfs-csi-version" "$NFS_CSI_VERSION"
  validate_dns_label "--nfs-csi-namespace" "$NFS_CSI_NAMESPACE"
  validate_dns_label "--nfs-csi-release" "$NFS_CSI_RELEASE"
  validate_no_newline "--nfs-csi-nfs-image-repository" "$NFS_CSI_NFS_IMAGE_REPOSITORY"
  validate_no_shell_whitespace "--nfs-csi-nfs-image-repository" "$NFS_CSI_NFS_IMAGE_REPOSITORY"
  if [[ -n "$NFS_CSI_NFS_IMAGE_REPOSITORY" && -z "$NFS_CSI_NFS_IMAGE_TAG" && -n "$NFS_CSI_VERSION" ]]; then
    NFS_CSI_NFS_IMAGE_TAG="v${NFS_CSI_VERSION}"
  fi
  validate_no_newline "--nfs-csi-nfs-image-tag" "$NFS_CSI_NFS_IMAGE_TAG"
  validate_no_shell_whitespace "--nfs-csi-nfs-image-tag" "$NFS_CSI_NFS_IMAGE_TAG"
  NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX="${NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX%/}"
  validate_no_newline "--nfs-csi-sidecar-image-repository-prefix" "$NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX"
  validate_no_shell_whitespace "--nfs-csi-sidecar-image-repository-prefix" "$NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX"
  validate_no_newline "--nfs-server-script" "$NFS_SERVER_SCRIPT"
  validate_dns_label "--nfs-namespace" "$NFS_NAMESPACE"
  validate_dns_label "--nfs-name" "$NFS_NAME"
  validate_no_newline "--nfs-image" "$NFS_IMAGE"
  validate_no_shell_whitespace "--nfs-image" "$NFS_IMAGE"
  validate_absolute_path "--nfs-host-path" "$NFS_HOST_PATH"
  validate_absolute_path "--nfs-shared-directory" "$NFS_SHARED_DIRECTORY"
  validate_service_type
  validate_dns_label "--storage-class" "$STORAGE_CLASS_NAME"

  validate_dns_label "--test-namespace" "$TEST_NAMESPACE"
  validate_dns_label "test PVC name" "$TEST_PVC_NAME"
  validate_dns_label "test Job name" "$TEST_JOB_NAME"
  validate_no_newline "--test-image" "$TEST_IMAGE"
  validate_no_shell_whitespace "--test-image" "$TEST_IMAGE"
  validate_no_newline "--rollout-timeout" "$ROLLOUT_TIMEOUT"
  validate_no_shell_whitespace "--rollout-timeout" "$ROLLOUT_TIMEOUT"

}

check_prerequisites() {
  log "Checking local prerequisites"
  command -v "$OCNE_BIN" >/dev/null 2>&1 || die "ocne binary not found: ${OCNE_BIN}"
  command -v "$KUBECTL_BIN" >/dev/null 2>&1 || die "kubectl binary not found: ${KUBECTL_BIN}"
  [[ -x "$NFS_SERVER_SCRIPT" ]] || die "NFS server deployment script is missing or not executable: ${NFS_SERVER_SCRIPT}"
}

catalog_has_version() {
  local chart="$1"
  local version="$2"
  local output

  log "Checking ${CATALOG_NAME} catalog for ${chart} ${version}"
  output="$("$OCNE_BIN" catalog search --name "$CATALOG_NAME" --pattern "^${chart}$")"
  awk -v chart="$chart" -v version="$version" 'NR > 1 && $1 == chart && $2 == version { found = 1 } END { exit found ? 0 : 1 }' <<<"$output"
}

check_catalog_version() {
  if [[ -z "$NFS_CSI_VERSION" ]]; then
    log "No NFS CSI chart version specified; OCNE will use the catalog default"
    return
  fi

  catalog_has_version "csi-driver-nfs" "$NFS_CSI_VERSION" || \
    die "OCNE catalog ${CATALOG_NAME} does not contain csi-driver-nfs ${NFS_CSI_VERSION}"
}

create_nfs_csi_values_file() {
  if [[ -z "$NFS_CSI_NFS_IMAGE_REPOSITORY" && -z "$NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX" ]]; then
    log "No NFS CSI image override requested; using csi-driver-nfs chart defaults"
    return
  fi

  TMP_DIR="$(mktemp -d)"
  NFS_CSI_VALUES_FILE="${TMP_DIR}/csi-driver-nfs-values.yaml"
  log "Writing NFS CSI image override values to ${NFS_CSI_VALUES_FILE}"
  printf 'image:\n' >"$NFS_CSI_VALUES_FILE"

  if [[ -n "$NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX" ]]; then
    log "Configuring CSI sidecar images from ${NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX}; nfsplugin image is unchanged"
    {
      printf '  csiProvisioner:\n'
      printf '    repository: %s/csi-provisioner\n' "$NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX"
      printf '  csiResizer:\n'
      printf '    repository: %s/csi-resizer\n' "$NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX"
      printf '  csiSnapshotter:\n'
      printf '    repository: %s/csi-snapshotter\n' "$NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX"
      printf '  livenessProbe:\n'
      printf '    repository: %s/livenessprobe\n' "$NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX"
      printf '  nodeDriverRegistrar:\n'
      printf '    repository: %s/csi-node-driver-registrar\n' "$NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX"
      printf '  externalSnapshotter:\n'
      printf '    repository: %s/snapshot-controller\n' "$NFS_CSI_SIDECAR_IMAGE_REPOSITORY_PREFIX"
    } >>"$NFS_CSI_VALUES_FILE"
  fi

  if [[ -n "$NFS_CSI_NFS_IMAGE_REPOSITORY" ]]; then
    log "Configuring explicit nfsplugin image override ${NFS_CSI_NFS_IMAGE_REPOSITORY}:${NFS_CSI_NFS_IMAGE_TAG}"
    cat >>"$NFS_CSI_VALUES_FILE" <<EOF_VALUES
  nfs:
    repository: ${NFS_CSI_NFS_IMAGE_REPOSITORY}
    tag: ${NFS_CSI_NFS_IMAGE_TAG}
EOF_VALUES
  fi
}


wait_for_cluster() {
  local expected_nodes=$((CONTROL_PLANE_NODES + WORKER_NODES))
  local deadline=$((SECONDS + NODE_READY_TIMEOUT_SECONDS))
  local count="0"
  local args=()

  log "Waiting for Kubernetes API access"
  run_kubectl version --client=true


  log "Waiting for ${expected_nodes} node(s) to register"
  mapfile -t args < <(kubectl_args)
  while (( SECONDS < deadline )); do
    count="$("$KUBECTL_BIN" "${args[@]}" get nodes --no-headers 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ' || true)"
    if [[ "$count" == "$expected_nodes" ]]; then
      log "Detected ${count}/${expected_nodes} node(s)"
      break
    fi
    log "Detected ${count}/${expected_nodes} node(s); waiting"
    sleep 10
  done

  [[ "$count" == "$expected_nodes" ]] || die "timed out waiting for ${expected_nodes} node(s)"
  run_kubectl wait --for=condition=Ready nodes --all --timeout="${NODE_READY_TIMEOUT_SECONDS}s"
}

release_installed() {
  run_ocne application show --namespace "$NFS_CSI_NAMESPACE" --release "$NFS_CSI_RELEASE" >/dev/null 2>&1
}

install_nfs_csi_driver() {
  if release_installed; then
    log "OCNE application ${NFS_CSI_NAMESPACE}/${NFS_CSI_RELEASE} is already installed; updating to requested version"
    local update_args=(
      application update
      --catalog "$CATALOG_NAME"
      --release "$NFS_CSI_RELEASE"
      --namespace "$NFS_CSI_NAMESPACE"
      --reset-values
    )
    if [[ -n "$NFS_CSI_VERSION" ]]; then
      update_args+=(--version "$NFS_CSI_VERSION")
    fi
    if [[ -n "$NFS_CSI_VALUES_FILE" ]]; then
      update_args+=(--values "$NFS_CSI_VALUES_FILE")
    fi

    run_ocne "${update_args[@]}"
    return
  fi

  log "Installing csi-driver-nfs through the OCNE CLI"
  local args=(
    application install
    --catalog "$CATALOG_NAME"
    --name csi-driver-nfs
    --release "$NFS_CSI_RELEASE"
    --namespace "$NFS_CSI_NAMESPACE"
  )
  if [[ -n "$NFS_CSI_VERSION" ]]; then
    args+=(--version "$NFS_CSI_VERSION")
  fi
  if [[ -n "$NFS_CSI_VALUES_FILE" ]]; then
    args+=(--values "$NFS_CSI_VALUES_FILE")
  fi

  run_ocne "${args[@]}"
}

wait_for_nfs_csi_driver() {
  log "Waiting for CSIDriver nfs.csi.k8s.io"
  local deadline=$((SECONDS + TEST_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if kubectl_quiet get csidriver nfs.csi.k8s.io; then
      log "CSIDriver nfs.csi.k8s.io is present"
      break
    fi
    log "CSIDriver nfs.csi.k8s.io is not present yet; waiting"
    sleep 5
  done

  kubectl_quiet get csidriver nfs.csi.k8s.io || die "timed out waiting for CSIDriver nfs.csi.k8s.io"
  log "Waiting for csi-driver-nfs controller rollout"
  run_kubectl -n "$NFS_CSI_NAMESPACE" rollout status deployment/csi-nfs-controller --timeout "$ROLLOUT_TIMEOUT"
  log "Waiting for csi-driver-nfs node rollout"
  run_kubectl -n "$NFS_CSI_NAMESPACE" rollout status daemonset/csi-nfs-node --timeout "$ROLLOUT_TIMEOUT"
}

deploy_nfs_server() {
  log "Deploying the NFS server by invoking ${NFS_SERVER_SCRIPT}"
  local args=(
    --namespace "$NFS_NAMESPACE"
    --name "$NFS_NAME"
    --image "$NFS_IMAGE"
    --host-path "$NFS_HOST_PATH"
    --shared-directory "$NFS_SHARED_DIRECTORY"
    --service-type "$NFS_SERVICE_TYPE"
    --storage-class "$STORAGE_CLASS_NAME"
    --rollout-timeout "$ROLLOUT_TIMEOUT"
  )
  if [[ -n "$KUBECONFIG_PATH" ]]; then
    args=(--kubeconfig "$KUBECONFIG_PATH" "${args[@]}")
  fi

  run "$NFS_SERVER_SCRIPT" "${args[@]}"
}

render_smoke_test_manifest() {
  cat <<MANIFEST
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${TEST_NAMESPACE}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${TEST_PVC_NAME}
  namespace: ${TEST_NAMESPACE}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ${STORAGE_CLASS_NAME}
  resources:
    requests:
      storage: 1Mi
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ${TEST_JOB_NAME}
  namespace: ${TEST_NAMESPACE}
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: ${TEST_JOB_NAME}
    spec:
      restartPolicy: Never
      containers:
        - name: smoke
          image: ${TEST_IMAGE}
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              echo "starting NFS CSI smoke test"
              echo "cluster=${CLUSTER_NAME}" > /mnt/nfs/ocne-nfs-csi-test.txt
              echo "storageClass=${STORAGE_CLASS_NAME}" >> /mnt/nfs/ocne-nfs-csi-test.txt
              echo "reading test file"
              cat /mnt/nfs/ocne-nfs-csi-test.txt
              grep -q "cluster=${CLUSTER_NAME}" /mnt/nfs/ocne-nfs-csi-test.txt
              grep -q "storageClass=${STORAGE_CLASS_NAME}" /mnt/nfs/ocne-nfs-csi-test.txt
              echo "NFS CSI smoke test passed"
          volumeMounts:
            - name: nfs-volume
              mountPath: /mnt/nfs
      volumes:
        - name: nfs-volume
          persistentVolumeClaim:
            claimName: ${TEST_PVC_NAME}
MANIFEST
}

apply_smoke_test_manifest() {
  if kubectl_quiet get namespace "$TEST_NAMESPACE"; then
    log "Deleting any existing smoke-test Job ${TEST_NAMESPACE}/${TEST_JOB_NAME} before applying the current test manifest"
    run_kubectl -n "$TEST_NAMESPACE" delete job "$TEST_JOB_NAME" --ignore-not-found=true
    run_kubectl -n "$TEST_NAMESPACE" wait --for=delete "job/${TEST_JOB_NAME}" --timeout="${TEST_TIMEOUT_SECONDS}s" || true
    log "Deleting any existing smoke-test PVC ${TEST_NAMESPACE}/${TEST_PVC_NAME} before applying the current test manifest"
    run_kubectl -n "$TEST_NAMESPACE" delete pvc "$TEST_PVC_NAME" --ignore-not-found=true
    run_kubectl -n "$TEST_NAMESPACE" wait --for=delete "pvc/${TEST_PVC_NAME}" --timeout="${TEST_TIMEOUT_SECONDS}s" || true
  fi

  log "Applying NFS CSI smoke-test namespace, PVC, and Job"
  render_smoke_test_manifest | run_kubectl apply -f -
}

wait_for_pvc_bound() {
  local deadline=$((SECONDS + TEST_TIMEOUT_SECONDS))
  local phase=""
  local args=()

  log "Waiting for PVC ${TEST_NAMESPACE}/${TEST_PVC_NAME} to bind"
  mapfile -t args < <(kubectl_args)
  while (( SECONDS < deadline )); do
    phase="$("$KUBECTL_BIN" "${args[@]}" -n "$TEST_NAMESPACE" get pvc "$TEST_PVC_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$phase" == "Bound" ]]; then
      log "PVC ${TEST_NAMESPACE}/${TEST_PVC_NAME} is Bound"
      return
    fi
    log "PVC ${TEST_NAMESPACE}/${TEST_PVC_NAME} phase is ${phase:-<missing>}; waiting"
    sleep 5
  done

  log "PVC did not bind before timeout; describing PVC for diagnostics"
  run_kubectl -n "$TEST_NAMESPACE" describe pvc "$TEST_PVC_NAME" || true
  die "timed out waiting for PVC ${TEST_NAMESPACE}/${TEST_PVC_NAME} to bind"
}

diagnose_job_failure() {
  log "Collecting smoke-test diagnostics"
  run_kubectl -n "$TEST_NAMESPACE" get pvc,pv,pod,job -o wide || true
  run_kubectl -n "$TEST_NAMESPACE" describe job "$TEST_JOB_NAME" || true
  run_kubectl -n "$TEST_NAMESPACE" describe pods -l "app=${TEST_JOB_NAME}" || true
  run_kubectl -n "$TEST_NAMESPACE" logs "job/${TEST_JOB_NAME}" --all-containers=true || true
}

wait_for_smoke_test_job() {
  log "Waiting for Job ${TEST_NAMESPACE}/${TEST_JOB_NAME} to complete"
  if ! run_kubectl -n "$TEST_NAMESPACE" wait --for=condition=complete "job/${TEST_JOB_NAME}" --timeout="${TEST_TIMEOUT_SECONDS}s"; then
    diagnose_job_failure
    die "NFS CSI smoke-test Job did not complete successfully"
  fi

  log "Smoke-test Job completed; logs follow"
  run_kubectl -n "$TEST_NAMESPACE" logs "job/${TEST_JOB_NAME}" --all-containers=true
}

cleanup_test_artifacts() {
  if [[ "$KEEP_TEST_ARTIFACTS" == "true" ]]; then
    log "Keeping test namespace ${TEST_NAMESPACE} by request"
    return
  fi

  log "Deleting test namespace ${TEST_NAMESPACE}"
  run_kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found=true
}

print_summary() {
  log "NFS CSI cluster test completed"
  log "Cluster name: ${CLUSTER_NAME}"
  if [[ -n "$KUBECONFIG_PATH" ]]; then
    log "Kubeconfig: ${KUBECONFIG_PATH}"
  else
    log "Kubeconfig: kubectl current context"
  fi
  log "CSI driver release: ${NFS_CSI_NAMESPACE}/${NFS_CSI_RELEASE}"
  log "NFS server service: ${NFS_NAME}.${NFS_NAMESPACE}.svc.cluster.local"
  log "StorageClass: ${STORAGE_CLASS_NAME}"
}

main() {
  log "Starting NFS CSI cluster test script"
  parse_args "$@"
  [[ -n "$CATALOG_NAME" ]] || die "Run tests/run-changed.sh to build and register this checkout catalog"
  log "Using an externally provisioned cluster; cluster lifecycle belongs to the caller"
  [[ -n "$KUBECONFIG_PATH" && -s "$KUBECONFIG_PATH" ]] || die "Supply an existing kubeconfig with --kubeconfig or KUBECONFIG"
  validate_inputs
  check_prerequisites
  check_catalog_version
  create_nfs_csi_values_file
  wait_for_cluster
  install_nfs_csi_driver
  wait_for_nfs_csi_driver
  deploy_nfs_server
  apply_smoke_test_manifest
  wait_for_pvc_bound
  wait_for_smoke_test_job
  cleanup_test_artifacts
  print_summary
}

main "$@"
