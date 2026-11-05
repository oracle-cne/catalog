#!/usr/bin/env bash
# Copyright (c) 2026, Oracle and/or its affiliates.
# Resource wrapper: one named suite or selected TSV rows -> setup -> test -> cleanup.
set -Eeuo pipefail
log() { printf 'catalog-resources: %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
source "$root/tests/runner/catalog-server.sh"
source "$root/tests/runner/cluster.sh"
if [[ ${1:-} == --help ]]; then
    printf 'Usage: tests/runner/run-tests.sh SUITE\n       tests/runner/run-tests.sh --plan COMMIT < selected-tests.tsv\n'
    exit 0
elif [[ ${1:-} == --plan ]]; then
    (($# == 2)) || die '--plan requires the selected catalog commit'
    mode=plan
    head=$2
    mapfile -t plan
else
    (($# == 1)) || die 'supply a component suite name, such as prometheus'
    mode=suite
    suite=$1
    [[ $suite =~ ^[a-z0-9][a-z0-9-]*$ && -x tests/$suite/test.sh && -s tests/$suite/cluster.yaml ]] || die "unknown component suite: $suite"
    catalog_test_ensure_dependencies git
    head=$(git rev-parse --verify HEAD)
    plan=("$suite")
fi
((${#plan[@]})) || die 'no selected tests were supplied'
log "Preparing resources for ${#plan[@]} selected test(s)"
kubeconfig=${KUBECONFIG:-}
cleanup() {
    local status=$?
    trap - EXIT
    catalog_test_stop || status=1
    catalog_test_cluster_stop || status=1
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -n $kubeconfig ]]; then
    [[ -f $kubeconfig && -r $kubeconfig && -s $kubeconfig ]] || die 'KUBECONFIG must name an existing, readable, nonempty file'
fi
export KUBECONFIG="$kubeconfig"
export OCNE_BIN=${OCNE_BIN:-ocne}
export KUBECTL_BIN=${KUBECTL_BIN:-kubectl}
catalog_test_serve "$head"
failed=0
for entry in "${plan[@]}"; do
    arguments=()
    if [[ $mode == plan ]]; then
        IFS=$'\t' read -r app version suite option extra value <<< "$entry"
        arguments+=("$option" "$version")
        [[ $extra == - ]] || arguments+=("$extra" "$value")
    else
        suite=$entry
        app=$suite
        version='catalog default'
    fi
    if [[ -z $kubeconfig ]]; then
        catalog_test_cluster_start "$root/tests/$suite/cluster.yaml" "$suite"
    fi
    catalog_test_register
    log "Starting $app $version ($suite) in the selected cluster"
    command=("$root/tests/$suite/test.sh" --kubeconfig "$KUBECONFIG" "${arguments[@]}")
    if [[ $suite == oauth2-proxy ]]; then
        [[ -n ${METALLB_ADDRESS_POOL:-} ]] || die 'METALLB_ADDRESS_POOL is required for the OAuth2 integration suite'
        command+=(--metallb-address-pool "$METALLB_ADDRESS_POOL")
    fi
    if CATALOG_TEST_NAME="$catalog_test_name" "${command[@]}"; then
        log "PASS $app $version"
    else
        status=$?
        log "FAIL $app $version (exit $status)"
        failed=1
    fi
    catalog_test_unregister || die 'test catalog cleanup failed'
    catalog_test_cluster_stop || die 'test cluster cleanup failed'
done
log "Selected application tests finished; failure status=$failed"
exit "$failed"
