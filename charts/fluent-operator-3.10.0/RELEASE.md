
### Added

- `batchSize` support for the OpenTelemetry Fluent Bit output ([#2015](https://github.com/fluent/fluent-operator/pull/2015))
- `rawLogKey` and raw format support for the Kafka Fluent Bit output ([#2000](https://github.com/fluent/fluent-operator/pull/2000))
- `totalLimitSize` (storage total limit) support for the Splunk Fluent Bit output ([#2009](https://github.com/fluent/fluent-operator/pull/2009))

### Changed

- `fluentbit.service` value now accepts any valid Fluent Bit `[service]` field, merged over the chart defaults ([#2010](https://github.com/fluent/fluent-operator/pull/2010))
- Bumped default Fluent Bit image tag to `5.1.0` ([#2027](https://github.com/fluent/fluent-operator/pull/2027))
- Bumped fluent-operator to v3.10.0
