#!/usr/bin/env bash
# Copyright (c) 2026, Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at
# https://oss.oracle.com/licenses/upl.

# Exercise the Rook-Ceph quickstart data plane after the Rook operator has
# been installed. The script deliberately uses separate test resource names,
# so it can run without modifying an existing application CephCluster.
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
KUBECONFIG_PATH=""
ROOK_NAMESPACE="rook-ceph"
CLUSTER_NAME="rook-ceph-core-test"
TEST_NAMESPACE="rook-ceph-core-test"
CEPH_IMAGE="${CEPH_IMAGE:-olcne/ceph:v19.2.5}"
CEPH_DEVICE="${CEPH_DEVICE:-sda4}"
TEST_IMAGE="${TEST_IMAGE:-container-registry.oracle.com/os/oraclelinux:8}"
AWS_CLI_IMAGE="${AWS_CLI_IMAGE:-public.ecr.aws/aws-cli/aws-cli:2.27.41}"
TIMEOUT_SECONDS="1800"
KEEP_TEST_ARTIFACTS="true"

BLOCK_POOL_NAME="core-test-rbd"
BLOCK_STORAGE_CLASS="core-test-rbd"
BLOCK_PVC_NAME="core-test-rbd"
BLOCK_JOB_NAME="core-test-rbd"
BLOCK_POD_NAME="core-test-rbd-consumer"
FILESYSTEM_NAME="core-test-cephfs"
FILESYSTEM_STORAGE_CLASS="core-test-cephfs"
FILESYSTEM_PVC_NAME="core-test-cephfs"
FILESYSTEM_WRITER_JOB_NAME="core-test-cephfs-writer"
FILESYSTEM_READER_JOB_NAME="core-test-cephfs-reader"
FILESYSTEM_POD_NAME="core-test-cephfs-consumer"
OBJECT_STORE_NAME="core-test-object"
OBJECT_USER_NAME="core-test-user"
OBJECT_JOB_NAME="core-test-object"

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} [options]

Creates a test CephCluster and exercises RBD block, CephFS shared filesystem,
and RGW S3 object storage. The Rook operator must already be installed.
The test uses three-way replicated pools, so three worker nodes with raw,
unformatted storage devices available to Rook are required.

  --kubeconfig PATH              Kubeconfig to use. Default: current context.
  --rook-namespace NAME          Rook operator namespace. Default: ${ROOK_NAMESPACE}
  --cluster-name NAME            Test CephCluster name. Default: ${CLUSTER_NAME}
  --test-namespace NAME          Namespace for workload Jobs. Default: ${TEST_NAMESPACE}
  --ceph-image IMAGE             Ceph image for CephCluster. Default: ${CEPH_IMAGE}
  --ceph-device DEVICE           Dedicated host device for Ceph OSDs. Default: ${CEPH_DEVICE}
  --test-image IMAGE             Image for block and CephFS Jobs. Default: ${TEST_IMAGE}
  --aws-cli-image IMAGE          Image for S3 Job. Default: ${AWS_CLI_IMAGE}
  --timeout SECONDS              Per-readiness wait timeout. Default: ${TIMEOUT_SECONDS}
  --cleanup-test-artifacts       Delete workload Jobs, PVCs, and test namespace on success.
  --keep-test-artifacts          Preserve workload artifacts on success (default).
  --help                         Show this help.

Examples:
  ${SCRIPT_NAME} --kubeconfig ~/.kube/kubeconfig.ocne-rook.local
  ${SCRIPT_NAME} --cleanup-test-artifacts
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
  [[ -z "$KUBECONFIG_PATH" ]] || printf '%s\n' --kubeconfig "$KUBECONFIG_PATH"
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
  [[ -n "${2:-}" ]] || die "$1 requires a value"
}

