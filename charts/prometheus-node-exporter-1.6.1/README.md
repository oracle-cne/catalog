# Prometheus Node Exporter

Prometheus exporter for hardware and OS metrics exposed by *NIX kernels, written in Go with pluggable metric collectors.

This chart bootstraps a Prometheus [Node Exporter](http://github.com/prometheus/node_exporter) daemonset on a [Kubernetes](http://kubernetes.io) cluster.

## Install The Application

```console
ocne application install --release [RELEASE_NAME] --namespace [NAMESPACE]
```
## Uninstall Chart

```console
ocne application install --release [RELEASE_NAME] --namespace [NAMESPACE]
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
