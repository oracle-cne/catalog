# Fluent Operator Helm chart

[Fluent Operator](https://github.com/fluent/fluent-operator/) provides a Kubernetes-native logging pipeline based on Fluent-Bit and Fluentd.

## Deploy Fluent Operator with Oracle Cloud Native Environment

The Fluent Bit section of the Fluent Operator supports different CRI `docker`, `containerd`,  and `CRI-O`.
`containerd` and `CRI-O` use the `CRI Log` format which is different with `docker`, they require additional parser to parse JSON application logs. You should set different `containerRuntime` depending on your container runtime.

The default runtime is docker, you can choose other runtimes as follows.

If your container runtime is `containerd` or  `cri-o`, you can set the `containerRuntime` parameter to `containerd` or `crio`. e.g.

```shell
ocne application install --namespace fluent --name fluent-operator --release fluent-operator
```

Fluent Operator CRDs will be installed by default when running an install for the application. But if the CRD already exists, it will be skipped with a warning. So make sure you install the CRDs by yourself if you upgrade your Fluent Operator version.

> Note: During the upgrade process, if a CRD was previously created using the create operation, an error will occur during the apply operation. Using apply here allows the CRD to be replaced and created in its entirety in a single operation.

## Upgrading

Helm [does not manage the lifecycle of CRDs](https://helm.sh/docs/chart_best_practices/custom_resource_definitions/), so if the Fluent Operator CRDs already exist, subsequent 
chart upgrades will not add or remove CRDs even if they have changed.  During upgrades, users should manually update CRDs:

```
wget https://github.com/fluent/fluent-operator/releases/download/<version>/fluent-operator.tgz
tar -xf fluent-operator.tgz
kubectl replace -f fluent-operator/crds
```

## Chart Values

```
helm show values fluent/fluent-operator
```