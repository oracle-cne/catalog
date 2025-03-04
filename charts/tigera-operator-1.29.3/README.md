# Calico

Calico is a widely adopted, battle-tested open source networking and network security solution for Kubernetes, virtual machines, and bare-metal workloads.
Calico provides two major services for Cloud Native applications:

- Network connectivity between workloads.
- Network security policy enforcement between workloads.

Calico’s flexible architecture supports a wide range of deployment options, using modular components and technologies, including:

- Choice of data plane technology, whether it be [eBPF](https://projectcalico.docs.tigera.io/maintenance/ebpf/use-cases-ebpf), standard Linux, [Windows HNS](https://docs.microsoft.com/en-us/virtualization/windowscontainers/container-networking/architecture) or [VPP](https://github.com/projectcalico/vpp-dataplane)
- Enforcement of the full set of Kubernetes network policy features, plus for those needing a richer set of policy features, Calico network policies.
- An optimized Kubernetes Service implementation using eBPF.
- Kubernetes [apiserver integration](./apiserver), for managing Calico configuration and Calico network policies.
- Both non-overlay and [overlay (via IPIP or VXLAN)](https://projectcalico.docs.tigera.io/networking/vxlan-ipip) networking options in either public cloud or on-prem deployments.
- [CNI plugins](./cni-plugin) for Kubernetes to provide highly efficient pod networking and IP Address Management (IPAM).
- A [BGP routing stack](https://projectcalico.docs.tigera.io/networking/bgp) that can advertise routes for workload and service IP addresses to physical network infrastructure.

# Installing

Install the application

```
ocne application install --release calico --name tigera-operator --namespace tigera-operator
```

# Values reference

The default values.yaml should be suitable for most basic deployments.

```
# Image pull secrets to provision for pulling images from private registries.
# This field is a map of desired Secret name to .dockerconfigjson formatted data to use for the secret.
# Populates the `imagePullSecrets` property for all Pods controlled by the `Installation` resource.
imagePullSecrets: {}

# Configures general installation parameters for Calico. Schema is based
# on the operator.tigera.io/Installation API documented
# here: https://projectcalico.docs.tigera.io/reference/installation/api#operator.tigera.io/v1.InstallationSpec
installation:
  enabled: true
  kubernetesProvider: ""

# Configures general installation parameters for Calico. Schema is based
# on the operator.tigera.io/Installation API documented
# here: https://projectcalico.docs.tigera.io/reference/installation/api#operator.tigera.io/v1.APIServerSpec
apiServer:
  enabled: true

# Certificates for communications between calico/node and calico/typha.
# If left blank, will be automatically provisioned.
certs:
  node:
    key:
    cert:
    commonName:
  typha:
    key:
    cert:
    commonName:
    caBundle:

# Resources for the tigera/operator pod itself.
# By default, no resource requests or limits are specified.
resources: {}

# Tolerations for the tigera/operator pod itself.
# By default, will schedule on all possible place.
tolerations:
- effect: NoExecute
  operator: Exists
- effect: NoSchedule
  operator: Exists

# NodeSelector for the tigera/operator pod itself.
nodeSelector:
  kubernetes.io/os: linux

# Custom annotations for the tigera/operator pod itself
podAnnotations: {}

# Custom labels for the tigera/operator pod itself
podLabels: {}

# Configuration for the tigera operator images to deploy.
tigeraOperator:
  image: olcne/operator
  registry: container-registry.oracle.com
calicoctl:
  image: container-registry.oracle.com/olcne/ctl
```
