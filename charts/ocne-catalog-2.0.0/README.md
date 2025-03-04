# app-catalog

Application Catalog for Oracle Cloud Native Environment

This chart helms to deploy Application Catalog on a [Kubernetes](http://kubernetes.io) cluster.

## Prerequisites

## Install Chart

```sh
$> ocne application install --release ocne-catalog --name ocne-catalog --namespace ocne-system
```

## Uninstall Chart

```sh
$> ocne application uninstall --release ocne-catalog --namespace ocne-system
```

This removes all the Kubernetes components associated with the chart and deletes the release.

