# 研究与选型

本目录记录 MoonFMI 在设计前做的技术研究，重点回答三个问题：

1. 其他 FMI 实现是怎么做的，哪些经验可以复用？
2. 在 MoonBit 生态里，哪些能力已经具备，哪些需要自研或绕过？
3. 对 MoonFMI 来说，最现实的实现路径是什么？

> 研究基于 2026 年 10 月的公开资料与本地工具链（`moon 0.1.20261023`）。外部库/标准草案会变化，落地前应重新验证。

---

## 1. 研究对象

| 对象 | 类型 | 研究重点 | 文档 |
| --- | --- | --- | --- |
| FMPy | Python FMU 工具链 | 导入、主算法、校验、CLI、源码构建 | [`fmpy.md`](fmpy.md) |
| fmi-rs | Rust FMU 工具链 | 分层 crate、类型化 schema、导入/导出、测试数据 | [`fmi-rs.md`](fmi-rs.md) |
| FMI-LS-WASM | 标准草案 | WASM component 映射、FMU 布局、回调 | [`wasm-fmi.md`](wasm-fmi.md) |
| Bodylight.js / OpenModelica | 浏览器仿真 | 浏览器内 FMU 执行方式 | [`wasm-fmi.md`](wasm-fmi.md) |
| MoonBit 生态 | 语言与库 | XML/ZIP/FFI/动态加载/WASM/组件模型 | [`moonbit-ecosystem.md`](moonbit-ecosystem.md) |
| 其他工具 | 生态 | 测试语料、交叉检查、SSP、FMU SDK | [`other-tools.md`](other-tools.md) |

---

## 2. 核心结论

### 2.1 架构上，FMPy 和 fmi-rs 都采用“分层 + 版本分派”

- FMPy：`fmi1.py` / `fmi2.py` / `fmi3.py` 各自封装 ctypes，`model_description.py` 统一解析，`simulation.py` 提供 ME/CS 主算法，`validation.py` 独立校验。
- fmi-rs：`fmi-sys`（原始绑定）、`fmi-schema`（XML 模型）、`fmi`（安全 API）、`fmi-sim`（主算法）、`fmi-export`（导出）、`cargo-fmi`（打包）。

**对 MoonFMI 的启示：**

- 不要做一个“大一统”的 FMI 抽象；按版本分层，公共层只放元数据/值容器/诊断。
- 解析、校验、运行时绑定、主算法、打包应分包，便于测试和按 target 裁剪。
- 版本分派放在门面层，调用方可以选择使用门面或版本专用 API。

### 2.2 运行时校验不能依赖 XSD

- FMPy 用 `lxml` + 官方 XSD 做结构校验，再用手写 `validation.py` 做语义校验；它还区分 `validate_variable_names` 和 `validate_model_structure`。
- fmi-rs 的 `fmi-schema` 用强类型反序列化，XSD 主要作为开发参考。

**对 MoonFMI 的启示：**

- 运行时：手写类型化解析 + 语义校验，错误信息带路径/行号/规则编号。
- CI：用 `xmllint`/`lxml` 对测试样品做独立的 XSD 对照检查，用来分清“样品坏了”还是“我们的解析器坏了”。
- 不要把 XSD 校验器塞进 MoonBit 核心包。

### 2.3 native 导入可行，WASM 导入是另一条技术栈

- native：`dlopen`/`LoadLibraryW` + C ABI 绑定。FMPy 用 ctypes，fmi-rs 用 `libloading`；MoonBit 有 `tonyfettes/dl` 一类库，路径可行。
- WASM：浏览器只能执行 WASM component（FMI-LS-WASM）或自定义 wasm 模块。不能把 native `.dll` 直接加载到浏览器。

**对 MoonFMI 的启示：**

- native 与 wasm 后端必须隔离，共享上层模型/主算法，不共享加载器。
- 首个可用版本先做 native CS 导入；WASM 作为独立里程碑。
- 如果目标是浏览器，优先做 FMI-LS-WASM 导出，而不是 native FMU 导出。

### 2.4 MoonBit 的短板主要在“系统边界”

| 短板 | 影响 | 应对 |
| --- | --- | --- |
| 无成熟 XSD 校验器 | 不能运行时校验 | 现成 XML 解析 + 语义规则 |
| XML/ZIP 库需验证 | FMU 解包是基础 | 优先用 `Milky2018/xml` / `fzip` 包一层；不满足再自研 |
| 不能直接导出 `.dll/.so` | native 导出受限 | C 包装 + 外部编译器；或只做源码 FMU |
| `String` UTF-16、FMI UTF-8 | 字符串转换 | 统一 UTF-8 边界层 |
| `Bool` 宽度与 C 不完全一致 | 布尔数组错位 | 用 `Int`/`Byte` 中转或 C shim |
| `size_t` 随 target 变化 | ABI 错误 | 按 target 映射 + ABI 测试 |
| 组件模型工具链待验证 | LS-WASM 导出不确定 | 先做最小 POC |

### 2.5 测试语料比“自己造 FMU”更重要

- `modelica/Reference-FMUs` 覆盖官方语义，是最小可靠语料。
- `modelica/fmi-cross-check` 覆盖大量工具的真实输出，能暴露兼容性问题。
- fmi-rs 的 `fmi-test-data`、FMPy 的测试 FMU 可以作为补充。