validate_dns_label() {
  [[ "$2" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#2} -le 63 ]] || \
    die "$1 must be a Kubernetes DNS label: $2"
}

validate_positive_integer() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive integer: $2"
}

validate_single_line() {
  [[ "$2" != *$'\n'* && "$2" != *$'\r'* ]] || die "$1 must be one line"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kubeconfig) need_arg "$1" "${2:-}"; KUBECONFIG_PATH="$2"; shift 2 ;;
      --kubeconfig=*) KUBECONFIG_PATH="${1#*=}"; shift ;;
      --rook-namespace) need_arg "$1" "${2:-}"; ROOK_NAMESPACE="$2"; shift 2 ;;
      --rook-namespace=*) ROOK_NAMESPACE="${1#*=}"; shift ;;
      --cluster-name) need_arg "$1" "${2:-}"; CLUSTER_NAME="$2"; shift 2 ;;
      --cluster-name=*) CLUSTER_NAME="${1#*=}"; shift ;;
      --test-namespace) need_arg "$1" "${2:-}"; TEST_NAMESPACE="$2"; shift 2 ;;
      --test-namespace=*) TEST_NAMESPACE="${1#*=}"; shift ;;
      --ceph-image) need_arg "$1" "${2:-}"; CEPH_IMAGE="$2"; shift 2 ;;
      --ceph-image=*) CEPH_IMAGE="${1#*=}"; shift ;;
      --ceph-device) need_arg "$1" "${2:-}"; CEPH_DEVICE="$2"; shift 2 ;;
      --ceph-device=*) CEPH_DEVICE="${1#*=}"; shift ;;
      --test-image) need_arg "$1" "${2:-}"; TEST_IMAGE="$2"; shift 2 ;;
      --test-image=*) TEST_IMAGE="${1#*=}"; shift ;;
      --aws-cli-image) need_arg "$1" "${2:-}"; AWS_CLI_IMAGE="$2"; shift 2 ;;
      --aws-cli-image=*) AWS_CLI_IMAGE="${1#*=}"; shift ;;
      --timeout) need_arg "$1" "${2:-}"; TIMEOUT_SECONDS="$2"; shift 2 ;;
      --timeout=*) TIMEOUT_SECONDS="${1#*=}"; shift ;;
      --cleanup-test-artifacts) KEEP_TEST_ARTIFACTS="false"; shift ;;
      --keep-test-artifacts) KEEP_TEST_ARTIFACTS="true"; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

validate_inputs() {
  validate_dns_label "--rook-namespace" "$ROOK_NAMESPACE"
  validate_dns_label "--cluster-name" "$CLUSTER_NAME"
  validate_dns_label "--test-namespace" "$TEST_NAMESPACE"
  validate_positive_integer "--timeout" "$TIMEOUT_SECONDS"
  validate_single_line "--kubeconfig" "$KUBECONFIG_PATH"
  validate_single_line "--ceph-image" "$CEPH_IMAGE"
  validate_single_line "--ceph-device" "$CEPH_DEVICE"
  validate_single_line "--test-image" "$TEST_IMAGE"
  validate_single_line "--aws-cli-image" "$AWS_CLI_IMAGE"
  [[ -z "$KUBECONFIG_PATH" || -f "$KUBECONFIG_PATH" ]] || die "kubeconfig does not exist: $KUBECONFIG_PATH"
}

check_prerequisites() {
  log "Checking kubectl access, Rook CRDs, and operator availability"
  command -v "$KUBECTL_BIN" >/dev/null 2>&1 || die "kubectl was not found: $KUBECTL_BIN"
  run_kubectl version --client=true
  run_kubectl get crd cephclusters.ceph.rook.io
  run_kubectl -n "$ROOK_NAMESPACE" rollout status deployment/rook-ceph-operator --timeout="${TIMEOUT_SECONDS}s"
}

