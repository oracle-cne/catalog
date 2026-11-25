#!/usr/bin/env bash
# Copyright (c) 2026, Oracle and/or its affiliates.
# Command-to-RPM mapping for the catalog test entry point and its lifecycle.

catalog_test_privileged_operation() {
    # Only installation of missing packages may acquire additional privileges.
    case ${1:-} in
        dnf) [[ ${2:-} == install && ${3:-} == -y && $# -ge 4 ]] || die 'invalid privileged DNF operation' ;;
        *) die "unsupported privileged operation: ${1:-<empty>}" ;;
    esac
    if ((EUID == 0)); then
        log "Running required host operation as the current root user: $1"
        "$@"
    else
        command -v sudo >/dev/null || die "sudo is required for the privileged $1 operation"
        log "Elevating only the required host operation: $1"
        sudo -n -- "$@"
    fi
}

catalog_test_ensure_dependencies() {
    local tool package
    local missing=() packages=() unsupported=() unavailable=()
    local -A selected_packages=()
    log 'Checking required catalog test commands'
    for tool in "$@"; do
        if command -v -- "$tool" >/dev/null 2>&1; then
            log "Dependency available: $tool"
            continue
        fi
        missing+=("$tool")
        case $tool in
            git|yq|make|helm|podman|curl|tar|sed|grep|ocne|kubectl) package=$tool ;;
            awk) package=gawk ;;
            cmp) package=diffutils ;;
            find) package=findutils ;;
            basename|dirname|mktemp|rm|cat|sort|mkdir|chmod|sleep|date|wc|head|tail|tr|base64|seq|cut|stat)
                package=coreutils ;;
            *) unsupported+=("$tool"); continue ;;
        esac
        log "Missing dependency: $tool (DNF package: $package)"
        if [[ ! -v selected_packages[$package] ]]; then
            packages+=("$package")
            selected_packages[$package]=1
        fi
    done
    ((${#missing[@]})) || { log 'All required commands are available; no DNF installation needed'; return 0; }
    log "Missing commands: ${missing[*]}"
    ((${#unsupported[@]} == 0)) || die "no DNF package mapping for: ${unsupported[*]}; custom executable paths must already exist"
    command -v dnf >/dev/null || die "dnf is required to install missing commands: ${missing[*]}"
    log "Installing missing dependency packages through enabled DNF repositories: ${packages[*]}"
    catalog_test_privileged_operation dnf install -y "${packages[@]}" || die "DNF dependency installation failed; required commands: ${missing[*]}"
    hash -r
    for tool in "${missing[@]}"; do
        if command -v -- "$tool" >/dev/null 2>&1; then
            log "Installed dependency verified: $tool"
        else
            unavailable+=("$tool")
        fi
    done
    ((${#unavailable[@]} == 0)) || die "commands still unavailable after DNF installation: ${unavailable[*]}"
    log 'Dependency installation and verification complete'
}
