# 任务 Backlog

> 状态：提案。优先级 P0/P1/P2/P3；规模 S（≤1 天）、M（2–5 天）、L（1–2 周）、XL（>2 周）。依赖用任务 ID 表示。
> P0 阶段的展开（做什么/参考什么/验收标准）见 [`p0-plan.md`](p0-plan.md)。

---

## 1. 使用方式

- 每个任务应能独立验收；
- 完成任务时更新本表状态；
- 新增任务先判断是否属于现有 epic；
- 不在任务中隐藏“大重构”；大重构拆成可回滚的步骤。

状态：`todo` / `doing` / `done` / `blocked` / `dropped`。

---

## 2. Epic A · 基础设施

| ID | 任务 | 优先级 | 规模 | 依赖 | 验收 |
| --- | --- | --- | --- | --- | --- |
| A-01 | 建立 `zip`、`xml`、`schema`、`fmi`、`backend/*`、`sim`、`export`、`cli` 包骨架 | P0 | S | — | `moon check` 通过，依赖方向符合架构 |
| A-02 | CI：fmt/info/test + Windows/Linux | P0 | M | A-01 | PR 必须全绿 |
| A-03 | 测试语料清单与校验和 | P0 | S | — | `tests/data/README` 记录来源/许可 |
| A-04 | XSD 对照检查（可选，外部工具 xmllint/lxml） | P0 | S | A-03 | 四类样品预期结果写死；工具可用时能复现 |
| A-05 | Spike：`dl` 加载自建动态库 | P0 | S | — | Windows/Linux 调用成功 |
| A-06 | Spike：C shim 链接 MoonBit native | P0 | M | — | 明确可行/退路并记录 |
| A-07 | Spike：MoonBit wasm → component | P0 | M | — | wasmtime 调用成功 |
| A-08 | 基准测试脚手架 | P2 | S | A-02 | 输出可比较的中位数 |

---

## 3. Epic B · 解析与校验

| ID | 任务 | 优先级 | 规模 | 依赖 | 验收 |
| --- | --- | --- | --- | --- | --- |
| B-01 | XML 读取封装（`Milky2018/xml`） | P0 | M | A-01 | 事件流/行列号/错误 |
| B-02 | XML 安全限制（DTD/实体/大小/深度） | P0 | M | B-01 | 恶意样品被拒绝 |
| B-03 | ZIP 只读 + 条目枚举（`fzip`） | P0 | M | A-01 | 读取真实 FMU |
| B-04 | ZIP 路径穿越/炸弹防护 | P0 | M | B-03 | 负例测试 |
| B-05 | ZIP 确定性写入 | P2 | M | B-03 | 两次打包哈希一致 |
| B-06 | 公共值/类型/单位模型 | P0 | M | A-01 | 单元测试 |
| B-07 | FMI 2 类型化模型描述 | P0 | L | B-01 | 最小/完整 fixture |
| B-08 | FMI 3 类型化模型描述 | P0 | L | B-01 | 最小/完整 fixture |
| B-09 | 默认值与“显式提供”语义 | P0 | M | B-07/B-08 | 诊断可区分默认值 |
| B-10 | 索引构建（name/vr/type/unit） | P0 | M | B-07/B-08 | O(n) 测试 |
| B-11 | MD-001…007 根/接口规则 | P1 | S | B-10 | 正反例 |
| B-12 | MD-010…020 变量规则 | P1 | L | B-10 | 正反例 |
| B-13 | MD-030…036 数组/Clock | P1 | L | B-08 | FMI 3 正反例 |
| B-14 | MD-040…049 模型结构 | P1 | L | B-10 | FMI 2/3 正反例 |
| B-15 | MD-050…054 单位/类型 | P1 | M | B-10 | 正反例 |
| B-16 | MD-060…063 安全规则 | P1 | M | B-03/B-04 | 恶意语料 |
| B-17 | 诊断对象/排序/去重 | P1 | M | B-11…B-16 | golden 快照 |
| B-18 | `moonfmi validate` 文本/JSON | P1 | M | B-17 | 退出码/JSON 稳定 |
| B-19 | 字段覆盖脚本（XSD vs 模型） | P2 | M | B-07/B-08 | CI 报告差异 |
| B-20 | fuzz 固定种子回归 | P2 | M | B-02/B-04 | 无 panic/OOM |

---

## 4. Epic C · native 运行时

| ID | 任务 | 优先级 | 规模 | 依赖 | 验收 |
| --- | --- | --- | --- | --- | --- |
| C-01 | `Backend`/`Instance` 抽象 | P0 | M | B-06 | 主算法可 mock |
| C-02 | 主机平台 → 目录映射 | P0 | S | — | 平台矩阵测试 |
| C-03 | FMU 安全解压 | P0 | M | B-04 | 私有临时目录/清理 |
| C-04 | 动态库加载（绝对路径/依赖） | P0 | M | A-05/C-03 | Windows/Linux |
| C-05 | 符号表绑定/可选符号 | P0 | M | C-04 | 缺失符号可定位 |
| C-06 | C shim：回调/结构体/日志 | P0 | L | A-06 | 日志测试 |
| C-07 | FMI 2 实例化/释放 | P1 | M | C-05/C-06 | 真实 FMU |
| C-08 | FMI 2 get/set/状态码 | P1 | L | C-07 | 类型/布尔测试 |
| C-09 | FMI 2 状态保存/序列化 | P2 | M | C-08 | 能力缺失报错 |
| C-10 | CS 主算法 | P1 | L | C-08 | BouncingBall |
| C-11 | CS 事件/回滚/早退 | P1 | L | C-10 | 事件测试 |
| C-12 | 结果记录 CSV/内存 | P1 | M | C-10 | 列稳定 |
| C-13 | ME 主算法（Euler/RK4） | P2 | L | C-08 | VanDerPol |
| C-14 | ME 事件检测 | P2 | L | C-13 | 事件时间测试 |
| C-15 | FMI 3 实例化（CS/ME） | P1 | L | C-06/B-08 | Reference-FMU |
| C-16 | FMI 3 新类型/数组 | P1 | L | C-15 | ABI/数组测试 |
| C-17 | FMI 3 CS | P1 | M | C-15/C-16 | 事件/早退 |
| C-18 | FMI 3 ME | P2 | M | C-15/C-16 | 参考轨迹 |
| C-19 | FMI 3 SE 可行性研究 | P3 | M | C-15 | 报告，不承诺 |

