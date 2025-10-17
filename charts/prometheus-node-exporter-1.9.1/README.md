# Prometheus Node Exporter

Prometheus exporter for hardware and OS metrics exposed by *NIX kernels, written in Go with pluggable metric collectors.

This chart bootstraps a Prometheus [Node Exporter](http://github.com/prometheus/node_exporter) daemonset on a [Kubernetes](http://kubernetes.io) cluster using the [Helm](https://helm.sh) package manager.

## Get Repository Info
<!-- textlint-disable terminology -->
```console
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

_See [helm repo](https://helm.sh/docs/helm/helm_repo/) for command documentation._
<!-- textlint-enable -->
## Install Chart

```console
ocne application install --release [RELEASE_NAME] --namespace [NAMESPACE]
```

_See [configuration](#configuring) below._

_See [helm install](https://helm.sh/docs/helm/helm_install/) for command documentation._

## Uninstall Chart

```console
ocne application install --release [RELEASE_NAME] --namespace [NAMESPACE]
```

This removes all the Kubernetes components associated with the chart and deletes the release.

## Upgrading Chart

```console
ocne application update --release [RELEASE_NAME] --namespace [NAMESPACE]
```

_See [helm upgrade](https://helm.sh/docs/helm/helm_upgrade/) for command documentation._

### 3.x to 4.x

Starting from version 4.0.0, the `node exporter` chart is using the [Kubernetes recommended labels](https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/). Therefore you have to delete the daemonset before you upgrade.

```console
kubectl delete daemonset -l app=prometheus-node-exporter
ocne application update prometheus-node-exporter --release prometheus-node-exporter
```

If you use your own custom [ServiceMonitor](https://github.com/prometheus-operator/prometheus-operator/blob/main/Documentation/api-reference/api.md#servicemonitor) or [PodMonitor](https://github.com/prometheus-operator/prometheus-operator/blob/main/Documentation/api-reference/api.md#podmonitor), please ensure to upgrade their `selector` fields accordingly to the new labels.

### From 2.x to 3.x

Change the following:

```yaml
hostRootFsMount: true
```

to:

```yaml
hostRootFsMount:
  enabled: true
  mountPropagation: HostToContainer
```

## Configuring

See [Customizing the Chart Before Installing](https://helm.sh/docs/intro/using_helm/#customizing-the-chart-before-installing). To see all configurable options with detailed comments, visit the chart's [values.yaml](./values.yaml), or run these configuration commands:

```console
helm show values prometheus-community/prometheus-node-exporter
```

### kube-rbac-proxy

You can enable `prometheus-node-exporter` endpoint protection using `kube-rbac-proxy`. By setting `kubeRBACProxy.enabled: true`, this chart will deploy a RBAC proxy container protecting the node-exporter endpoint.
To authorize access, authenticate your requests (via a `ServiceAccount` for example) with a `ClusterRole` attached such as:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus-node-exporter-read
rules:
  - apiGroups: [ "" ]
    resources: ["services/node-exporter-prometheus-node-exporter"]
    verbs:
      - get
```

See [kube-rbac-proxy examples](https://github.com/brancz/kube-rbac-proxy/tree/master/examples/resource-attributes) for more details.
