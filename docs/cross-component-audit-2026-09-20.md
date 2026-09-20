# OpenRec 跨子项目一致性审查（2026-09-20）

后续状态：用户指定的 SDK 字段、算法固定版本、目录断言、容器 LightGBM 支持及
rank PyTorch 升级已完成本地修复和相关部署验证，见
[同步验收记录](component-sync-2026-09-20.md)。下文保留修复前的审查证据；未纳入此次范围的
问题（包括完整 LightGBM 集群生命周期验收）仍待处理。

## 范围与结论

本次检查工作区源码、分发清单、现有模型产物和两个运行容器，重点覆盖 EB-NeRD
实验新增的上下文/交互特征、短窗口行为特征和 LightGBM。没有修改业务代码、模型、
分发版本或部署，也没有执行会停止在线服务的集群验收脚本。

结论：LightGBM 的产品二分类路径在源码中已接通，但存在明确的跨实现正确性问题，
以及分发、验收和运行实例落后。实验 LambdaRank/扩展特征产物不能直接视为线上可发布产物。

P1 表示会阻断有效训练/使用，或改变特征及标签值；P2 表示契约、SDK、分发和验证缺口。
这些优先级是本次审查的修复建议，并非对生产事故的认定。

## 已确认的问题

### F01 / P1：新增短窗口特征未进入 Spark 训练样本

- 位置：`rec-algorithm/jobs/spark/point_in_time.py:7,34,61`；
  `rec-algorithm/algorithm/rank/training.py:207`。
- 目录、Python 聚合和 Java feature-core 已支持 5m/1h/24h 曝光计数和 value sum，
  Spark PIT 仍固定生成旧的 1/7/30 天计数与累计动作统计。
- 隔离 Spark 实测：用户侧缺少 `event_expose_count_{5m,1h,24h}` 与
  `event_value_sum_{5m,1h,24h}` 六列；物品侧复用同一 `_behavior` 实现，也缺这六列。
- 这些特征进入了 LR/FM/LightGBM 默认支持列表；选择它们时，训练器的实际物化检查
  会拒绝缺列样本。只选择 age/weight 等旧字段的验收不能覆盖这个问题。
- 建议：让 Spark 按目录解析窗口、过滤条件、聚合算子；逐列对照 Python 与 Java 的结果。

### F02 / P1：在线刷新不能让新增短窗口随时间过期

- 位置：`rank-engine/service/feature_service.py:260`；
  `data-processor/feature-core/src/main/java/com/openrec/dp/feature/FeatureSnapshot.java`。
- 在线只重算 recency 和匹配 `event_count_*d` 的窗口。Redis 快照的
  `recentEventTimeCounts` 只有事件数，不能重建按动作过滤的曝光计数和 value sum。
- 复现：t=100 的一次 expose/value=5，到 t=1000 时，离线 5m 计数和 sum 均为 0，
  rank 刷新后仍分别为 1、5。旧的 1d 计数双方均为 1。
- 实时适配器在事件到达时输出快照，没有在这里看到用于这些窗口衰减的定时输出。
- 建议：同步扩展窗口物化/快照契约及刷新逻辑；单纯调低刷新间隔不能修复。

### F03 / P1：pandas 版本不同导致日期字符串特征值不同

- 位置：`rec-algorithm/algorithm/feature/content_feature.py:7`。
- `_epoch_seconds` 假定 `pd.to_datetime(...).astype('int64')` 总是纳秒，再除以 1e9。
- 同一 ISO 发布时间 `2026-09-19T00:00:00Z`、as_of 为次日零点：
  本机 pandas 3.0.5 算出 `content_age_hours=496686.84`；离线容器 pandas 2.3.3 算出 24。
  秒/毫秒数字字符串在本机样例中正常。
- 算法 requirements/实验环境使用 pandas 3，产品训练与 rank requirements 使用 pandas 2，
  因此这是实际可触发的跨环境差异；本次没有据此认定既有 EB-NeRD 数字时间戳结果无效。
- 建议：明确转换单位，并覆盖日期字符串、秒、毫秒、缺失和非法值的跨版本测试。

### F04 / P1：曝光点击归因只使用 trace_id，误删其他候选负例

