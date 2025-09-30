#! /bin/bash

APP="$1"
APP_VERSION="$2"
KUBE_VERSION="$3"

REPO_NAME="tmp-repo"

TEMPLATE_FILE="$PWD/templates/$APP/template.yaml"

set -x

REPO_URL=$(yq .repo "$TEMPLATE_FILE")
ICON=$(yq .icon "$TEMPLATE_FILE")
CHART=$(yq .chart "$TEMPLATE_FILE")

pushd "charts"

helm repo add "$REPO_NAME" "$REPO_URL"
helm pull --untar "$REPO_NAME/$CHART" --version "v$APP_VERSION"
helm repo remove "$REPO_NAME"

mv "$CHART" "${APP}-${APP_VERSION}"
pushd "${APP}-${APP_VERSION}"

yq -i ".version = \"$APP_VERSION\"" Chart.yaml
yq -i ".appVersion = \"$APP_VERSION\"" Chart.yaml
yq -i ".icon = \"icons/$ICON\"" Chart.yaml
yq -i ".kubeVersion = \"$KUBE_VERSION\"" Chart.yaml
yq -i ".name = \"$APP\"" Chart.yaml

yq -r -0 '.extraChartYqs[]' "$TEMPLATE_FILE" | xargs -0 -I{} yq -i {} Chart.yaml

TEMPLATES=$(yq -r '.extraImages | keys | .[]' "$TEMPLATE_FILE")
for tmpl in $TEMPLATES; do
	yq -r -0 ".extraImages.\"$tmpl\" | .[]" "$TEMPLATE_FILE" | xargs -0 -I{} sed -i "1s;^;# extra-image: {}\n;" templates/$tmpl
done

yq '.values' "$TEMPLATE_FILE" > vals.tmp

NUM_LATEST_IMAGES=$(yq '.latestImages | length' "$TEMPLATE_FILE")
NUM_LATEST_IMAGES=$((NUM_LATEST_IMAGES-1))
for i in $(seq 0 $NUM_LATEST_IMAGES); do
	REG_PATH=$(yq ".latestImages[$i].name" "$TEMPLATE_FILE")
	REG=$(yq "$REG_PATH" vals.tmp)
	IMAGE="$REGISTRY/$REG"
	LATEST=$(skopeo list-tags "docker://$IMAGE" | yq .Tags[] | grep -v -e '-amd64' | grep -v -e '-arm64' | sort -V | tail -1)
	echo "latest for $IMAGE: $LATEST"
	TAG_PATH=$(yq ".latestImages[$i].tag" "$TEMPLATE_FILE")
	yq -i "$TAG_PATH = \"$LATEST\"" vals.tmp
done

yq -i '. *= load("vals.tmp")' values.yaml
rm vals.tmp

popd # APP-APP_VERSION

popd # charts
