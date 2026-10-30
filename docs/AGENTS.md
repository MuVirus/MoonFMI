# MoonFMI 文档中心

> 本文件是 `docs/` 的入口，供人和 AI 代理共用。项目根目录的 [`../AGENTS.md`](../AGENTS.md) 记录 MoonBit 工程约定；本文件只负责文档导航。

本目录是 MoonFMI 项目的技术文档集合，覆盖标准资料、竞品研究、架构设计、实施路线和参考资料。

MoonFMI 的目标是用 MoonBit 构建一套可用的 FMI 工具链，优先级为：

1. **FMU 导入与仿真**（native 为主，wasm 为增量能力）
2. **主算法与 CLI 工具**
3. **FMU 导出**（先源码 FMU，再 WASM FMU）
4. **验证、打包与交叉测试**

> 当前阶段：P0 的基础设施已落地——9 包骨架、依赖方向检查、Windows/Linux CI 配置、8 个真实 FMU 的下载与校验、可选的官方 XSD 对照。代码仍以占位类型为主，业务逻辑从 P0 后续阶段开始。详见 [`records/2026-10-30.md`](records/2026-10-30.md)。

---

## 1. 文档地图

| 目录 | 内容 | 适合谁读 |
| --- | --- | --- |
| [`standards/`](standards/README.md) | FMI 2.0.4 / 3.0.2 标准梳理、API、模型描述、随附 XSD 与头文件 | 所有人，尤其是实现者 |
| [`research/`](research/README.md) | FMPy、fmi-rs、WASM-FMI、MoonBit 生态、其他工具的研究 | 架构与选型 |
| [`design/`](design/README.md) | 总体架构、导入器、主算法、导出器、WASM 策略、ABI、验证、打包、CLI 与测试 | 实现者 |
| [`roadmap/`](roadmap/README.md) | 分阶段路线图、P0 详细执行计划、任务 backlog、风险清单 | 项目管理者与贡献者 |
| [`records/`](records/README.md) | 按阶段归档的实施记录：做了什么、怎么验证、与计划的偏差 | 项目管理者与后续维护者 |
| [`references/`](references/README.md) | 外部链接、术语表 | 所有人 |

### 建议阅读顺序

**第一次接触本项目：**

1. 本文件
2. [`standards/fmi-overview.md`](standards/fmi-overview.md)
3. [`research/README.md`](research/README.md)
4. [`design/architecture.md`](design/architecture.md)
5. [`roadmap/roadmap.md`](roadmap/roadmap.md)

**准备实现导入器：**

1. [`standards/fmi2-api.md`](standards/fmi2-api.md)
2. [`standards/fmi3-api.md`](standards/fmi3-api.md)
3. [`standards/model-description.md`](standards/model-description.md)
4. [`design/importer.md`](design/importer.md)
5. [`design/ffi-and-abi.md`](design/ffi-and-abi.md)
6. [`design/xsd-and-validation.md`](design/xsd-and-validation.md)

**准备实现导出器 / WASM：**

1. [`research/wasm-fmi.md`](research/wasm-fmi.md)
2. [`design/exporter.md`](design/exporter.md)
3. [`design/wasm-strategy.md`](design/wasm-strategy.md)
4. [`design/packaging.md`](design/packaging.md)

**准备做验证与测试：**

1. [`standards/xsd-inventory.md`](standards/xsd-inventory.md)
2. [`design/cli-and-testing.md`](design/cli-and-testing.md)
3. [`research/other-tools.md`](research/other-tools.md)

**准备复现或审查已完成的阶段：**

1. [`records/README.md`](records/README.md)
2. 按日期归档的记录，例如 [`records/2026-10-30.md`](records/2026-10-30.md)

---

## 2. 当前状态

