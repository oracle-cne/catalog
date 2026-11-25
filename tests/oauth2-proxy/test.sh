#!/usr/bin/env bash
# Copyright (c) 2026, Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at
# https://oss.oracle.com/licenses/upl.

# Create a libvirt OCNE cluster and exercise the complete HTTP authentication
# path: MetalLB -> ingress-nginx -> oauth2-proxy -> Dex -> nginx.
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLUSTER_NAME="ocne-oauth2-integration"
CONTROL_PLANE_NODES=1
WORKER_NODES=3
KUBECONFIG_PATH="${KUBECONFIG:-}"
CHECK_ONLY=false
KEEP_GENERATED_FILES=false

CATALOG_NAME="${CATALOG_TEST_NAME:-}"
METALLB_VERSION="${METALLB_VERSION:-0.16.1}"
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-1.15.1}"
DEX_VERSION="${DEX_VERSION:-2.45.1}"
OAUTH2_PROXY_VERSION="${OAUTH2_PROXY_VERSION:-7.15.4}"

METALLB_NAMESPACE="metallb-system"
INGRESS_NAMESPACE="ingress-nginx"
DEX_NAMESPACE="dex"
OAUTH2_PROXY_NAMESPACE="oauth2-proxy"
APP_NAMESPACE="oauth2-demo"
METALLB_ADDRESS_POOL=""
APP_HOST="nginx.oauth2-proxy.test"
DEX_HOST="dex.oauth2-proxy.test"
NODE_READY_TIMEOUT_SECONDS=1200
ROLLOUT_TIMEOUT="600s"
LOAD_BALANCER_TIMEOUT_SECONDS=300

OCNE_BIN="${OCNE_BIN:-ocne}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

TMP_DIR=""
DEX_VALUES_FILE=""
OAUTH2_PROXY_VALUES_FILE=""
INGRESS_VALUES_FILE=""
METALLB_MANIFEST=""
DEX_INGRESS_MANIFEST=""
APP_MANIFEST=""
INGRESS_LOAD_BALANCER_IP=""

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} --kubeconfig PATH [options]

Install and validate applications in an existing cluster.
The caller provisions cluster.yaml and owns cluster cleanup.
KUBECONFIG may supply the existing kubeconfig instead of --kubeconfig.
OCNE_BIN and KUBECTL_BIN select CLI executables (defaults: ocne, kubectl).

  --metallb-address-pool VALUE    Address or range MetalLB may advertise, for
                                  example 192.168.122.240-192.168.122.250.
                                  Choose unused addresses on the libvirt L2
                                  network; the script cannot safely infer one.
  --app-host HOST                 Protected nginx host. Default: ${APP_HOST}
  --dex-host HOST                 Dex issuer host. Default: ${DEX_HOST}
  --metallb-version VERSION       Default: ${METALLB_VERSION}
  --ingress-nginx-version VERSION Default: ${INGRESS_NGINX_VERSION}
  --dex-version VERSION           Default: ${DEX_VERSION}
  --oauth2-proxy-version VERSION  Default: ${OAUTH2_PROXY_VERSION}
  --node-ready-timeout SECONDS    Default: ${NODE_READY_TIMEOUT_SECONDS}
  --rollout-timeout DURATION      Default: ${ROLLOUT_TIMEOUT}
  --load-balancer-timeout SECONDS Default: ${LOAD_BALANCER_TIMEOUT_SECONDS}
  --check-only                    Validate inputs and generate manifests only.
  --keep-generated-files          Preserve generated values and manifests.
  --help                          Show this help.
