#! /bin/bash
set -e

CHART_DIR="$1"
CHART_NAME=$(basename "$CHART_DIR")
CHART_FILE="$CHART_DIR/Chart.yaml"

NAME=$(yq -r '.name' "$CHART_FILE")
VERSION=$(yq -r '.version' "$CHART_FILE")
APP_VERSION=$(yq -r '.appVersion' "$CHART_FILE")
KUBE_VERSION=$(yq -r '.kubeVersion' "$CHART_FILE")
ICON=$(yq -r '.icon' "$CHART_FILE")

# Make sure names and versions are all correct
echo "Check that chart version is defined"
[ -n "$VERSION" ]
echo "Check that appVersion is defined"
[ -n "$APP_VERSION" ]
echo "Checking chart path matches name-version"
[ "$NAME-$VERSION" == "$CHART_NAME" ]
echo "Checking that chart version equals app version"
[ "$VERSION" == "$APP_VERSION" ]
echo "Checking that a kubeVersion is defined"
[ -n "$KUBE_VERSION" ]

echo "Ensure that an icon is present"
[ -n "$ICON" ]
stat "./olm/$ICON" > /dev/null

echo "Ensure that a values.yaml is present"
stat "$CHART_DIR/values.yaml" > /dev/null

echo "Ensure that the chart is in the README.md"
grep -q "$NAME[[:space:]]*|[[:space:]].*$VERSION" README.md


# Make sure there are no forbidden registries
BAD_FILES=
REGISTRIES="
docker.io
quay.io
registry.k8s.io
"
for registry in $REGISTRIES; do
	echo "Checking for references to $registry"
	# cat is to supress the non-zero exit code if grep has no matches
	FILES=$(find "$CHART_DIR" -type f)
	for file in $FILES; do
		# Ignore CRDs
		if grep -v -q '^kind: CustomResourceDefinition$' "$file"; then
			continue
		fi
		BAD_FILES="$BAD_FILES$(grep -l $registry "$file" | cat)"

	done
done

echo "Checking that no references to any bad registries are present"
BAD_FILES=$(echo "$BAD_FILES" | sort | uniq)
echo "$BAD_FILES"
[ -z "$BAD_FILES" ]
