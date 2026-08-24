# End-to-end CI

## Runner tiers

Quality and standalone workflows use GitHub-hosted Ubuntu runners. Cluster acceptance uses a
dedicated Linux x86-64 runner with the labels `self-hosted`, `linux`, `x64`, and `openrec-cluster`.

The cluster runner should provide at least 16 CPU cores, 32 GiB RAM, 100 GiB free storage, Docker
Engine with Compose v2, JDK 8, Maven, Python 3, curl, rsync, Git, and Bash. It must be dedicated to
trusted OpenRec workflow code; cluster jobs execute repository scripts and start privileged data
infrastructure.

Do not expose a persistent self-hosted runner to pull requests from forks. Cluster workflow triggers
are limited to scheduled default-branch runs and maintainer-initiated manual dispatches.

## Test ownership

- Component unit tests remain in their component repositories.
- `quality.yml` detects cross-repository build and contract drift.
- `standalone-e2e.yml` is the required minimum distribution acceptance.
- `cluster-e2e.yml` proves distributed lifecycle behavior and is required before a stable release.

Every E2E workflow runs cleanup under `always()` and uploads sanitized diagnostic logs on failure.
The runner should also use an ephemeral VM or perform an independent post-job cleanup so an aborted
workflow cannot contaminate the next run.

The quality workflow checks out only the Java components used by its compatibility build. Set
`OPENREC_COMPONENTS` to a space-separated list when running `scripts/checkout-components.sh` to
select components; when it is unset, the script continues to check out the complete manifest.
