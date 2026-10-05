# Single-JDK 21 build

All OpenRec Java source components now build and run with Java 21: rec-server (including
graph/proto/contrib), Java SDK, example/init, example/web and data-processor. Application classes
target class-file version 65 (`--release 21`). Consumers running on Java 8, 11 or 17 must upgrade
their JVM before using these artifacts.

## Build and CI

Install JDK 21 and Maven 3.9+, then set either `JAVA_HOME` or `OPENREC_JAVA21_HOME` to the JDK directory:

```bash
export OPENREC_JAVA21_HOME=/path/to/jdk-21
./scripts/build-components.sh
```

The shared Java helper selects the first JDK 21 with `bin/javac` from `OPENREC_JAVA21_HOME`,
Actions' `JAVA_HOME_21_X64`, `JAVA_HOME`, the resolved `javac` on `PATH`, then workspace
`.tools/jdk21`. It sets `JAVA_HOME`, `PATH` and the runtime `JAVA` command to that installation.
If no candidate is JDK 21, startup fails with `JDK 21 required; set OPENREC_JAVA21_HOME`.
`OPENREC_JAVA21_HOME` is interpreted by the distribution scripts; for direct `mvn`/`java` commands,
set `JAVA_HOME` and put its `bin` directory on `PATH` yourself. SDK, init, web and server builds no
longer switch JDKs. CI provisions only Java 21; there is no Java 8 shared-library test fork.

The SDK's independent protocol-source CI build also targets Java 21 and uses a compatible
Lombok processor. The distribution manifest pins the companion rec-server and SDK commits;
publish these before the distribution commit so fresh checkouts can resolve them.

The build, cluster and standalone scripts check workspace Maven cache permissions, including nested
artifacts. If it contains inaccessible paths, they use `.cache/maven-repository-<uid>` instead.
Set `OPENREC_MAVEN_REPO` to select another writable directory; an inaccessible explicit cache
fails early. Without a workspace cache or override, Maven retains its own default/settings.

## Compatibility and verification

The Java bytecode migration itself preserved HTTP payloads, Kafka envelopes and serving schemas.
It raises the minimum Java runtime for shared artifacts. Subsequent startup fixes add readiness
endpoints and debug `recallDiagnostics`; see [recommendation readiness](recommendation-readiness.md)
for the current response and acceptance contract.
Validate the producer and consumer chain with the rec-server tests, SDK tests, init/web tests,
the distribution build, and the script tests. Verify emitted OpenRec classes use major 65.

Validated locally on 2026-10-04 with JDK 21:

- `rec-server`: `mvn clean install` passed (139 tests passed, two existing tests skipped).
- `sdk/java-client`: `mvn clean install` passed (six tests); the independent CI protocol POM
  also passed `clean verify`. Spotless was upgraded to 3.10.3 for JDK 21 compatibility.
- `data-processor`: `mvn clean verify` passed (26 tests, including Flink state restore and
  Spark micro-batch processing).
- `example`: `./scripts/build-components.sh` passed the full server/SDK/init/web chain;
  init's three tests and web's two tests passed. All seven modules emitted major 65 classes.
- `python3 -m unittest discover -s scripts/tests -v` passed 11 tests; `./scripts/validate.sh`
  passed manifest/documentation and shell syntax checks (ShellCheck was unavailable).

These are historical results for the 2026-10-04 build-only change. Later standalone and cluster
startup regressions, including the previously failing CI UserCF scenario, are recorded in the
[readiness verification log](recommendation-readiness.md). Those local runs are not evidence of
a successful remote GitHub Actions run.

Older migration documents retain historical test results and the previous dual-JDK rollout.
Their Java 8 build instructions no longer apply to the current manifest. Rollback requires the
previous compatible component refs together, rather than mixing new Java 21 artifacts with an
older JVM.

Independent ZooKeeper, Kafka, HBase, Hadoop and Hive daemon JVMs are configured by
bigdata-platform and are outside this source-build change.
