#! /bin/bash

APP="$1"
APP_VERSION="$2"
KUBE_VERSION="$3"

REPO_NAME="tmp-repo"

TEMPLATE_FILE="$PWD/templates/$APP/template.yaml"

if [ -z "$REGISTRY" ]; then
	REGISTRY=container-registry.oracle.com
fi

set -x

REPO_URL=$(yq .repo "$TEMPLATE_FILE")
ICON=$(yq .icon "$TEMPLATE_FILE")
CHART=$(yq .chart "$TEMPLATE_FILE")
CHART_VERSION=$(yq -re .chartVersion "$TEMPLATE_FILE" 2>/dev/null)
if [ "$?" != "0" ]; then
	CHART_VERSION="$APP_VERSION"
fi

pushd "charts"

helm repo add "$REPO_NAME" "$REPO_URL"
helm pull --untar "$REPO_NAME/$CHART" --version "v$CHART_VERSION"
if [ "$?" != "0" ]; then
	echo "Could not pull ${CHART}@${CHART_VERSION} from ${REPO_URL}"
	exit 1
fi

helm repo remove "$REPO_NAME"

mv "$CHART" "${APP}-${APP_VERSION}"
pushd "${APP}-${APP_VERSION}"

yq -i ".version = \"$APP_VERSION\"" Chart.yaml
yq -i ".appVersion = \"$APP_VERSION\"" Chart.yaml
yq -i ".icon = \"icons/$ICON\"" Chart.yaml
yq -i ".kubeVersion = \"$KUBE_VERSION\"" Chart.yaml
yq -i ".name = \"$APP\"" Chart.yaml

if yq -e '.extraChartYqs' "$TEMPLATE_FILE" > /dev/null 2>&1; then
	yq -r -0 '.extraChartYqs[]' "$TEMPLATE_FILE" | xargs -0 -I{} yq -i {} Chart.yaml
fi

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
yq -i '. *= load("vals.tmp")' values.yaml
rm vals.tmp

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
		else
			echo "Unsupported tag mode \"$TAG_MODE\" for $IMAGE"
			exit 1
		fi

		TAG_PATH=$(yq ".${LIST_NAME}[$i].tag" "$TEMPLATE_FILE")
		yq -i "$TAG_PATH = \"$TAG\"" values.yaml
	done
}

process_image_tags images appVersion
process_image_tags latestImages latest


popd # APP-APP_VERSION

popd # charts
