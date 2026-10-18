# OpenRec 0.2.0 component releases

The seven runtime/source-build dependencies are fixed by `openrec.json`. The model
repository is a companion bootstrap bundle and is not automatically checked out.
Fresh installations can generate CPU bootstrap artifacts from the committed fixture.

| Repository | Tag | Commit |
|---|---|---|
| [rec-server](https://github.com/open-rec/rec-server/releases/tag/v0.2.0) | `v0.2.0` | `2f4e39ff304efd4eec3e27ec3acc5c281da2aa7a` |
| [rec-algorithm](https://github.com/open-rec/rec-algorithm/releases/tag/v0.2.0) | `v0.2.0` | `8cd58b8491470027a5e24ed1e4dd7cfd99d569fb` |
| [rank-engine](https://github.com/open-rec/rank-engine/releases/tag/v0.2.0) | `v0.2.0` | `d43b07580bb4cbcd45ae8e325d5c125895262ebd` |
| [data-processor](https://github.com/open-rec/data-processor/releases/tag/v0.2.0) | `v0.2.0` | `027384d729f70277f3dec8b9e5951c51dba6c759` |
| [rec-console](https://github.com/open-rec/rec-console/releases/tag/v0.2.0) | `v0.2.0` | `d6298e67b9c690a872b6c2605cb9d9100eecec9d` |
| [sdk](https://github.com/open-rec/sdk/releases/tag/v0.2.0) | `v0.2.0` | `2571a2f789799c02fc0fbeab2dd38503d78fcec8` |
| [bigdata-platform](https://github.com/open-rec/bigdata-platform/releases/tag/v0.2.0) | `v0.2.0` | `bfc4a45002f39e125e0f60342a9ab7cc4eef54ed` |
| [model](https://github.com/open-rec/model/releases/tag/v0.2.0) | `v0.2.0` | `d8cf7b89475d6e75f6c2c61a54ab213b799df34e` |

The distribution is published as [open-rec/openrec@v0.2.0](https://github.com/open-rec/openrec/releases/tag/v0.2.0).
All nine product repositories have a `release/0.2.0` maintenance branch. The SDK also
provides `go-client/v0.2.0` for Go module resolution. Experiments are independently
versioned and are outside this product release.

Use these commits together. See the [release notes](../RELEASE_NOTES.md) for bootstrap
build 19, persisted graph/DAG migrations, optional embeddings and rollback guidance.
Recommendation API, mutation envelope and feature catalog versions are independent
of package release numbers; their declared contracts are unchanged by release packaging.
