#! /bin/bash

APP_PATTERN="$1"
APP=""
APP_VERSION="$2"
KUBE_VERSION="$3"
ROOT_DIR="$PWD"

REPO_NAME="tmp-repo"

TEMPLATE_FILE=""

if [ -z "$REGISTRY" ]; then
	REGISTRY=container-registry.oracle.com
fi

preserve_values_yaml_before_yq() {
	awk '
		/^[[:space:]]*$/ {
			print "#__GENERATE_SH_BLANK__"
			next
		}
		/^[[:space:]]*#/ {
			print "#" $0
			next
		}
		{
			print
		}
	' values.yaml > values.yaml.preserved
	mv values.yaml.preserved values.yaml
}

restore_values_yaml_after_yq() {
	awk '
		/^[[:space:]]*#/ {
			line = $0
			sub(/^[[:space:]]*#/, "", line)
			if (line == "__GENERATE_SH_BLANK__") {
				print ""
			} else {
				print line
			}
			next
		}
		{
			print
		}
	' values.yaml > values.yaml.restored
	mv values.yaml.restored values.yaml
}

update_values_yaml_with_yq() {
	EXPR="$1"
	preserve_values_yaml_before_yq
	yq -i "$EXPR" values.yaml
	STATUS="$?"
	if [ "$STATUS" != "0" ]; then
		restore_values_yaml_after_yq
		echo "Could not apply values.yaml yq expression: ${EXPR}"
		exit "$STATUS"
	fi
	restore_values_yaml_after_yq
}

apply_extra_values_yqs() {
	if ! yq -e '.extraValuesYqs' "$TEMPLATE_FILE" > /dev/null 2>&1; then
		echo "No extra values.yaml yq expressions defined for ${APP}"
		return
	fi

	echo "Applying extra values.yaml yq expressions for ${APP}"
	while IFS= read -r -d '' EXPR; do
		echo "Applying values.yaml yq expression: ${EXPR}"
		APP_VERSION="$APP_VERSION" TEMPLATE_DIR="$(dirname "$TEMPLATE_FILE")" update_values_yaml_with_yq "$EXPR"
	done < <(yq -r -0 '.extraValuesYqs[]' "$TEMPLATE_FILE")
}

apply_extra_file_yqs() {
	if ! yq -e '.extraFileYqs' "$TEMPLATE_FILE" > /dev/null 2>&1; then
		echo "No extra chart file yq expressions defined for ${APP}"
		return
	fi

	NUM_FILE_YQS=$(yq '.extraFileYqs | length' "$TEMPLATE_FILE")
	NUM_FILE_YQS=$((NUM_FILE_YQS-1))
	for i in $(seq 0 $NUM_FILE_YQS); do
		TARGET_FILE=$(yq -r ".extraFileYqs[$i].file" "$TEMPLATE_FILE")
		EXPR=$(yq -r ".extraFileYqs[$i].yq" "$TEMPLATE_FILE")
		if [ ! -f "$TARGET_FILE" ]; then
			echo "Skipping missing chart file ${TARGET_FILE} for ${APP}"
			continue
		fi
		echo "Applying yq expression to ${TARGET_FILE}: ${EXPR}"
		APP_VERSION="$APP_VERSION" TEMPLATE_DIR="$(dirname "$TEMPLATE_FILE")" yq -i "$EXPR" "$TARGET_FILE"
		STATUS="$?"
		if [ "$STATUS" != "0" ]; then
			echo "Could not apply yq expression to ${TARGET_FILE}: ${EXPR}"
			exit "$STATUS"
		fi
	done
}

apply_template_patches() {
	if ! yq -e '.patches' "$TEMPLATE_FILE" > /dev/null 2>&1; then
		echo "No patches defined for ${APP}"
		return
	fi

	NUM_PATCHES=$(yq '.patches | length' "$TEMPLATE_FILE")
	NUM_PATCHES=$((NUM_PATCHES-1))
	for i in $(seq 0 $NUM_PATCHES); do
		PATCH_BODY=$(yq -r ".patches[$i].patch" "$TEMPLATE_FILE")
		REQUIRED=$(yq -r ".patches[$i].required" "$TEMPLATE_FILE")
		if [ "$REQUIRED" = "null" ]; then
			REQUIRED=true
		fi

		PATCH_FILE=$(mktemp)
		printf "%s\n" "$PATCH_BODY" > "$PATCH_FILE"
		echo "Checking contextual patch ${i} for ${APP}"
		patch --dry-run --batch --forward --fuzz=0 -p0 < "$PATCH_FILE"
		STATUS="$?"
		if [ "$STATUS" != "0" ]; then
			rm -f "$PATCH_FILE"
			if [ "$REQUIRED" = "false" ]; then
				echo "Skipping optional patch ${i} for ${APP}: patch context not found"
				continue
			fi
			echo "Cannot apply required patch ${i} for ${APP}"
			exit "$STATUS"
		fi

		echo "Applying contextual patch ${i} for ${APP}"
		patch --batch --forward --no-backup-if-mismatch --fuzz=0 -p0 < "$PATCH_FILE"
		STATUS="$?"
		rm -f "$PATCH_FILE"
		if [ "$STATUS" != "0" ]; then
			echo "Could not apply patch ${i} for ${APP}"
			exit "$STATUS"
		fi
	done
}

