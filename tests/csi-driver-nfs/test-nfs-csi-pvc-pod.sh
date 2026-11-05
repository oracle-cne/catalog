#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
KUBECONFIG_PATH="${KUBECONFIG:-}"
TEST_NAMESPACE="nfs-csi-pod-test"
STORAGE_CLASS_NAME="nfs-csi"
PVC_NAME="nfs-csi-pod-pvc"
POD_NAME="nfs-csi-pod"
POD_IMAGE="${POD_IMAGE:-registry.k8s.io/volume-nfs:0.8}"
PVC_SIZE="1Mi"
MOUNT_PATH="/mnt/nfs"
HOLD_SECONDS="3600"
WAIT_TIMEOUT_SECONDS="300"
DRY_RUN="false"
CLEANUP_AFTER="false"
REPLACE_EXISTING="false"

usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_NAME} [options]

Deploys a PersistentVolumeClaim and a Pod that mounts it through the NFS CSI
StorageClass. The Pod writes and reads a marker file on the mounted volume,
then sleeps so the mounted PVC remains available for inspection.

Options:
  --kubeconfig PATH          Kubeconfig path. Default: KUBECONFIG env or kubectl default.
  --namespace NAME           Test namespace. Default: ${TEST_NAMESPACE}
  --storage-class NAME       StorageClass to use. Default: ${STORAGE_CLASS_NAME}
  --pvc-name NAME            PVC name. Default: ${PVC_NAME}
  --pod-name NAME            Pod name. Default: ${POD_NAME}
  --image IMAGE              Test Pod image. Default: ${POD_IMAGE}
  --pvc-size SIZE            PVC request size. Default: ${PVC_SIZE}
  --mount-path PATH          Container mount path. Default: ${MOUNT_PATH}
  --hold-seconds SECONDS     Seconds the Pod sleeps after the write/read test. Default: ${HOLD_SECONDS}
  --wait-timeout SECONDS     PVC and Pod wait timeout. Default: ${WAIT_TIMEOUT_SECONDS}
  --replace-existing         Delete an existing Pod with the same name before applying.
  --cleanup                  Delete the test Pod and PVC after a successful check.
  --dry-run                  Print the generated Kubernetes manifests and exit.
  --help                     Show this help.

Environment:
  KUBECTL_BIN                kubectl executable. Default: kubectl
  KUBECONFIG                 Kubeconfig path when --kubeconfig is omitted.
  POD_IMAGE                  Default test Pod image.

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --kubeconfig ~/.kube/config
  ${SCRIPT_NAME} --namespace nfs-test --storage-class nfs-csi
  ${SCRIPT_NAME} --replace-existing --hold-seconds 600
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
        TEST_NAMESPACE="$2"
        shift 2
        ;;
      --namespace=*)
        TEST_NAMESPACE="${1#*=}"
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
      --pvc-name)
        need_arg "$1" "${2:-}"
        PVC_NAME="$2"
        shift 2
        ;;
      --pvc-name=*)
        PVC_NAME="${1#*=}"
        shift
        ;;
      --pod-name)
        need_arg "$1" "${2:-}"
        POD_NAME="$2"
        shift 2
        ;;
      --pod-name=*)
        POD_NAME="${1#*=}"
        shift
        ;;
      --image)
        need_arg "$1" "${2:-}"
        POD_IMAGE="$2"
        shift 2
        ;;
      --image=*)
        POD_IMAGE="${1#*=}"
        shift
        ;;
      --pvc-size)
        need_arg "$1" "${2:-}"
        PVC_SIZE="$2"
        shift 2
        ;;
      --pvc-size=*)
        PVC_SIZE="${1#*=}"
        shift
        ;;
      --mount-path)
        need_arg "$1" "${2:-}"
        MOUNT_PATH="$2"
        shift 2
        ;;
      --mount-path=*)
        MOUNT_PATH="${1#*=}"
        shift
        ;;
      --hold-seconds)
        need_arg "$1" "${2:-}"
        HOLD_SECONDS="$2"
        shift 2
        ;;
      --hold-seconds=*)
        HOLD_SECONDS="${1#*=}"
        shift
        ;;
      --wait-timeout)
        need_arg "$1" "${2:-}"
        WAIT_TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --wait-timeout=*)
        WAIT_TIMEOUT_SECONDS="${1#*=}"
        shift
        ;;
      --replace-existing)
        REPLACE_EXISTING="true"
        shift
        ;;
      --cleanup)
        CLEANUP_AFTER="true"
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

