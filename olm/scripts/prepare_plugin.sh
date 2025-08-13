#!/bin/bash
#
# Copyright (c) 2024, Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.

# This script extracts values.yaml from the charts under <component>/<version>/values.yaml, which is necessary to
# populate the Helm values when the user clicks on "Install" button for a given component in the catalog plugin UI
#

set -e

[ -z "$1" ] && { echo "ERROR: specify the root directory containing the chart bundles"; exit 1; }

CHART_ROOT=$1

CHART_VALUES=${CHART_ROOT}/../values

# Extract values.yaml from the chart bundle
function extractValuesYaml {
  local chartName=$1
  local chartVersion=$2
  local chartBundle=$3
  mkdir -p "${CHART_VALUES}/${chartName}/${chartVersion}"
  cd "$CHART_VALUES/${chartName}/${chartVersion}"
 
  # Extract values.yaml and remove the chartName directory
  gunzip -c $chartBundle | tar xf - ${chartName}/values.yaml
  mv $chartName/values.yaml .
  rm -rf $chartName
  cd ${CHART_ROOT}
}

rm -rf $CHART_VALUES
mkdir -p $CHART_VALUES

cd $CHART_ROOT
for i in *.tgz; do
    [ -f "$i" ] || break
    
    # Remove extension 
    withoutExtn="${i%.*}"
 
    # Extract chart name and version 
    chartName="${withoutExtn%%[0-9]*}"      # Remove from first digit onward
    chartName="${chartName%-}"              # Remove trailing hyphen if present
    chartVersion=${withoutExtn##*-}

    extractValuesYaml ${chartName} ${chartVersion} $(pwd)/$i
done