render_ceph_resources() {
  cat <<MANIFEST
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${ROOK_NAMESPACE}
spec:
  dataDirHostPath: /var/lib/rook
  cephVersion:
    image: ${CEPH_IMAGE}
    allowUnsupported: false
  mon:
    count: 3
    allowMultiplePerNode: false
  mgr:
    count: 2
    allowMultiplePerNode: false
  dashboard:
    enabled: false
  monitoring:
    enabled: false
  storage:
    useAllNodes: true
    useAllDevices: false
    deviceFilter: ${CEPH_DEVICE}
---
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: ${BLOCK_POOL_NAME}
  namespace: ${ROOK_NAMESPACE}
spec:
  failureDomain: host
  replicated:
    size: 3
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${BLOCK_STORAGE_CLASS}
provisioner: ${ROOK_NAMESPACE}.rbd.csi.ceph.com
parameters:
  clusterID: ${ROOK_NAMESPACE}
  pool: ${BLOCK_POOL_NAME}
  imageFormat: "2"
  imageFeatures: layering,fast-diff,object-map,deep-flatten,exclusive-lock
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: ${ROOK_NAMESPACE}
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: ${ROOK_NAMESPACE}
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: ${ROOK_NAMESPACE}
reclaimPolicy: Delete
allowVolumeExpansion: true
---
apiVersion: ceph.rook.io/v1
kind: CephFilesystem
metadata:
  name: ${FILESYSTEM_NAME}
  namespace: ${ROOK_NAMESPACE}
spec:
  metadataPool:
    replicated:
      size: 3
  dataPools:
    - failureDomain: host
      replicated:
        size: 3
  metadataServer:
    activeCount: 1
    activeStandby: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${FILESYSTEM_STORAGE_CLASS}
provisioner: ${ROOK_NAMESPACE}.cephfs.csi.ceph.com
parameters:
  clusterID: ${ROOK_NAMESPACE}
  fsName: ${FILESYSTEM_NAME}
  pool: ${FILESYSTEM_NAME}-data0
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: ${ROOK_NAMESPACE}
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: ${ROOK_NAMESPACE}
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-cephfs-node
  csi.storage.k8s.io/node-stage-secret-namespace: ${ROOK_NAMESPACE}
reclaimPolicy: Delete
allowVolumeExpansion: true
---
apiVersion: ceph.rook.io/v1
kind: CephObjectStore
metadata:
  name: ${OBJECT_STORE_NAME}
  namespace: ${ROOK_NAMESPACE}
spec:
  metadataPool:
    failureDomain: host
    replicated:
      size: 3
  dataPool:
    failureDomain: host
    replicated:
      size: 3
  preservePoolsOnDelete: false
  gateway:
    port: 80
    instances: 1
---
apiVersion: ceph.rook.io/v1
kind: CephObjectStoreUser
metadata:
  name: ${OBJECT_USER_NAME}
  namespace: ${ROOK_NAMESPACE}
spec:
  store: ${OBJECT_STORE_NAME}
  displayName: Rook Ceph core test user
MANIFEST
}

apply_ceph_resources() {
  log "Applying CephCluster, RBD, CephFS, and RGW test resources"
  render_ceph_resources | run_kubectl apply -f -
}

wait_for_jsonpath_value() {
  local description="$1" resource="$2" jsonpath="$3" expected="$4"
  local deadline=$((SECONDS + TIMEOUT_SECONDS)) actual=""
  log "Waiting for ${description} to report ${expected}"
  while (( SECONDS < deadline )); do
    actual="$(run_kubectl -n "$ROOK_NAMESPACE" get "$resource" -o "jsonpath=${jsonpath}" 2>/dev/null || true)"
    if [[ "$actual" == "$expected" ]]; then
      log "${description} reported ${expected}"
      return
    fi
    log "${description} currently reports ${actual:-<empty>}; waiting"
    sleep 10
  done
  diagnose_ceph_failure
  die "timed out waiting for ${description} to report ${expected}; last value: ${actual:-<empty>}"
}

