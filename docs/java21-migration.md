# Java 21 migration: rec-server first

Validated on 2026-10-04. This phase upgrades rec-server to Java 21 and Spring Boot 4.1.1.
SDK, init, web, and data-processor continue to run on Java 8. The console remains Python/React.

## Companion changes

- rec-server `c4cc8df29eb066cce6b6c3073fbe641912fd50ae`: neutral Maven parent, Boot BOM confined
  to server, Java 8 compatible graph/proto/contrib, Jackson 3 application JSON, springdoc,
  updated Java 21 build/runtime images and CI.
- data-processor `a70c004a545b1797a650cac3343ece95ce612fe0`: declare the Flink module's Lombok
  processor explicitly; build rec-proto in CI with Java 21, then run processor tests on Java 8.
  The server parent formatter requires Java 17 or newer even when building Java 8 bytecode.
  No streaming runtime, feature formula, or checkpoint changes.
- example: declare init's Lombok processor, select Java 21 for the server build and Java 8 for
  consumers, provision both JDKs in CI, and add isolated HTTP acceptance.

The component commits and this distribution commit are local until published. Publish companion
components first, then the distribution; the manifest retains immutable refs. HTTP/Kafka contract
versions stay at 1. Java 8 consumers need the accompanying direct Lombok dependency declarations
because rec-proto no longer exports its annotation processor as a runtime dependency.

## Validation results

Builds used isolated source copies and a disposable Maven repository because the workspace's
existing generated directories/cache contain files not writable by the current user. No generated
runtime copies were hand-edited. Local build JDK: Temurin 21.0.12.1; image runtime: Temurin 21.0.11.

| Check | Result |
| --- | --- |
| Java 8 baseline `mvn clean test` in rec-server | 131 discovered, 129 passed, 2 existing external-service tests skipped |
| Java 21 `mvn clean install` in rec-server | 138 discovered, 136 passed, same 2 skipped |
| Shared library tests forked under Java 8 | 38 passed |
| Public API comparison using `javap -public` | 59 top-level classes unchanged across proto/graph/contrib |
| Shared artifact class versions | All 71 classes use major 52 (Java 8); server classes use major 65 (Java 21) |
| Java 8 SDK `mvn clean install` | 6 tests passed |
| Java 8 init `mvn clean verify` | 3 tests passed |
| Java 8 web `mvn clean verify` | Passed; this module has no Java tests |
| Java 8 data-processor `mvn clean verify` | 26 tests passed, including Flink state and Spark micro-batch tests; both engines packaged |
| Distribution script tests | 9 passed; Java selection and Maven retry handling |
| Distribution manifest, SDK and rank feature contract checks | Passed |
| Changed shell scripts and workflow YAML | Parsed successfully |
| Canonical rec-server Dockerfile build | Passed; candidate started with Java 21 and Boot 4.1.1 |
| Real standalone HTTP acceptance | Health, OpenAPI, metrics, graph authorization, entity CRUD, event insert/delete, nonempty recommendation passed |
| Real cluster Kafka acceptance | Item/user INSERT→DELETE and event INSERT→UPDATE preserve keys, envelope v1, payload and ordering |

Both Boot profiles also have automated context/HTTP tests with mocked external stores. Live image
acceptance used disposable Redis and dedicated Kafka topics alongside the existing Elasticsearch
8.5 service (read-only cluster-info call). PF4J loaded and started the contrib plugin successfully.
The existing cluster intentionally continues rejecting event DELETE; its behavior was preserved.

The full `example_standalone/start.sh` / `example_cluster/start.sh` acceptance flows were not run:
they switch deployment modes and mutate shared fixture/platform state. Isolated image acceptance
was used alongside producer/consumer tests. This phase does not claim a full offline training/model
release regression or a controlled production-load performance comparison.

## Reproduce

Set `OPENREC_JAVA21_HOME` and `OPENREC_JAVA8_HOME` to installed JDKs. Run Java commands in their
owning repository; use an isolated Maven repository for migration verification.

```bash
# rec-server, with JAVA_HOME pointing to JDK 21
mvn clean install
mvn -pl graph,proto,contrib test -Djvm="$OPENREC_JAVA8_HOME/bin/java"

# sdk/java-client, with JAVA_HOME pointing to JDK 8
mvn clean install
# example/init, example/web, and data-processor, each with JDK 8
mvn clean verify

# example
python3 -m unittest discover -s scripts/tests -v
python3 scripts/validate_distribution.py
python3 scripts/verify_sdk_feature_contract.py
python3 scripts/verify_rank_feature_contract.py
```

For HTTP acceptance, point the following command at a standalone candidate using disposable Redis
and the Redis recall store. It writes unique test entities, checks recommendation output, then
deletes those entities and event members:

```bash
python3 scripts/verify_java_server_upgrade.py \
  --url http://127.0.0.1:23579 --token "$SERVING_GRAPH_TOKEN"
```

## Local images and rollout

The validated image is `openrec/rec-server:latest` / `openrec/rec-server:jdk21`, image ID
`0813fbd6838698d3ad69c5475f8ffd6132f0c4524ac8d69b5b3f8f7b3e7e66c0`.
The previous image is retained as `openrec/rec-server:pre-jdk21-20261004`, image ID
`71b4c9c7c94e13acfb4956033f7402ca52da37ad36e9763362e7546719c857d7`.

The running cluster rec-server was recreated on 2026-10-04 with the validated image:

```bash
docker compose -p openrec-cluster-apps -f example_cluster/docker-compose.yml \
  up -d --no-deps --no-build --force-recreate --wait --wait-timeout 180 rec-server
```

The container reports Temurin 21.0.11 and is healthy. Health, OpenAPI and JVM metrics passed;
item/user serving graphs match the saved pre-restart graphs. Other running container IDs remained
unchanged. The first three recommendation probes returned HTTP 500 due to recall/rank node timeouts
during warm-up. The following 13 consecutive requests succeeded with 10 results each; all graph
nodes, including rank, succeeded in the final 10 requests. This is a rollout smoke check, not a
load test. The health endpoint alone does not establish that recommendation dependencies are warm.

To roll back, retag the saved image as `openrec/rec-server:latest` and recreate only rec-server
with `--no-deps --no-build`. Keep the matching source/config revisions. Do not delete platform
volumes or streaming state; this phase does not migrate them.