| 工作项 | 状态 | 说明 |
| --- | --- | --- |
| FMI 2.0.4 XSD 全套 | ✅ 完成 | 7 个文件，位于 `standards/schemas/fmi2/` |
| FMI 3.0.2 XSD 全套 | ✅ 完成 | 12 个文件，位于 `standards/schemas/fmi3/` |
| FMI 2.0.4 官方头文件 | ✅ 完成 | 3 个文件，位于 `standards/headers/fmi2/` |
| FMI 3.0.2 官方头文件 | ✅ 完成 | 3 个文件，位于 `standards/headers/fmi3/` |
| 标准与 API 梳理 | ✅ 完成 | `standards/` |
| 竞品与生态研究 | ✅ 完成 | `research/` |
| 架构与详细设计 | ✅ 完成（提案） | `design/` |
| 路线图与风险 | ✅ 完成 | `roadmap/` |
| P0 基础设施 | ✅ 完成 | 9 包骨架、CI、FMU 语料、XSD 对照；见 [`records/2026-10-30.md`](records/2026-10-30.md) |
| 9 包骨架与依赖检查 | ✅ 完成 | `src/`、`tools/check-deps.mjs`；native/wasm 各 8 个测试通过 |
| Windows + Linux CI | 🟡 已配置，待首跑 | `.github/workflows/ci.yml` |
| 真实 FMU 测试语料 | ✅ 完成 | 8 个 Reference-FMUs v0.0.42，清单 + SHA-256 + 离线缓存 |
| 官方 XSD 对照 | ✅ 完成（可选） | 5 个样品，5/5 按预期；不实现 XSD 引擎 |
| FMI-LS-WASM POC | ⬜ 未开始 | 需要验证工具链 |

状态图例：✅ 完成，🟡 进行中，⬜ 未开始，⚠️ 有阻塞或待验证。

---

## 3. 关键结论（先读这一段）

### 3.1 标准范围

- 首个可用版本聚焦 **FMI 2.0.4 + FMI 3.0.2**。
- FMI 1.0 暂不支持，也不建议在早期投入；它的 API 与 2.0 差异大、生态占比持续下降。
- 三种接口中，**Co-Simulation（CS）优先**，其次是 **Model Exchange（ME）**，**Scheduled Execution（SE）** 放到 FMI 3 完善阶段。

### 3.2 导入器可行，但 native 与 wasm 是两条路径

- **Native 导入**：解压 FMU、解析 `modelDescription.xml`、用 `dlopen` / `LoadLibraryW` 加载 `binaries/<platform>/<modelIdentifier>.dll|so|dylib`，再解析 C 符号。MoonBit 生态已有 `tonyfettes/dl` 一类动态加载库，技术上可行。
- **浏览器导入**：浏览器不能加载 native 动态库。能执行的只有：
  - 符合 **FMI-LS-WASM** 的 WASM component FMU；或
  - 将源码 FMU 编译成 wasm 后的自定义运行方式。
- 因此，“MoonBit 写一个浏览器 FMU 播放器”与“MoonBit 写一个 native FMU 导入器”不是同一件事，应拆成两个后端。

### 3.3 XSD 是“标准资料”和 CI 里的独立对照检查，不是运行时依赖

- MoonBit 目前没有成熟的通用 XSD 校验器。
- 推荐做法：**现成 XML 解析器 + 手写类型化构建器 + 语义校验器**；XSD 用于 CI 中对测试样品做独立对照检查，以及作为字段/约束的权威参考。
- 仅靠 XSD 不够：XSD 无法表达大量跨字段规则（如 `initial` 与 `causality` 的组合、`ModelStructure` 引用一致性、Clock 规则等），必须另写语义校验。

### 3.4 MoonBit 的工具链缺口

| 缺口 | 影响 | 应对 |
| --- | --- | --- |
| 不能直接把 MoonBit 包导出为 `.dll/.so` | 无法直接生成 native 二进制 FMU | 生成 C 包装层 + 外部 C 编译器；或先做源码 FMU |
| 无通用 XSD 校验器 | 不能运行时直接校验 XSD | 现成 XML 解析 + 语义校验；CI 用外部工具 |
| XML/ZIP 库成熟度需验证 | FMU 解包与模型描述解析是基础能力 | 优先用 `Milky2018/xml` / `fzip` 包一层；不满足再自研 |
| `String` 为 UTF-16，FMI 为 UTF-8 NUL 结尾 | 字符串参数/返回值需要转换 | 统一封装 UTF-8 转换与生命周期管理 |
| `Bool` 与 C 的表示不完全一致 | FMI 2 的 Boolean 是 `int`，FMI 3 是 `bool` | 不直接映射 `Bool` 数组；用 `Int`/`Byte` 中转或 C shim |
| `size_t` 宽度随目标变化 | 二进制/字符串长度参数在 32/64 位不同 | 按 target 选择 `UInt32`/`UInt64`，并加 ABI 测试 |