- 位置：`rec-algorithm/algorithm/rank/lr.py:87`。
- 同一个推荐 trace 中 A/B 都曝光、只点击 A，实际数据集最后只保留 A 的 click，B 的
  expose 也被删除。当前代码使用 `identity = ['trace_id']`。
- 这影响使用 EventDataSet 的产品 LR/FM/LightGBM 训练；实验直接使用已准备标签的路径
  不等于验证了这里的归因。
- 建议：定义候选级曝光身份，结合 user/item/scene 和归因窗口，避免请求级 trace 被当作
  单个候选的曝光身份。

### F05 / P1：Spark 与 Python 的 mutation 解析顺序不同

- 位置：`rec-algorithm/jobs/spark/point_in_time.py:34`；
  对照 `rec-algorithm/algorithm/feature/point_in_time.py:103`。
- Python 先选标签时刻可见的最新 mutation，再判断事件业务时间；Spark 在 join 时先过滤
  `event.time < label.time`，然后才选最新 mutation。
- 隔离 Spark 复现：事件原业务时间 50、mutation 时间 60；在 mutation 时间 80 更新为
  业务时间 150。标签时间 100 时应排除该事件，实际 Spark 仍累计旧记录，event_count=1。
- 建议：先按可见 mutation 确定事件状态，再做行为时间过滤；补更新业务时间的 parity 样例。

### F06 / P1：Spark 样本 fallback ID 缺少 scene，发生碰撞和行扩增

- 位置：`rec-algorithm/jobs/spark/point_in_time.py:91`。
- 行为事件 fallback 身份包含 scene，标签 `_sample_id` 的 fallback 却不包含 scene。
- 隔离 Spark 复现：无 eventId、user/item/type/time/trace 相同但 scene 不同的两条标签，
  得到同一个 sample ID，并在后续 join 中扩成四行。训练器之后会拒绝重复身份。
- 建议：统一使用完整的事件身份定义，并覆盖 global 多场景样本。

### F07 / P2：Python/Go SDK 未同步 Java 协议字段

- 位置：`sdk/python-client/openrec/models.py:43,74`；`sdk/go-client/types.go:74,103`。
- Java Item 已有 `subcategory`，Event 已有 `eventId`；Python/Go 强类型模型均缺少这两个字段。
- 通过这些模型接入，无法自然传递新内容特征或稳定事件身份；手工 JSON 绕行不等于 SDK 支持。
- Java SDK 直接依赖 rec-proto，没有同样的重复类型遗漏，但仍需使用新 proto 构建。
- 建议：同步序列化字段，并为各语言增加同一协议样例的契约检查。

### F08 / P2：分发清单未包含最新 Spark 发布时间兼容修复

- 位置：`example/release/openrec.json:24`；`experiments/.github/workflows/ci.yml:25`。
- example 固定 rec-algorithm `14ed024302fee14c115796beb00abc8bac7b4019`，
  工作区和 experiments CI 使用 `9003733844c4ea84e2024bea8e5631e2ec3bb084`。
- 后者修复缺少 pub_time 列时 Spark 表达式解析失败。按分发清单 checkout 的用户仍取不到它；
  对原始 JSON reader 总是提供该列的路径，未据此断言所有训练都会失败。
- SDK 仍使用浮动 `main`，开发分发允许它，但不可据此保证不可变发布的可复现性。
- 建议：纳入兼容提交，并在正式发布时固定 SDK；避免仅通过本地 `--local` 验证。

### F09 / P2：集群验收仍绑定旧目录和旧模型集合

- 位置：`example/example_cluster/verify_rank_model.sh:160`。
- 当前目录 v14，脚本仍断言 `catalog_version == 2`，新版本正确产物也会被判失败。
- 脚本实际训练/发布/回滚仍覆盖 LR/FM，没有完整执行 LightGBM 生命周期。
- `verify_rank_feature_contract.py` 已覆盖三类模型，但主要验证 DAG/runner 参数传递，
  不会发现 LightGBM 缺包、真实 Spark 窗口缺列或线上加载问题。
- 建议：从当前目录读取期望版本，增加 LightGBM 实际训练、发布、评分、回滚、恢复验收。

### F10 / P1（部署状态）：正在运行的实例尚未同步 LightGBM

