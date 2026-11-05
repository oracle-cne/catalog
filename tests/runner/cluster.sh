#!/usr/bin/env bash
# Copyright (c) 2026, Oracle and/or its affiliates.
# Native OCNE profile lifecycle for clusters owned by this test run.

catalog_test_cluster_name=
catalog_test_cluster_directory=

catalog_test_cluster_start() {
    local profile=$1 suite=$2 resolved
    [[ -s $profile ]] || die "missing component cluster profile: $profile"
    catalog_test_ensure_dependencies "$OCNE_BIN" yq
    log 'Using the supplied libvirt/provider environment without host configuration changes'
    catalog_test_cluster_directory=$(mktemp -d "${TMPDIR:-/tmp}/catalog-cluster.XXXXXXXX")
    catalog_test_cluster_name="catalog-$suite-${catalog_test_cluster_directory##*.}"
    catalog_test_cluster_name=${catalog_test_cluster_name,,}
    # Record ownership before start: failed provisioning can leave partial VMs.
    unset KUBECONFIG
    log "Starting OCNE cluster $catalog_test_cluster_name using $profile"
    "$OCNE_BIN" cluster start --config "$profile" --cluster-name "$catalog_test_cluster_name" --auto-start-ui=false
    log "Resolving kubeconfig for $catalog_test_cluster_name through OCNE cluster show"
    resolved=$("$OCNE_BIN" cluster show --cluster-name "$catalog_test_cluster_name")
    [[ -n $resolved && -f $resolved && -r $resolved && -s $resolved ]] || die "OCNE did not export a readable, nonempty kubeconfig for $catalog_test_cluster_name"
    export KUBECONFIG="$resolved"
    log "Component cluster ready: $catalog_test_cluster_name; KUBECONFIG=$KUBECONFIG"
}

catalog_test_cluster_stop() {
    if [[ -n $catalog_test_cluster_name ]]; then
        if [[ -n ${CATALOG_RETAIN:-} ]]; then
            log "Retaining OCNE cluster $catalog_test_cluster_name because CATALOG_RETAIN is non-empty"
            log "Inspect its kubeconfig with: $OCNE_BIN cluster show --cluster-name $catalog_test_cluster_name"
        else
            log "Deleting owned OCNE cluster $catalog_test_cluster_name"
            if ! "$OCNE_BIN" cluster delete --cluster-name "$catalog_test_cluster_name"; then
                log "ERROR: could not delete owned OCNE cluster $catalog_test_cluster_name"
                return 1
            fi
        fi
        catalog_test_cluster_name=
        unset KUBECONFIG
    fi
    if [[ -n $catalog_test_cluster_directory ]]; then
        rm -rf -- "$catalog_test_cluster_directory" || return 1
        catalog_test_cluster_directory=
    fi
}
