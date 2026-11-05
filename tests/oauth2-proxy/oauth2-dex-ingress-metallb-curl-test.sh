#!/usr/bin/env bash
# Copyright (c) 2026, Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at
# https://oss.oracle.com/licenses/upl.

# Exercise the deployment created by test.sh
# using curl only. The test follows the browser-facing authorization-code flow
# and validates the resulting oauth2-proxy session against the nginx page.
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
LOAD_BALANCER_ADDRESS=""
APP_HOST="nginx.oauth2-proxy.test"
DEX_HOST="dex.oauth2-proxy.test"
USERNAME="admin@example.com"
PASSWORD="password"
CURL_TIMEOUT_SECONDS=30
KEEP_ARTIFACTS=false

TMP_DIR=""
COOKIE_JAR=""
HEADERS_FILE=""
LOGIN_PAGE_FILE=""
APP_BODY_FILE=""

usage() {
  cat <<USAGE
Usage:
  ${SCRIPT_NAME} --address METALLB_IP [options]

Validates the MetalLB -> ingress-nginx -> oauth2-proxy -> Dex -> nginx path.
No DNS or /etc/hosts changes are needed: curl resolves both configured hosts to
the supplied MetalLB address for this test only.

Required:
  --address IP                    MetalLB address assigned to ingress-nginx.

Options:
  --app-host HOST                 Protected application host. Default: ${APP_HOST}
  --dex-host HOST                 Dex issuer host. Default: ${DEX_HOST}
  --username USERNAME             Dex test username. Default: ${USERNAME}
  --password PASSWORD             Dex test password. Default: password
  --timeout SECONDS               Per-request curl timeout. Default: ${CURL_TIMEOUT_SECONDS}
  --keep-artifacts                Preserve curl headers, cookies, and bodies.
  --help                          Show this help.

Example:
  ${SCRIPT_NAME} --address 192.168.122.240
USAGE
}

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need_arg() { [[ -n "${2:-}" ]] || die "$1 requires a value"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --address) need_arg "$1" "${2:-}"; LOAD_BALANCER_ADDRESS="$2"; shift 2 ;;
      --address=*) LOAD_BALANCER_ADDRESS="${1#*=}"; shift ;;
      --app-host) need_arg "$1" "${2:-}"; APP_HOST="$2"; shift 2 ;;
      --app-host=*) APP_HOST="${1#*=}"; shift ;;
      --dex-host) need_arg "$1" "${2:-}"; DEX_HOST="$2"; shift 2 ;;
      --dex-host=*) DEX_HOST="${1#*=}"; shift ;;
      --username) need_arg "$1" "${2:-}"; USERNAME="$2"; shift 2 ;;
      --username=*) USERNAME="${1#*=}"; shift ;;
      --password) need_arg "$1" "${2:-}"; PASSWORD="$2"; shift 2 ;;
      --password=*) PASSWORD="${1#*=}"; shift ;;
      --timeout) need_arg "$1" "${2:-}"; CURL_TIMEOUT_SECONDS="$2"; shift 2 ;;
      --timeout=*) CURL_TIMEOUT_SECONDS="${1#*=}"; shift ;;
      --keep-artifacts) KEEP_ARTIFACTS=true; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

