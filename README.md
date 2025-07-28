# Oracle Cloud Native Environment Application Catalog

The Oracle Cloud Native Environment Application Catalog is Helm repository
that contains a set of curated cloud native applications.

## Installation

The catalog is installed automatically by the Oracle Cloud Native Environment
CLI.  It is also possible to install the catalog from the catalog itself, by
installing the `ocne-catalog` chart.

## Support Matrix

### Supported for Oracle Cloud Native Environment 2.0

| Application                                         | Chart                       | Versions                                       |
|-----------------------------------------------------|-----------------------------|------------------------------------------------|
| Cert Manager                                        | cert-manager                | 1.17.2<br>1.16.3<br>1.14.5                     |
| Cluster API Core Controller                         | core-capi                   | 1.9.9<br>1.9.4<br>1.8.12<br>1.7.1              |
| Cluster API Kubeadm Control Plane Controller        | control-plane-capi          | 1.9.9<br>1.9.4<br>1.8.12<br>1.7.1              |
| Cluster API Kubeadm Bootstrap Controller            | bootstrap-capi              | 1.9.9<br>1.9.4<br>1.8.12<br>1.7.1              |
| Cluster API for Oracle Cloud Infrastructure         | oci-capi                    | 0.19.0<br>0.17.0<br>0.16.0<br>0.15.0           |
| Cert Manager OCI Webhook                            | cert-manager-webhook-oci    | 1.1.0                                          |
| CoreDNS                                             | coredns                     | 2.0.0                                          |
| CSI Driver for oVirt                                | ovirt-csi-driver            | 4.21.0-alpha1<br>4.20.0                        |
| CSI NFS Driver for Kubernetes                       | csi-driver-nfs              | 4.11.0                                         |
| Dex                                                 | dex                         | 2.43.1<br>2.39.1                               |
| ExternalIP Webhook                                  | externalip-webhook          | 1.0.0                                          |
| Flannel                                             | flannel                     | 2.0.0<br>0.22.3                                |
| Fluent Operator                                     | fluent-operator             | 3.4.0<br>3.2.0                                 |
| Fluentd                                             | fluentd                     | 1.14.5                                         |
| Grafana                                             | grafana                     | 7.5.17                                         |
| Ingress Nginx                                       | ingress-nginx               | 1.12.1<br>1.9.6                                |
| Istio CRDs                                          | istio-base                  | 1.24.6<br>1.24.1<br>1.22.8<br>1.22.6<br>1.20.5 |
| Istiod                                              | istiod                      | 1.24.6<br>1.24.1<br>1.22.8<br>1.22.6<br>1.20.5 |
| Istio Egress Gateway                                | istio-egress                | 1.24.6<br>1.24.1<br>1.22.8<br>1.22.6<br>1.20.5 |
| Istio Ingress Gateway                               | istio-ingress               | 1.24.6<br>1.24.1<br>1.22.8<br>1.22.6<br>1.20.5 |
| Istio Gateway                                       | istio-gateway               | 1.24.6<br>1.24.1<br>1.22.8<br>1.22.6           |
| Istio Ztunnel                                       | istio-ztunnel               | 1.24.6<br>1.24.1                               |
| Istio CNI                                           | istio-cni                   | 1.24.6<br>1.24.1                               |
| Keycloak                                            | keycloak                    | 21.1.2                                         |
| Kube Prometheus Stack                               | kube-prometheus-stack       | 0.63.0                                         |
| Kube Proxy                                          | kube-proxy                  | 2.0.0                                          |
| Kube State Metrics                                  | kube-state-metrics          | 2.8.2                                          |
| KubeVirt                                            | kubevirt                    | 1.5.2<br>1.4.1<br>1.3.1<br>1.2.2<br>1.1.1      |
| MetalLB                                             | metallb                     | 0.15.2<br>0.13.10                              |
| Multus                                              | multus                      | 4.2.1<br>4.0.2                                 |
| OAuth2 Proxy                                        | oauth2-proxy                | 7.8.0                                          |
| OCI Cloud Controller Manager                        | oci-ccm                     | 1.30.0<br>1.28.0                               |
| OLVM CAPI Controller Manager                        | olvm-capi                   | 1.0.0                                          |
| OpenSearch                                          | opensearch                  | 2.15.0                                         |
| OpenSearch Dashboards                               | opensearch-dashboards       | 2.15.0                                         |
| Oracle Cloud Native Environment Application Catalog | ocne-catalog                | 2.0.0                                          |
| Prometheus                                          | prometheus                  | 2.31.1                                         |
| Prometheus Adapter                                  | prometheus-adapter          | 0.10.0                                         |
| Prometheus Node Exporter                            | prometheus-node-exporter    | 1.6.1                                          |
| Rook                                                | rook                        | 1.14.12<br>1.13.10<br>1.12.3                   |
| Tigera Operator with Calico                         | tigera-operator             | 1.32.12<br>1.32.4                              |
| Oracle Cloud Native Environment Dashboard           | ui                          | 2.2.0<br>2.0.0                                 |
| Kubernetes Gateway API CRDs                         | kubernetes-gateway-api-crds | 1.2.1                                          |

### Supported While Upgrading From Oracle Cloud Native Environment 1.x

| Application | Chart | Versions |
|-------------|-------|----------|
| Cert Manager | cert-manager | 1.9.1 |
| Istio CRDs | istio-base | 1.19.9 |
| Istiod | istiod | 1.19.9 |
| Istio Egress Gateway | istio-egress | 1.19.9 |
| Istio Ingress Gateway | istio-ingress | 1.19.9 |
| KubeVirt | kubevirt | 1.0.1<br>0.59.0<br>0.58.0 |
| MetalLB | metallb | 0.12.1 |
| OCI Cloud Controller Manager | oci-ccm | 1.27.2 |
| Rook | rook | 1.11.6<br>1.10.9 |
| Tigera Operator with Calico | tigera-operator | 1.32.12<br>1.32.4<br>1.29.3 |

## Documentation

### Building

```
make
```

This will build all charts in the `./charts` directory and package them into
a Helm repository in `./repo`.

### Adding a Chart

To add a chart, simply add it to the `./charts` directory in a subdirectory
named for the chart and chart version.  For example, the chart `mycoolapp` at
version `2.3.4` would be put inside `./charts/mycoolapp-2.3.4`.  All charts
must be created such that the chart version and application version are
identical and are not prefixed with a 'v'.

## Contributing


This project welcomes contributions from the community. Before submitting a pull request, please [review our contribution guide](./CONTRIBUTING.md)

## Security

Please consult the [security guide](./SECURITY.md) for our responsible security vulnerability disclosure process

## License

Copyright (c) 2023 Oracle and/or its affiliates.

Released under the Universal Permissive License v1.0 as shown at
<https://oss.oracle.com/licenses/upl/>.
