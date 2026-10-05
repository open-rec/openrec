# OpenRec 0.1.0 validation record

Validated on 2026-10-05. The release changes package/jar versions, matching consumers and startup paths, release documentation and publication workflows. It does not change recommendation payloads, feature formulas, model weights or mutation schemas.

## Checks executed during release preparation

| Area | Command / scope | Result |
|---|---|---|
| rec-server | Java 21 `mvn clean install` | 151 tests: 149 passed, 2 existing live-service skips; all five modules built |
| Java SDK | Java 21 `mvn clean install` against rec-proto 0.1.0 | 6 passed; rec-client 0.1.0 installed |
| data-processor | Java 21 `mvn clean verify` | 26 passed, including Flink state/parity and Spark micro-batches; 0.1.0 jars built |
| example/init | Java 21 `mvn clean verify` | 3 passed; executable assembly built |
| example/web | Java 21 `mvn clean verify` | 2 passed; Spring Boot jar built |
| rec-algorithm | Current source copied into a temporary `openrec/rec-algorithm:latest` container; `python -m pytest -q -p no:cacheprovider test` with Spark 4.0.4 and the separate training interpreter | 140 passed |
| Algorithm package | `pip wheel --no-deps --no-build-isolation` in an isolated source copy | `rec_algorithm-0.1.0-py3-none-any.whl` built |
| rank-engine | Temporary `openrec/rank-engine:latest` container, newly built algorithm 0.1.0 wheel installed; `python -m pytest -q -p no:cacheprovider test` | 51 passed |
| rec-console backend | Temporary `openrec/rec-console:latest` container; complete `test` suite, plus the opt-in Elasticsearch lifecycle test against the running ES service | 51 isolated tests and 1 real-ES integration test passed |
| rec-console frontend | Node 22.22.0 container, copied frontend tree, `npm run build` | TypeScript and Vite build passed |
| Python SDK | `python -m unittest discover -s tests -q` | 5 passed |
| Go SDK | Go 1.22 container, `go vet ./...` and `go test ./...` | Passed |
| experiments | `.venv/bin/python -m pytest -q -p no:cacheprovider tests` | 30 passed |
| Catalog | `validate_catalog.py` and `publish_catalog.py --check` | 264 canonical features, 92 fitted references; packaged copies match |
| Bootstrap bundle | `check_default_artifacts.py --data ../example/data/test --model-root ../model` | Input/catalog/output checks passed |
| Distribution | `python -m unittest discover -s scripts/tests -q` | 28 passed |
| Cross-component contracts | `verify_rank_feature_contract.py` and `verify_sdk_feature_contract.py` | Passed |
| Manifest | `validate_distribution.py --require-immutable` | Version/ref/documentation checks passed |
| Deployment definitions | `docker compose config --quiet` for platform, standalone and cluster; `bash -n` for tracked shell scripts | Passed |

Java builds used isolated source copies to avoid pre-existing generated directories. Tests that bind loopback ports or attach Mockito agents ran outside the restrictive sandbox. Container source mounts were read-only; test/model outputs went to temporary locations. Test tools were added only to disposable containers, not to running services. The algorithm tests used the offline image's Python 3.11/PyTorch 2.8 training interpreter; rank-engine used its Python 3.12/PyTorch 2.10 serving runtime. These checks are not a replacement for every possible dependency/version matrix.

The rec-console backend, Python SDK, model and feature checks also ran earlier in the same release review; subsequent release edits there affect documentation, version metadata and repository packaging. No browser interaction suite was run.

## Integration and remote CI evidence

The maintainer confirmed that the latest remote Actions runs before release preparation were successful. This record does not claim an independently queried remote result for the new release commits.

The [recommendation readiness log](../docs/recommendation-readiness.md) records the 2026-10-05 standalone/cold-restart and full cluster startup regressions, including all 13 bootstrap tasks, ranked recommendations and Kafka/Spark/Redis feature parity. Those are historical local integration runs for the application behavior carried into this release. A fresh standalone/cluster deployment was not restarted during this packaging pass. The lifecycle scripts remain available for installation-specific acceptance.

Functional CI uses relaxed request/node deadlines on shared runners. No throughput, latency, HA, authentication or online recommendation-quality guarantee is inferred from these checks. For deployment, use the exact [component set](COMPONENTS.md), preserve existing data and checkpoints, and follow the documented readiness and upgrade procedures.