### 3.5 导出器的现实排序

1. **源码 FMU**：最可行。生成 `modelDescription.xml`、C 源码、`buildDescription.xml`，由外部编译器构建。
2. **WASM FMU**：最有差异化。MoonBit 的 `wasm` 目标 + component model 工具链可以尝试，但需要 POC。
3. **Native 二进制 FMU**：当前受 MoonBit 无法导出动态库限制，只能通过 C 包装 + 外部链接实现，工程成本高，优先级最低。

### 3.6 建议的代码分层

按交付物分包（参考 fmi-rs），而不是按 `xml`/`model`/`validate` 这类技术概念拆碎：

```text
src/
  zip        只读 ZIP + 安全解压（导入、导出共用）
  xml        XML 读取与安全限制（封装现成库）
  schema     FMI 2/3 类型化模型 + 语义校验
  fmi        打开 FMU、Instance/Backend 抽象、值模型、错误
  backend/
    native   dlopen/LoadLibraryW + C shim（native only）
    wasm     LS-WASM component（wasm only）
  sim        CS/ME/SE 主算法 + 结果记录
  export     IR + 代码生成 + 打包
  cli        组合根
tests/
  data       语料清单与下载脚本
  abi        sizeof/offsetof 基线
  spikes     P0 一次性验证
```

`sim` 只依赖 `fmi` 的抽象接口，所以同一套主算法可以驱动 native 和 wasm 后端；后端只被 `cli` 引用，核心包不感知平台。完整理由与 fmi-rs 对照见 [`design/architecture.md`](design/architecture.md) §3.2。

---

## 4. 文档约定

### 4.1 版本

- FMI 2 指 **FMI 2.0.4**。
- FMI 3 指 **FMI 3.0.2**。
- 若某行为只在更早的 2.0.x / 3.0.x 中存在，会单独注明。

### 4.2 代码与 API

- 文档中的 MoonBit 代码是**示意**，不保证与最终 API 完全一致。
- 包名使用 `MuVirus/MoonFMI/...` 形式；实际目录以 `design/architecture.md` 为准。
- C 函数名、类型名保持官方拼写，便于与头文件对照。

### 4.3 链接

- 内部链接使用相对路径。
- 外部链接集中在 [`references/links.md`](references/links.md)，正文只引用必要的官方文档。

### 4.4 标准文件

`standards/schemas/` 与 `standards/headers/` 中的文件来自 FMI 官方仓库，保持原样，不修改。来源、版本和校验和见各目录的 `README.md`。

---

## 5. 维护方式

- 标准升级时，先更新 `standards/` 的随附文件与清单，再更新受影响的 API/模型描述文档，最后更新设计与路线图。
- 任何设计决策变更，应在 `design/` 对应文档中记录“决策 / 理由 / 替代方案 / 影响”。
- 每个阶段结束，在 `records/` 新增一份实施记录，写清实际命令、证据、与计划的偏差和遗留问题；记录是历史快照，不回改。
- 新增外部依赖前，先在 `research/moonbit-ecosystem.md` 中补充评估，避免核心包被不成熟依赖锁死。
- 路线图中的阶段完成标准应可验证（测试、交叉检查、性能指标），避免“代码写完即完成”。

---

## 6. 相关文件

- 项目说明：[`../README.mbt.md`](../README.mbt.md)
- 模块配置：[`../moon.mod`](../moon.mod)
- 贡献指南（如有）：仓库根目录 `AGENTS.md`