USAGE
}

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
log_command() { printf '[%s] Running:' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >&2; printf ' %q' "$@" >&2; printf '\n' >&2; }
run() { log_command "$@"; "$@"; }
need_arg() { [[ -n "${2:-}" ]] || die "$1 requires a value"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kubeconfig) need_arg "$1" "${2:-}"; KUBECONFIG_PATH="$2"; shift 2 ;;
      --kubeconfig=*) KUBECONFIG_PATH="${1#*=}"; shift ;;
      --metallb-address-pool) need_arg "$1" "${2:-}"; METALLB_ADDRESS_POOL="$2"; shift 2 ;;
      --metallb-address-pool=*) METALLB_ADDRESS_POOL="${1#*=}"; shift ;;
      --app-host) need_arg "$1" "${2:-}"; APP_HOST="$2"; shift 2 ;;
      --app-host=*) APP_HOST="${1#*=}"; shift ;;
      --dex-host) need_arg "$1" "${2:-}"; DEX_HOST="$2"; shift 2 ;;
      --dex-host=*) DEX_HOST="${1#*=}"; shift ;;
      --metallb-version) need_arg "$1" "${2:-}"; METALLB_VERSION="$2"; shift 2 ;;
      --metallb-version=*) METALLB_VERSION="${1#*=}"; shift ;;
      --ingress-nginx-version) need_arg "$1" "${2:-}"; INGRESS_NGINX_VERSION="$2"; shift 2 ;;
      --ingress-nginx-version=*) INGRESS_NGINX_VERSION="${1#*=}"; shift ;;
      --dex-version) need_arg "$1" "${2:-}"; DEX_VERSION="$2"; shift 2 ;;
      --dex-version=*) DEX_VERSION="${1#*=}"; shift ;;
      --oauth2-proxy-version) need_arg "$1" "${2:-}"; OAUTH2_PROXY_VERSION="$2"; shift 2 ;;
      --oauth2-proxy-version=*) OAUTH2_PROXY_VERSION="${1#*=}"; shift ;;
      --node-ready-timeout) need_arg "$1" "${2:-}"; NODE_READY_TIMEOUT_SECONDS="$2"; shift 2 ;;
      --node-ready-timeout=*) NODE_READY_TIMEOUT_SECONDS="${1#*=}"; shift ;;
      --rollout-timeout) need_arg "$1" "${2:-}"; ROLLOUT_TIMEOUT="$2"; shift 2 ;;
      --rollout-timeout=*) ROLLOUT_TIMEOUT="${1#*=}"; shift ;;
      --load-balancer-timeout) need_arg "$1" "${2:-}"; LOAD_BALANCER_TIMEOUT_SECONDS="$2"; shift 2 ;;
      --load-balancer-timeout=*) LOAD_BALANCER_TIMEOUT_SECONDS="${1#*=}"; shift ;;
      --check-only) CHECK_ONLY=true; shift ;;
      --keep-generated-files) KEEP_GENERATED_FILES=true; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

