# app-catalog

Application Catalog / App Catalog for OCNE

This chart helms to deploy App Catalog on a [Kubernetes](http://kubernetes.io) cluster using the [Helm](https://helm.sh) package manager.

## Prerequisites

- Helm 3.2.0+

## Install Chart

```sh
$> helm install [RELEASE_NAME] [fully qualified path to unpacked chart directory charts/app-catalog] \
        --namespace mynamespace \
        --create-namespace \
        --set image.repository=[container registry/namespace/helm-charts]
        --set image.tag=v1.0.0
```
The command deploys app-catalog on the Kubernetes cluster in the namespace mynamespace, with default configurations.

_See [configuration](#configuration) below._

_See [helm install](https://helm.sh/docs/helm/helm_install/) for command documentation._

## Uninstall Chart

```sh
$> helm uninstall [RELEASE_NAME]
```

This removes all the Kubernetes components associated with the chart and deletes the release.

_See [helm uninstall](https://helm.sh/docs/helm/helm_uninstall/) for command documentation._

## Upgrading Chart

```sh
$> helm upgrade [RELEASE_NAME] [CHART] --install
```

_See [helm upgrade](https://helm.sh/docs/helm/helm_upgrade/) for command documentation._
