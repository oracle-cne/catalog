# Oracle Cloud Native Environment Application Catalog

The Oracle Cloud Native Environment Application Catalog is Helm repository
that contains a set of curated cloud native applications.

## Installation

The catalog is installed automatically by the Oracle Cloud Native Environment
CLI.  It is also possible to install the catalog from the catalog itself, by
installing the `ocne-catalog` chart.

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
