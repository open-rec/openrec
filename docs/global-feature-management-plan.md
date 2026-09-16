# Global feature management implementation plan

## Scope and contract

The first release supports the existing LR/FM feature implementations. Feature
engineering, new data collection, backfills, and new model adapters remain manual
engineering work. The console must distinguish declared capability from observed
online availability; a registered feature alone is not proof of serving readiness.

Model management has three views: global feature catalog, offline training, and
online deployment. Training selects source-user and candidate feature IDs. The
ordered selection, selected definition fingerprints, fitted encoders, training
configuration, evaluation results, and weights form one immutable release.
Publishing never edits that selection. Training never automatically publishes.

## Implementation sequence

1. **Shared contracts (rec-algorithm).** Validate model-specific supported feature
   subsets; support independent source/candidate selections for item and user
   ranking. Persist selected definition fingerprints in FeatureSpace. New releases
   tolerate unrelated catalog additions while rejecting incompatible dependencies;
   legacy releases retain their existing validation behavior.
2. **Training pipeline (rec-console, example, rec-algorithm).** Pass
   the same selection through the console, Airflow, Spark runner and trainer.
   Validate at each trust boundary. Default new UI training to all scenes and
   separate manual publication from DAG completion. Retain legacy scene artifacts.
3. **Management UI (rec-console).** Expose the catalog and LR/FM capability lists,
   feature selection, training parameters and Airflow run states. Deployment shows
   immutable dependencies, evaluation results and the active global target model.
4. **Serving safety (rank-engine).** Check required feature columns before
   activation. Capture a consistent model/feature snapshot per scoring request;
   serialize feature refresh with publication so refresh cannot overwrite a newer
   model's encoding. Keep existing Redis producers and encoded-cache optimization.
5. **Validation and rollout.** Test subset round trips, item/user selection,
   incompatible definitions, training-only DAG behavior, online/offline score
   parity, publication and rollback. Build the frontend; run component tests and
   distribution checks. Rebuild the algorithm wheel, runner, rank and console
   images together and deploy the companion Airflow DAG.

## Acceptance

- LR/FM can train different nonempty supported feature subsets.
- Selection survives every hop and is visible on the retained model version.
- Training leaves the active model unchanged; publication is an explicit action.
- Rollback restores the original weights and encoding, without refitting.
- New unrelated catalog features do not invalidate new-format releases.
- Missing production capability is rejected; runtime data gaps are distinguishable
  from metadata declarations and do not silently authorize publication.
- Standalone keeps its existing feature availability; model management is cluster-only.

## Boundaries

This iteration does not introduce Feast, a separate feature-server deployment,
automatic feature engineering, distributed training isolation, or GPU tuning.
Physical storage remains Redis plus historical Hive/HDFS data. New global releases
use `global` as an artifact scope, not as a recommendation scene filter.


## API examples and rollout

Read capabilities with `GET /api/models/features`. Submit training with
`POST /api/models/training`, for example:

```json
{
  "business_date": "2026-09-15",
  "revision": "r001",
  "scene": "global",
  "model_type": "lr",
  "target_type": "item",
  "epochs": 5,
  "min_auc": 0.6,
  "feature_selection": {
    "user": ["user.age"],
    "candidate": ["item.weight"]
  }
}
```

The response contains the Airflow run ID; completion creates a retained version,
not an active model. Use `GET /api/models/releases/global?target_type=item` to
obtain its actual version, then `POST /api/models/releases/publish` with only
`scene`, `version` and `target_type`. Extra feature overrides are rejected.
`GET /api/models/runtime` reports rank-engine health even when it returns 503.

Deploy rec-algorithm, rank-engine, rec-console and bigdata-platform at the exact
companion commits recorded in `release/openrec.json`, together with this example
revision. The component changes were pushed before updating these references.
Redis and Kafka schemas are unchanged; data-processor and rec-server need no
companion edits.
Re-publish the intended retained version once to establish the console's global
per-target record; old per-scene records are not migrated automatically. Keep old
artifacts for rollback. New-format subsets require the new algorithm package;
rolling software back requires restoring a compatible old model as well.

Presence checks reject an entirely absent selected column. They do not measure
per-entity completeness, freshness SLAs or producer health; individual missing
values continue to use the fitted encoder's existing missing-value policy.


## Implementation and verification status

Steps 1–4 are implemented in the published companion commits. Step 5 component,
distribution and live local-cluster acceptance are complete. The release manifest
pins the four updated components to their compatible commits. Live acceptance explicitly published FM, rolled back to LR and
verified recovery after restart; see the local-cluster validation record.

Verified using the existing local application images and read-only source mounts:

- Rank-engine suite plus algorithm feature tests, Spark runner tests and temporal
  split tests: **90 passed**. Includes real LR/FM subset training for item/user
  targets, saved encoder score parity, missing-feature rejection and concurrent
  publication/refresh consistency.
- Complete rec-console suite: **39 passed**. The training orchestration tests were
  rerun after adding automatic unpause of the manual training DAG: **3 passed**.
- `cd rec-console/frontend && npm run build`: passed TypeScript and Vite build.
- `python example/scripts/verify_rank_feature_contract.py`: passed actual DAG
  task extraction and runner argument transport, without a live Spark service.
- `python example/scripts/validate_distribution.py`: passed existing manifest and
  documentation checks. Updated companion references are pinned to published
  commits.
- `bash -n example/example_cluster/verify_rank_model.sh`: passed. The script now
  checks training does not change the active version before explicit publication.
- `bash package.sh` in a temporary container copy: wheel built, including the
  Spark rank job, FeatureSpace and catalog JSON resources.
- Modified Python files: Ruff formatting and E/W checks with a 79-character line
  limit passed. Generated frontend build metadata was restored.

The live Hive/Spark/Kafka/Redis acceptance script passed on 2026-09-16 after
`start.sh --local`; see [local validation](local-cluster-feature-validation.md).
Browser-based interaction tests have not been run.

## Offline execution boundary correction

The previous implementation handed the final training step to rank-engine. This
is superseded by `rec-console → Airflow → rec-algorithm Spark job → offline
PyTorch trainer → immutable release`. Rank-engine only loads and scores releases.
Catalog discovery/validation move to the algorithm runner. LR/FM run on the
offline driver CPU after distributed Spark preparation; model parameters are not
trained distributively. Feature implementation remains an engineering task.

Deploy rec-algorithm, rec-console and rank-engine together at the companion
commits pinned in `release/openrec.json`. These component commits were pushed
before updating the distribution references.
The runner's `rank-artifact-init` prerequisite transfers ownership of releases
and training directories to the Spark user when upgrading older volumes. It
leaves online activation records unchanged. No bigdata-platform change is needed.

`verify_rank_model.sh` now stops rank-engine before feature discovery and LR/FM
training, verifies that training leaves publication unchanged, then starts
inference and verifies explicit publication, scores, rollback and recovery.
