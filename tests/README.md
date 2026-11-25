# Application tests

Each `tests/<application>/` directory contains an OCNE `cluster.yaml` and an
executable `test.sh`, together with application-specific fixtures and additional
functional checks. Profiles use the native OCNE cluster configuration format;
there is no separate profile schema or Jenkins-specific metadata.

Execution is `tests/run-changed.sh` (select tests) → `tests/runner/run-tests.sh`
(provision resources, run the selection, clean up) → `tests/<suite>/test.sh`
(install and validate the application). The resource wrapper uses the existing
catalog-server and cluster lifecycle helpers. Component scripts do not provision
clusters or catalogs. No executable scripts are generated in temporary directories.

Application dependency relationships belong in the application's template as
`applicationDependencies` (see the catalog README). Before selecting suites,
`run-changed.sh` recursively verifies that every declared dependency exists at
the required version in the selected commit. Generated chart annotations retain
the resolved relationships; older charts use their committed template. Missing
dependencies, invalid chart identities and cycles fail before provisioning.
The selector does not generate missing charts during testing: `generate.sh`
creates them before the candidate is committed. Component suites own dependency
installation and functional validation; Istio installs its matching stack.

Run `tests/run-changed.sh` to provision each selected test from its component
`cluster.yaml`, or supply `KUBECONFIG` to reuse an existing cluster. The dispatcher builds
this checkout's committed charts, serves them through nginx and registers a
temporary catalog in the cluster. Selected suites install or update applications
from that catalog and perform the checks carried over from
`test-suite/component-tests`. Clusters created by the dispatcher are deleted
after their tests, including failures, unless `CATALOG_RETAIN` is non-empty.

For example, from this repository root:

```sh
tests/run-changed.sh
# Run Prometheus directly through the resource wrapper.
tests/runner/run-tests.sh prometheus
# Preserve automatically created clusters for inspection, including after failures.
CATALOG_RETAIN=1 tests/run-changed.sh
# Reuse an externally provisioned cluster; the dispatcher will not delete it.
KUBECONFIG=/path/to/application-test.kubeconfig tests/run-changed.sh
```

Application resource cleanup follows each suite's existing behavior. Supplied
clusters remain available for inspection and repair. In an issue/PR workflow
that already provisions a cluster, export its kubeconfig as `KUBECONFIG` so the
dispatcher reuses that lifecycle. Provider credentials and access to the Jenkins
control cluster are not test inputs.

## Environments and checks

The topology and Kubernetes versions below preserve the source scripts defaults.
Profiles contain no installation of the application under test. All select
libvirt and disable the UI and running catalog. All selected tests use the
temporary catalog built from this checkout. There is no public catalog selector
or embedded-catalog fallback. The dispatcher supplies the changed chart versions
to the suites explicitly.

| Application | Control planes / workers | Kubernetes | Initial CNI | Checks |
| --- | --- | --- | --- | --- |
| `tigera-operator` | 1 / 3 | 1.33 | none | Install Calico; check operator, workloads, and node readiness |
| `rook` | 1 / 3 | 1.33 | Flannel | Install operator; additional core test exercises RBD, CephFS, and S3 |
| `csi-driver-nfs` | 1 / 1 | 1.33 | Flannel | Install driver and NFS server; validate PVC and read/write Job |
| `prometheus` | 1 / 1 | 1.33 | Flannel | Install and check deployment; additional metrics test verifies scraping/querying |
| `fluent-operator` | 1 / 3 | 1.34 | Flannel | Install operator and logging workload; verify log collection and image sources |
| `oauth2-proxy` | 1 / 3 | 1.35 | Flannel | Install Dex, ingress-nginx, MetalLB, proxy and demo; additional curl test exercises login |
| `istio` | 1 / 3 | 1.33 | Flannel | Install sidecar/ambient components and Bookinfo; validate images and routing |

Calico requires registered nodes and a reachable API before testing, but node
readiness follows candidate CNI installation. Use `cluster.yaml` for Iptables
and BPF modes; use `cluster-nftables.yaml` with
`--calico-linux-dataplane Nftables`. The test validates the existing kube-proxy
configuration for Nftables; it does not provision or reconfigure the cluster.

Rook profiles retain 256Gi VM disks and inline Butane configuration creating the
unformatted `/dev/sda4` partition after 30GiB for Ceph. The core test requires
three workers with those devices available. Its default resource retention
allows post-failure inspection; use its cleanup options as appropriate.

OAuth2 integration requires `--metallb-address-pool` with unused addresses on the
provisioned cluster's L2 network. This environment-specific value is deliberately
not guessed or embedded in the cluster profile. The additional curl test takes
`--address` with the assigned ingress LoadBalancer address.

Istio tests cover several catalog applications, so the directory uses `istio`
as the suite name. Companion scripts remain in that directory. The script can
retrieve upstream Bookinfo manifests; use `--bookinfo-manifest` and
`--bookinfo-ref` for a selected local fixture or revision.

