# Java 21: streaming processors, shared engine images and web

This phase follows the rec-server migration. It upgrades application build/runtime requirements,
not every independent storage daemon's JVM. The release manifest pins all companion repositories.

| Component | Previous | New |
| --- | --- | --- |
| data-processor | Java 8 bytecode | Java 21 bytecode |
| Spark driver/executors and algorithm runner | 3.5.3 / Scala 2.12 | 4.0.4 / Scala 2.13 / Java 21 |
| Flink JobManager/TaskManagers | 1.14.6 / Java 8 | 2.2.1 / Java 21 |
| Flink Kafka connector | bundled 1.14.6 | 5.0.0-2.2 |
| Engine Hadoop clients | mixed Hadoop 2/3 | shaded Hadoop 3.4.1 clients |
| Spark Kafka client | 3.4.1 | 3.9.1 |
| example/web | Boot 2.3.1 / Java 8 | Boot 4.1.1 / Java 21 |
| SDK | Java 8, Gson internal APIs | Java 8, Gson 2.13.2 public APIs |

Kafka broker 3.7.1, Hadoop server 3.3.6, Hive 4.0.1, HBase 2.5.10 and ZooKeeper 3.9.2 remain
independent services at their existing versions/JVMs. Real integration checks below establish the
paths used here; this is not a claim that those server versions run on Java 21. Do not replace the
platform-wide `JRE_BASE_IMAGE` with Java 21: it also controls unrelated daemons.

Spark [supports Java 17/21](https://spark.apache.org/docs/4.0.4/).
Flink's [Java compatibility documentation](https://nightlies.apache.org/flink/flink-docs-release-2.2/docs/deployment/java_compatibility/)
still labels Java 21 support experimental. Its [Kafka connector compatibility](https://flink.apache.org/downloads/)
includes Flink 2.2 for connector 5.0.0. Flink 1.x to 2.x state compatibility is
[not guaranteed](https://flink.apache.org/2025/03/24/apache-flink-2.0.0-a-new-era-of-real-time-data-processing/).

## Source and deployment changes

- Maven builds, CI and example launchers select Java 21 for data-processor/web. SDK and init
  retain Java 8. The shared rec-server graph/proto/contrib artifacts retain Java 8 compatibility.
- Flink uses the current lifecycle API and relocated legacy sink interface. Feature formulas,
  mutation envelopes, Redis keys, HBase rows and UTC Hive partitions are unchanged.
- HBase's transitive Hadoop 2 jars are excluded. Both processors use the matching engine's
  Hadoop 3.4.1 client; shaded application jars merge service descriptors and omit signatures.
- The Flink image merges configuration into the upstream `config.yaml`, preserving required JVM
  module arguments. Its RocksDB backend comes from the distribution, without old 1.14 JNI jars.
- Spark image/connector versions and rec-algorithm's image, PySpark extra and CI JDK move together.
- web uses Jackson 3, `spring.data.redis.*` and `spring.web.resources.*`. The Java SDK no longer
  calls removed Gson internals. URLs, response fields and default port 12345 remain unchanged.
- Both processor entry points accept an optional first argument naming an external properties
  file. Values override bundled defaults, so validation can use isolated stores without editing jars.

## Validation (2026-10-04)

- JDK 21 `mvn clean verify`: 26 processor tests passed, including a real Spark micro-batch and
  Flink snapshot/restore with stale-event retraction; both shaded jars built.
- web `mvn clean verify`: two Boot HTTP/Redis JSON compatibility tests passed. Real web against the
  existing rec-server/Redis returned resolved cards from recommendation, hot and new tabs; config
  and experiment discovery passed. Tests used viewport mode to avoid writing exposures.
- SDK on Java 8: six tests and `clean install` passed with the updated Gson dependency.
  Java 8 init: three tests and `clean verify` passed.
- Both platform images built. Spark reports 4.0.4 / Java 21.0.12.1; Flink reports 2.2.1 / Java 21.0.11.
- Flink consumed dedicated Kafka topics and wrote user/item records and features to disposable Redis;
  checkpoints completed and a canonical savepoint was written to a dedicated HDFS directory.
  Flink 2 restored that savepoint and continued completing checkpoints without failures.
- Spark 4 consumed the same isolated mutation contract, wrote raw entities/features to dedicated HDFS
  paths, and wrote all three entity kinds into HBase tables with a dedicated test prefix.
- Spark 4 read existing Hive 4 metastore database/table listings and its HDFS test output.
- The rebuilt `openrec/rec-algorithm:jdk21` candidate imports the runner on Java 21; its separate
  PyTorch 2.8 training environment remains available. The build used the existing project local-mode
  training base after Docker Hub timed out. Another 28 feature/runner/publisher tests passed.
- rec-algorithm's `test/jobs/spark/smoke_recall.py` passed in the new Spark image, including local
  formula parity and an isolated embedded Hive warehouse.
- Spark 3.5.3 generated fresh isolated raw/JSON-feature checkpoints. Spark 4.0.4 resumed all four
  queries at their committed Kafka offsets. Replaying the old event and inserting one new event
  produced user/item event counts of 2, preserving state and deduplication; deleting the new event
  retracted both counts to 1.
- Distribution Java-selection/retry tests (9), workflow YAML, shell syntax, feature catalog and
  SDK/rank contract checks passed.

These checks used temporary containers, Kafka topics, HBase tables and HDFS paths. The existing
streaming jobs and their checkpoint/savepoint directories were not upgraded or reset. No full
training/model-release regression or production-load benchmark is claimed.

## Existing installation rollout

1. Publish SDK, data-processor, bigdata-platform and rec-algorithm companion commits before the
   example manifest. Install both JDKs and set `OPENREC_JAVA21_HOME` / `OPENREC_JAVA8_HOME` for scripts.
2. Build the new platform images and rebuild rec-algorithm from `openrec/spark:4.0.4`. All Spark
   drivers/workers/runners must use matching Spark and Scala versions. Do not submit the new jar
   to the old cluster or attach the old algorithm runner to the new master.
3. Stop scheduled Spark submissions and drain existing jobs. Stop the old streaming application
   cleanly; record Kafka offsets and copy **all four** checkpoint directories to a backup. Retain
   the old images, jars, HDFS history and platform configuration.
4. Test a copy of the actual installation's checkpoint with isolated sinks before cutover. The
   synthetic 3.5.3 to 4.0.4 recovery above is evidence for this topology, not a guarantee for every
   historical checkpoint. Preserve shuffle partition count and state partitioning. Never have old
   and new jobs concurrently own a checkpoint or write the same serving/history state.
5. Recreate only Spark master/workers/history and the algorithm runner with the matched new images,
   then submit the Java 21 processor. Verify resumed offsets, mutation ordering/tombstones, feature
   counts, raw HDFS partitions, HBase records and offline Hive queries before resuming schedules.
6. Flink is an alternative processor. Stop at a savepoint and retain it, but do not assume a direct
   1.14 to 2.2 restore. Prove restore on a copy or rebuild state from complete mutation history with
   an explicit Kafka offset boundary. If history is incomplete, keep the old job until a lossless
   migration exists. Do not use `--allowNonRestoredState` to hide incompatible state.
7. Restart web with the new jar using `$OPENREC_JAVA21_HOME/bin/java`; migrate any local Redis/cache
   property overrides to the names above. Check `/api/config`, the static page and all tabs.

Rollback restores old engine images/jars/config **and the pre-upgrade checkpoint backup**. Do not
assume Spark 3 or Flink 1 can read state written by the upgraded engine. Never remove platform
volumes, silently start from empty checkpoints, or reset Kafka offsets as routine cleanup.