**对 MoonFMI 的启示：**

- 从第一天起就建立“语料 + 期望结果”的回归测试。
- 不要只测自己导出的 FMU，否则会形成“自洽但不互通”的假象。
- 用 FMPy/OMSimulator/OpenModelica 做交叉验证。

---

## 3. 研究问题清单

| 编号 | 问题 | 状态 | 结论 |
| --- | --- | --- | --- |
| R-01 | FMI 2/3 的 C ABI 差异 | ✅ | 见 [`../standards/fmi2-api.md`](../standards/fmi2-api.md)、[`fmi3-api.md`](../standards/fmi3-api.md) |
| R-02 | `modelDescription.xml` 的完整字段 | ✅ | 见 [`../standards/model-description.md`](../standards/model-description.md) |
| R-03 | XSD 是否足够做运行时校验 | ✅ | 不够；需语义校验 |
| R-04 | FMPy 的模块划分 | ✅ | 见 [`fmpy.md`](fmpy.md) |
| R-05 | fmi-rs 的 crate 分层 | ✅ | 见 [`fmi-rs.md`](fmi-rs.md) |
| R-06 | MoonBit 的 XML/ZIP 能力 | 🟡 | 有候选库，需 spike |
| R-07 | MoonBit 的动态加载能力 | ✅ | `tonyfettes/dl` 可用；需 ABI 验证 |
| R-08 | MoonBit 能否导出 native 动态库 | ⚠️ | 目前不能直接导出；需 C 包装 |
| R-09 | MoonBit 的 WASM 目标与组件模型 | 🟡 | 可产出 wasm；component 化需工具链 POC |
| R-10 | 浏览器 FMU 执行路径 | ✅ | 只能 wasm component / 自定义 wasm |
| R-11 | FMI-LS-WASM 的成熟度 | 🟡 | 草案，非规范；需跟踪 |
| R-12 | 测试语料与交叉检查 | ✅ | Reference-FMUs + cross-check |
| R-13 | 源码 FMU 的构建方式 | ✅ | 生成 C + buildDescription，外部编译 |
| R-14 | SSP 是否在范围内 | ⬜ | 暂不支持，后续评估 |

---

## 4. 研究方法与局限

### 4.1 方法

- 阅读官方规范、XSD、头文件；
- 阅读 FMPy / fmi-rs / FMI-LS-WASM 的源码与文档；
- 检查 MoonBit 工具链版本、target 列表、包管理生态；
- 对关键假设做最小实验（如 `moon build --target wasm`、动态加载符号）。

### 4.2 局限

- 未对所有候选 MoonBit 库做完整兼容性测试；
- 未在真实浏览器中验证 LS-WASM 组件；
- 未覆盖所有 FMI 工具的“非标准”行为；
- 性能数据尚未采集；
- 外部库版本可能变化。

这些局限应在路线图的 POC 阶段逐项消除，而不是在文档中假定成立。

---

## 5. 对设计的输入

| 设计决策 | 研究依据 |
| --- | --- |
| 分包：`schema` / `fmi` / `backend/{native,wasm}` / `sim` / `export` | FMPy 与 fmi-rs 的分层 |
| 运行时用现成解析器 + 语义校验 | FMPy 的 XSD + validation 双轨；MoonBit 无 XSD 校验器 |
| native 优先、wasm 独立 | 浏览器限制 + MoonBit 工具链现状 |
| 源码 FMU 优先于 native 二进制 FMU | MoonBit 不能直接导出动态库 |
| WASM 导出作为差异化 | FMI-LS-WASM 草案 + MoonBit `wasm` target |
| C shim 处理 ABI 边界 | 布尔/字符串/结构体/`size_t` 差异 |
| 交叉检查纳入 CI | fmi-cross-check 的实践 |

---

## 6. 后续研究

1. **MoonBit XML/ZIP spike**：解析 1000 个真实 `modelDescription.xml`，测吞吐、内存、错误恢复。
2. **ABI spike**：用 C 写一个最小 FMU，MoonBit 通过 `dl` 调用，覆盖所有类型。
3. **WASM 导入 spike**：用 wasmtime 加载一个 LS-WASM 示例 component，确认资源/回调映射。
4. **WASM 导出 spike**：把一个最小 MoonBit 模型 component 化，跑通 `wasm-tools component new` + 宿主调用。
5. **交叉检查**：选 20 个 Reference-FMUs，和 FMPy 的结果做数值对比。
6. **性能基线**：解析 10k 变量、10 万步 CS 仿真的时间/内存。

这些 spike 的验收标准见 [`../roadmap/roadmap.md`](../roadmap/roadmap.md)。

---

## 7. 文档索引

- [`fmpy.md`](fmpy.md) — Python 参考实现
- [`fmi-rs.md`](fmi-rs.md) — Rust 参考实现
- [`wasm-fmi.md`](wasm-fmi.md) — WASM/FMI-LS-WASM/浏览器
- [`moonbit-ecosystem.md`](moonbit-ecosystem.md) — MoonBit 能力评估
- [`other-tools.md`](other-tools.md) — 测试语料与其他工具
- [`../references/links.md`](../references/links.md) — 外部链接
