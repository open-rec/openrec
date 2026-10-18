# Repository tools

Scripts are grouped by responsibility. Run the commands below from the `openrec/`
repository root. The mode entry points remain `standalone/start.sh` and
`cluster/start.sh`; normal startup invokes the required internal helpers itself.

## Initialization and mode-specific checks

Initialization tools live alongside the Java loader in [`init/tools`](../init/tools):

| File | Responsibility |
|---|---|
| `init.sh` | Shared preparation/import functions, sourced by each mode's `init.sh` |
| `init-input.py` | Validate raw CSV inputs and select warmup samples |
| `fixture-inputs.json` | Bundled acceptance fixture hashes |
| `ensure-model-artifacts.sh` | Reuse a validated model bundle or build one from raw data |

[`standalone/verify.sh`](../standalone/verify.sh) contains the default-fixture
recommendation checks. It is sourced by `standalone/start.sh` after initialization
and uses that script's context; it is not a standalone command. Cluster acceptance
scripts and Airflow DAGs remain under [`cluster`](../cluster).

## Runtime checks

| File | Responsibility | Invocation |
|---|---|---|
| [`runtime/wait-recommendation-ready.py`](runtime/wait-recommendation-ready.py) | Warm item/user routes and wait for verified readiness | Startup; also callable manually |
| [`runtime/verify-init-recommendation.py`](runtime/verify-init-recommendation.py) | Verify custom-data results and ranking behavior | Initialization |
| [`runtime/verify_embedding.py`](runtime/verify_embedding.py) | Compare candidate vectors with the inference service | Startup when embeddings are enabled |
| [`runtime/configure-functional-graph.py`](runtime/configure-functional-graph.py) | Set explicit graph timeout budgets for functional acceptance | Startup when configured |
| [`runtime/verify_http_contract.py`](runtime/verify_http_contract.py) | Exercise HTTP health, metrics, authorization, CRUD, events, and recommendation | Manual; requires an isolated running deployment |

The HTTP contract check was previously named `verify_java_server_upgrade.py`.
It remains useful beyond the Java migration and is not part of ordinary startup.
Use each Python command's `--help` for parameters. Runtime checks may issue requests
or write test data; they are distinct from the offline checks below.

## CI and distribution contracts

| File | Responsibility |
|---|---|
| [`ci/validate.sh`](ci/validate.sh) | Distribution policy, source syntax, and Compose validation |
| [`ci/build-components.sh`](ci/build-components.sh) | Isolated Java component builds and tests |
| [`ci/verify-feature-parity.sh`](ci/verify-feature-parity.sh) | Python/Flink/Spark feature parity tests |
| [`ci/verify_rank_feature_contract.py`](ci/verify_rank_feature_contract.py) | Offline training DAG and feature transport checks |
| [`ci/verify_sdk_feature_contract.py`](ci/verify_sdk_feature_contract.py) | Python/Go SDK fields versus Java protocol types |

```bash
./scripts/ci/validate.sh
python3 -m unittest discover -s scripts/tests -v
python3 scripts/ci/verify_rank_feature_contract.py
python3 scripts/ci/verify_sdk_feature_contract.py
```

Component builds and parity checks need their corresponding JDK, Python packages,
and checked-out source repositories. The shell scripts reuse `scripts/lib`.

## Checkout and release

| File | Responsibility |
|---|---|
| [`release/checkout-components.sh`](release/checkout-components.sh) | Check out component refs from `release/openrec.json` |
| [`release/validate_distribution.py`](release/validate_distribution.py) | Validate the release manifest and local documentation links; shared by CI and packaging |
| [`release/package-release.sh`](release/package-release.sh) | Archive committed HEAD and create a SHA-256 checksum |

```bash
./scripts/release/checkout-components.sh
python3 scripts/release/validate_distribution.py --require-immutable
./scripts/release/package-release.sh
```

## Shared libraries and tests

`lib/java.sh` selects JDK 21. `lib/maven-repository.sh` selects a writable dependency
cache. `lib/maven.sh` wraps Maven with bounded transport retries. These files are
sourced by callers, not executed as user commands.

`tests/` contains unit tests for initialization, startup helpers, and distribution
contracts. CI discovers this directory directly. Add tests there when changing a
shared script, and update callers and this index when adding or moving an entry point.

## Local source with existing images

`lib/local-source.sh` is sourced by both launchers with `--reuse-images`. It builds current Java
and frontend outputs and starts Compose with `--no-build --pull never`.
`runtime/local-source-compose.py` generates the runtime mount overlay and Spark algorithm ZIP;
its arguments are the workspace root, mode runtime directory, and mode name.