cleanup_pull_dir() {
	PULL_DIR="$1"
	if [ -z "$PULL_DIR" ] || [ ! -d "$PULL_DIR" ]; then
		return
	fi

	case "$PULL_DIR" in
		"$ROOT_DIR"/charts/.pull-*)
			echo "Removing temporary chart pull directory ${PULL_DIR}"
			rm -rf "$PULL_DIR"
			;;
		*)
			echo "Refusing to remove unexpected pull directory ${PULL_DIR}"
			exit 1
			;;
	esac
}

backup_existing_output_dir() {
	OUTPUT_DIR="$1"
	if [ ! -e "$OUTPUT_DIR" ]; then
		echo "Output directory ${OUTPUT_DIR} does not exist; fresh generation will create it"
		return
	fi

	BACKUP_PARENT=$(mktemp -d "$ROOT_DIR/charts/.${OUTPUT_DIR}.previous.XXXXXX")
	BACKUP_DIR="${BACKUP_PARENT}/${OUTPUT_DIR}"
	echo "Output directory ${OUTPUT_DIR} already exists; preserving it at ${BACKUP_DIR}"
	mv "$OUTPUT_DIR" "$BACKUP_DIR"
}

pull_chart_to_temp_dir() {
	PULL_DIR=$(mktemp -d "$ROOT_DIR/charts/.pull-${APP}-${APP_VERSION}.XXXXXX")
	echo "Pulling ${CHART}@${V_CHART_VERSION} into temporary directory ${PULL_DIR}"
	helm pull --untar --destination "$PULL_DIR" "$REPO_NAME/$CHART" --version "$V_CHART_VERSION"
	if [ "$?" != "0" ]; then
		echo "Could not pull ${CHART}@${V_CHART_VERSION} from ${REPO_URL}; retrying ${CHART_VERSION}"
		cleanup_pull_dir "$PULL_DIR"
		PULL_DIR=$(mktemp -d "$ROOT_DIR/charts/.pull-${APP}-${APP_VERSION}.XXXXXX")
		echo "Pulling ${CHART}@${CHART_VERSION} into temporary directory ${PULL_DIR}"
		helm pull --untar --destination "$PULL_DIR" "$REPO_NAME/$CHART" --version "$CHART_VERSION"
		if [ "$?" != "0" ]; then
			echo "Could not pull ${CHART}@${CHART_VERSION} from ${REPO_URL}"
			cleanup_pull_dir "$PULL_DIR"
			exit 1
		fi
	fi

	echo "Pulled ${CHART} into ${PULL_DIR}/${CHART}"
}

sanitize_chart_readme() {
	if [ ! -f README.md ]; then
		return
	fi

	echo "Sanitizing Helm command examples in README.md"
	sed -i \
		-e "s/^[[:space:]]*helm install .*/ocne application install --release [RELEASE_NAME] --name ${APP} --namespace [NAMESPACE]/I" \
		-e "s/^[[:space:]]*helm upgrade .*/ocne application update --release [RELEASE_NAME] --namespace [NAMESPACE]/I" \
		-e "s/^[[:space:]]*helm uninstall .*/ocne application uninstall --release [RELEASE_NAME] --namespace [NAMESPACE]/I" \
		-e "s/^[[:space:]]*helm delete .*/ocne application uninstall --release [RELEASE_NAME] --namespace [NAMESPACE]/I" \
		README.md
}

update_readme_version() {
	awk -v app="$APP" -v version="$APP_VERSION" '
		BEGIN {
			FS = "|"
			OFS = "|"
		}
		$0 ~ /^\|/ && $3 ~ "^[[:space:]]*" app "[[:space:]]*$" {
			versions = $4
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", versions)
			numVersions = split(versions, versionList, /<br>/)
			updatedVersions = version
			for (i = 1; i <= numVersions; i++) {
				currentVersion = versionList[i]
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", currentVersion)
				if (currentVersion != "" && currentVersion != version) {
					updatedVersions = updatedVersions "<br>" currentVersion
				}
			}
			$4 = " " updatedVersions " "
		}
		{
			print
		}
	' README.md > README.md.updated
	mv README.md.updated README.md
}

