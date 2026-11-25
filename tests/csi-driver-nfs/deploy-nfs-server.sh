#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
KUBECONFIG_PATH="${KUBECONFIG:-}"
NFS_NAMESPACE="${NFS_NAMESPACE:-default}"
NFS_NAME="${NFS_NAME:-nfs-server}"
NFS_IMAGE="${NFS_IMAGE:-registry.k8s.io/volume-nfs:0.8}"
NFS_HOST_PATH="${NFS_HOST_PATH:-/var/lib/nfs-vol}"
NFS_SHARED_DIRECTORY="${NFS_SHARED_DIRECTORY:-/exports}"
NFS_SERVICE_TYPE="${NFS_SERVICE_TYPE:-ClusterIP}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
STORAGE_CLASS_NAME=""
SKIP_WAIT="false"
DRY_RUN="false"

usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_NAME} [options]

Deploys an example NFS server into an existing Kubernetes cluster using the
same server shape documented by kubernetes-csi/csi-driver-nfs:
  service:    nfs-server.<namespace>.svc.cluster.local
  share path: /

Options:
  --kubeconfig PATH              Kubeconfig path. Default: KUBECONFIG env or kubectl default.
  --namespace NAME               Namespace for the NFS server. Default: ${NFS_NAMESPACE}
  --name NAME                    Service and Deployment name. Default: ${NFS_NAME}
  --image IMAGE                  NFS server image. Default: ${NFS_IMAGE}
  --host-path PATH               Node hostPath backing the export. Default: ${NFS_HOST_PATH}
  --shared-directory PATH        Container export directory. Default: ${NFS_SHARED_DIRECTORY}
  --service-type TYPE            ClusterIP, LoadBalancer, or NodePort. Default: ${NFS_SERVICE_TYPE}
  --storage-class NAME           Also create a StorageClass for nfs.csi.k8s.io.
  --rollout-timeout DURATION     kubectl rollout timeout. Default: ${ROLLOUT_TIMEOUT}
  --skip-wait                    Apply resources without waiting for rollout.
  --dry-run                      Print the generated Kubernetes manifests and exit.
  --help                         Show this help.

Environment:
  KUBECTL_BIN                    kubectl executable. Default: kubectl
  KUBECONFIG                     Kubeconfig path when --kubeconfig is omitted.
  NFS_NAMESPACE                  Namespace default.
  NFS_NAME                       Service and Deployment name default.
  NFS_IMAGE                      NFS server image default.
  NFS_HOST_PATH                  hostPath default.
  NFS_SHARED_DIRECTORY           Export directory default.
  NFS_SERVICE_TYPE               Service type default.
  ROLLOUT_TIMEOUT                Rollout timeout default.

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --kubeconfig ~/.kube/config --namespace storage
  ${SCRIPT_NAME} --host-path /srv/nfs --service-type LoadBalancer
  ${SCRIPT_NAME} --storage-class nfs-csi
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
        NFS_NAMESPACE="$2"
        shift 2
        ;;
      --namespace=*)
        NFS_NAMESPACE="${1#*=}"
        shift
        ;;
      --name)
        need_arg "$1" "${2:-}"
        NFS_NAME="$2"
        shift 2
        ;;
      --name=*)
        NFS_NAME="${1#*=}"
        shift
        ;;
      --image)
        need_arg "$1" "${2:-}"
        NFS_IMAGE="$2"
        shift 2
        ;;
      --image=*)
        NFS_IMAGE="${1#*=}"
        shift
        ;;
      --host-path)
        need_arg "$1" "${2:-}"
        NFS_HOST_PATH="$2"
        shift 2
        ;;
      --host-path=*)
        NFS_HOST_PATH="${1#*=}"
        shift
        ;;
      --shared-directory)
        need_arg "$1" "${2:-}"
        NFS_SHARED_DIRECTORY="$2"
        shift 2
        ;;
      --shared-directory=*)
        NFS_SHARED_DIRECTORY="${1#*=}"
        shift
        ;;
      --service-type)
        need_arg "$1" "${2:-}"
        NFS_SERVICE_TYPE="$2"
        shift 2
        ;;
      --service-type=*)
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
      --rollout-timeout)
        need_arg "$1" "${2:-}"
        ROLLOUT_TIMEOUT="$2"
        shift 2
        ;;
      --rollout-timeout=*)
        ROLLOUT_TIMEOUT="${1#*=}"
        shift
        ;;
      --skip-wait)
        SKIP_WAIT="true"
        shift
        ;;
      --dry-run)
        DRY_RUN="true"
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
      die "--service-type must be ClusterIP, LoadBalancer, or NodePort"
      ;;
  esac
}

validate_inputs() {
  log "Validating deployment inputs"
  validate_no_newline "--kubeconfig" "$KUBECONFIG_PATH"
  validate_dns_label "--namespace" "$NFS_NAMESPACE"
  validate_dns_label "--name" "$NFS_NAME"
  validate_no_newline "--image" "$NFS_IMAGE"
  validate_no_shell_whitespace "--image" "$NFS_IMAGE"
  validate_absolute_path "--host-path" "$NFS_HOST_PATH"
  validate_absolute_path "--shared-directory" "$NFS_SHARED_DIRECTORY"
  validate_no_newline "--rollout-timeout" "$ROLLOUT_TIMEOUT"
  validate_no_shell_whitespace "--rollout-timeout" "$ROLLOUT_TIMEOUT"
  validate_service_type
  if [[ -n "$STORAGE_CLASS_NAME" ]]; then
    validate_dns_label "--storage-class" "$STORAGE_CLASS_NAME"
  fi
}

