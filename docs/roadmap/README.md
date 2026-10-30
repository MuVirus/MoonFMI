# 路线图

本目录把设计拆成可验收的阶段。路线图是**顺序建议**，不是承诺；每个阶段结束必须满足“退出标准”，否则不进入下一阶段。

---

## 1. 文档

| 文件 | 内容 |
| --- | --- |
| [`roadmap.md`](roadmap.md) | P0–P8 阶段、目标、交付物、退出标准 |
| [`p0-plan.md`](p0-plan.md) | P0 详细执行计划：做什么、参考什么、验收标准 |
| [`backlog.md`](backlog.md) | 可执行任务清单、优先级、依赖 |
| [`risks.md`](risks.md) | 风险登记、触发条件、缓解/应急 |

---

## 2. 总体策略

```text
P0 基础设施/工具链验证
  → P1 解析 + 校验（纯 MoonBit，可独立交付）
  → P2 native FMI 2 CS 导入（首个可用版本）
  → P3 native FMI 2 ME
  → P4 FMI 3（CS/ME，含新类型/数组）
  → P5 CLI/诊断/打包完善
  → P6 源码 FMU 导出
  → P7 WASM（LS-WASM）
  → P8 硬化/生态/性能
```

关键判断：

- **P0 不通过，不写导入器**：C shim 链接、动态加载、XML/ZIP 能力必须先验证。
- **P2 是 MVP**：能加载并仿真一个真实 FMI 2 CS FMU，比“支持所有版本”更重要。
- **P3/P4 可以部分并行**：FMI 3 解析器可以在 P2 期间做，但运行时要等 ABI/主算法稳定。
- **P6/P7 是增量**：不阻塞 P2–P5 的可用性。
- **P8 不是“最后再说”**：安全/模糊测试从 P1 就开始积累语料。

---

## 3. 优先级

| 优先级 | 含义 |
| --- | --- |
| P0 | 阻塞后续；不做就无法继续 |
| P1 | MVP 必需；首个可用版本应包含 |
| P2 | 重要但不阻塞 MVP |
| P3 | 探索/生态/优化 |

---

## 4. 完成定义（DoD）

一个任务算完成，必须：

1. 代码 + 测试 + 文档；
2. `moon fmt` / `moon info` / `moon test` 通过；
3. 新增/变更的 `.mbti` 已审查；
4. 错误路径有诊断/测试；
5. 涉及标准字段的，链接到标准文档/规则编号；
6. 涉及平台/ABI 的，在至少一个真实平台验证；
7. 不引入未记录的依赖；
8. 更新 backlog/风险（如适用）。

阶段完成还需满足该阶段的**退出标准**（见 [`roadmap.md`](roadmap.md)）。

---

## 5. 相关文档

- 设计索引：[`../design/README.md`](../design/README.md)
- 架构：[`../design/architecture.md`](../design/architecture.md)
- 测试：[`../design/cli-and-testing.md`](../design/cli-and-testing.md)
- 风险：[`risks.md`](risks.md)
