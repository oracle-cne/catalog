#! /bin/bash

APP="$1"
APP_VERSION="$2"
KUBE_VERSION="$3"

REPO_NAME="tmp-repo"

TEMPLATE_FILE="$PWD/templates/$APP/chart.yaml"

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
yq -i '. *= load("vals.tmp")' values.yaml
rm vals.tmp

popd # APP-APP_VERSION

popd # charts