## Local verification

```sh
find tests -name '*.sh' -exec bash -n {} \;
tests/rook/test.sh --help
```

Syntax checks do not establish a successful cluster or application test.
The original standalone component scripts remain available in `test-suite`
during migration. These new source files are not currently installed by the
catalog RPM or included in its served Helm repository; consumers must stage the
`tests` tree from a selected catalog revision.

## Run only changed applications

`tests/run-changed.sh` compares committed chart contents with the merge base of
`HEAD` and its parent branch. Automatic discovery examines local and `origin`
`main` and `release/*` refs, retaining the unique common ancestor that descends
from all other candidate common ancestors. Git does not store the branch name
used at creation. Discovery logs the selected base refs and fork point; refs
sharing that fork point are equivalent for selecting changed charts.
Incomparable ancestors, unavailable history and shallow checkouts fail explicitly.
No fetch, checkout or other Git write is performed. Maintain the parent refs
in the checkout preparation step. Base refs are always discovered; there is no
base argument or environment override:

```sh
# Print application/version/suite/version-option/extra-option/extra-value TSV.
tests/run-changed.sh --list
# Inspect an existing development ref without checking it out.
tests/run-changed.sh --head origin/315-add-rook-1189-helm-charts --list
```

A check against that development ref selected:

```text
rook	1.18.9	rook	--rook-version	-	-
```

`--head REF` permits selection from another revision; execution requires that
revision to be checked out. Working-tree changes are excluded. Parent-side
changes after the fork are excluded. Every changed chart directory is selected
once, including new versions, value changes, and moves between applications.
Removed chart versions have no candidate to install and are logged without
execution. README-only changes produce an empty successful selection.
The entry point only selects branch changes. For a manual component run,
`tests/runner/run-tests.sh prometheus` provisions the Prometheus profile, serves
this checkout's catalog, runs the component test and cleans up. The changed-test
entry point calls this same wrapper with its selected TSV plan. The wrapper
inherits the caller's OCNE defaults; neither script overrides `OCNE_DEFAULTS`.

`tests/suites.tsv` explicitly maps chart names to existing test suites and their
version arguments. Dependency applications such as Dex, ingress-nginx and
MetalLB use the OAuth2 integration suite. Ambient Istio components use ambient
mode; Gateway API CRDs select Gateway API routing. Applications without coverage
fail selection with the complete list of missing mappings. Add a real suite and
mapping before enabling such updates; no missing coverage is silently skipped.
Multiple changed versions run separately. Suite failures are recorded, remaining
selected charts still run, and the overall exit status is nonzero.

Run against a suitable caller-provisioned cluster:

```sh
KUBECONFIG=/path/to/test.kubeconfig tests/run-changed.sh
```

Each selected suite requires the topology, Kubernetes version, storage and CNI
in its `cluster.yaml`. Automatically created clusters use that profile unchanged,
with only a unique cluster name and UI startup disabled on the CLI. A supplied
kubeconfig is suitable only when it satisfies
all selected suites. OAuth2 also needs `METALLB_ADDRESS_POOL` on the cluster's
L2 network. The dispatcher does not fabricate that environment-specific value.
This path runs each suite's `test.sh`; additional companion checks remain separate.

The only supplied cluster input is `KUBECONFIG`, which must name an existing,
readable, nonempty file when set. An invalid supplied path fails rather than
starting another cluster. There is no runner callback or kubeconfig command-line
option.

### Cluster lifecycle

| Invocation | Cluster behavior |
| --- | --- |
| `KUBECONFIG=/path/to/config tests/run-changed.sh` | Reuse the supplied cluster; never delete it |
| `tests/run-changed.sh` with no `KUBECONFIG` | Create a fresh cluster per selected application/version from its suite profile; delete after each test |
| `CATALOG_RETAIN=1 tests/run-changed.sh` with no `KUBECONFIG` | Retain every created cluster, including failed or partially provisioned clusters |
| `tests/run-changed.sh --list` | Select tests without starting clusters or the catalog server |

Any non-empty `CATALOG_RETAIN` value enables retention, including `0` and `false`.
The cluster name and command for locating its kubeconfig are logged. Retention
does not retain the temporary catalog registration or nginx container. CI agent
teardown remains controlled by the invoking build environment.

Provisioning uses native `ocne cluster start --config ... --cluster-name ...`,
then obtains the exported kubeconfig through `ocne cluster show`. Deletion uses
the owned cluster name through `ocne cluster delete`. These follow the existing
integration suite's `tests/setup/setup` and shared `codex.provisionTestCluster`
call paths. Jenkins Groovy provisioning is not callable by this standalone shell
entry point; the OCNE CLI remains the owner of provisioning and its cached state.
The provided component profile is passed directly, preserving Kubernetes version,
topology, CNI and disk configuration.