---

## 5. Epic D · CLI 与诊断

| ID | 任务 | 优先级 | 规模 | 依赖 | 验收 |
| --- | --- | --- | --- | --- | --- |
| D-01 | `simulate` 命令 | P1 | M | C-10 | 可跑 MVP |
| D-02 | `info` 命令 | P1 | S | B-17 | 摘要/JSON |
| D-03 | `doctor` 命令 | P2 | S | A-02 | 环境检查 |
| D-04 | JSON schema 文档/测试 | P1 | M | B-18/D-01 | 兼容性测试 |
| D-05 | 错误信息改进 | P1 | M | B-17 | 含路径/规则/建议 |
| D-06 | `package` 命令 | P2 | M | B-05 | 可被 FMPy 打开 |
| D-07 | shell completion | P3 | S | D-01 | bash/zsh/pwsh |

---

## 6. Epic E · 导出

| ID | 任务 | 优先级 | 规模 | 依赖 | 验收 |
| --- | --- | --- | --- | --- | --- |
| E-01 | 模型 IR | P2 | L | B-06 | IR 可校验 |
| E-02 | `modelDescription.xml` 生成 | P2 | L | E-01 | XSD 通过 |
| E-03 | C 模型/入口代码生成 | P2 | XL | E-02 | 可编译 |
| E-04 | 源码 FMU 布局/CMake | P2 | M | E-03 | 外部构建成功 |
| E-05 | FMI 3 `buildDescription.xml` | P2 | M | E-04 | XSD 通过 |
| E-06 | 纯 C native FMU | P2 | M | E-04 | Windows/Linux 加载 |
| E-07 | 生成 FMU 回读/对比 | P2 | M | E-04 | 与参考一致 |
| E-08 | 可复现打包 | P3 | M | B-05/E-04 | 哈希稳定 |

---

## 7. Epic F · WASM

| ID | 任务 | 优先级 | 规模 | 依赖 | 验收 |
| --- | --- | --- | --- | --- | --- |
| F-01 | POC-1 core → component | P2 | M | A-07 | wasmtime 调用 |
| F-02 | WIT 绑定（common） | P2 | L | F-01 | `get-version` |
| F-03 | resource 实例生命周期 | P2 | L | F-02 | 宿主 drop |
| F-04 | 最小 CS component | P2 | XL | F-03 | Adder 步进 |
| F-05 | wasmtime 宿主 + 回调 | P2 | L | F-04 | 日志/结果 |
| F-06 | `jco` 浏览器 POC | P3 | L | F-04 | Chrome/Firefox |
| F-07 | WASM FMU 打包/manifest | P2 | M | F-04 | XSD/布局 |
| F-08 | WASM 导出器 | P3 | XL | F-04/E-01 | 生成可加载 FMU |

---

## 8. Epic G · 硬化

| ID | 任务 | 优先级 | 规模 | 依赖 | 验收 |
| --- | --- | --- | --- | --- | --- |
| G-01 | XML/ZIP fuzz 扩展 | P2 | M | B-20 | 固定种子回归 |
| G-02 | fmi-cross-check 集成 | P2 | L | C-10 | 报告生成 |
| G-03 | 性能基线/回归 | P2 | M | A-08 | 阈值告警 |
| G-04 | 安全审查/沙箱方案 | P2 | L | C-04 | 风险清单 |
| G-05 | 文档/示例/迁移 | P1 | M | 全程 | 新用户可跑通 |
| G-06 | 发布检查/SBOM | P2 | M | 全部 | release checklist |

---

## 9. 推荐首批任务（按顺序）

1. A-01、A-02：没有骨架和 CI，后面无法稳定推进。
2. B-01、B-03、B-04：解析/容器是所有功能的基础。
3. A-05、A-06：尽早确认 native 边界。
4. B-07、B-08、B-17：先把模型描述和诊断做对。
5. C-01…C-08：打通最小实例。
6. C-10：MVP 主算法。
7. A-07 + F-01：WASM 只做 POC，不阻塞 MVP。

---

## 10. 明确不做（首版）

- FMI 1.0；
- FMI 3 SE 的完整调度器；
- 通用 Modelica 编译器；
- 通用 DAE/刚性求解器；
- 浏览器加载任意 native FMU；
- 自动修复非法 FMU；
- 云端服务/账号系统。

---

## 11. 相关文档

- 阶段：[`roadmap.md`](roadmap.md)
- 风险：[`risks.md`](risks.md)
- 设计：[`../design/README.md`](../design/README.md)
- 测试：[`../design/cli-and-testing.md`](../design/cli-and-testing.md)
