# 实施记录

本目录保存按日期归档的工作日志，记录每天实际做了什么、如何验证。

与相邻目录的分工：

- [`../roadmap/`](../roadmap/README.md)：接下来要做什么，阶段、任务、验收标准；
- [`../design/`](../design/README.md)：为什么这样设计，架构、接口、取舍；
- `records/`：已经做了什么，命令、结果、遗留问题。

记录是历史快照，不随设计变更回改。

---

## 1. 记录列表

| 日期 | 内容 |
| --- | --- |
| [`2026-11-20`](2026-11-20.md) | moonfig 接入：CLI 配置层（`--config`、JSON/INI/dotenv、`MOONFMI_` 环境变量）、依赖准入、能力缺口台账 |
| [`2026-11-19`](2026-11-19.md) | 0.7.0 全量开发：sandbox/--set/couple 收口、LS-WASM 校验、矩阵导出、安全硬化、ARM CI |
| [`2026-11-18`](2026-11-18.md) | 按优先级完善:C-11 CS 回滚、C-08 Integer/Boolean 绑定(修 ABI 参数序缺陷)、C-20 多 FMU 耦合 MVP、E-09 数组方程、MD-038 + 字段覆盖 100%、CLI 可复现性实测 |
| [`2026-11-15`](2026-11-15.md) | P2 收尾(Dahlquist 对照、多实例)、P3 FMI 2 ME、P4 FMI 3 CS/ME、P5 CLI/诊断/打包 |
| [`2026-11-17-b`](2026-11-17-b.md) | FMI 3 SE 实现、F-08 WASM 导出器、F-06 浏览器实测、cross-check 跨版本对照、FMPy 实测、Linux CI 首跑(R-24 关闭) |
| [`2026-11-17`](2026-11-17.md) | P6 源码 FMU 导出、P7 WASM CS 组件与打包、C-09 FMI 2 状态序列化、P8 首轮硬化(bench/fuzz/crosscheck/安全审查/发布清单) |
| [`2026-11-02`](2026-11-02.md) | C 中间层编入构建、FMU 日志回调、ABI 基线、C 参考宿主、BouncingBall 端到端；同日完成 WASM G1–G3 探针 |
| [`2026-10-31`](2026-10-31.md) | XML 安全读取、ZIP 安全打开、真实 FMU 集成测试、动态库加载与诊断 |
| [`2026-10-30`](2026-10-30.md) | 9 包骨架、依赖方向检查、Windows/Linux 自动检查、8 个真实 FMU 测试样品、可选 XSD 对照 |

---

## 2. 命名约定

```text
YYYY-MM-DD.md
```

文件名只写日期，不加阶段、周次或其他后缀。同一天的内容合并在一份日志里。

---

## 3. 相关文档

- 路线图：[`../roadmap/README.md`](../roadmap/README.md)
- 设计索引：[`../design/README.md`](../design/README.md)
- 文档入口：[`../AGENTS.md`](../AGENTS.md)
