#!/usr/bin/env bash
# Copyright (c) 2026, Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0.
set -Eeuo pipefail

log() { printf 'catalog-tests: %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
usage() {
    cat <<'USAGE'
Usage: tests/run-changed.sh [--head REF] [--list]
Compare committed charts against the branch fork point. --list prints TSV:
application, version, suite, version option, extra option, extra value.
Discover base refs from main and release/* local/origin refs using Git ancestry.
Reject missing or ambiguous ancestry rather than selecting an arbitrary parent.
--head defaults to HEAD. Working-tree edits are not included.
KUBECONFIG may supply an existing, readable, nonempty kubeconfig. When absent,
create a cluster per selected test using its component cluster.yaml profile.
Delete owned clusters afterward unless CATALOG_RETAIN is non-empty.
Build the candidate Helm repository, serve it with
containerized nginx, and register a temporary catalog for the selected suites.
OCNE_BIN defaults to ocne. Supplied clusters are never deleted by this script.
--list needs Git and yq only; it does not contact Kubernetes.
Missing command dependencies are installed through the enabled DNF repositories.
USAGE
}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
head_ref=HEAD
list=false
while (($#)); do
    case $1 in
        --help) usage; exit 0 ;;
        --list) list=true; shift ;;
        --head)
            (($# >= 2)) && [[ -n $2 ]] || die "$1 requires a value"
            head_ref=$2
            shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
source "$root/tests/runner/dependencies.sh"
source "$root/application-dependencies.sh"
catalog_test_ensure_dependencies git yq awk sort mktemp rm cat
head=$(git rev-parse --verify --end-of-options "${head_ref}^{commit}") || die "invalid head: $head_ref"
log "Selecting committed chart changes at $head"
[[ $(git rev-parse --is-shallow-repository) == false ]] || die 'complete Git history is required; supply a complete checkout'
# Git records ancestry, not the name used at branch creation. Retain only
# maximal common ancestors and their refs; never choose between incomparable
# fork points using dates, branch names, or commit counts.
refs=$(git for-each-ref --format='%(refname)' refs/heads/main refs/heads/release/ refs/remotes/origin/main refs/remotes/origin/release/)
declare -A forks=()
while IFS= read -r ref; do
    [[ -n $ref ]] || continue
    parent=$(git rev-parse --verify "${ref}^{commit}")
    candidate=$(git merge-base --all "$parent" "$head") || die "cannot compare parent candidate $ref"
    [[ $candidate != *$'\n'* ]] || die "multiple merge bases for $ref; base discovery cannot resolve ancestry"
    forks[$candidate]="${forks[$candidate]:-} $ref"
    log "Parent candidate $ref has fork point $candidate"
done <<< "$refs"
maximal=()
for candidate in "${!forks[@]}"; do
    ancestor=false
    for other in "${!forks[@]}"; do
        [[ $candidate != "$other" ]] || continue
        if git merge-base --is-ancestor "$candidate" "$other"; then
            ancestor=true
            break
        else
            status=$?
            ((status == 1)) || die 'ancestry inspection failed'
        fi
    done
    $ancestor || maximal+=("$candidate")
done
((${#maximal[@]} == 1)) || die 'base ref discovery found missing or ambiguous ancestry; no unique fork point is available'
fork=${maximal[0]}
log "Discovered base refs:${forks[$fork]}; fork point $fork"
# Disabling rename detection includes both sides of moves, including moves
# between applications. Read NUL-delimited paths without shell word splitting.
paths=$(mktemp)
cleanup() {
    local status=$?
    trap - EXIT
    log 'Removing temporary changed-path list'
    rm -f "$paths" || status=1
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
git diff --no-renames --name-only -z "$fork" "$head" -- charts > "$paths"
declare -A charts=()
while IFS= read -r -d '' path; do
    [[ $path == charts/*/* ]] || continue
    chart=${path#charts/}
    charts[${chart%%/*}]=1
done < "$paths"
plan=()
missing=()
while IFS= read -r chart; do
    [[ -n $chart ]] || continue
    chart_paths=$(git ls-tree -r --name-only "$head" -- "charts/$chart/") || die "cannot inspect candidate chart $chart"
    if [[ -z $chart_paths ]]; then
        log "Removed chart $chart has no candidate to install"
        continue
    fi
    [[ $'\n'$chart_paths$'\n' == *$'\n'"charts/$chart/Chart.yaml"$'\n'* ]] || die "candidate chart $chart is missing Chart.yaml"
    metadata=$(git show "$head:charts/$chart/Chart.yaml") || die "cannot read chart $chart"
    app=$(printf '%s\n' "$metadata" | yq -r .name) || die "invalid chart metadata: $chart"
    version=$(printf '%s\n' "$metadata" | yq -r .version) || die "invalid chart metadata: $chart"
    [[ $app =~ ^[a-z0-9][a-z0-9-]*$ && $version =~ ^[0-9][a-zA-Z0-9.+-]*$ && $chart == "$app-$version" ]] || die "invalid chart identity: $chart"
    catalog_check_application_dependencies "$head" "$app" "$version" "$metadata" || die "invalid application dependency chain for $chart"
    mapping=$(awk -F '\t' -v app="$app" '$1 == app { print; count++ } END { if (count != 1) exit 1 }' tests/suites.tsv) || {
        missing+=("$app ($version)")
        continue
    }
    IFS=$'\t' read -r mapped suite option extra value <<< "$mapping"
    [[ -x tests/$suite/test.sh && -s tests/$suite/cluster.yaml ]] || die "suite $suite is missing test.sh or cluster.yaml"
    plan+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$app" "$version" "$suite" "$option" "$extra" "$value")")
    log "Selected $app $version using suite $suite"
done < <(printf '%s\n' "${!charts[@]}" | LC_ALL=C sort)
((${#missing[@]} == 0)) || die "no test mapping for changed applications: ${missing[*]}; add coverage in tests/suites.tsv"
if ((${#plan[@]} == 0)); then
    log 'No new or modified application charts; no tests required'
    exit 0
fi
if $list; then
    printf '%s\n' "${plan[@]}"
    exit 0
fi
checkout_head=$(git rev-parse --verify HEAD)
[[ $head == "$checkout_head" ]] || die '--head selects another revision; use --list or run from that revision checkout'
log "Passing ${#plan[@]} selected test(s) to the resource wrapper"
printf '%s\n' "${plan[@]}" | "$root/tests/runner/run-tests.sh" --plan "$head"
