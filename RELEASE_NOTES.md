# OpenRec v0.1.0

Released: 2026-10-05

OpenRec distribution. First coordinated OpenRec source release.

## Features

- One versioned assembly of the online service, algorithms, ranking, streaming, control plane, infrastructure and SDKs.
- Standalone quick start and a distributed cluster reference deployment with committed fixture data.
- Item/user recommendation APIs, multi-channel recall, feature consistency and model/recall/graph lifecycle management.
- Java 21 source builds, recommendation readiness/warmup, recall diagnostics and ranked recommendation acceptance.
- Immutable component manifest, compatibility checks, source bundle and SHA-256 checksum assets.

## Installation and compatibility

Use `scripts/checkout-components.sh` to obtain the exact component commits in `release/openrec.json`. All OpenRec Java modules and clients require Java 21. Maven artifacts and the rec-algorithm package are now `0.1.0`; old `1.0-SNAPSHOT` jar names and `0.0.1` wheel references must be updated together.

This is a source distribution for evaluation, development and distributed integration. Standalone bypasses ranking; cluster enables the full lifecycle. The console has no authentication, sample credentials must be replaced, and the supplied cluster is not a production HA topology. Functional CI timeout overrides are not latency guarantees.

## Validation and known boundaries

See this repository's README for build/test commands and deployment requirements. The coordinated release's [validation record](https://github.com/open-rec/openrec/blob/v0.1.0/release/VALIDATION.md) distinguishes checks executed for this release from historical integration evidence.

This initial release establishes a versioned source baseline. Source archives and checksums are published; external package registries and container registries are not populated by the source-release workflow. Upgrade the complete compatible distribution, retain data/checkpoints/artifacts, and preserve prior component refs for rollback.

## Component versions

See [the exact component commits](release/COMPONENTS.md) and [distribution manifest](release/openrec.json). Every product repository is tagged `v0.1.0` on its `release/0.1.0` branch.