yaml_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

nfs_server_dns() {
  printf '%s.%s.svc.cluster.local' "$NFS_NAME" "$NFS_NAMESPACE"
}

render_nfs_manifest() {
  local image_yaml
  local host_path_yaml
  local shared_directory_yaml

  image_yaml="$(yaml_quote "$NFS_IMAGE")"
  host_path_yaml="$(yaml_quote "$NFS_HOST_PATH")"
  shared_directory_yaml="$(yaml_quote "$NFS_SHARED_DIRECTORY")"

  cat <<MANIFEST
---
apiVersion: v1
kind: Service
metadata:
  name: ${NFS_NAME}
  namespace: ${NFS_NAMESPACE}
  labels:
    app: ${NFS_NAME}
    app.kubernetes.io/name: ${NFS_NAME}
    app.kubernetes.io/component: nfs-server
spec:
  type: ${NFS_SERVICE_TYPE}
  selector:
    app: ${NFS_NAME}
  ports:
    - name: tcp-2049
      port: 2049
      targetPort: 2049
      protocol: TCP
    - name: udp-111
      port: 111
      targetPort: 111
      protocol: UDP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${NFS_NAME}
  namespace: ${NFS_NAMESPACE}
  labels:
    app: ${NFS_NAME}
    app.kubernetes.io/name: ${NFS_NAME}
    app.kubernetes.io/component: nfs-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${NFS_NAME}
  template:
    metadata:
      labels:
        app: ${NFS_NAME}
        app.kubernetes.io/name: ${NFS_NAME}
        app.kubernetes.io/component: nfs-server
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      containers:
        - name: nfs-server
          image: ${image_yaml}
          env:
            - name: SHARED_DIRECTORY
              value: ${shared_directory_yaml}
          volumeMounts:
            - mountPath: ${shared_directory_yaml}
              name: nfs-vol
          securityContext:
            privileged: true
          ports:
            - name: tcp-2049
              containerPort: 2049
              protocol: TCP
            - name: udp-111
              containerPort: 111
              protocol: UDP
      volumes:
        - name: nfs-vol
          hostPath:
            path: ${host_path_yaml}
            type: DirectoryOrCreate
MANIFEST
}

render_storage_class_manifest() {
  local server_yaml
  server_yaml="$(yaml_quote "$(nfs_server_dns)")"

  cat <<MANIFEST
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS_NAME}
provisioner: nfs.csi.k8s.io
parameters:
  server: ${server_yaml}
  share: "/"
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - nfsvers=4.1
MANIFEST
}

render_all_manifests() {
  render_nfs_manifest
  if [[ -n "$STORAGE_CLASS_NAME" ]]; then
    render_storage_class_manifest
  fi
}

check_prerequisites() {
  log "Checking local prerequisites"
  command -v "$KUBECTL_BIN" >/dev/null 2>&1 || die "kubectl executable not found: ${KUBECTL_BIN}"
}

check_cluster_access() {
  log "Checking Kubernetes cluster access"
  run_kubectl version --client=true
  run_kubectl cluster-info
}

ensure_namespace() {
  log "Ensuring namespace ${NFS_NAMESPACE} exists"
  if kubectl_quiet get namespace "$NFS_NAMESPACE"; then
    log "Namespace ${NFS_NAMESPACE} already exists"
    return
  fi
  run_kubectl create namespace "$NFS_NAMESPACE"
}

check_nfs_csi_driver() {
  if [[ -z "$STORAGE_CLASS_NAME" ]]; then
    log "Skipping NFS CSI driver check because no StorageClass was requested"
    return
  fi

  log "Checking for CSIDriver nfs.csi.k8s.io before creating StorageClass ${STORAGE_CLASS_NAME}"
  kubectl_quiet get csidriver nfs.csi.k8s.io || \
    die "CSIDriver nfs.csi.k8s.io is not installed; install the Kubernetes CSI NFS driver before using --storage-class"
}

apply_manifests() {
  log "Applying NFS server manifests"
  render_all_manifests | run_kubectl apply -f -
}

wait_for_rollout() {
  if [[ "$SKIP_WAIT" == "true" ]]; then
    log "Skipping rollout wait by request"
    return
  fi

  log "Waiting for Deployment ${NFS_NAMESPACE}/${NFS_NAME} rollout"
  run_kubectl -n "$NFS_NAMESPACE" rollout status "deployment/${NFS_NAME}" --timeout "$ROLLOUT_TIMEOUT"
}

print_summary() {
  log "Deployment complete"
  log "NFS service DNS: $(nfs_server_dns)"
  log "NFS share path: /"
  log "Backing hostPath: ${NFS_HOST_PATH}"
  if [[ -n "$STORAGE_CLASS_NAME" ]]; then
    log "StorageClass: ${STORAGE_CLASS_NAME}"
  else
    log "StorageClass creation skipped; pass --storage-class NAME when nfs.csi.k8s.io is installed"
  fi
}

main() {
  log "Starting NFS server deployment script"
  parse_args "$@"
  validate_inputs

  if [[ "$DRY_RUN" == "true" ]]; then
    log "Dry run requested; generated manifests follow"
    render_all_manifests
    log "Dry run complete; no Kubernetes changes were made"
    exit 0
  fi

  check_prerequisites
  check_cluster_access
  ensure_namespace
  check_nfs_csi_driver
  apply_manifests
  wait_for_rollout
  print_summary
}

main "$@"
