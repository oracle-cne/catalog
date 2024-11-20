# Istiod Helm Chart

This chart installs an Istiod deployment.

## Installing The Application

Before installing, ensure CRDs are installed in the cluster (from the `istio-base` application).

To install the application with the release name `istiod`:

```console
ocne application install --release istiod --name istiod --namespace istio-system
```

## Uninstalling The Application

To uninstall/delete the `istiod` deployment:

```console
ocne application uninstall --release istiod --namespace istio-system
```

### Examples

#### Configuring mesh configuration settings

Any [Mesh Config](https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/) options can be configured like below:

```yaml
meshConfig:
  accessLogFile: /dev/stdout
```

#### Revisions

Control plane revisions allow deploying multiple versions of the control plane in the same cluster.
This allows safe [canary upgrades](https://istio.io/latest/docs/setup/upgrade/canary/)

```yaml
revision: my-revision-name
```