validate_dns_label() { [[ "$2" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "$1 must be a DNS label: $2"; }
validate_host() { [[ "$2" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] && [[ "$2" != *".."* ]] || die "$1 must be a lowercase DNS host: $2"; }
validate_integer() { [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be an integer: $2"; }
validate_one_line() { [[ -n "$2" && "$2" != *$'\n'* ]] || die "$1 must be a non-empty single-line value"; }


validate_inputs() {
  log "Validating all cluster, catalog, network, and hostname inputs"
  validate_dns_label "candidate catalog" "$CATALOG_NAME"
  validate_host "--app-host" "$APP_HOST"
  validate_host "--dex-host" "$DEX_HOST"
  [[ "$APP_HOST" != "$DEX_HOST" ]] || die "--app-host and --dex-host must be different"
  validate_one_line "--metallb-address-pool" "$METALLB_ADDRESS_POOL"
  validate_integer "--node-ready-timeout" "$NODE_READY_TIMEOUT_SECONDS"
  validate_integer "--load-balancer-timeout" "$LOAD_BALANCER_TIMEOUT_SECONDS"
  (( NODE_READY_TIMEOUT_SECONDS > 0 && LOAD_BALANCER_TIMEOUT_SECONDS > 0 )) || die "timeout values must be greater than zero"
  [[ "$ROLLOUT_TIMEOUT" =~ ^[0-9]+(s|m|h)$ ]] || die "--rollout-timeout must be an integer followed by s, m, or h"
}

check_executable() {
  if [[ "$2" == */* ]]; then [[ -x "$2" ]] || die "$1 is not executable: $2"; else command -v -- "$2" >/dev/null 2>&1 || die "$1 was not found in PATH: $2"; fi
}

check_prerequisites() {
  log "Checking OCNE CLI, kubectl, and temporary-directory tooling"
  check_executable "OCNE CLI" "$OCNE_BIN"
  check_executable "mktemp" mktemp
  [[ "$CHECK_ONLY" == true ]] || check_executable "kubectl" "$KUBECTL_BIN"
}

create_workspace() {
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCRIPT_NAME%.sh}.XXXXXX")"
  DEX_VALUES_FILE="${TMP_DIR}/dex-values.yaml"
  OAUTH2_PROXY_VALUES_FILE="${TMP_DIR}/oauth2-proxy-values.yaml"
  INGRESS_VALUES_FILE="${TMP_DIR}/ingress-nginx-values.yaml"
  METALLB_MANIFEST="${TMP_DIR}/metallb-address-pool.yaml"
  DEX_INGRESS_MANIFEST="${TMP_DIR}/dex-ingress.yaml"
  APP_MANIFEST="${TMP_DIR}/oauth2-demo.yaml"
  log "Generated configuration directory: ${TMP_DIR}"
}

cleanup() {
  if [[ -z "$TMP_DIR" ]]; then return; fi
  if [[ "$KEEP_GENERATED_FILES" == true ]]; then log "Keeping generated configuration directory: ${TMP_DIR}"; else log "Removing generated configuration directory: ${TMP_DIR}"; rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT

write_configuration() {
  log "Writing catalog values and direct nginx, ingress, and MetalLB manifests"
  cat >"$DEX_VALUES_FILE" <<EOF_DEX
config:
  issuer: http://${DEX_HOST}
  storage:
    type: memory
  web:
    http: 0.0.0.0:5556
  enablePasswordDB: true
  staticClients:
  - id: oauth2-proxy
    name: oauth2-proxy integration test
    secret: oauth2-proxy-client-secret
    redirectURIs:
    - http://${APP_HOST}/oauth2/callback
  staticPasswords:
  - email: admin@example.com
    # bcrypt hash for the public integration-test password: password
    hash: "\$2a\$10\$0yUgUPf/vAFv7un/SRzbXuINGImif9d.LYaBW884NiUqYLn2/L1bC"
    username: admin
    userID: 08a8684b-db88-4b73-90a9-3cd1661f5466
EOF_DEX
}

write_oauth2_proxy_values() {
  local ingress_load_balancer_ip="$1"
  log "Writing oauth2-proxy values with Dex issuer host alias ${DEX_HOST} -> ${ingress_load_balancer_ip}"
  cat >"$OAUTH2_PROXY_VALUES_FILE" <<EOF_PROXY
config:
  clientID: oauth2-proxy
  clientSecret: oauth2-proxy-client-secret
  cookieSecret: "mM4UMfMR8pPGta1qgtcsRVhXrYxSI8MDe4GN8JzWGdA="
  configFile: |-
    provider = "oidc"
    oidc_issuer_url = "http://${DEX_HOST}"
    redirect_url = "http://${APP_HOST}/oauth2/callback"
    email_domains = [ "*" ]
    insecure_oidc_allow_unverified_email = true
    cookie_secure = false
    skip_provider_button = true
    set_xauthrequest = true
    reverse_proxy = true
    upstreams = [ "file:///dev/null" ]
hostAliases:
- ip: ${ingress_load_balancer_ip}
  hostnames:
  - ${DEX_HOST}
EOF_PROXY
}

write_remaining_configuration() {
  cat >"$INGRESS_VALUES_FILE" <<'EOF_INGRESS_VALUES'
controller:
  service:
    type: LoadBalancer
EOF_INGRESS_VALUES
  cat >"$DEX_INGRESS_MANIFEST" <<EOF_DEX_INGRESS
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dex
  namespace: ${DEX_NAMESPACE}
spec:
  ingressClassName: nginx
  rules:
  - host: ${DEX_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: dex
            port:
              number: 5556
EOF_DEX_INGRESS
  cat >"$METALLB_MANIFEST" <<EOF_METALLB
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: integration-pool
  namespace: ${METALLB_NAMESPACE}
spec:
  addresses:
  - ${METALLB_ADDRESS_POOL}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: integration-pool
  namespace: ${METALLB_NAMESPACE}
spec:
  ipAddressPools:
  - integration-pool
EOF_METALLB
  cat >"$APP_MANIFEST" <<EOF_APP
apiVersion: v1
kind: Namespace
metadata:
  name: ${APP_NAMESPACE}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-page
  namespace: ${APP_NAMESPACE}
data:
  index.html: |
    <!doctype html><html><body><h1>OCNE oauth2-proxy integration test passed</h1><p>MetalLB, ingress-nginx, oauth2-proxy, Dex, and nginx are connected.</p></body></html>
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
  namespace: ${APP_NAMESPACE}
data:
  nginx.conf: |
    pid /tmp/nginx.pid;
    error_log /dev/stderr info;
    events { worker_connections 1024; }
    http {
      access_log /dev/stdout;
      server {
        listen 8080;
        default_type text/html;
        location / { return 200 '<!doctype html><html><body><h1>OCNE oauth2-proxy integration test passed</h1><p>MetalLB, ingress-nginx, oauth2-proxy, Dex, and nginx are connected.</p></body></html>'; }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: ${APP_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: olcne/ingress-nginx-controller:v1.15.1
        command:
        - /usr/sbin/nginx
        args:
        - -c
        - /etc/nginx-test/nginx.conf
        - -g
        - daemon off;
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: page
          mountPath: /usr/share/nginx/html/index.html
          subPath: index.html
        - name: config
          mountPath: /etc/nginx-test/nginx.conf
          subPath: nginx.conf
      volumes:
      - name: page
        configMap:
          name: nginx-page
      - name: config
        configMap:
          name: nginx-config
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: ${APP_NAMESPACE}
spec:
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: oauth2-proxy
  namespace: ${OAUTH2_PROXY_NAMESPACE}
spec:
  ingressClassName: nginx
  rules:
  - host: ${APP_HOST}
    http:
      paths:
      - path: /oauth2
        pathType: Prefix
        backend:
          service:
            name: oauth2-proxy
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dex
  namespace: ${DEX_NAMESPACE}
spec:
  ingressClassName: nginx
  rules:
  - host: ${DEX_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: dex
            port:
              number: 5556
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx
  namespace: ${APP_NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/auth-url: http://oauth2-proxy.${OAUTH2_PROXY_NAMESPACE}.svc.cluster.local/oauth2/auth
    nginx.ingress.kubernetes.io/auth-signin: http://${APP_HOST}/oauth2/start?rd=\$escaped_request_uri
    nginx.ingress.kubernetes.io/auth-response-headers: x-auth-request-user,x-auth-request-email
spec:
  ingressClassName: nginx
  rules:
  - host: ${APP_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx
            port:
              number: 80
EOF_APP
}

run_ocne() { log_command "KUBECONFIG=${KUBECONFIG_PATH}" "$OCNE_BIN" "$@"; KUBECONFIG="$KUBECONFIG_PATH" "$OCNE_BIN" "$@"; }
run_kubectl() { run "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" "$@"; }
kubectl_quiet() { "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" "$@" >/dev/null 2>&1; }


wait_for_nodes() {
  local expected=4 deadline=$((SECONDS + NODE_READY_TIMEOUT_SECONDS)) count=0
  log "Waiting for all ${expected} Kubernetes nodes to become Ready"
  while (( SECONDS < deadline )); do
    count="$("$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" { n++ } END { print n + 0 }')"
    [[ "$count" == "$expected" ]] && { log "All ${expected} nodes are Ready"; return; }
    log "Detected ${count}/${expected} Ready nodes; waiting"
    sleep 10
  done
  die "timed out waiting for ${expected} Ready nodes"
}

verify_catalog_chart() {
  local name="$1" output
  log "Verifying ${name} is available in catalog ${CATALOG_NAME}"
  output="$(KUBECONFIG="$KUBECONFIG_PATH" "$OCNE_BIN" catalog search --name "$CATALOG_NAME" --pattern "^${name}$")"
  printf '%s\n' "$output" >&2
  awk -v chart="$name" '$1 == chart { found = 1 } END { exit !found }' <<<"$output" || die "catalog ${CATALOG_NAME} does not contain ${name}"
}

install_catalog_application() {
  local name="$1" release="$2" namespace="$3" version="$4" values="${5:-}"
  if KUBECONFIG="$KUBECONFIG_PATH" "$OCNE_BIN" application show --namespace "$namespace" --release "$release" >/dev/null 2>&1; then
    log "Updating existing ${namespace}/${release} from catalog ${CATALOG_NAME}"
    local update=(application update --catalog "$CATALOG_NAME" --namespace "$namespace" --release "$release" --version "$version" --reset-values)
    [[ -z "$values" ]] || update+=(--values "$values")
    run_ocne "${update[@]}"
  else
    log "Installing ${name} as ${namespace}/${release} from catalog ${CATALOG_NAME}"
    local install=(application install --catalog "$CATALOG_NAME" --namespace "$namespace" --name "$name" --release "$release" --version "$version")
    [[ -z "$values" ]] || install+=(--values "$values")
    run_ocne "${install[@]}"
  fi
}

wait_for_load_balancer_ip() {
  local deadline=$((SECONDS + LOAD_BALANCER_TIMEOUT_SECONDS)) ip=""
  log "Waiting for ingress-nginx LoadBalancer service to receive a MetalLB address"
  while (( SECONDS < deadline )); do
    ip="$("$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$INGRESS_NAMESPACE" get service ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "$ip" ]] && { printf '%s\n' "$ip"; return; }
    log "Ingress LoadBalancer has no address yet; waiting"
    sleep 5
  done
  die "timed out waiting for a MetalLB address on ingress-nginx-controller"
}

smoke_test() {
  local load_balancer_ip="$1" status location
  log "Checking that the protected nginx endpoint redirects unauthenticated traffic to oauth2-proxy and Dex"
  status="$("$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" -n "$APP_NAMESPACE" get ingress nginx -o name)"
  [[ "$status" == "ingress.networking.k8s.io/nginx" ]] || die "protected nginx Ingress was not created"
  if command -v curl >/dev/null 2>&1; then
    location="$(curl --silent --show-error --noproxy '*' --max-time 20 --resolve "${APP_HOST}:80:${load_balancer_ip}" -D - -o /dev/null "http://${APP_HOST}/" | awk 'BEGIN { IGNORECASE=1 } /^location:/ { print $2; exit }' | tr -d '\r')"
    [[ "$location" == *"/oauth2/start"* ]] || die "nginx did not redirect unauthenticated traffic to oauth2-proxy; Location was ${location:-<missing>}"
    log "Unauthenticated request redirects to ${location}"
  else
    log "curl is unavailable; skipping the HTTP redirect assertion"
  fi
}

print_summary() {
  local load_balancer_ip="$1"
  log "Integrated deployment completed successfully"
  log "Kubeconfig: ${KUBECONFIG_PATH}"
  log "MetalLB address: ${load_balancer_ip}"
  log "Add this mapping on the client that will use the test: ${load_balancer_ip} ${APP_HOST} ${DEX_HOST}"
  log "Open http://${APP_HOST}/ and sign in with admin@example.com / password"
  log "Expected page: OCNE oauth2-proxy integration test passed"
}

main() {
  log "Starting OAuth2, Dex, ingress-nginx, MetalLB, and nginx integration test"
  parse_args "$@"
  [[ -n "$CATALOG_NAME" ]] || die "Run tests/run-changed.sh to build and register this checkout catalog"
  log "Using an externally provisioned cluster; cluster lifecycle belongs to the caller"
  [[ -n "$KUBECONFIG_PATH" && -s "$KUBECONFIG_PATH" ]] || die "Supply an existing kubeconfig with --kubeconfig or KUBECONFIG"
  validate_inputs
  check_prerequisites
  create_workspace
  write_configuration
  write_remaining_configuration
  if [[ "$CHECK_ONLY" == true ]]; then log "Validation and manifest generation completed; no cluster or application was changed"; return; fi
  wait_for_nodes
  verify_catalog_chart metallb
  verify_catalog_chart ingress-nginx
  verify_catalog_chart dex
  verify_catalog_chart oauth2-proxy
  install_catalog_application metallb metallb "$METALLB_NAMESPACE" "$METALLB_VERSION"
  run_kubectl -n "$METALLB_NAMESPACE" rollout status deployment/metallb-controller --timeout "$ROLLOUT_TIMEOUT"
  run_kubectl -n "$METALLB_NAMESPACE" rollout status daemonset/metallb-speaker --timeout "$ROLLOUT_TIMEOUT"
  run_kubectl apply -f "$METALLB_MANIFEST"
  install_catalog_application ingress-nginx ingress-nginx "$INGRESS_NAMESPACE" "$INGRESS_NGINX_VERSION" "$INGRESS_VALUES_FILE"
  run_kubectl -n "$INGRESS_NAMESPACE" rollout status deployment/ingress-nginx-controller --timeout "$ROLLOUT_TIMEOUT"
  INGRESS_LOAD_BALANCER_IP="$(wait_for_load_balancer_ip)"
  log "Ingress LoadBalancer address is ${INGRESS_LOAD_BALANCER_IP}"
  write_oauth2_proxy_values "$INGRESS_LOAD_BALANCER_IP"
  install_catalog_application dex dex "$DEX_NAMESPACE" "$DEX_VERSION" "$DEX_VALUES_FILE"
  run_kubectl -n "$DEX_NAMESPACE" rollout status deployment/dex --timeout "$ROLLOUT_TIMEOUT"
  run_kubectl apply -f "$DEX_INGRESS_MANIFEST"
  install_catalog_application oauth2-proxy oauth2-proxy "$OAUTH2_PROXY_NAMESPACE" "$OAUTH2_PROXY_VERSION" "$OAUTH2_PROXY_VALUES_FILE"
  run_kubectl -n "$OAUTH2_PROXY_NAMESPACE" rollout status deployment/oauth2-proxy --timeout "$ROLLOUT_TIMEOUT"
  run_kubectl apply -f "$APP_MANIFEST"
  run_kubectl -n "$APP_NAMESPACE" rollout status deployment/nginx --timeout "$ROLLOUT_TIMEOUT"
  smoke_test "$INGRESS_LOAD_BALANCER_IP"
  print_summary "$INGRESS_LOAD_BALANCER_IP"
}

main "$@"
