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

Install the application.

```
ocne application install --release calico --name tigera-operator --namespace tigera-operator
```

# Values reference

The default values.yaml should be suitable for most basic deployments.

```
# imagePullSecrets is a special helm field which, when specified, creates a secret
# containing the pull secret which is used to pull all images deployed by this helm chart and the resulting operator.
# this field is a map where the key is the desired secret name and the value is the contents of the imagePullSecret.
#
# Example: --set-file imagePullSecrets.gcr=./pull-secret.json
imagePullSecrets: {}

# Configures general installation parameters for Calico. Schema is based
# on the operator.tigera.io/Installation API documented
# here: https://projectcalico.docs.tigera.io/reference/installation/api#operator.tigera.io/v1.InstallationSpec
installation:
  enabled: true
  kubernetesProvider: ""

  # imagePullSecrets are configured on all images deployed by the tigera-operator.
  # secrets specified here must exist in the tigera-operator namespace; they won't be created by the operator or helm.
  # imagePullSecrets are a slice of LocalObjectReferences, which is the same format they appear as on deployments.
  #
  # Example: --set installation.imagePullSecrets[0].name=my-existing-secret
  imagePullSecrets: []

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
  image: olcne/tigera-operator
  registry: container-registry.oracle.com
calicoctl:
  image: container-registry.oracle.com/olcne/ctl

# Configuration for the Calico CSI plugin - setting to None will disable the plugin, default: /var/lib/kubelet
kubeletVolumePluginPath: None
```