- 只读核对时，`rec-algorithm-runner` 的 `/opt/conda/bin/python` 无 lightgbm 包，
  容器中的 runner 源码无 lightgbm 支持。
- `rank-engine` 容器也无 lightgbm 包，容器 `model.py` 只注册 lr/fm。
- 两者目录都已读到 v14，说明目录版本一致不能证明运行代码和依赖已同步。
- 当前工作区 requirements、runner、rank model map 都已加入 LightGBM，属于源码与部署状态差异。
- 建议：代码问题修复并完成测试后，协调重建/部署算法、rank、console；增加模型能力探针。
  本次未重启、升级或修改这些容器。

### F11 / P2：rank Docker 实际 PyTorch 版本与直接安装、文档不同

- 位置：`rank-engine/Dockerfile:1,13`、`rank-engine/requirements.txt:2`、`rank-engine/README.md:69`。
- Docker 以 PyTorch 2.8 镜像为基础，仅安装 requirements-common；直接安装 requirements.txt
  使用 torch 2.10。README 却声称 Docker 也安装 requirements.txt、最终为 2.10。
- 运行容器实测 torch 2.8.0+cu129；离线训练基础镜像也使用 2.8。
- 未发现足以认定当前权重不兼容的证据，但 CI、实验和部署不是文档所说的同一环境。
- 建议：明确支持矩阵及真实镜像版本；要统一时同步测试训练和推理，而非只改徽标。

## 必须区分的实验/产品能力边界

### B01：实验扩展特征未成为完整的在线可重放产物

- 目录共有 172 个逻辑特征，60 个声明 online/offline，112 个声明 offline-only。
  后者被产品 select_features 拒绝，当前属于明确能力边界，不应全部算成实现遗漏。
- experiments 在基础 FeatureSpace 编码后拼接上下文、交互、会话等列；随后保存的
  `*.features.json` 仍只描述基础空间。
- 实际检查两个已存在运行目录：
  `ebnerd-192-shared-lr-seed42` 和
  `ebnerd-stage14-past-engagement-pruned-rerun-lightgbm-seed42` 的 manifest 记录输入维度 192，
  sidecar 的 input_dim 都是 78。扩展列名称等有记录，但完整拟合变换并未全部进入该 sidecar。
- 当前在线维度校验能拒绝这种直接加载，属于有效防护。不能把这些文件直接发布到 rank-engine；
  也不能把实验效果解释为产品当前已上线效果。
- 下一步应定义独立的实验 bundle/serveable release 类型，持久化全部变换、输入上下文、
  历史状态依赖与特征顺序，并验证重载后的评分一致性。

### B02：EB-NeRD 使用 LambdaRank，产品 LightGBM 使用 binary

- 位置：`experiments/openrec_experiments/runner.py:891`；
  `rec-algorithm/algorithm/rank/training.py:258`；`rank-engine/model.py:8`。
- 实验按 group 训练 LambdaRank；产品训练与推理注册的是 LightGBMBinaryModel。
- rank loader 仅检查特征维度，未检查 Booster objective。用仅含产品特征的 LambdaRank
  权重进入该 loader，有可能通过维度检查但分数语义不同。
- 合成复现：排名 wrapper 返回约 0.547/0.453；同一权重经 binary loader 返回
  0.188/-0.188（原始 margin）。顺序相同不代表与召回分数融合后行为相同。
- 现有 192 维实验 bundle 首先会被维度检查拦住，不应误称它已能直接加载。
- 建议：产物显式声明 objective、score semantics 和后处理；不支持的 objective 应明确拒绝。

## 已对齐的部分与各仓库覆盖情况