validate_inputs() {
  [[ "$LOAD_BALANCER_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "--address must be an IPv4 address: ${LOAD_BALANCER_ADDRESS:-<missing>}"
  [[ "$APP_HOST" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$APP_HOST" != *".."* ]] || die "--app-host must be a lowercase DNS host"
  [[ "$DEX_HOST" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$DEX_HOST" != *".."* ]] || die "--dex-host must be a lowercase DNS host"
  [[ "$APP_HOST" != "$DEX_HOST" ]] || die "--app-host and --dex-host must differ"
  [[ "$CURL_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive integer"
  command -v curl >/dev/null 2>&1 || die "curl was not found in PATH"
  command -v awk >/dev/null 2>&1 || die "awk was not found in PATH"
  command -v mktemp >/dev/null 2>&1 || die "mktemp was not found in PATH"
}

create_workspace() {
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCRIPT_NAME%.sh}.XXXXXX")"
  COOKIE_JAR="${TMP_DIR}/cookies.txt"
  HEADERS_FILE="${TMP_DIR}/headers.txt"
  LOGIN_PAGE_FILE="${TMP_DIR}/dex-login.html"
  APP_BODY_FILE="${TMP_DIR}/nginx.html"
  log "Curl test artifacts directory: ${TMP_DIR}"
}

cleanup() {
  if [[ -z "$TMP_DIR" ]]; then return; fi
  if [[ "$KEEP_ARTIFACTS" == true ]]; then
    log "Keeping curl test artifacts in ${TMP_DIR}"
  else
    log "Removing curl test artifacts"
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

curl_common() {
  printf '%s\n' --silent --show-error --noproxy '*' --connect-timeout "$CURL_TIMEOUT_SECONDS" --max-time "$CURL_TIMEOUT_SECONDS" \
    --resolve "${APP_HOST}:80:${LOAD_BALANCER_ADDRESS}" \
    --resolve "${DEX_HOST}:80:${LOAD_BALANCER_ADDRESS}"
}

run_curl() {
  local args=()
  mapfile -t args < <(curl_common)
  curl "${args[@]}" "$@"
}

assert_dex_discovery() {
  local discovery
  log "Checking Dex discovery through ingress-nginx and MetalLB"
  discovery="$(run_curl "http://${DEX_HOST}/.well-known/openid-configuration")"
  grep -Eq "\"issuer\"[[:space:]]*:[[:space:]]*\"http://${DEX_HOST}\"" <<<"$discovery" || die "Dex discovery did not report issuer http://${DEX_HOST}"
  grep -Eq "\"authorization_endpoint\"[[:space:]]*:" <<<"$discovery" || die "Dex discovery did not return an authorization endpoint"
  log "Dex discovery reports the configured issuer and authorization endpoint"
}

assert_unauthenticated_redirect() {
  local status location
  log "Checking nginx external authentication redirects an unauthenticated request"
  status="$(run_curl --dump-header "$HEADERS_FILE" --output /dev/null --write-out '%{http_code}' "http://${APP_HOST}/")"
  [[ "$status" == 302 ]] || die "expected HTTP 302 from protected nginx endpoint, got ${status}"
  location="$(awk 'BEGIN { IGNORECASE=1 } /^location:/ { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$HEADERS_FILE")"
  [[ "$location" == *"/oauth2/start"* ]] || die "protected endpoint did not redirect to oauth2-proxy; Location was ${location:-<missing>}"
  log "Unauthenticated request redirects to oauth2-proxy"
}

find_login_form_action() {
  awk 'BEGIN { RS=">"; IGNORECASE=1 }
    /<form/ && match($0, /action="[^"]+"/) {
      print substr($0, RSTART + 8, RLENGTH - 9)
      exit
    }' "$LOGIN_PAGE_FILE"
}

absolute_login_action() {
  local action="$1" login_url="$2"
  case "$action" in
    http://*|https://*) printf '%s\n' "$action" ;;
    /*) printf 'http://%s%s\n' "$DEX_HOST" "$action" ;;
    *) printf '%s/%s\n' "${login_url%/*}" "$action" ;;
  esac
}

login_and_assert_page() {
  local login_url action action_url final_url status approval_request
  log "Starting the oauth2-proxy authorization flow"
  login_url="$(run_curl --location --cookie "$COOKIE_JAR" --cookie-jar "$COOKIE_JAR" --output "$LOGIN_PAGE_FILE" --write-out '%{url_effective}' "http://${APP_HOST}/oauth2/start?rd=%2F")"
  [[ "$login_url" == http://${DEX_HOST}/* ]] || die "oauth2-proxy did not redirect to Dex; final URL was ${login_url}"
  action="$(find_login_form_action)"
  [[ -n "$action" ]] || die "could not locate the Dex password-login form action in ${login_url}"
  action="${action//&amp;/&}"
  action_url="$(absolute_login_action "$action" "$login_url")"
  log "Submitting the Dex password login form for ${USERNAME}"
  final_url="$(run_curl --location --cookie "$COOKIE_JAR" --cookie-jar "$COOKIE_JAR" --data-urlencode "login=${USERNAME}" --data-urlencode "password=${PASSWORD}" --output "$APP_BODY_FILE" --write-out '%{url_effective}' "$action_url")"
  if [[ "$final_url" == http://${DEX_HOST}/approval?* ]]; then
    approval_request="$(awk 'BEGIN { RS=">" } match($0, /name="req" value="[^"]+"/) { print substr($0, RSTART + 18, RLENGTH - 19); exit }' "$APP_BODY_FILE")"
    [[ -n "$approval_request" ]] || die "could not locate the Dex approval request value"
    log "Granting the Dex authorization request"
    final_url="$(run_curl --location --cookie "$COOKIE_JAR" --cookie-jar "$COOKIE_JAR" --data-urlencode "req=${approval_request}" --data-urlencode 'approval=approve' --output "$APP_BODY_FILE" --write-out '%{url_effective}' "$final_url")"
  fi
  [[ "$final_url" == http://${APP_HOST}/* ]] || die "Dex login did not return through oauth2-proxy to the application; final URL was ${final_url}"
  grep -Fq 'OCNE oauth2-proxy integration test passed' "$APP_BODY_FILE" || die "authenticated request did not receive the nginx integration-test page"
  log "Authorization code, oauth2-proxy callback, and nginx response succeeded"
  status="$(run_curl --cookie "$COOKIE_JAR" --output "$APP_BODY_FILE" --write-out '%{http_code}' "http://${APP_HOST}/")"
  [[ "$status" == 200 ]] || die "session cookie did not authorize a subsequent nginx request; got HTTP ${status}"
  grep -Fq 'OCNE oauth2-proxy integration test passed' "$APP_BODY_FILE" || die "subsequent authenticated request did not return the nginx integration-test page"
  log "oauth2-proxy session cookie authorizes a subsequent nginx request"
}

main() {
  log "Starting curl integration test for MetalLB, ingress-nginx, oauth2-proxy, Dex, and nginx"
  parse_args "$@"
  validate_inputs
  create_workspace
  assert_dex_discovery
  assert_unauthenticated_redirect
  login_and_assert_page
  log "Curl integration test completed successfully"
}

main "$@"