ceph_health_is_acceptable() {
  local health warning_codes clock_skew_severity

  health="$(run_kubectl -n "$ROOK_NAMESPACE" get "cephcluster/${CLUSTER_NAME}" -o jsonpath='{.status.ceph.health}' 2>/dev/null || true)"
  if [[ "$health" == "HEALTH_OK" ]]; then
    log "CephCluster ${CLUSTER_NAME} health is HEALTH_OK"
    return 0
  fi

  [[ "$health" == "HEALTH_WARN" ]] || return 1

  warning_codes="$(run_kubectl -n "$ROOK_NAMESPACE" get "cephcluster/${CLUSTER_NAME}" -o go-template='{{range $key, $value := .status.ceph.details}}{{printf "%s\n" $key}}{{end}}' 2>/dev/null || true)"
  [[ "$warning_codes" == "MON_CLOCK_SKEW" ]] || return 1

  clock_skew_severity="$(run_kubectl -n "$ROOK_NAMESPACE" get "cephcluster/${CLUSTER_NAME}" -o jsonpath='{.status.ceph.details.MON_CLOCK_SKEW.severity}' 2>/dev/null || true)"
  [[ "$clock_skew_severity" == "HEALTH_WARN" ]] || return 1

  log "CephCluster ${CLUSTER_NAME} health is HEALTH_WARN only because of MON_CLOCK_SKEW; continuing"
}

wait_for_ceph_health() {
  local deadline=$((SECONDS + TIMEOUT_SECONDS)) health="" warning_codes=""

  log "Waiting for CephCluster ${CLUSTER_NAME} health to be HEALTH_OK, or HEALTH_WARN only for MON_CLOCK_SKEW"
  while (( SECONDS < deadline )); do
    if ceph_health_is_acceptable; then
      return
    fi
    health="$(run_kubectl -n "$ROOK_NAMESPACE" get "cephcluster/${CLUSTER_NAME}" -o jsonpath='{.status.ceph.health}' 2>/dev/null || true)"
    warning_codes="$(run_kubectl -n "$ROOK_NAMESPACE" get "cephcluster/${CLUSTER_NAME}" -o go-template='{{range $key, $value := .status.ceph.details}}{{printf "%s\n" $key}}{{end}}' 2>/dev/null || true)"
    log "CephCluster ${CLUSTER_NAME} health is ${health:-<missing>}; warning codes: ${warning_codes:-<none>}; waiting"
    sleep 5
  done

  diagnose_ceph_failure
  die "timed out waiting for CephCluster ${CLUSTER_NAME} health to become acceptable"
}

diagnose_ceph_failure() {
  log "Collecting Rook-Ceph diagnostics"
  run_kubectl -n "$ROOK_NAMESPACE" get cephcluster,cephblockpool,cephfilesystem,cephobjectstore,cephobjectstoreuser -o wide || true
  run_kubectl -n "$ROOK_NAMESPACE" get pods -o wide || true
  run_kubectl -n "$ROOK_NAMESPACE" describe "cephcluster/${CLUSTER_NAME}" || true
  run_kubectl -n "$ROOK_NAMESPACE" logs deployment/rook-ceph-operator --all-containers=true --tail=200 || true
}

wait_for_ceph_services() {
  wait_for_ceph_health
  wait_for_jsonpath_value "CephBlockPool ${BLOCK_POOL_NAME} phase" "cephblockpool/${BLOCK_POOL_NAME}" '{.status.phase}' "Ready"
  wait_for_jsonpath_value "CephFilesystem ${FILESYSTEM_NAME} phase" "cephfilesystem/${FILESYSTEM_NAME}" '{.status.phase}' "Ready"
  wait_for_jsonpath_value "CephObjectStore ${OBJECT_STORE_NAME} phase" "cephobjectstore/${OBJECT_STORE_NAME}" '{.status.phase}' "Ready"
  wait_for_object_user_secret
}

wait_for_object_user_secret() {
  local secret="rook-ceph-object-user-${OBJECT_STORE_NAME}-${OBJECT_USER_NAME}"
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  log "Waiting for RGW credentials secret ${ROOK_NAMESPACE}/${secret}"
  while (( SECONDS < deadline )); do
    if kubectl_quiet -n "$ROOK_NAMESPACE" get secret "$secret"; then
      log "RGW credentials secret ${ROOK_NAMESPACE}/${secret} is present"
      return
    fi
    log "RGW credentials secret ${ROOK_NAMESPACE}/${secret} is not present yet; waiting"
    sleep 10
  done
  diagnose_ceph_failure
  die "timed out waiting for RGW credentials secret ${ROOK_NAMESPACE}/${secret}"
}