Libvirt is assumed to be configured and working for the caller. The dispatcher
does not probe or manage libvirt services, inspect or create KVM devices, install
virtualization packages, or run virsh. This preserves the host's modular libvirt
configuration, including its virt-proxyd setup. Native OCNE operations use the
caller's existing provider access and report any provisioning failure directly.

The candidate repository and nginx container are built once per run. The catalog
is registered in each selected cluster, removed after its suite, and the owned
cluster is then deleted or retained. Test failures still allow subsequent suites
to run after successful cleanup. Provisioning, kubeconfig-export and cleanup
failures abort the run and trigger cleanup of the currently owned resources.

### Candidate catalog lifecycle

The resource wrapper archives the selected commit into an isolated temporary directory
and runs the existing catalog Makefile there. This builds a fresh Helm repository
containing all candidate charts, including unchanged companion applications.
Working-tree files and stale build output cannot enter that repository.
The integration suite's `tools/start-test-catalog.sh` instead invokes a generator
that replaces its synthetic fixture charts; it does not accept candidate source.
This lifecycle keeps the catalog Makefile as the packaging owner.

Podman runs `container-registry.oracle.com/olcne/nginx:1.26.3` to serve
`/charts/index.yaml` and chart archives. The candidate repository and generated
nginx configuration are mounted read-only. Podman allocates a host port bound
only to loopback. A private health endpoint and index comparison verify that
this container serves the generated repository. No host nginx is required.

The resource wrapper creates a unique namespace and registers the HTTP endpoint there
using `ocne catalog add`. OCNE's external-catalog connection fetches that endpoint
directly from the CLI process, so the server needs no cluster ingress, CNI, image
build or registry publication. This temporary catalog is intended for CLI tests
on the worker; its loopback URI is not an endpoint for other cluster clients.

The generated catalog name is passed internally to every selected suite. Suites
reject a public `--catalog` option and require dispatcher context; their install,
update and catalog-search operations all use the generated catalog. Existing
per-application catalog environment overrides are not read.

After success, failure or a handled interrupt, cleanup unregisters the catalog,
deletes its namespace, collects nginx logs, removes the owned container and its
anonymous volumes, and removes the temporary
repository. Cleanup failures make the overall run fail. Application resources
in supplied clusters remain under their existing lifecycle contracts.

Execution requires `ocne`, `kubectl`, `make`, Helm, Podman, curl, tar and cmp,
in addition to Git, yq and the standard shell utilities. The dispatcher checks
selection tools before inspecting Git, then build/test tools only when selected
applications will run. Missing commands are mapped to DNF packages and installed
with `dnf install -y`, one transaction per phase. Existing commands are retained;
no DNF transaction runs when the required commands are already available.

Package names match command names for Git, yq, make, Helm, Podman, curl, tar,
sed, grep, OCNE and kubectl. `awk` uses `gawk`, `cmp` uses `diffutils`, `find`
uses `findutils`, and standard utilities use `coreutils`. Duplicate packages are
installed once per transaction.
Every missing command is checked again after installation. DNF failures and
commands still unavailable afterward fail the
corresponding setup phase.

Installation uses the enabled system repositories. Only DNF installation
may use `sudo -n -- dnf install -y PACKAGES` when the caller is not already root. Sudo retains
its normal environment filtering; no variables are explicitly preserved or
forwarded. No shell, workflow, OCNE command, Helm command, Podman command,
or application test is elevated. Existing root build-container callers
execute these host operations directly. The script does not add repositories or
bypass package checks. If DNF is
unavailable, it reports all missing commands. `OCNE_BIN` and `KUBECTL_BIN` can
select existing tool executables; missing custom executable paths fail explicitly
because installing the standard RPM cannot supply an arbitrary path. Neither
setting selects a different catalog. No CLI rebuild with an embedded catalog is
required, and nginx remains supplied exclusively by the specified container image.

### Automatic build integration

`olm/test/test.sh` is the standard pipeline's automatically discovered acceptance
entry point and forwards to this dispatcher. No Jenkinsfile or shared-library
implementation is added. The existing owner is
`pipeline/vars/olcnePipeline.groovy:runAcceptanceTests`, which calls the default
repository script through `executeScript`; the muxer invokes that child pipeline
for its configured platform and architecture. Existing x86_64-only acceptance
execution, credentials, image setup, skip controls and cleanup ownership apply.
Workflows that already own a cluster export `KUBECONFIG` for it. Other builds
allow the dispatcher to create and clean up the component-profile clusters.
The dispatcher does not read workflow-specific kubeconfig variables or change
the shared provisioner.

The `codex-worker:8`
image includes OCNE, Helm, Podman and kubectl. Podman must be able to pull or use
the specified nginx image and run its container in the build environment.
A PR target is deliberately not used as a
parent: catalog release work may fork from `main` while targeting a release ref.
Absent execution prerequisites fail acceptance rather than selecting another
catalog or reporting a successful skipped application test.

