#! /bin/bash

APP="$1"
APP_VERSION="$2"
KUBE_VERSION="$3"
ROOT_DIR="$PWD"

REPO_NAME="tmp-repo"

TEMPLATE_FILE="$ROOT_DIR/templates/$APP/template.yaml"

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
	restore_values_yaml_after_yq
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

helm pull --untar "$REPO_NAME/$CHART" --version "$V_CHART_VERSION"
if [ "$?" != "0" ]; then
	echo "Could not pull ${CHART}@${V_CHART_VERSION} from ${REPO_URL}; retrying ${CHART_VERSION}"
	helm pull --untar "$REPO_NAME/$CHART" --version "$CHART_VERSION"
	if [ "$?" != "0" ]; then
		echo "Could not pull ${CHART}@${CHART_VERSION} from ${REPO_URL}"
		exit 1
	fi
fi

helm repo remove "$REPO_NAME"

mv "$CHART" "${APP}-${APP_VERSION}"
pushd "${APP}-${APP_VERSION}"

yq -i ".version = \"$APP_VERSION\"" Chart.yaml
yq -i ".appVersion = \"$APP_VERSION\"" Chart.yaml
yq -i ".icon = \"icons/$ICON\"" Chart.yaml
yq -i ".kubeVersion = \"$KUBE_VERSION\"" Chart.yaml
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

yq '.values' "$TEMPLATE_FILE" > vals.tmp
update_values_yaml_with_yq '. *= load("vals.tmp")'
rm vals.tmp

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
