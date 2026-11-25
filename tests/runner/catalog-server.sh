#!/usr/bin/env bash
# Copyright (c) 2026, Oracle and/or its affiliates.
# Sourced by run-changed.sh; owns only its candidate repository and nginx container.

source "${BASH_SOURCE[0]%/*}/dependencies.sh"

catalog_test_directory=
catalog_test_registered=false
catalog_test_namespace_created=false
catalog_test_name=
catalog_test_uri=

catalog_test_unregister() {
    local failed=0
    if $catalog_test_registered; then
        log "Removing test catalog $catalog_test_name from the cluster"
        if ! "$OCNE_BIN" catalog remove --name "$catalog_test_name" --namespace "$catalog_test_name"; then
            log "ERROR: could not remove test catalog $catalog_test_name"
            failed=1
        fi
        catalog_test_registered=false
    fi
    if $catalog_test_namespace_created; then
        log "Deleting test catalog namespace $catalog_test_name"
        if ! "$KUBECTL_BIN" delete namespace "$catalog_test_name" --wait=true --timeout=30s; then
            log "ERROR: could not delete test catalog namespace $catalog_test_name"
            failed=1
        fi
        catalog_test_namespace_created=false
    fi
    return "$failed"
}

catalog_test_stop() {
    local failed=0
    catalog_test_unregister || failed=1
    if [[ -n $catalog_test_directory && -s $catalog_test_directory/nginx.cid ]]; then
        local container
        container=$(cat "$catalog_test_directory/nginx.cid")
        log 'Collecting candidate catalog nginx logs'
        podman logs "$container" || failed=1
        log 'Removing candidate catalog nginx container and anonymous volumes'
        podman rm --force --volumes "$container" || failed=1
    fi
    if [[ -n $catalog_test_directory ]]; then
        log 'Removing isolated candidate catalog files'
        rm -rf -- "$catalog_test_directory" || failed=1
        catalog_test_directory=
    fi
    return "$failed"
}

catalog_test_serve() {
    local revision=$1 binding attempt response container
    catalog_test_ensure_dependencies make helm podman curl tar cmp find sed grep \
        basename dirname mkdir chmod sleep date wc head tail tr base64 seq cut stat \
        "$OCNE_BIN" "$KUBECTL_BIN"
    catalog_test_directory=$(mktemp -d /tmp/catalog-tests.XXXXXXXX)
    catalog_test_name="catalog-tests-${catalog_test_directory##*.}"
    catalog_test_name=${catalog_test_name,,}
    mkdir -p "$catalog_test_directory/source" "$catalog_test_directory/public"
    log "Staging candidate catalog commit $revision without modifying the checkout"
    git archive "$revision" Makefile check-chart.sh README.md charts olm/icons |
        tar -xf - -C "$catalog_test_directory/source"
    log 'Building candidate Helm repository through the catalog Makefile'
    make -C "$catalog_test_directory/source" REPO_DIR="$catalog_test_directory/public/charts"
    [[ -s $catalog_test_directory/public/charts/index.yaml ]] || die 'catalog build did not produce index.yaml'

    # The registration is consumed by OCNE on this worker (ExternalName catalogs
    # use their annotated URI directly). No address discovery or cluster pod is
    # needed. A private health token prevents accepting another server's response.
    cat > "$catalog_test_directory/nginx.conf" <<NGINX
worker_processes 1;
pid /tmp/nginx.pid;
error_log stderr;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path /tmp/client_body;
    proxy_temp_path /tmp/proxy;
    fastcgi_temp_path /tmp/fastcgi;
    uwsgi_temp_path /tmp/uwsgi;
    scgi_temp_path /tmp/scgi;
    server {
        listen 80;
        location = /health { return 200 '$catalog_test_name'; }
        location /charts/ { root /srv/catalog; }
    }
}
NGINX
    chmod -R a+rX "$catalog_test_directory/public"
    log 'Starting candidate catalog with container-registry.oracle.com/olcne/nginx:1.26.3'
    # Keep a CID file even when startup fails, so cleanup can remove a partially
    # started container. Podman allocates the host port rather than guessing one.
    podman run --detach --name "$catalog_test_name" \
        --cidfile "$catalog_test_directory/nginx.cid" \
        --publish 127.0.0.1::80 \
        --volume "$catalog_test_directory/public:/srv/catalog:ro,Z" \
        --volume "$catalog_test_directory/nginx.conf:/etc/nginx/nginx.conf:ro,Z" \
        container-registry.oracle.com/olcne/nginx:1.26.3 \
        nginx -c /etc/nginx/nginx.conf -e /dev/stderr -g 'daemon off;'
    container=$(cat "$catalog_test_directory/nginx.cid")
    binding=$(podman port "$container" 80/tcp)
    [[ $binding =~ ^127[.]0[.]0[.]1:[0-9]+$ ]] || die 'nginx has no valid loopback port mapping'
    catalog_test_uri="http://$binding"
    log "Candidate catalog nginx is published at $catalog_test_uri"
    response=
    for ((attempt = 0; attempt < 20; attempt++)); do
        [[ $(podman inspect --format '{{.State.Running}}' "$container") == true ]] || die 'candidate catalog nginx container exited during startup'
        if response=$(curl --noproxy '*' --fail --silent --show-error --connect-timeout 1 --max-time 2 "$catalog_test_uri/health") &&
                [[ $response == "$catalog_test_name" ]]; then
            break
        fi
        sleep 1
    done
    [[ $response == "$catalog_test_name" ]] || die 'candidate catalog nginx did not become ready'
    curl --noproxy '*' --fail --silent --show-error --max-time 10 "$catalog_test_uri/charts/index.yaml" > "$catalog_test_directory/served-index.yaml"
    cmp "$catalog_test_directory/public/charts/index.yaml" "$catalog_test_directory/served-index.yaml" || die 'served index differs from candidate index'
}

catalog_test_register() {
    log "Creating isolated test catalog namespace $catalog_test_name"
    "$KUBECTL_BIN" create namespace "$catalog_test_name"
    catalog_test_namespace_created=true
    log "Registering candidate catalog $catalog_test_name in the supplied cluster"
    "$OCNE_BIN" catalog add --name "$catalog_test_name" --namespace "$catalog_test_name" --uri "$catalog_test_uri"
    catalog_test_registered=true
    log 'Verifying OCNE can read the registered candidate catalog'
    "$OCNE_BIN" catalog search --name "$catalog_test_name"
}

catalog_test_start() {
    catalog_test_serve "$1"
    catalog_test_register
}
