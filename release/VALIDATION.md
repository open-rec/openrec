# OpenRec 0.2.0 validation record

Release preparation: 2026-10-18.

The maintainer confirmed that the refactored application chains and CI passed
before this release. All nine product repositories were fetched from origin and
matched their respective default-branch tips before creating `release/0.2.0`.
Release preparation changes version metadata, matching artifact paths and release
documentation. It does not regenerate model weights or modify fixture data.

## Local release checks

| Area | Command / scope | Result |
|---|---|---|
| Distribution tests | `python3 -B -m unittest discover -s scripts/tests -q` in openrec | 55 passed |
| Rank feature transport | `python3 -B scripts/ci/verify_rank_feature_contract.py` | Passed |
| SDK contracts | `python3 -B scripts/ci/verify_sdk_feature_contract.py` | Passed |
| Python SDK | `python3 -B -m unittest discover -s tests -q` in sdk/python-client | 7 passed |
| Feature catalog | `python3 -B feature/catalog/validate_catalog.py` and `python3 -B feature/catalog/publish_catalog.py --check` in model | 264 features, 92 fitted references; packaged copies match |
| Bootstrap artifacts | `PYTHONPATH=. python3 -B tool/check_default_artifacts.py --data ../openrec/data/test --model-root ../model` in rec-algorithm | Passed; no artifacts changed |
| Algorithm wheel | `python3 -m pip wheel --no-deps --no-build-isolation --wheel-dir /tmp/openrec-release-020/wheels /tmp/openrec-release-020/rec-algorithm` | rec_algorithm-0.2.0 wheel built from isolated source copy |
| Distribution policy | `bash scripts/ci/validate.sh` | Passed; shell syntax, Python parsing, Compose configuration and tracked-file policy; shellcheck unavailable |

Java builds used isolated source copies under `/tmp/openrec-release-020` and the
workspace Java 21/Maven 3.9.9 toolchain with an existing offline dependency cache.
The following commands used `-o -B -ntp` and
`-Dmaven.repo.local=/home/xsank.mz/openrec/.cache/maven-repository-127058`:

- rec-server: `mvn clean install -DskipTests`, then `mvn -pl graph,proto,contrib test`.
- sdk/java-client: `mvn clean verify`, then `mvn install` to supply the distribution builds.
- data-processor: `mvn clean verify`; the sandbox blocked Spark socket creation,
  so `mvn install` was rerun outside the sandbox and passed all modules and tests.
- openrec/init and openrec/web: `mvn install`, including tests and executable packaging.

Test totals: graph/proto/contrib 44 passed; Java SDK 7 passed; data-processor 31
passed; initialization 13 passed and 1 skipped; Web Demo 2 passed.
All resulting Java artifacts use version 0.2.0. Component commit hooks also passed
Java formatting and console Python style checks. The full rec-server live-service
suite and full Python application suites were not rerun for these version-only
source edits. Model artifacts and deterministic fixture files remain byte-identical
to the release baseline.

## Remote acceptance and publication

At the maintainer's explicit request, remote acceptance workflow dispatch remains
with the maintainer. This record does not claim that the new release commits have
passed remote Quality, Standalone E2E or Cluster E2E. No full deployment restart
was performed during release preparation. Prior successful CI and end-to-end
results are maintainer-reported evidence for the baseline, not newly executed
release-commit tests.

Pushing the annotated `v0.2.0` tags triggers each repository's existing Release
workflow to publish source archives and checksums. Branch pushes may also trigger
existing push-based CI automatically. No workflow definitions are changed.

Use the exact [component set](COMPONENTS.md) and [upgrade instructions](../RELEASE_NOTES.md).
Functional checks do not establish throughput, latency, authentication or HA guarantees.
The historical [v0.1.0 validation record](https://github.com/open-rec/openrec/blob/v0.1.0/release/VALIDATION.md)
remains available under its immutable tag.
