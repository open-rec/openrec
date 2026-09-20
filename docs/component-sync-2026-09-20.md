# SDK、分发与 LightGBM 运行环境同步验收

日期：2026-09-20。范围为用户指定的五项同步修复；没有处理审查报告中的其他特征计算问题。

## 首轮代码变更（后续基础镜像修复见文末）

- Python SDK 增加 `Item.subcategory`、`Event.event_id`，JSON 使用 `eventId`。
  新字段放在 dataclass 末尾，保留现有位置参数含义；未提供 event_id 时仍省略该 JSON 字段。
- Go SDK 增加 `Item.Subcategory`、`Event.EventID`，对应 JSON 字段为 subcategory/eventId。
- example 的 rec-algorithm ref 更新为 `9003733844c4ea84e2024bea8e5631e2ec3bb084`。
- 模型验收从特征网关返回的 catalog.json 获取目录版本和 SHA-256，不再硬编码 v2。
  离线检查直接执行验收脚本中的断言，验证当前目录可通过、错误版本或哈希被拒绝。
- rank Docker 安装 requirements.txt 中的 torch 2.10.0，移除基础镜像中绑定旧 torch 的
  未使用 torchvision/torchaudio；构建执行 pip check 和 torch/LightGBM 导入检查。
- 新增 SDK 与 Java rec-proto 的 Item/Event 字段一致性检查，并接入 example Quality workflow。

## 实际部署

重建并更新现有 `openrec-cluster-apps` 项目中的两个服务，复用原模型卷和活动记录：

| 服务 | 实测状态 | 实测能力 |
| --- | --- | --- |
| rec-algorithm-runner | healthy | LightGBM 4.7.0；网关包含 lr/fm/lightgbm；目录 v14 |
| rank-engine | healthy | torch 2.10.0+cu128；LightGBM 4.7.0；注册 lr/fm/lightgbm；item/user 均 ready |

新镜像：

- rec-algorithm：`sha256:196cb572e67ecb0832e2295a5d4a5a540fc7807fe04f7fa83f04e30e273e6564`
- rank-engine：`sha256:ae29ee7bbb3ee7bbe4788482dff8099320fb142cfa42c88bd9c067cfb6960dd6`

构建遇到 Docker Hub 超时和包镜像下载缓慢，因此本机使用升级前 rank 镜像作为缓存起点。
rank 最终仍由 requirements.txt 安装并校验 torch 2.10.0。CUDA wheel 复用本机缓存；缺少的
Python 3.11 wheel 下载后按 PyPI SHA-256 校验，经临时 localhost wheel 服务离线安装。
临时 wheel 服务已停止。默认 Dockerfile 和 Compose 仍可从官方基础镜像正常构建。

保留回退镜像标签 `openrec/rank-engine:pre-sync-20260920` 和
`openrec/rec-algorithm:pre-sync-20260920`，未删除原镜像或模型卷。

## 验证

- SDK Python：`PYTHONPATH=python-client python -m unittest discover -s python-client/tests -v`，5 项通过。
- SDK Go：`go test ./...` 通过，包含 subcategory/eventId 编解码与旧事件省略字段检查。
- example：`python3 scripts/verify_sdk_feature_contract.py` 通过。
- example：`python3 scripts/verify_rank_feature_contract.py` 通过，包括目录版本/哈希负例。
- example：`python3 scripts/validate_distribution.py` 和 `bash -n example_cluster/verify_rank_model.sh` 通过。
- 新 rank 镜像：实际镜像代码和依赖下运行完整 `test/`，44 项通过；未连接外部服务。
- 新算法容器：合成 LightGBM fit/save/load/score 通过，重载分数一致；临时产物清理完成。
- 新 rank 容器：pip check 通过；独立进程使用真实 Redis 特征及默认 item/user LightGBM
  产物加载、评分通过。加载使用 persist=False，不改变在线服务的活动模型。
- 在线活动 item 模型仍为 `/bootstrap-models/rank/item/lr.pth`；
  `/models/active/item.json` SHA-256 升级前后均为
  `56fb11918f0eac91056d79fbf1dafc833238ac15699e1a04ff2eb4240c99a081`。
- 对 user_247 和 item_0/item_1/item_2 的前后在线抽样评分，最大绝对差为
  `7.748603820800781e-07`。前后请求时间与特征刷新时间不同，不是固定输入逐位一致性测试；
  最初使用的更严格比较阈值未通过，此处保留实际差异，不声称评分逐位相同。

此次没有执行完整的 Spark 训练→控制台发布→回滚集群验收，也没有将在线模型切换为 LightGBM。
运行时检查仍观察到 24 个不兼容目录的历史特征快照被现有逻辑跳过；本次未清理 Redis 数据。

日志保存在本机 `/tmp/openrec-sync-*-20260920.log`；升级前后抽样评分保存在
`/tmp/openrec-sync-score-before-20260920.json` 和 `/tmp/openrec-sync-score-after-20260920.json`。
后续已提交并推送 SDK、rank 和算法兼容文档，分发引用已同步固定到对应提交；cluster 启动由用户确认正常。


## Rank base-image follow-up

Rank Dockerfile, Compose, and cluster `--local` now default to
`pytorch/pytorch:2.10.0-cuda12.8-cudnn9-runtime`. The image supplies Torch; the
build checks Torch 2.10.0 / CUDA 12.8 before installing only application requirements.
The new base uses Ubuntu system Python 3.12, so container pip installation explicitly
sets `PIP_BREAK_SYSTEM_PACKAGES=1`.

Offline training retains its existing PyTorch 2.8 base: its Spark assembly copies
`/opt/conda`, which does not exist in the new serving base. The local startup script
therefore no longer inherits the training base from `RANK_BASE_IMAGE`.

Validation: the requested base was pulled through the DaoCloud mirror after Docker
Hub timed out and the previous Aliyun endpoint returned 404. Its manifest digest is
`sha256:b85566342b86d13a67712e9315d40cdc2dad7f8d86df1aff3831f80835edbcca`.
An actual rank build with the Tsinghua pip index passed `pip check`; its full log
contains no Torch, Triton, or NVIDIA wheel downloads. All 18 retained packages in
those groups have exactly the same versions as the base image. The final runtime
is Torch 2.10.0+cu128, CUDA 12.8, LightGBM 4.7.0. The image's complete rank test suite
passed: 44 tests, with two existing FastAPI lifespan deprecation warnings.

Both cluster and standalone Compose configurations parse successfully; distribution
manifest, rank feature contract, and shell syntax checks passed. Local evidence:
`/tmp/openrec-rank-cu128-build.log`, `/tmp/openrec-rank-cu128-tests.log`, and
`/tmp/openrec-cu128-{base,final}-packages.txt`. No live containers were restarted and
no active model records were changed. The user subsequently confirmed cluster startup works. Component changes were
committed and pushed before the final example commit; `release/openrec.json` pins
the companion rank-engine, rec-algorithm, and SDK commits.
