#!/usr/bin/env bash
# Copyright (c) 2026, Oracle and/or its affiliates.
# Standard olcnePipeline acceptance entry point. Provisioning belongs to caller.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
printf 'catalog-tests: entering automatic acceptance tests\n' >&2
exec "$root/tests/run-changed.sh" "$@"
