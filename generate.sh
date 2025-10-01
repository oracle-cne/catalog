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

yq -r -0 '.extraChartYqs[]' "$TEMPLATE_FILE" | xargs -0 -I{} yq -i {} Chart.yaml

TRANSFORMS=$(yq -r '.transforms | keys | .[]' "$TEMPLATE_FILE")
for xform in $TRANSFORMS; do
	yq -r -0 ".transforms.\"$xform\".extraImages | .[]" "$TEMPLATE_FILE" | xargs -0 -I{} sed -i "1s;^;# extra-image: {}\n;" templates/$xform

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

NUM_LATEST_IMAGES=$(yq '.latestImages | length' "$TEMPLATE_FILE")
NUM_LATEST_IMAGES=$((NUM_LATEST_IMAGES-1))
for i in $(seq 0 $NUM_LATEST_IMAGES); do
	REG_PATH=$(yq ".latestImages[$i].name" "$TEMPLATE_FILE")
	REG=$(yq "$REG_PATH" values.yaml)
	IMAGE="$REGISTRY/$REG"
	LATEST=$(skopeo list-tags "docker://$IMAGE" | yq .Tags[] | grep -v -e '-amd64' | grep -v -e '-arm64' | sort -V | tail -1)
	echo "latest for $IMAGE: $LATEST"
	TAG_PATH=$(yq ".latestImages[$i].tag" "$TEMPLATE_FILE")
	yq -i "$TAG_PATH = \"$LATEST\"" values.yaml
done


popd # APP-APP_VERSION

popd # charts
