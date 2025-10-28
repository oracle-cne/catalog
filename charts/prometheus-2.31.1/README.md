# Prometheus

[Prometheus](https://prometheus.io/), a [Cloud Native Computing Foundation](https://cncf.io/) project, is a systems and service monitoring system. It collects metrics from configured targets at given intervals, evaluates rule expressions, displays the results, and can trigger alerts if some condition is observed to be true.

This chart bootstraps a [Prometheus](https://prometheus.io/) deployment on a [Kubernetes](http://kubernetes.io) cluster using the [Helm](https://helm.sh) package manager.

## Prerequisites

- Kubernetes 1.16+

## Install The Application

```console
ocne application install --release [RELEASE_NAME] --name prometheus --namespace [NAMESPACE]
```

## Uninstall The Application

```console
ocne application uninstall --release [RELEASE_NAME] --namespace [NAMESPACE]
```

This removes all the Kubernetes components associated with the application and deletes the release.

### Scraping Pod Metrics via Annotations

This chart uses a default configuration that causes prometheus to scrape a variety of kubernetes resource types, provided they have the correct annotations. In this section we describe how to configure pods to be scraped; for information on how other resource types can be scraped you can do a `helm template` to get the kubernetes resource definitions, and then reference the prometheus configuration in the ConfigMap against the prometheus documentation for [relabel_config](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config) and [kubernetes_sd_config](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#kubernetes_sd_config).

In order to get prometheus to scrape pods, you must add annotations to the the pods as below:

```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/path: /metrics
    prometheus.io/port: "8080"
```

You should adjust `prometheus.io/path` based on the URL that your pod serves metrics from. `prometheus.io/port` should be set to the port that your pod serves metrics from. Note that the values for `prometheus.io/scrape` and `prometheus.io/port` must be enclosed in double quotes.

### Sharing Alerts Between Services

```yaml
# values.yaml
# ...

# service1-alert.yaml
serverFiles:
  alerts:
    service1:
      - alert: anAlert
      # ...

# service2-alert.yaml
serverFiles:
  alerts:
    service2:
      - alert: anAlert
      # ...
```

```console
ocne application install --release [RELEASE_NAME] --name prometheus --values values.yaml --values service1-alert.yaml --values service2-alert.yaml
```

### RBAC Configuration

Roles and RoleBindings resources will be created automatically for `server` service.

To manually setup RBAC you need to set the parameter `rbac.create=false` and specify the service account to be used for each service by setting the parameters: `serviceAccounts.{{ component }}.create` to `false` and `serviceAccounts.{{ component }}.name` to the name of a pre-existing service account.

> **Tip**: You can refer to the default `*-clusterrole.yaml` and `*-clusterrolebinding.yaml` files in [templates](templates/) to customize your own.

### ConfigMap Files

AlertManager is configured through [alertmanager.yml](https://prometheus.io/docs/alerting/configuration/). This file (and any others listed in `alertmanagerFiles`) will be mounted into the `alertmanager` pod.

Prometheus is configured through [prometheus.yml](https://prometheus.io/docs/operating/configuration/). This file (and any others listed in `serverFiles`) will be mounted into the `server` pod.

### Ingress TLS

If your cluster allows automatic creation/retrieval of TLS certificates (e.g. [cert-manager](https://github.com/jetstack/cert-manager)), please refer to the documentation for that mechanism.

To manually configure TLS, first create/retrieve a key & certificate pair for the address(es) you wish to protect. Then create a TLS secret in the namespace:

```console
kubectl create secret tls prometheus-server-tls --cert=path/to/tls.cert --key=path/to/tls.key
```

Include the secret's name, along with the desired hostnames, in the alertmanager/server Ingress TLS section of your custom `values.yaml` file:

```yaml
server:
  ingress:
    ## If true, Prometheus server Ingress will be created
    ##
    enabled: true

    ## Prometheus server Ingress hostnames
    ## Must be provided if Ingress is enabled
    ##
    hosts:
      - prometheus.domain.com

    ## Prometheus server Ingress TLS configuration
    ## Secrets must be manually created in the namespace
    ##
    tls:
      - secretName: prometheus-server-tls
        hosts:
          - prometheus.domain.com
```

### NetworkPolicy

Enabling Network Policy for Prometheus will secure connections to Alert Manager and Kube State Metrics by only accepting connections from Prometheus Server. All inbound connections to Prometheus Server are still allowed.

To enable network policy for Prometheus, install a networking plugin that implements the Kubernetes NetworkPolicy spec, and set `networkPolicy.enabled` to true.

If NetworkPolicy is enabled for Prometheus' scrape targets, you may also need to manually create a networkpolicy which allows it.
