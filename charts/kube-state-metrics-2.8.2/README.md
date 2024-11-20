# kube-state-metrics Helm Chart

Installs the [kube-state-metrics agent](https://github.com/kubernetes/kube-state-metrics).

## Install The Application

```console
ocne application install --release [RELEASE_NAME] --name kube-state-metrics --namespace [NAMESPACE]
```
## Uninstall The Application

```console
ocne application uninstall --release [RELEASE_NAME} --namespace [NAMESPACE]
```

## Configuration

See [Customizing the Chart Before Installing](https://helm.sh/docs/intro/using_helm/#customizing-the-chart-before-installing). To see all configurable options with detailed comments:

```console
helm show values prometheus-community/kube-state-metrics
```

### kube-rbac-proxy

You can enable `kube-state-metrics` endpoint protection using `kube-rbac-proxy`. By setting `kubeRBACProxy.enabled: true`, this chart will deploy one RBAC proxy container per endpoint (metrics & telemetry).
To authorize access, authenticate your requests (via a `ServiceAccount` for example) with a `ClusterRole` attached such as:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-state-metrics-read
rules:
  - apiGroups: [ "" ]
    resources: ["services/kube-state-metrics"]
    verbs:
      - get
```

See [kube-rbac-proxy examples](https://github.com/brancz/kube-rbac-proxy/tree/master/examples/resource-attributes) for more details.