validate_inputs() {
  log "Validating test inputs"
  validate_no_newline "--kubeconfig" "$KUBECONFIG_PATH"
  validate_dns_label "--namespace" "$TEST_NAMESPACE"
  validate_dns_label "--storage-class" "$STORAGE_CLASS_NAME"
  validate_dns_label "--pvc-name" "$PVC_NAME"
  validate_dns_label "--pod-name" "$POD_NAME"
  validate_no_newline "--image" "$POD_IMAGE"
  validate_no_shell_whitespace "--image" "$POD_IMAGE"
  validate_no_newline "--pvc-size" "$PVC_SIZE"
  validate_no_shell_whitespace "--pvc-size" "$PVC_SIZE"
  validate_absolute_path "--mount-path" "$MOUNT_PATH"
  validate_no_shell_whitespace "--mount-path" "$MOUNT_PATH"
  validate_integer "--hold-seconds" "$HOLD_SECONDS"
  validate_integer "--wait-timeout" "$WAIT_TIMEOUT_SECONDS"
}

yaml_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

marker_file() {
  printf '%s/ocne-nfs-csi-pvc-pod-test.txt' "$MOUNT_PATH"
}

render_manifest() {
  local image_yaml
  local pvc_size_yaml
  local mount_path_yaml
  local hold_seconds_yaml
  local storage_class_yaml
  local marker_file_yaml

  image_yaml="$(yaml_quote "$POD_IMAGE")"
  pvc_size_yaml="$(yaml_quote "$PVC_SIZE")"
  mount_path_yaml="$(yaml_quote "$MOUNT_PATH")"
  hold_seconds_yaml="$(yaml_quote "$HOLD_SECONDS")"
  storage_class_yaml="$(yaml_quote "$STORAGE_CLASS_NAME")"
  marker_file_yaml="$(yaml_quote "$(marker_file)")"

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
  name: ${PVC_NAME}
  namespace: ${TEST_NAMESPACE}
  labels:
    app.kubernetes.io/name: ${POD_NAME}
    app.kubernetes.io/component: nfs-csi-pvc-test
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ${STORAGE_CLASS_NAME}
  resources:
    requests:
      storage: ${pvc_size_yaml}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${TEST_NAMESPACE}
  labels:
    app: ${POD_NAME}
    app.kubernetes.io/name: ${POD_NAME}
    app.kubernetes.io/component: nfs-csi-pvc-test
spec:
  restartPolicy: Never
  containers:
    - name: pvc-check
      image: ${image_yaml}
      env:
        - name: STORAGE_CLASS_NAME
          value: ${storage_class_yaml}
        - name: MOUNT_PATH
          value: ${mount_path_yaml}
        - name: MARKER_FILE
          value: ${marker_file_yaml}
        - name: HOLD_SECONDS
          value: ${hold_seconds_yaml}
      command:
        - /bin/sh
        - -c
        - |
          set -eu
          echo "starting NFS CSI PVC Pod test"
          echo "checking mounted directory at \${MOUNT_PATH}"
          test -d "\${MOUNT_PATH}"
          echo "writing marker file to \${MARKER_FILE}"
          {
            echo "storageClass=\${STORAGE_CLASS_NAME}"
            echo "pod=${POD_NAME}"
            echo "namespace=${TEST_NAMESPACE}"
            date -u '+timestamp=%Y-%m-%dT%H:%M:%SZ'
          } > "\${MARKER_FILE}"
          echo "reading marker file from \${MARKER_FILE}"
          cat "\${MARKER_FILE}"
          grep -q "storageClass=\${STORAGE_CLASS_NAME}" "\${MARKER_FILE}"
          grep -q "pod=${POD_NAME}" "\${MARKER_FILE}"
          echo "NFS CSI PVC Pod test passed"
          echo "sleeping for \${HOLD_SECONDS} seconds so the mounted PVC can be inspected"
          sleep "\${HOLD_SECONDS}"
      volumeMounts:
        - name: nfs-csi-volume
          mountPath: ${mount_path_yaml}
  volumes:
    - name: nfs-csi-volume
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
MANIFEST
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

check_storage_class() {
  log "Checking StorageClass ${STORAGE_CLASS_NAME}"
  kubectl_quiet get storageclass "$STORAGE_CLASS_NAME" || \
    die "StorageClass ${STORAGE_CLASS_NAME} was not found"
}

replace_existing_pod() {
  if [[ "$REPLACE_EXISTING" != "true" ]]; then
    return
  fi

  log "Deleting existing Pod ${TEST_NAMESPACE}/${POD_NAME} before applying replacement"
  run_kubectl -n "$TEST_NAMESPACE" delete pod "$POD_NAME" --ignore-not-found=true
}

apply_manifest() {
  log "Applying namespace, PVC, and Pod manifests"
  render_manifest | run_kubectl apply -f -
}

wait_for_pvc_bound() {
  local deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
  local phase=""
  local args=()

  log "Waiting for PVC ${TEST_NAMESPACE}/${PVC_NAME} to bind"
  mapfile -t args < <(kubectl_args)
  while (( SECONDS < deadline )); do
    phase="$("$KUBECTL_BIN" "${args[@]}" -n "$TEST_NAMESPACE" get pvc "$PVC_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$phase" == "Bound" ]]; then
      log "PVC ${TEST_NAMESPACE}/${PVC_NAME} is Bound"
      return
    fi
    log "PVC ${TEST_NAMESPACE}/${PVC_NAME} phase is ${phase:-<missing>}; waiting"
    sleep 5
  done

  log "PVC did not bind before timeout; describing PVC"
  run_kubectl -n "$TEST_NAMESPACE" describe pvc "$PVC_NAME" || true
  die "timed out waiting for PVC ${TEST_NAMESPACE}/${PVC_NAME} to bind"
}

diagnose_pod_failure() {
  log "Collecting Pod diagnostics"
  run_kubectl -n "$TEST_NAMESPACE" get pvc,pv,pod -o wide || true
  run_kubectl -n "$TEST_NAMESPACE" describe pvc "$PVC_NAME" || true
  run_kubectl -n "$TEST_NAMESPACE" describe pod "$POD_NAME" || true
  run_kubectl -n "$TEST_NAMESPACE" logs "$POD_NAME" --all-containers=true || true
}

wait_for_pod_ready() {
  log "Waiting for Pod ${TEST_NAMESPACE}/${POD_NAME} to become Ready"
  if ! run_kubectl -n "$TEST_NAMESPACE" wait --for=condition=Ready "pod/${POD_NAME}" --timeout="${WAIT_TIMEOUT_SECONDS}s"; then
    diagnose_pod_failure
    die "Pod ${TEST_NAMESPACE}/${POD_NAME} did not become Ready"
  fi

  log "Pod ${TEST_NAMESPACE}/${POD_NAME} is Ready; startup logs follow"
  run_kubectl -n "$TEST_NAMESPACE" logs "$POD_NAME" --all-containers=true --tail=50
}

cleanup_after_success() {
  if [[ "$CLEANUP_AFTER" != "true" ]]; then
    log "Leaving Pod ${TEST_NAMESPACE}/${POD_NAME} and PVC ${TEST_NAMESPACE}/${PVC_NAME} in place"
    return
  fi

  log "Deleting test Pod and PVC after successful verification"
  run_kubectl -n "$TEST_NAMESPACE" delete pod "$POD_NAME" --ignore-not-found=true
  run_kubectl -n "$TEST_NAMESPACE" delete pvc "$PVC_NAME" --ignore-not-found=true
}

print_summary() {
  log "NFS CSI PVC Pod test deployment complete"
  log "Namespace: ${TEST_NAMESPACE}"
  log "StorageClass: ${STORAGE_CLASS_NAME}"
  log "PVC: ${PVC_NAME}"
  log "Pod: ${POD_NAME}"
  log "Mount path: ${MOUNT_PATH}"
}

main() {
  log "Starting NFS CSI PVC Pod test script"
  parse_args "$@"
  validate_inputs

  if [[ "$DRY_RUN" == "true" ]]; then
    log "Dry run requested; generated manifests follow"
    render_manifest
    log "Dry run complete; no Kubernetes changes were made"
    exit 0
  fi

  check_prerequisites
  check_cluster_access
  check_storage_class
  replace_existing_pod
  apply_manifest
  wait_for_pvc_bound
  wait_for_pod_ready
  cleanup_after_success
  print_summary
}

main "$@"
