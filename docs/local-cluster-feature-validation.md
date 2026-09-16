# 本地 cluster 全局特征验收记录

日期：2026-09-16。使用本地工作区源码，通过 `--local` 构建并启动，随后运行真实
Kafka、Spark、Hive、Redis、Airflow、rank-engine、rec-server 和 rec-console 链路。

## 执行方式

本机 Docker 共享存储容量很大，但剩余空间低于组件默认百分比水位。使用以下显式
配置保留 10 GB 空间保护；不适合作为所有机器的默认配置，也没有关闭磁盘检查。

```bash
YARN_DISK_MAX_UTILIZATION_PERCENTAGE=99.99 \
YARN_DISK_MIN_FREE_MB=10240 \
OPENREC_ES_DISK_LOW=20gb \
OPENREC_ES_DISK_HIGH=15gb \
OPENREC_ES_DISK_FLOOD=10gb \
bash example/example_cluster/start.sh --local

bash example/example_cluster/verify_rank_model.sh
```

启动流程完整成功：平台冒烟检查、应用容器健康检查、Kafka → data-processor → Redis
特征一致性检查、`openrec_cluster_bootstrap` DAG 和 Web Demo 启动均通过。
模型链路修复后分别重建了控制台、rank-engine 和算法 runner，再执行完整模型验收。

## 模型验收结果

验收数据覆盖 `scene_0` 和 `scene_1`，训练范围为 `global`，排序目标为 `item`。

| 模型 | 版本 | 源用户特征 | 候选物品特征 |
| --- | --- | --- | --- |
| LR | `20260916-r1153571` | `user.age` | `item.weight` |
| FM | `20260916-r1153572` | `user.age`, `user.gender` | `item.weight`, `item.category` |

- 从控制台训练 API 发起任务，Airflow 和 Spark 实际执行成功。
- 两次训练完成后，原在线发布记录未改变。
- 手动发布 LR，再发布 FM，检查版本、特征清单、编码维度、样本数和评估指标。
- rec-server 的真实推荐响应包含 FM 排序分数。
- 回滚到 LR 后健康检查通过；重启 rank-engine 后仍加载同一 LR 版本。
- 最终活动版本为 `20260916-r1153571`，cluster 保持运行。

Airflow runs：

- `manual__2026-09-16T11:54:09.549586+00:00`
- `manual__2026-09-16T11:54:45.502560+00:00`

本地日志：`/tmp/openrec-cluster-local-validation-clean.log`（启动成功）及
`/tmp/openrec-global-features-e2e-pass.log`（模型链路成功）。

## 验证过程中修复的问题

1. 启动脚本将平台已有 Airflow 的 8091 端口误判为业务端口冲突；已移除该预检查。
2. 共享磁盘触发 YARN 不健康和 Elasticsearch 索引只读；增加显式水位配置能力，
   保持默认百分比，新增 YARN 最低剩余 10240 MB 保护。
3. Redis 存在 15 条历史验收 v1 快照，与当前 v2 目录不兼容。仅备份并清理了明确
   属于旧 `rank_accept` / `parity` 样例的快照，没有绕过目录验证。
   备份为 `/tmp/openrec-stale-test-features.json`。
4. Airflow 3 触发接口要求 `logical_date`；客户端已补充 UTC 时间并增加回归测试。
5. Spark ZIP 分发无法用普通路径打开特征目录；改用包资源读取并增加 ZIP 回归测试。
6. Spark 默认文件系统为 HDFS，训练服务却从共享模型卷读取样本；改为通过 driver
   逐行导出到共享卷，避免全部收集到 driver 内存。
7. DAG 现在保留 runner 的实际 HTTP 错误详情；验收脚本提交失败后立即退出。

## 补充检查与范围

- 排序/算法回归：90 项通过；控制台回归：39 项通过。
- 分发契约和清单检查通过，修改的 Python 文件通过格式与 E/W 检查。
- 本次真实集群验证 item 排序；user 排序子集已有单元测试覆盖，但未单独运行集群训练。
- AUC 门槛在验收中为 0，用于验证功能链路，不代表推荐效果达到生产标准。
- 浏览器交互测试未执行。
- 四个组件仓库已提交并推送，对应提交号已固定在 `release/openrec.json`，
  example 在组件推送成功后更新。

## 组件版本

| 组件 | 提交 |
| --- | --- |
| `rec-algorithm` | `3ff7a7a5e7de16e1394f9760d20686da988ace77` |
| `rank-engine` | `3e4ce09825a217383b84d966ea46adc96354c606` |
| `rec-console` | `e5424271c5f67a7b17c7418b92e20296a3a175e8` |
| `bigdata-platform` | `59091f14c16213b5f7f0fed16f31405e8473fd3f` |
