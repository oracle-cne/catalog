# Fluent Operator Helm Chart

[Fluent Operator](https://github.com/fluent/fluent-operator) provides great flexibility in building a logging layer based on Fluent Bit and Fluentd.

## Deploy Fluent Operator with Oracle Cloud Native Environment

The Fluent Bit section of the Fluent Operator supports different CRI `docker`, `containerd`,  and `CRI-O`. 
`containerd` and `CRI-O` use the `CRI Log` format which is different with `docker`, they requires additional parser to parse JSON application logs. You should set different `containerRuntime` depending on your container runtime.

The default runtime is docker, you can choose other runtimes as follows.

If your container runtime is `containerd` or  `cri-o`, you can set the `containerRuntime` parameter to `containerd` or `crio`. e.g.

```shell
ocne application install --namespace fluent --name fluent-operator --release fluent-operator
```

Fluent Operator CRDs will be installed by default when running an install for the application. But if the CRD already exists, it will be skipped with a warning. So make sure you install the CRDs by yourself if you upgrade your Fluent Operator version.

> Note: During the upgrade process, if a CRD was previously created using the create operation, an error will occur during the apply operation. Using apply here allows the CRD to be replaced and created in its entirety in a single operation.

## Fluent Operator Walkthrough

For more info on various use cases of Fluent Operator, you can refer to [Fluent-Operator-Walkthrough](https://github.com/kubesphere-sigs/fluent-operator-walkthrough).

## Collect Kubernetes logs
This guide provisions a logging pipeline including the Fluent Bit DaemonSet and its log input/filter/output configurations to collect Kubernetes logs including container logs and kubelet logs.

![logging stack](https://raw.githubusercontent.com/fluent/fluent-operator/master/docs/images/logging-stack.svg)

> Note that you need a running Elasticsearch v5+ cluster to receive log data before start. **Remember to adjust [output-elasticsearch.yaml](https://github.com/fluent/fluent-operator/blob/master/manifests/logging-stack/output-elasticsearch.yaml) to your own es setup**. Kafka and Fluentd outputs are optional and are turned off by default.

#### Deploy the Kubernetes logging pipeline with Helm

You can also deploy the Kubernetes logging pipeline with Helm, just need to set the `Kubernetes` parameter to `true`(default):

```shell
ocne application update --namespace fluent --release fluent-operator --values <(cat << EOF
containerRuntime: docker
EOF
)
```

If you want to deploy  `fluentd`, just need to set the `fluentd.enable` parameter to `true`.:

```shell
ocne application update --namespace fluent --release fluent-operator --values <(cat << EOF
containerRuntime: docker
fluentd:
  enable: true
EOF
)
```

Within a couple of minutes, you should observe an index available:

```shell
$ curl localhost:9200/_cat/indices
green open ks-logstash-log-2020.04.26 uwQuoO90TwyigqYRW7MDYQ 1 1  99937 0  31.2mb  31.2mb
```

Success!