resolve_kube_version() {
	BOUND="$1"
	URL=$(yq -r ".kubeVersion.${BOUND}.url // \"\"" "$TEMPLATE_FILE")
	COMMAND=$(yq -r ".kubeVersion.${BOUND}.command // \"\"" "$TEMPLATE_FILE")
	if [ -z "$URL" ] && [ -z "$COMMAND" ]; then
		echo "Template kubeVersion stanza must define ${BOUND}.url or ${BOUND}.command for ${APP}" >&2
		exit 1
	fi

	if [ -n "$URL" ]; then
		echo "Fetching ${BOUND} kubeVersion page for ${APP}: ${URL}" >&2
		PAGE_CONTENT=$(curl -L --fail -sS "$URL")
		STATUS="$?"
		if [ "$STATUS" != "0" ]; then
			echo "Could not fetch ${BOUND} kubeVersion page for ${APP}: ${URL}" >&2
			exit "$STATUS"
		fi
	fi

	if [ -n "$COMMAND" ]; then
		echo "Resolving ${BOUND} kubeVersion for ${APP} with template command" >&2
		if [ -n "$URL" ]; then
			COMMAND_OUTPUT=$(
				printf "%s" "$PAGE_CONTENT" | \
				APP="$APP" \
				APP_VERSION="$APP_VERSION" \
				CHART="$CHART" \
				CHART_VERSION="$CHART_VERSION" \
				KUBE_VERSION_URL="$URL" \
				ROOT_DIR="$ROOT_DIR" \
				TEMPLATE_DIR="$(dirname "$TEMPLATE_FILE")" \
					bash -o pipefail -c "$COMMAND"
			)
		else
			COMMAND_OUTPUT=$(
				APP="$APP" \
				APP_VERSION="$APP_VERSION" \
				CHART="$CHART" \
				CHART_VERSION="$CHART_VERSION" \
				ROOT_DIR="$ROOT_DIR" \
				TEMPLATE_DIR="$(dirname "$TEMPLATE_FILE")" \
					bash -o pipefail -c "$COMMAND"
			)
		fi
		STATUS="$?"
		if [ "$STATUS" != "0" ]; then
			echo "Could not resolve ${BOUND} kubeVersion for ${APP}" >&2
			exit "$STATUS"
		fi
	else
		COMMAND_OUTPUT="$PAGE_CONTENT"
	fi

	RESOLVED_VERSION=$(printf "%s" "$COMMAND_OUTPUT" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
	if [ -z "$RESOLVED_VERSION" ]; then
		echo "Template kubeVersion resolver for ${BOUND} produced no output for ${APP}" >&2
		exit 1
	fi
	if printf "%s" "$RESOLVED_VERSION" | grep -q '[[:space:]]'; then
		echo "Template kubeVersion resolver for ${BOUND} must output exactly one version for ${APP}: ${RESOLVED_VERSION}" >&2
		exit 1
	fi

	echo "Resolved ${BOUND} kubeVersion for ${APP}: ${RESOLVED_VERSION}" >&2
	printf "%s" "$RESOLVED_VERSION"
}

set_chart_kube_version_from_template() {
	if ! yq -e '.kubeVersion' "$TEMPLATE_FILE" > /dev/null 2>&1; then
		return 1
	fi

	MINIMUM_KUBE_VERSION=$(resolve_kube_version minimum)
	MAXIMUM_KUBE_VERSION=$(resolve_kube_version maximum)
	RESOLVED_KUBE_VERSION=">= ${MINIMUM_KUBE_VERSION} < ${MAXIMUM_KUBE_VERSION}"

	echo "Setting Chart.yaml kubeVersion from template kubeVersion stanza: ${RESOLVED_KUBE_VERSION}"
	yq -i ".kubeVersion = \"$RESOLVED_KUBE_VERSION\"" Chart.yaml
	return 0
}

set_chart_kube_version() {
	if [ -n "$KUBE_VERSION" ]; then
		echo "Setting Chart.yaml kubeVersion from argument: ${KUBE_VERSION}"
		yq -i ".kubeVersion = \"$KUBE_VERSION\"" Chart.yaml
		return
	fi

	if set_chart_kube_version_from_template; then
		return
	fi

	SOURCE_KUBE_VERSION=$(yq -r '.kubeVersion // ""' Chart.yaml)
	if [ -n "$SOURCE_KUBE_VERSION" ]; then
		echo "Using source chart kubeVersion: ${SOURCE_KUBE_VERSION}"
	else
		echo "No kubeVersion argument given and source chart does not define kubeVersion"
		exit 1
	fi
}

normalize_app_version() {
	APP_VERSION=$(echo "${APP_VERSION}" | sed 's/^v//')
}

normalize_github_repo_url() {
	RAW_GITHUB_REPO_URL="$1"

	if [[ "$RAW_GITHUB_REPO_URL" == git@github.com:* ]]; then
		RAW_GITHUB_REPO_URL="https://github.com/${RAW_GITHUB_REPO_URL#git@github.com:}"
	fi

	RAW_GITHUB_REPO_URL="${RAW_GITHUB_REPO_URL%.git}"
	RAW_GITHUB_REPO_URL="${RAW_GITHUB_REPO_URL%/}"

	if [[ "$RAW_GITHUB_REPO_URL" != https://github.com/*/* ]]; then
		echo "GitHub release templates require a GitHub repository URL, got '${RAW_GITHUB_REPO_URL}'"
		exit 1
	fi

	echo "$RAW_GITHUB_REPO_URL"
}

copy_optional_chart_metadata() {
	METADATA_FIELD="$1"

	if yq -e ".${METADATA_FIELD}" "$TEMPLATE_FILE" > /dev/null 2>&1; then
		echo "Copying optional chart metadata field ${METADATA_FIELD}"
		METADATA_FIELD="$METADATA_FIELD" TEMPLATE_FILE="$TEMPLATE_FILE" \
			yq -i '.[strenv(METADATA_FIELD)] = load(strenv(TEMPLATE_FILE))[strenv(METADATA_FIELD)]' Chart.yaml
	fi
}

cleanup_github_release_work_dir() {
	if [ -n "$GITHUB_RELEASE_WORK_DIR" ] && [ -d "$GITHUB_RELEASE_WORK_DIR" ]; then
		echo "Cleaning up temporary GitHub release workspace ${GITHUB_RELEASE_WORK_DIR}"
		rm -rf "$GITHUB_RELEASE_WORK_DIR"
	fi
}

fail_github_release_chart() {
	echo "$1"
	cleanup_github_release_work_dir
	exit 1
}

generate_github_release_crd_chart() {
	SOURCE_TYPE=$(yq -r '.sourceType // ""' "$TEMPLATE_FILE")
	if [ "$SOURCE_TYPE" != "gitHubRelease" ]; then
		return 1
	fi

	echo "Detected GitHub release template for ${APP}"
	normalize_app_version
	GITHUB_RELEASE_WORK_DIR=""

	if ! command -v helmify > /dev/null 2>&1; then
		fail_github_release_chart "GitHub release templates require helmify"
	fi

	GITHUB_REPO_URL=$(yq -r '.repo // ""' "$TEMPLATE_FILE")
	if [ -z "$GITHUB_REPO_URL" ] || [ "$GITHUB_REPO_URL" = "null" ]; then
		fail_github_release_chart "GitHub release template for ${APP} does not define repo"
	fi
	GITHUB_REPO_URL=$(normalize_github_repo_url "$GITHUB_REPO_URL")
	echo "Using GitHub repository ${GITHUB_REPO_URL}"

	RELEASE_TAG=$(yq -r '.releaseTag // ""' "$TEMPLATE_FILE")
	if [ -z "$RELEASE_TAG" ] || [ "$RELEASE_TAG" = "null" ]; then
		RELEASE_TAG_PREFIX=$(yq -r '.releaseTagPrefix // "v"' "$TEMPLATE_FILE")
		RELEASE_TAG="${RELEASE_TAG_PREFIX}${APP_VERSION}"
	fi
	echo "Using GitHub release tag ${RELEASE_TAG}"

	NUM_CRD_FILES=$(yq '.files // [] | length' "$TEMPLATE_FILE")
	if [ "$NUM_CRD_FILES" -lt 1 ]; then
		fail_github_release_chart "GitHub release template for ${APP} must define at least one file in files"
	fi
	echo "Template lists ${NUM_CRD_FILES} GitHub release file(s)"

	ICON=$(yq -r '.icon // ""' "$TEMPLATE_FILE")
	if [ -z "$ICON" ] || [ "$ICON" = "null" ]; then
		fail_github_release_chart "GitHub release template for ${APP} does not define icon"
	fi

	CHART_DESCRIPTION=$(yq -r '.description // ""' "$TEMPLATE_FILE")
	if [ -z "$CHART_DESCRIPTION" ] || [ "$CHART_DESCRIPTION" = "null" ]; then
		CHART_DESCRIPTION="$APP"
	fi

	CRD_DIR=$(yq -r '.crdDir // "crds"' "$TEMPLATE_FILE")
	if [ -z "$CRD_DIR" ] || [[ "$CRD_DIR" = /* ]] || [[ "$CRD_DIR" == *..* ]]; then
		fail_github_release_chart "Invalid CRD directory '${CRD_DIR}' for ${APP}"
	fi
	if [ "$CRD_DIR" != "crds" ]; then
		fail_github_release_chart "Unsupported CRD directory '${CRD_DIR}' for ${APP}; helmify -crd-dir writes CRDs to crds"
	fi

	CHART_DIR="$ROOT_DIR/charts/${APP}-${APP_VERSION}"
	if [ -e "$CHART_DIR" ]; then
		fail_github_release_chart "Chart directory ${CHART_DIR} already exists"
	fi

	GITHUB_RELEASE_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/github-release-chart.XXXXXX")
	if [ "$?" != "0" ] || [ ! -d "$GITHUB_RELEASE_WORK_DIR" ]; then
		fail_github_release_chart "Could not create temporary GitHub release workspace"
	fi
	HELMIFY_INPUT_FILE="${GITHUB_RELEASE_WORK_DIR}/release-resources.yaml"
	HELMIFY_CHART_DIR="${GITHUB_RELEASE_WORK_DIR}/${APP}"
	printf "" > "$HELMIFY_INPUT_FILE"

	TOTAL_RESOURCE_COUNT=0
	TOTAL_CRD_KIND_COUNT=0
	echo "Preparing helmify input in ${HELMIFY_INPUT_FILE}"

	CRD_FILE_INDEX=0
	while [ "$CRD_FILE_INDEX" -lt "$NUM_CRD_FILES" ]; do
		CRD_FILE=$(yq -r ".files[$CRD_FILE_INDEX]" "$TEMPLATE_FILE")
		if [ -z "$CRD_FILE" ] || [ "$CRD_FILE" = "null" ] || [[ "$CRD_FILE" = /* ]] || [[ "$CRD_FILE" == *..* ]]; then
			fail_github_release_chart "Invalid GitHub release file entry '${CRD_FILE}' for ${APP}"
		fi

		CRD_FILE_NAME=$(basename "$CRD_FILE")
		DOWNLOAD_PATH="${GITHUB_RELEASE_WORK_DIR}/${CRD_FILE_INDEX}-${CRD_FILE_NAME}"
		DOWNLOAD_URL="${GITHUB_REPO_URL}/releases/download/${RELEASE_TAG}/${CRD_FILE}"
		echo "Downloading ${DOWNLOAD_URL} to ${DOWNLOAD_PATH}"
		curl -L --fail -sS -o "$DOWNLOAD_PATH" "$DOWNLOAD_URL"
		if [ "$?" != "0" ]; then
			fail_github_release_chart "Could not download ${DOWNLOAD_URL}"
		fi

		RESOURCE_COUNT=$(yq eval-all '[select(.kind != null and .apiVersion != null)] | length' "$DOWNLOAD_PATH")
		if [ "$?" != "0" ]; then
			fail_github_release_chart "Downloaded file ${CRD_FILE_NAME} is not valid YAML"
		fi
		if [ "$RESOURCE_COUNT" -lt 1 ]; then
			fail_github_release_chart "Downloaded file ${CRD_FILE_NAME} does not contain any Kubernetes resource documents"
		fi

		INVALID_RESOURCE_DOC_COUNT=$(yq eval-all '[select(. != null and (.kind == null or .apiVersion == null))] | length' "$DOWNLOAD_PATH")
		if [ "$?" != "0" ]; then
			fail_github_release_chart "Could not validate Kubernetes resource documents in ${CRD_FILE_NAME}"
		fi
		if [ "$INVALID_RESOURCE_DOC_COUNT" -gt 0 ]; then
			fail_github_release_chart "Downloaded file ${CRD_FILE_NAME} contains non-Kubernetes YAML documents"
		fi

		CRD_KIND_COUNT=$(yq eval-all '[select(.kind == "CustomResourceDefinition")] | length' "$DOWNLOAD_PATH")
		if [ "$?" != "0" ]; then
			fail_github_release_chart "Could not count CRDs in ${CRD_FILE_NAME}"
		fi
		NON_CRD_KINDS=$(yq eval-all 'select(.kind != "CustomResourceDefinition" and .kind != null) | .kind' "$DOWNLOAD_PATH")
		if [ -n "$NON_CRD_KINDS" ]; then
			echo "Detected non-CRD Kubernetes resource kind(s) in ${CRD_FILE_NAME}; helmify will render them under templates"
			echo "$NON_CRD_KINDS"
		fi

		if [ "$TOTAL_RESOURCE_COUNT" -gt 0 ]; then
			printf -- "---\n" >> "$HELMIFY_INPUT_FILE"
		fi
		yq eval-all 'select(.kind != null and .apiVersion != null) | ... comments = ""' "$DOWNLOAD_PATH" >> "$HELMIFY_INPUT_FILE"
		if [ "$?" != "0" ]; then
			fail_github_release_chart "Could not append sanitized Kubernetes resources from ${CRD_FILE_NAME}"
		fi

		TOTAL_RESOURCE_COUNT=$((TOTAL_RESOURCE_COUNT+RESOURCE_COUNT))
		TOTAL_CRD_KIND_COUNT=$((TOTAL_CRD_KIND_COUNT+CRD_KIND_COUNT))
		echo "Validated ${RESOURCE_COUNT} Kubernetes resource document(s), including ${CRD_KIND_COUNT} CRD document(s), in ${CRD_FILE_NAME}"

		CRD_FILE_INDEX=$((CRD_FILE_INDEX+1))
	done

	if [ "$TOTAL_CRD_KIND_COUNT" -lt 1 ]; then
		fail_github_release_chart "Downloaded GitHub release resources for ${APP} do not contain any CustomResourceDefinition documents"
	fi

	echo "Generating chart resources with helmify into ${HELMIFY_CHART_DIR}"
	helmify -crd-dir -original-name "$HELMIFY_CHART_DIR" < "$HELMIFY_INPUT_FILE"
	if [ "$?" != "0" ]; then
		fail_github_release_chart "helmify could not generate chart resources for ${APP}"
	fi
	if [ ! -d "${HELMIFY_CHART_DIR}/crds" ]; then
		fail_github_release_chart "helmify did not create the crds directory for ${APP}"
	fi

	GENERATED_CRD_FILE_COUNT=$(find "${HELMIFY_CHART_DIR}/crds" -type f | wc -l)
	if [ "$GENERATED_CRD_FILE_COUNT" -lt 1 ]; then
		fail_github_release_chart "helmify did not write any CRD files to ${HELMIFY_CHART_DIR}/crds"
	fi
	echo "helmify wrote ${GENERATED_CRD_FILE_COUNT} CRD file(s) to ${HELMIFY_CHART_DIR}/crds"

	echo "Moving generated chart to ${CHART_DIR}"
	mv "$HELMIFY_CHART_DIR" "$CHART_DIR"
	if [ "$?" != "0" ]; then
		fail_github_release_chart "Could not move generated chart to ${CHART_DIR}"
	fi

	pushd "$CHART_DIR"

	echo "Updating Chart.yaml catalog metadata"
	APP="$APP" \
	APP_VERSION="$APP_VERSION" \
	CHART_DESCRIPTION="$CHART_DESCRIPTION" \
	ICON="$ICON" \
	KUBE_VERSION="$KUBE_VERSION" \
		yq -i '.name = strenv(APP) | .version = strenv(APP_VERSION) | .appVersion = strenv(APP_VERSION) | .description = strenv(CHART_DESCRIPTION) | .icon = "icons/" + strenv(ICON) | .kubeVersion = strenv(KUBE_VERSION)' Chart.yaml
	copy_optional_chart_metadata keywords
	copy_optional_chart_metadata sources
	if ! yq -e '.sources' Chart.yaml > /dev/null 2>&1; then
		GITHUB_REPO_URL="$GITHUB_REPO_URL" yq -i '.sources = [strenv(GITHUB_REPO_URL)]' Chart.yaml
	fi

	popd
	cleanup_github_release_work_dir
	GITHUB_RELEASE_WORK_DIR=""

	echo "Finished generating GitHub release chart ${APP}-${APP_VERSION}"
	return 0
}

show_dependency_chart() {
	DEP_NAME="$1"
	DEP_REPO="$2"
	DEP_CHART_VERSION="$3"

	if [[ "$DEP_REPO" == oci://* ]]; then
		helm show chart "${DEP_REPO%/}/${DEP_NAME}" --version "$DEP_CHART_VERSION"
	elif [[ "$DEP_REPO" == @* ]]; then
		helm show chart "${DEP_REPO#@}/${DEP_NAME}" --version "$DEP_CHART_VERSION"
	elif [[ "$DEP_REPO" == alias:* ]]; then
		helm show chart "${DEP_REPO#alias:}/${DEP_NAME}" --version "$DEP_CHART_VERSION"
	else
		helm show chart "$DEP_NAME" --repo "$DEP_REPO" --version "$DEP_CHART_VERSION"
	fi
}

resolve_dependency_app_version() {
	DEP_NAME="$1"
	DEP_REPO="$2"
	DEP_CHART_VERSION="$3"

	echo "Resolving dependency chart ${DEP_NAME}@${DEP_CHART_VERSION} from ${DEP_REPO}"
	DEP_CHART_METADATA=$(show_dependency_chart "$DEP_NAME" "$DEP_REPO" "$DEP_CHART_VERSION")
	if [ "$?" != "0" ]; then
		echo "Could not inspect dependency chart ${DEP_NAME}@${DEP_CHART_VERSION} from ${DEP_REPO}"
		exit 1
	fi

	DEP_RESOLVED_CHART_VERSION=$(echo "$DEP_CHART_METADATA" | yq -r '.version // ""')
	DEP_RESOLVED_APP_VERSION=$(echo "$DEP_CHART_METADATA" | yq -r '.appVersion // ""' | sed 's/^v//')
	if [ -z "$DEP_RESOLVED_CHART_VERSION" ] || [ "$DEP_RESOLVED_CHART_VERSION" = "null" ]; then
		echo "Dependency chart ${DEP_NAME}@${DEP_CHART_VERSION} did not resolve to a chart version"
		exit 1
	fi
	if [ -z "$DEP_RESOLVED_APP_VERSION" ] || [ "$DEP_RESOLVED_APP_VERSION" = "null" ]; then
		echo "Dependency chart ${DEP_NAME}@${DEP_CHART_VERSION} does not define an appVersion"
		exit 1
	fi
	echo "Resolved dependency chart ${DEP_NAME}@${DEP_RESOLVED_CHART_VERSION} to app version ${DEP_RESOLVED_APP_VERSION}"
}

generate_dependency_chart() {
	DEP_APP="$1"
	DEP_APP_VERSION="$2"
	DEP_CHART_VERSION="$3"
	DEP_CHART_DIR="$ROOT_DIR/charts/${DEP_APP}-${DEP_APP_VERSION}"
	DEP_TEMPLATE_FILE="$ROOT_DIR/templates/${DEP_APP}/template.yaml"

	if [ -d "$DEP_CHART_DIR" ]; then
		echo "Dependency chart ${DEP_APP}-${DEP_APP_VERSION} already exists; using existing catalog chart"
		return
	fi

	if [ ! -f "$DEP_TEMPLATE_FILE" ]; then
		echo "Cannot generate dependency ${DEP_APP}-${DEP_APP_VERSION}: missing ${DEP_TEMPLATE_FILE}"
		exit 1
	fi

	echo "Generating dependency chart ${DEP_APP}-${DEP_APP_VERSION} from chart version ${DEP_CHART_VERSION}"
	(
		cd "$ROOT_DIR"
		CHART_VERSION="$DEP_CHART_VERSION" "$ROOT_DIR/generate.sh" "$DEP_APP" "$DEP_APP_VERSION" "$KUBE_VERSION"
	)
	if [ "$?" != "0" ]; then
		echo "Could not generate dependency chart ${DEP_APP}-${DEP_APP_VERSION}"
		exit 1
	fi
}

process_chart_dependencies() {
	NUM_DEPENDENCIES=$(yq '.dependencies // [] | length' Chart.yaml)
	DEP_INDEX=0

	while [ "$DEP_INDEX" -lt "$NUM_DEPENDENCIES" ]; do
		DEP_NAME=$(yq -r ".dependencies[$DEP_INDEX].name // \"\"" Chart.yaml)
		DEP_REPO=$(yq -r ".dependencies[$DEP_INDEX].repository // \"\"" Chart.yaml)
		DEP_CHART_VERSION=$(yq -r ".dependencies[$DEP_INDEX].version // \"\"" Chart.yaml)

		if [ -z "$DEP_NAME" ]; then
			echo "Dependency at index ${DEP_INDEX} does not define a name"
			exit 1
		fi

		if [ -z "$DEP_REPO" ] || [[ "$DEP_REPO" == file://* ]]; then
			echo "Skipping local dependency ${DEP_NAME} with repository '${DEP_REPO}'"
			DEP_INDEX=$((DEP_INDEX+1))
			continue
		fi

		if [ -z "$DEP_CHART_VERSION" ]; then
			echo "Dependency ${DEP_NAME} does not define a chart version"
			exit 1
		fi

		resolve_dependency_app_version "$DEP_NAME" "$DEP_REPO" "$DEP_CHART_VERSION"
		generate_dependency_chart "$DEP_NAME" "$DEP_RESOLVED_APP_VERSION" "$DEP_RESOLVED_CHART_VERSION"

		DEP_LOCAL_REPO="file://../${DEP_NAME}-${DEP_RESOLVED_APP_VERSION}"
		echo "Rewriting dependency ${DEP_NAME} to ${DEP_LOCAL_REPO}@${DEP_RESOLVED_APP_VERSION}"
		DEP_LOCAL_REPO="$DEP_LOCAL_REPO" \
		DEP_RESOLVED_APP_VERSION="$DEP_RESOLVED_APP_VERSION" \
			yq -i ".dependencies[$DEP_INDEX].repository = strenv(DEP_LOCAL_REPO) | .dependencies[$DEP_INDEX].version = strenv(DEP_RESOLVED_APP_VERSION)" Chart.yaml

		DEP_INDEX=$((DEP_INDEX+1))
	done
}

list_template_apps() {
	find "$ROOT_DIR/templates" -mindepth 2 -maxdepth 2 -name template.yaml \
		| sed 's#/template.yaml$##;s#^.*/##' \
		| sort
}

resolve_app_pattern() {
	if [ -z "$APP_PATTERN" ]; then
		echo "Usage: $0 APPLICATION_OR_PATTERN APP_VERSION [KUBE_VERSION]"
		exit 1
	fi

	if [ -f "$ROOT_DIR/templates/$APP_PATTERN/template.yaml" ]; then
		APP="$APP_PATTERN"
		TEMPLATE_FILE="$ROOT_DIR/templates/$APP/template.yaml"
		return
	fi

	TEMPLATE_APPS=$(list_template_apps)
	MATCHED_APPS=$(printf "%s\n" "$TEMPLATE_APPS" | grep -E -e "$APP_PATTERN")
	GREP_STATUS="$?"
	if [ "$GREP_STATUS" = "2" ]; then
		echo "Invalid application grep pattern: ${APP_PATTERN}"
		exit "$GREP_STATUS"
	fi
	if [ "$GREP_STATUS" != "0" ]; then
		echo "No application templates matched pattern: ${APP_PATTERN}"
		exit 1
	fi

	MATCH_COUNT=$(printf "%s\n" "$MATCHED_APPS" | grep -c .)
	if [ "$MATCH_COUNT" = "1" ]; then
		APP="$MATCHED_APPS"
		TEMPLATE_FILE="$ROOT_DIR/templates/$APP/template.yaml"
		return
	fi

	echo "Application pattern '${APP_PATTERN}' matched ${MATCH_COUNT} templates:"
	printf "%s\n" "$MATCHED_APPS"

	while IFS= read -r MATCHED_APP; do
		if [ -z "$MATCHED_APP" ]; then
			continue
		fi
		echo "Generating matched application template ${MATCHED_APP}"
		(
			cd "$ROOT_DIR"
			CHART_VERSION="$CHART_VERSION" "$ROOT_DIR/generate.sh" "$MATCHED_APP" "$APP_VERSION" "$KUBE_VERSION"
		)
		STATUS="$?"
		if [ "$STATUS" != "0" ]; then
			echo "Could not generate matched application template ${MATCHED_APP}"
			exit "$STATUS"
		fi
	done <<EOF
$MATCHED_APPS
EOF

	exit 0
}

resolve_app_pattern

set -x

if generate_github_release_crd_chart; then
	update_readme_version

	set +x

	echo "Required Images"
	echo ""
	echo ""

	echo "Latest Images"
	echo ""
	exit 0
fi

REPO_URL=$(yq .repo "$TEMPLATE_FILE")
helm repo add "$REPO_NAME" "$REPO_URL" --force-update

ICON=$(yq .icon "$TEMPLATE_FILE")
CHART=$(yq .chart "$TEMPLATE_FILE")
if [ -z "$CHART_VERSION" ] || [ "$CHART_VERSION" = "null" ]; then
	# If the chart version is not specified, then search
	# the repo by app version.
	CHART_DESCS=$(helm search repo "${REPO_NAME}/${CHART}" --versions -o yaml)
	CHART_VERSION=$(echo "$CHART_DESCS" | yq ".[] | select((.app_version == \"${APP_VERSION}\" or .app_version == \"v${APP_VERSION}\") and .name == \"${REPO_NAME}/${CHART}\") | .version")

fi
if [ -z "$CHART_VERSION" ] || [ "$CHART_VERSION" = "null" ]; then
	echo "Could not resolve a chart version for ${CHART} with app version ${APP_VERSION}"
	exit 1
fi

# Strip the 'v' off the front of app version, if it exists, to conform
# with catalog standards
normalize_app_version

pushd "charts"

if [[ "$CHART_VERSION" == v* ]]; then
	V_CHART_VERSION="$CHART_VERSION"
else
	V_CHART_VERSION="v$CHART_VERSION"
fi

pull_chart_to_temp_dir

helm repo remove "$REPO_NAME"

OUTPUT_DIR="${APP}-${APP_VERSION}"
backup_existing_output_dir "$OUTPUT_DIR"
echo "Moving pulled chart ${PULL_DIR}/${CHART} to ${OUTPUT_DIR}"
mv "$PULL_DIR/$CHART" "$OUTPUT_DIR"
cleanup_pull_dir "$PULL_DIR"
pushd "${APP}-${APP_VERSION}"

yq -i ".version = \"$APP_VERSION\"" Chart.yaml
yq -i ".appVersion = \"$APP_VERSION\"" Chart.yaml
yq -i ".icon = \"icons/$ICON\"" Chart.yaml
set_chart_kube_version
yq -i ".name = \"$APP\"" Chart.yaml
sanitize_chart_readme

if yq -e '.extraChartYqs' "$TEMPLATE_FILE" > /dev/null 2>&1; then
	yq -r -0 '.extraChartYqs[]' "$TEMPLATE_FILE" | xargs -0 -I{} yq -i {} Chart.yaml
fi

process_chart_dependencies

TRANSFORMS=$(yq -r '(.transforms // {}) | keys | .[]' "$TEMPLATE_FILE")
for xform in $TRANSFORMS; do
	if yq -e ".transforms.\"$xform\".extraImages" "$TEMPLATE_FILE" > /dev/null 2>&1; then
		yq -r -0 ".transforms.\"$xform\".extraImages | .[]" "$TEMPLATE_FILE" | xargs -0 -I{} sed -i "1s;^;# extra-image: {}\n;" templates/$xform
	fi

	TEXT=$(yq -re ".transforms.\"$xform\".prepend" "$TEMPLATE_FILE" 2>/dev/null)
	if [ "$?" != "0" ]; then
		continue
	fi
	FILE=$(cat templates/$xform)
	printf "%s\n%s" "$TEXT" "$FILE" > templates/$xform
done

if yq -e '((.values // {}) | length) > 0' "$TEMPLATE_FILE" > /dev/null 2>&1; then
	yq '.values' "$TEMPLATE_FILE" > vals.tmp
	update_values_yaml_with_yq '. *= load("vals.tmp")'
	rm vals.tmp
else
	echo "No values.yaml merge defined for ${APP}"
fi
apply_extra_values_yqs
apply_extra_file_yqs
apply_template_patches

IMAGES=""
LATEST_IMAGES=""

process_image_tags() {
	LIST_NAME="$1"
	TAG_MODE="$2"
	NUM_IMAGES=$(yq ".${LIST_NAME} | length" "$TEMPLATE_FILE")
	NUM_IMAGES=$((NUM_IMAGES-1))

	for i in $(seq 0 $NUM_IMAGES); do
		REG_PATH=$(yq ".${LIST_NAME}[$i].name" "$TEMPLATE_FILE")
		REG=$(yq "$REG_PATH" values.yaml)
		IMAGE="$REGISTRY/$REG"

		if [ "$TAG_MODE" = "appVersion" ]; then
			TAG_PREFIX=$(yq -r ".${LIST_NAME}[$i].prefix // \"v\"" "$TEMPLATE_FILE")
			TAG="${TAG_PREFIX}${APP_VERSION}"
			echo "using app version for $IMAGE: $TAG"
		elif [ "$TAG_MODE" = "latest" ]; then
			TAG=$(skopeo list-tags "docker://$IMAGE" | yq .Tags[] | grep -v -e '-amd64' | grep -v -e '-arm64' | sort -V | tail -1)
			echo "latest for $IMAGE: $TAG"
			LATEST_IMAGES=$(echo "$LATEST_IMAGES"; echo "${IMAGE}:${TAG}")
		else
			echo "Unsupported tag mode \"$TAG_MODE\" for $IMAGE"
			exit 1
		fi

		TAG_PATH=$(yq ".${LIST_NAME}[$i].tag" "$TEMPLATE_FILE")
		update_values_yaml_with_yq "$TAG_PATH = \"$TAG\""
		IMAGES=$(echo "$IMAGES"; echo "${IMAGE}:${TAG}")
	done
}

process_image_tags images appVersion
process_image_tags latestImages latest


popd # APP-APP_VERSION

popd # charts

# Update README.md
update_readme_version

set +x

IMAGES=$(echo "${IMAGES}" | sort | uniq)
LATEST_IMAGES=$(echo "${LATEST_IMAGES}" | sort | uniq)
echo "Required Images"
echo "${IMAGES}"
echo ""

echo "Latest Images"
echo "${LATEST_IMAGES}"