delete_prior_workloads() {
  log "Removing prior test workload resources so Jobs can be recreated"
  run_kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found=true
  run_kubectl wait --for=delete "namespace/${TEST_NAMESPACE}" --timeout="${TIMEOUT_SECONDS}s" || true
}

render_workloads() {
  local object_secret="rook-ceph-object-user-${OBJECT_STORE_NAME}-${OBJECT_USER_NAME}"
  local access_key secret_key
  log "Copying generated RGW credentials into the isolated workload namespace"
  access_key="$(run_kubectl -n "$ROOK_NAMESPACE" get secret "$object_secret" -o jsonpath='{.data.AccessKey}')"
  secret_key="$(run_kubectl -n "$ROOK_NAMESPACE" get secret "$object_secret" -o jsonpath='{.data.SecretKey}')"
  [[ -n "$access_key" && -n "$secret_key" ]] || die "RGW user secret ${ROOK_NAMESPACE}/${object_secret} does not contain AccessKey and SecretKey"
  cat <<MANIFEST
apiVersion: v1
kind: Namespace
metadata:
  name: ${TEST_NAMESPACE}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${object_secret}
  namespace: ${TEST_NAMESPACE}
type: Opaque
data:
  AccessKey: ${access_key}
  SecretKey: ${secret_key}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${BLOCK_PVC_NAME}
  namespace: ${TEST_NAMESPACE}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ${BLOCK_STORAGE_CLASS}
  resources:
    requests:
      storage: 1Gi
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ${BLOCK_JOB_NAME}
  namespace: ${TEST_NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: rbd
          image: ${TEST_IMAGE}
          command: [sh, -ec]
          args:
            - |
              log() { echo "[rbd] \$*"; }
              log "writing RBD test data"
              printf 'rook-rbd-core-test\\n' > /data/payload
              sha256sum /data/payload > /data/payload.sha256
              log "reading and verifying RBD test data"
              sha256sum -c /data/payload.sha256
              grep -qx 'rook-rbd-core-test' /data/payload
              log "RBD data-plane test passed"
          volumeMounts:
            - name: volume
              mountPath: /data
      volumes:
        - name: volume
          persistentVolumeClaim:
            claimName: ${BLOCK_PVC_NAME}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${FILESYSTEM_PVC_NAME}
  namespace: ${TEST_NAMESPACE}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ${FILESYSTEM_STORAGE_CLASS}
  resources:
    requests:
      storage: 1Gi
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ${FILESYSTEM_WRITER_JOB_NAME}
  namespace: ${TEST_NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsUser: 0
        runAsGroup: 0
      containers:
        - name: cephfs-writer
          image: ${TEST_IMAGE}
          securityContext:
            allowPrivilegeEscalation: true
            privileged: true
          command: [sh, -ec]
          args:
            - |
              log() { echo "[cephfs-writer] \$*"; }
              log "writer identity: \$(id)"
              log "writing CephFS shared file"
              printf 'rook-cephfs-core-test\\n' > /shared/payload
              sha256sum /shared/payload > /shared/payload.sha256
              log "CephFS writer completed"
          volumeMounts:
            - name: volume
              mountPath: /shared
      volumes:
        - name: volume
          persistentVolumeClaim:
            claimName: ${FILESYSTEM_PVC_NAME}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ${OBJECT_JOB_NAME}
  namespace: ${TEST_NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: rgw
          image: ${AWS_CLI_IMAGE}
          env:
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: ${object_secret}
                  key: AccessKey
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: ${object_secret}
                  key: SecretKey
            - name: AWS_DEFAULT_REGION
              value: us-east-1
          command: [sh, -ec]
          args:
            - |
              log() { echo "[rgw] \$*"; }
              endpoint=http://${ROOK_NAMESPACE}-rgw-${OBJECT_STORE_NAME}.${ROOK_NAMESPACE}.svc
              bucket=rook-ceph-core-test
              log "creating bucket at \$endpoint"
              aws --endpoint-url "\$endpoint" s3 mb "s3://\$bucket"
              printf 'rook-rgw-core-test\\n' > /tmp/payload
              log "uploading object"
              aws --endpoint-url "\$endpoint" s3 cp /tmp/payload "s3://\$bucket/payload"
              log "downloading and verifying object"
              aws --endpoint-url "\$endpoint" s3 cp "s3://\$bucket/payload" /tmp/downloaded
              cmp /tmp/payload /tmp/downloaded
              aws --endpoint-url "\$endpoint" s3 rm "s3://\$bucket/payload"
              aws --endpoint-url "\$endpoint" s3 rb "s3://\$bucket"
              log "RGW S3 data-plane test passed"
MANIFEST
}

render_cephfs_reader_workload() {
  cat <<MANIFEST
apiVersion: batch/v1
kind: Job
metadata:
  name: ${FILESYSTEM_READER_JOB_NAME}
  namespace: ${TEST_NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch
      containers:
        - name: cephfs-reader
          image: ${TEST_IMAGE}
          command: [sh, -ec]
          args:
            - |
              log() { echo "[cephfs-reader] \$*"; }
              log "reading CephFS shared file from a separate workload"
              sha256sum -c /shared/payload.sha256
              grep -qx 'rook-cephfs-core-test' /shared/payload
              log "CephFS shared-filesystem test passed"
          volumeMounts:
            - name: volume
              mountPath: /shared
      volumes:
        - name: volume
          persistentVolumeClaim:
            claimName: ${FILESYSTEM_PVC_NAME}
MANIFEST
}

render_storage_consumer_pods() {
  cat <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: ${BLOCK_POD_NAME}
  namespace: ${TEST_NAMESPACE}
  labels:
    app: ${BLOCK_POD_NAME}
spec:
  restartPolicy: Never
  containers:
    - name: rbd-consumer
      image: ${TEST_IMAGE}
      command: [sh, -ec, 'echo "[rbd-consumer] mounted RBD PVC"; sleep 3600']
      volumeMounts:
        - name: volume
          mountPath: /data
  volumes:
    - name: volume
      persistentVolumeClaim:
        claimName: ${BLOCK_PVC_NAME}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${FILESYSTEM_POD_NAME}
  namespace: ${TEST_NAMESPACE}
  labels:
    app: ${FILESYSTEM_POD_NAME}
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    fsGroupChangePolicy: OnRootMismatch
  containers:
    - name: cephfs-consumer
      image: ${TEST_IMAGE}
      command: [sh, -ec, 'echo "[cephfs-consumer] mounted CephFS PVC"; sleep 3600']
      volumeMounts:
        - name: volume
          mountPath: /shared
  volumes:
    - name: volume
      persistentVolumeClaim:
        claimName: ${FILESYSTEM_PVC_NAME}
MANIFEST
}

apply_workloads() {
  log "Applying RBD, CephFS writer, and RGW workload tests"
  render_workloads | run_kubectl apply -f -
}

apply_cephfs_reader_workload() {
  log "Applying CephFS reader workload after writer completion"
  render_cephfs_reader_workload | run_kubectl apply -f -
}

apply_storage_consumer_pods() {
  log "Applying persistent RBD and CephFS consumer Pods"
  render_storage_consumer_pods | run_kubectl apply -f -
}

wait_for_pvc_bound() {
  local name="$1" deadline=$((SECONDS + TIMEOUT_SECONDS)) phase=""
  log "Waiting for PVC ${TEST_NAMESPACE}/${name} to bind"
  while (( SECONDS < deadline )); do
    phase="$(run_kubectl -n "$TEST_NAMESPACE" get pvc "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" != "Bound" ]] || { log "PVC ${TEST_NAMESPACE}/${name} is Bound"; return; }
    log "PVC ${TEST_NAMESPACE}/${name} phase is ${phase:-<missing>}; waiting"
    sleep 5
  done
  diagnose_workload_failure "$name"
  die "timed out waiting for PVC ${TEST_NAMESPACE}/${name} to bind"
}

wait_for_job() {
  local name="$1"
  log "Waiting for Job ${TEST_NAMESPACE}/${name} to complete"
  if ! run_kubectl -n "$TEST_NAMESPACE" wait --for=condition=complete "job/${name}" --timeout="${TIMEOUT_SECONDS}s"; then
    diagnose_workload_failure "$name"
    die "Job ${TEST_NAMESPACE}/${name} did not complete successfully"
  fi
  log "Job ${TEST_NAMESPACE}/${name} completed; workload logs follow"
  run_kubectl -n "$TEST_NAMESPACE" logs "job/${name}" --all-containers=true
}

wait_for_pod_ready() {
  local name="$1"
  log "Waiting for storage consumer Pod ${TEST_NAMESPACE}/${name} to become Ready"
  if ! run_kubectl -n "$TEST_NAMESPACE" wait --for=condition=Ready "pod/${name}" --timeout="${TIMEOUT_SECONDS}s"; then
    diagnose_workload_failure "$name"
    die "storage consumer Pod ${TEST_NAMESPACE}/${name} did not become Ready"
  fi
  log "Storage consumer Pod ${TEST_NAMESPACE}/${name} is Ready"
}

verify_storage_consumer_pods() {
  wait_for_pod_ready "$BLOCK_POD_NAME"
  log "Verifying RBD payload from persistent consumer Pod ${BLOCK_POD_NAME}"
  run_kubectl -n "$TEST_NAMESPACE" exec "$BLOCK_POD_NAME" -- sh -ec \
    "sha256sum -c /data/payload.sha256 && grep -qx 'rook-rbd-core-test' /data/payload"
  wait_for_pod_ready "$FILESYSTEM_POD_NAME"
  log "Verifying CephFS payload from persistent consumer Pod ${FILESYSTEM_POD_NAME}"
  run_kubectl -n "$TEST_NAMESPACE" exec "$FILESYSTEM_POD_NAME" -- sh -ec \
    "sha256sum -c /shared/payload.sha256 && grep -qx 'rook-cephfs-core-test' /shared/payload"
}

diagnose_workload_failure() {
  local name="$1"
  log "Collecting workload diagnostics for ${name}"
  run_kubectl -n "$TEST_NAMESPACE" get pvc,pv,pod,job -o wide || true
  run_kubectl -n "$TEST_NAMESPACE" describe "job/${name}" || true
  run_kubectl -n "$TEST_NAMESPACE" logs "job/${name}" --all-containers=true || true
  diagnose_ceph_failure
}

run_workload_tests() {
  wait_for_pvc_bound "$BLOCK_PVC_NAME"
  wait_for_pvc_bound "$FILESYSTEM_PVC_NAME"
  wait_for_job "$BLOCK_JOB_NAME"
  wait_for_job "$FILESYSTEM_WRITER_JOB_NAME"
  apply_storage_consumer_pods
  verify_storage_consumer_pods
  apply_cephfs_reader_workload
  wait_for_job "$FILESYSTEM_READER_JOB_NAME"
  wait_for_job "$OBJECT_JOB_NAME"
}

cleanup_test_artifacts() {
  if [[ "$KEEP_TEST_ARTIFACTS" == "true" ]]; then
    log "Keeping workload namespace ${TEST_NAMESPACE} and Ceph test resources for inspection"
    return
  fi
  log "Deleting workload namespace ${TEST_NAMESPACE}; CephCluster and storage resources remain available"
  run_kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found=true
}

print_summary() {
  log "Rook-Ceph core test suite passed"
  log "CephCluster health: HEALTH_OK, or HEALTH_WARN only for MON_CLOCK_SKEW"
  log "RBD: dynamic provisioning, mount, write, read, and checksum verification passed"
  log "CephFS: dynamic provisioning and cross-workload shared-file verification passed"
  log "RGW: authenticated S3 bucket, upload, download, comparison, and cleanup passed"
}

main() {
  log "Starting Rook-Ceph core test suite"
  parse_args "$@"
  validate_inputs
  check_prerequisites
  apply_ceph_resources
  wait_for_ceph_services
  delete_prior_workloads
  apply_workloads
  run_workload_tests
  cleanup_test_artifacts
  print_summary
}

main "$@"
