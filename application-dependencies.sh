#!/usr/bin/env bash
# Application dependencies are separate catalog releases, not Helm subcharts.
# Emit resolved JSON; diagnostics stay on stderr for callers capturing metadata.
catalog_resolve_application_dependencies() {
    local template=$1 version=$2 document
    printf 'application-dependencies: Reading %s for version %s\n' "$template" "$version" >&2
    document=$(cat -- "$template") || return 1
    if ! printf '%s\n' "$document" | yq -e '
        (.applicationDependencies == null or (.applicationDependencies | tag) == "!!seq") and
        ([(.applicationDependencies // [])[] | select(
            (.name | tag) != "!!str" or
            (.name | test("^[a-z0-9][a-z0-9-]*$") | not) or
            (has("version") and ((.version | tag) != "!!str" or
                (.version | test("^[0-9][a-zA-Z0-9.+-]*$") | not)))
        )] | length == 0)
    ' >/dev/null; then
        printf 'application-dependencies: Invalid applicationDependencies in %s\n' "$template" >&2
        return 1
    fi
    printf '%s\n' "$document" | CATALOG_DEPENDENCY_VERSION="$version" yq -o=json -I=0 '
        (.applicationDependencies // []) |
            map(.version = (.version // strenv(CATALOG_DEPENDENCY_VERSION)))
    '
}

# Check committed dependency metadata before diff-selected tests provision resources.
catalog_check_application_dependencies() {
    local revision=$1 app=$2 version=$3 metadata=$4 chain=${5:-}
    local identity="$app@$version" dependencies rows name required child template_paths template
    case "|$chain|" in
        *"|$identity|"*)
            printf 'application-dependencies: Cycle: %s|%s\n' "$chain" "$identity" >&2
            return 1 ;;
    esac
    chain="${chain:+$chain|}$identity"
    dependencies=$(printf '%s\n' "$metadata" | yq -r '.annotations."catalog.oracle.com/application-dependencies" // ""') || return 1
    if [[ -n $dependencies ]]; then
        dependencies=$(catalog_resolve_application_dependencies <(printf 'applicationDependencies: %s\n' "$dependencies") "$version") || return 1
    else
        # Older catalog entries predate the annotation. Apply the template at
        # the same commit without rewriting those existing charts.
        template_paths=$(git ls-tree -r --name-only "$revision" -- "templates/$app/template.yaml") || return 1
        if [[ -n $template_paths ]]; then
            template=$(git show "$revision:templates/$app/template.yaml") || return 1
            dependencies=$(catalog_resolve_application_dependencies <(printf '%s\n' "$template") "$version") || return 1
        else
            dependencies='[]'
        fi
    fi
    rows=$(printf '%s\n' "$dependencies" | yq -r '.[] | [.name, .version] | @tsv') || return 1
    while IFS=$'\t' read -r name required; do
        [[ -n $name ]] || continue
        printf 'application-dependencies: Checking %s requires %s@%s at %s\n' "$identity" "$name" "$required" "$revision" >&2
        child=$(git show "$revision:charts/$name-$required/Chart.yaml") || return 1
        if ! printf '%s\n' "$child" | CATALOG_DEPENDENCY_NAME="$name" CATALOG_DEPENDENCY_VERSION="$required" yq -e '
            .name == strenv(CATALOG_DEPENDENCY_NAME) and
            .version == strenv(CATALOG_DEPENDENCY_VERSION) and
            .appVersion == strenv(CATALOG_DEPENDENCY_VERSION)' >/dev/null; then
            printf 'application-dependencies: Invalid dependency identity: %s@%s\n' "$name" "$required" >&2
            return 1
        fi
        catalog_check_application_dependencies "$revision" "$name" "$required" "$child" "$chain" || return 1
    done <<< "$rows"
}