| 子项目 | 本次核查结果 |
| --- | --- |
| model | 目录及副本检查通过；6 个已提交 item/user 模型 sidecar 能由当前 FeatureSpace 加载；默认 bundle hash 检查通过 |
| rec-algorithm | 三模型选择/训练接口已接通；PIT 窗口、mutation、身份、日期和标签问题见 F01/F03–F06 |
| data-processor | Java 目录和 golden fixture 已同步；新窗口聚合已有实现；本次未重跑全部 Maven/Flink 引擎测试 |
| rank-engine | 当前源码 LightGBM 加载评分单测通过；短窗口刷新和运行实例落后见 F02/F10 |
| rec-console | UI/API 已列入 LightGBM；产品可选集排除 offline-only 特征；训练参数通过 runner 契约检查 |
| rec-server | Item 新字段已加入 proto；rank RPC 仍传用户/候选身份，缺少实验上下文物化路径；未重新运行全部 Java 测试 |
| sdk | Java 使用共享 proto；Python/Go 重复类型未同步，见 F07 |
| experiments | CI 已固定最新算法修复；扩展特征和 LambdaRank 边界见 B01/B02；未重跑 EB-NeRD 全量实验 |
| example | 分发结构和参数传递检查通过，仍有 F08/F09；默认模型 bootstrap 校验已包含 LightGBM |
| bigdata-platform | 未发现本次新增模型要求的新端口/服务依赖；算法使用独立离线解释器，不要求 Spark executor 安装 PyTorch/LightGBM |

## 验证及环境限制

- `model`: `python3 feature/catalog/validate_catalog.py` 与
  `python3 feature/catalog/publish_catalog.py --check` 均通过，目录 v14。
- `example`: `python3 scripts/validate_distribution.py` 与
  `python3 scripts/verify_rank_feature_contract.py` 均通过。
- workspace: `PYTHONPATH=rec-algorithm python rec-algorithm/tool/check_default_artifacts.py
  --data example/data/test --model-root model` 通过。
- 使用 `/home/xsank.mz/miniforge3/envs/openrec/bin/python`，
  `PYTHONDONTWRITEBYTECODE=1` 和 `pytest -p no:cacheprovider`。
  缺少的 lightgbm 4.7.0/prometheus-client 0.23.1 仅安装到 `/tmp/openrec-audit-deps-20260920`，
  通过 PYTHONPATH 使用；不是对已部署依赖的更新。
- 算法：`test/algorithm/feature test/algorithm/rank/test_temporal_split.py
  test/algorithm/rank/test_training.py test/jobs/spark/test_runner.py` 共 62 项通过；
  本地临时 HTTP 端口测试单独在沙箱外运行，并绕过 localhost 代理。
  `test/algorithm/rank/test_lightgbm.py` 另有 3 项通过。
- rank：完整 test 中 40 项先通过、4 项因沙箱禁止 socket 无法执行；将对应
  `test/test_recovery_health.py` 整个文件在沙箱外重跑，14 项通过。
  去掉重跑重叠项，44 个独立测试全部通过。
- console：35 项通过；涉及 main 导入的检查因本机缺少 elasticsearch 包未完成。
- experiments：测试收集因本机缺少 pyarrow 未完成；检查了已有产物和代码，未重新验证效果指标。
- Spark：用现有镜像创建无外网、2 CPU/3GB、源码只读挂载的临时 local[2] 容器。
  `/tmp/openrec-audit-spark-20260920.py` 实际执行了 F01/F05/F06 样例。
  前两项复现成功；最后一项原先期望两条碰撞行，实际得到四条，因此诊断脚本最后的
  行数断言失败，直接暴露了额外的 join 扩增。该运行不是“完整 Spark 套件通过”。
- 原环境中三个 temporal_split 测试曾被 `model/rank/default/lr.features.json` 的旧指纹阻断；
  该目录未提交。设置隔离的 `OPENREC_MODEL_HOME=/tmp/openrec-audit-model-home-20260920`
  后通过。另一个 rec-algorithm/model 下旧 sidecar 也为本地未提交产物。
  这些归为本地缓存污染，不归为已提交默认 item/user 产物损坏；未删除或改写它们。
- data-processor 已有的 target/ 改动未处理。没有重建部署、切换模型或执行全量集群验收。

## 建议修复顺序

1. 先修 F01–F06，加入覆盖“原始事件→Spark 训练样本→持久化编码→rank 刷新”的共享用例。
2. 修 F07–F09/F11，固定兼容版本，补实际 LightGBM 生命周期验收。
3. 完成前两步后再处理 F10，重建部署并验证运行时模型能力、依赖和目录一致。
4. 单独规划 B01/B02 的实验到生产迁移；避免把新增 offline-only 特征直接标为 online-ready。
