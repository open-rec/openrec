# End-to-end CI

## Runner tiers

Quality, standalone, and cluster workflows use GitHub-hosted Ubuntu runners. The full cluster was
designed for at least 16 CPU cores, 32 GiB RAM, and 100 GiB free storage, so its hosted-runner job
uses reduced development heaps, limits Compose build concurrency, and reduces Spark executor cores.
These limits are CI acceptance sizing rather than production recommendations.

Cluster workflow triggers remain limited to scheduled default-branch runs and
maintainer-initiated manual dispatches because the job starts a large privileged Docker topology.

## Test ownership

- Component unit tests remain in their component repositories.
- `quality.yml` detects cross-repository build and contract drift.
- `standalone-e2e.yml` is the required minimum distribution acceptance.
- `cluster-e2e.yml` proves distributed lifecycle behavior and is required before a stable release.

Every E2E workflow runs cleanup under `always()` and uploads sanitized diagnostic logs on failure.
The runner should also use an ephemeral VM or perform an independent post-job cleanup so an aborted
workflow cannot contaminate the next run.

The quality workflow checks out the Java components used by its compatibility build and every
component referenced by the standalone and cluster Compose definitions. Set `OPENREC_COMPONENTS`
to a space-separated list when running `scripts/checkout-components.sh` to select components; when
it is unset, the script continues to check out the complete manifest.
Manifest branch refs are checked out as local tracking branches so a development workspace remains
attached to its branch. Immutable commit and tag refs intentionally use detached HEAD mode.
