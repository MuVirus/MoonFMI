# 总体架构

> 状态：设计提案。包名、类型名和 API 均为示意，最终以可编译代码和 `.mbti` 为准。

---

## 1. 目标与非目标

### 1.1 目标

1. 在 MoonBit 中提供**可独立测试**的 FMI 2.0.4 / 3.0.2 模型描述解析与语义校验。
2. 提供 native 平台的 FMU 导入与 CS/ME 仿真能力。
3. 提供 FMU 打包、源码导出和（实验性的）WASM FMU 导出能力。
4. 核心逻辑不依赖操作系统，能在 native 与 wasm 目标上编译和测试。
5. 错误信息能定位到文件、字段、变量和 FMI 规则编号。

### 1.2 非目标

- 不实现完整的 Modelica 编译器或符号求解器。
- 不替代 FMPy / OpenModelica 的模型编译能力。
- 不在首版支持 FMI 1.0。
- 不保证所有第三方 FMU 都能运行；只保证对不符合标准的行为给出明确诊断。
- 不把 XSD 校验器嵌入运行时（见 [`xsd-and-validation.md`](xsd-and-validation.md)）。

---

## 2. 分层

```text
┌──────────────────────────────────────────────────┐
│ cli   组合根：validate / info / simulate / export │
├──────────────┬─────────────────┬─────────────────┤
│ backend/     │ backend/wasm    │ sim / export    │
│ native       │ component       │ 主算法 / 代码生成 │
├──────────────┴─────────────────┴─────────────────┤
│ fmi   打开 FMU、Instance/Backend 抽象、值模型      │
├──────────────────────────────────────────────────┤
│ schema   FMI 2/3 类型化模型、索引、语义校验        │
├─────────────────────────┬────────────────────────┤
│ xml   pull parser       │ zip   容器 + 安全解压   │
└─────────────────────────┴────────────────────────┘
```

依赖方向严格向下：`cli → backend / sim / export → fmi → schema → xml / zip`。核心包不得反向依赖后端或 CLI；`backend/native` 与 `backend/wasm` 互不依赖，只由 `cli` 选择。

---

## 3. 包布局

分包方式参考 [fmi-rs](https://github.com/jondo2010/rust-fmi)：**先按交付物拆包，再在包内按 FMI 版本拆文件**，不按“xml / model / validate”这类技术概念拆成一堆小包。

```text
src/
  zip/              只读 ZIP + 安全解压（导入、导出共用）
  xml/              XML 读取层：封装现成 pull parser + 安全限制（schema 用）
  schema/           FMI 2/3 类型化模型、索引、语义校验
    fmi2_model.mbt
    fmi2_parse.mbt
    fmi3_model.mbt
    fmi3_parse.mbt
    validate.mbt
    diagnostic.mbt
  fmi/              打开 FMU、平台选择、Instance/Backend 抽象、值模型、错误
  backend/
    native/         dlopen/LoadLibraryW + C shim（仅 native）
    wasm/           LS-WASM / component 绑定（仅 wasm）
  sim/              CS、ME、SE 主算法 + 结果记录
  export/           IR + XML/C/WIT 代码生成 + FMU 打包
  cli/              组合根：解析参数、选择后端、调用 sim/export
tests/
  data/             语料清单与下载脚本
  abi/              sizeof/offsetof 基线与 C 对照
  spikes/           P0 一次性验证
```

包名采用 `MuVirus/MoonFMI/src/schema` 形式，`backend/native` 的导入路径是 `MuVirus/MoonFMI/src/backend/native`。每个包有独立 `moon.pkg`，只暴露必要的公开类型。

### 3.1 依赖规则

| 包 | 允许依赖 | 禁止依赖 |
| --- | --- | --- |
| `zip` | 标准库 | xml、schema、fmi |
| `xml` | 标准库 | zip、schema、fmi |
| `schema` | `xml` | zip、fmi、backend、sim、cli |
| `fmi` | `zip`、`schema` | backend、sim、export、cli |
| `backend/native` | `fmi`、C shim | sim、export、cli、`backend/wasm` |
| `backend/wasm` | `fmi`、WIT 绑定 | sim、export、cli、`backend/native` |
| `sim` | `fmi`、`schema` | backend、export、cli |
| `export` | `schema`、`zip` | fmi、backend、sim、cli |
| `cli` | 所有上层包 | — |

`sim` 只依赖 `fmi` 的抽象接口，因此同一套主算法可以跑在 native 和 wasm 后端上。后端只被 `cli` 引用，核心包不感知平台。

### 3.2 为什么这样分

对照 fmi-rs 的 workspace：

| fmi-rs | MoonFMI | 说明 |
| --- | --- | --- |
| `fmi-schema` | `schema` | 模型描述类型 + 解析 + 校验 |
| `quick-xml`、`zip`（外部依赖） | `xml`、`zip` | 对应 `Milky2018/xml`、`fzip`；薄封装而不是重写，单独成包便于测试与替换 |
| `fmi` | `fmi` | 打开 FMU、导入流程、`Instance` 抽象 |
| `fmi-sys` | `backend/native` | 原始 ABI 与 shim，单独隔离 |
| `fmi-export` + `fmi-export-derive` | `export` | MoonBit 没有 proc macro，代码生成直接写在 `export` |
| `fmi-sim` | `sim` + `cli` | 主算法与命令行分开，便于 wasm 宿主复用 `sim` |
| `fmi-test-data` | `tests/data` | 语料不参与发布 |
| `fmi-ls-bus` | 暂不建包 | 做分层标准时再加 |

三条约束决定了它不能完全照抄：

1. **没有 feature flag**。Rust 可以用 `cfg(feature = "wasm")` 在一个 crate 里切换后端；MoonBit 靠包级 `supported_targets`，所以 `backend/native` 与 `backend/wasm` 必须是独立包，`dl` 和 component 依赖才不会漏进另一个 target。
2. **包即编译单元，也是发布单元**。Rust 为了 semver 把功能拆成多个 crate；MoonBit 以 module 发布，包拆得太细只会增加 import 噪音。
3. **复用决定拆分**。`zip` 被导入和导出同时使用，所以独立；`xml` 只服务 `schema`，独立只是为了单独测试，是第一个可以合并的候选。

加新包的门槛：被两个以上上层复用，或有独立的 target 约束，或能显著减少编译依赖。三者都不满足，就先放进现有包。

---

## 4. 公共模型

### 4.1 值模型

FMI 2 与 FMI 3 的变量类型不同，但运行时值可以用统一枚举表达：

```moonbit
pub enum FmiValue {
  Real(Double)
  Integer(Int64)
  Boolean(Bool)
  String(String)
  Binary(Bytes)
  Float32(Float)
  Int8(Byte)
  UInt8(Byte)
  Int16(Int16)
  UInt16(UInt16)
  Int32(Int32)
  UInt32(UInt32)
  Int64(Int64)
  UInt64(UInt64)
  Clock(Bool)
}
```

约束：

- `Integer` 在 FMI 2 中对应 32 位 `int`，在 FMI 3 中按变量声明的具体宽度区分；写入前必须做范围检查。
- `Boolean` 在 FMI 2 中按 `fmi2Boolean`（C `int`）传输，在 FMI 3 中按 `fmi3Boolean`（C `bool`）传输。内部统一为 `Bool`，边界层负责转换。
- `String` 必须是 UTF-8 边界；MoonBit 内部 UTF-16 与 FMI UTF-8 的转换集中在后端。
- `Binary` 是带长度的字节串，不使用 NUL 结尾语义。
- 数组在公开 API 中使用 `Array[FmiValue]` 或按类型的 `Array[Double]`，避免每个元素装箱。

### 4.2 变量句柄

`valueReference` 是 FMI 运行时句柄，不是数组下标。设计上同时保留：

```moonbit
pub struct VariableRef {
  value_reference : UInt32
  name : String
  data_type : DataType
  dimensions : Array[Int]
}
```

- 解析后建立 `valueReference -> Variable` 索引；FMI 2 允许重复 `valueReference`，索引中保留列表。
- 访问 API 默认按变量名查找；批量 API 按 `valueReference`。
- 维度信息用于数组访问的边界检查，但不假设内存布局。

### 4.3 版本与接口

```moonbit
pub enum FmiVersion { V2; V3 }

pub enum InterfaceKind {
  ModelExchange
  CoSimulation
  ScheduledExecution
}
```

接口是否存在、支持哪些能力（事件模式、可变步长、状态保存等）均由解析后的 `ModelDescription` 决定，而不是由版本臆测。

---

## 5. `fmi` 包：实例抽象

### 5.1 后端接口

```moonbit
pub trait FmuBackend {
  fn version(self) -> FmiVersion
  fn interfaces(self) -> Array[InterfaceKind]
  fn instantiate(self, config : InstanceConfig) -> Instance raise FmiError
  fn close(self) -> Unit
}
```

`Instance` 只暴露标准操作，不暴露 `dlopen` 句柄或 wasm 资源：

```moonbit
pub trait Instance {
  fn set_real(self, vr : UInt32, value : Double) -> Unit raise FmiError
  fn get_real(self, vr : UInt32) -> Double raise FmiError
  fn set_values(self, values : Array[(UInt32, FmiValue)]) -> Unit raise FmiError
  fn get_values(self, refs : Array[UInt32]) -> Array[FmiValue] raise FmiError
  fn do_step(self, current : Double, step : Double) -> StepResult raise FmiError
  fn terminate(self) -> Unit raise FmiError
  fn free(self) -> Unit
}
```

具体实现可以按版本和接口拆成多个 trait（`CsInstance`、`MeInstance`、`SeInstance`），门面层再做统一封装。设计原则允许“版本专用 API”，不强行把 ME 的连续状态操作塞进 CS 接口。

### 5.2 实例配置

```moonbit
pub struct InstanceConfig {
  instance_name : String
  visible : Bool
  logging_on : Bool
  event_mode_used : Bool
  // FMI 3：可选中间变量、所需状态等
  required_intermediate_variables : Array[UInt32]
  // 资源目录；默认指向解压后的 resources/
  // 注意：FMI 2 传 URI，FMI 3 传原生绝对路径；无资源时为 None
  resource_path : String?
}
```

`instance_name` 必须非空且符合工具约定；`resource_path` 必须位于 FMU 解压目录内，禁止任意路径。内部统一保存相对解压根的路径，由各版本后端在实例化前转换成对应形式（FMI 2 → `file://` URI，FMI 3 → 原生绝对路径），避免上层感知差异。

### 5.3 回调

FMI 回调（日志、中间更新、时钟更新、锁/解锁抢占）由后端注册，统一转发到 MoonBit 回调对象：

```moonbit
pub struct Callbacks {
  log : (LogMessage) -> Unit
  intermediate_update : ((IntermediateUpdate) -> Unit)?
  clock_update : (() -> Unit)?
}
```

约束：

- 回调可能在 FMU 内部线程被调用；MoonBit 侧默认只做复制和入队，不执行重操作。
- 回调生命周期必须覆盖实例生命周期；实例释放前先注销。
- 回调中抛出的 MoonBit 异常不能穿越 C ABI，必须在边界捕获并记录。

---

## 6. 目标矩阵

| 能力 | native | wasm (core) | wasm32-wasip2 component | js |
| --- | --- | --- | --- | --- |
| XML/ZIP/schema/validate | ✅ | ✅ | ✅ | ✅ |
| native FMU 导入 | ✅ | ❌ | ❌ | ❌ |
| LS-WASM FMU 导入/运行 | ❌ | ⚠️ 待验证 | ✅ 目标 | ⚠️ 通过宿主 |
| CS/ME 主算法 | ✅ | ✅（纯逻辑） | ✅ | ✅ |
| 源码 FMU 导出 | ✅ | ✅ | ✅ | ✅ |
| native 二进制 FMU 导出 | ⚠️ 需 C 工具链 | ❌ | ❌ | ❌ |
| WASM FMU 导出 | ❌ | ⚠️ POC | ✅ 目标 | ❌ |

`preferred_target = "wasm"` 只表示默认构建目标，不意味着所有能力都走 wasm。native 后端是首个可用路径。

---

## 7. 公开 API 草案

```moonbit
pub fn open_fmu(path : String, options : OpenOptions) -> Fmu raise FmiError

pub struct Fmu {
  // 私有：解压目录、动态库句柄、模型描述
}

pub fn Fmu::model_description(self) -> &ModelDescription
pub fn Fmu::capabilities(self) -> Capabilities
pub fn Fmu::instantiate(self, config : InstanceConfig) -> Instance raise FmiError
pub fn Fmu::close(self) -> Unit

pub struct SimulationConfig {
  start_time : Double
  stop_time : Double
  communication_step : Double
  tolerance : Double?
  solver : SolverChoice
}

pub fn simulate_cs(fmu : &Fmu, config : SimulationConfig) -> SimulationResult raise FmiError
```

API 设计约束：

1. **打开与实例化分离**：解析/校验可以在不加载动态库的情况下完成，便于 `validate` 和 `info`。
2. **显式关闭**：`Fmu` 持有解压目录和库句柄；`Instance` 释放前不得关闭 `Fmu`。实现可用引用计数，但 API 上仍要求顺序正确。
3. **批量优先**：标量 get/set 是便利方法，主算法内部使用批量调用，减少跨 ABI 次数。
4. **不隐藏状态**：`StepResult` 明确包含事件、终止、早退和最后成功时间。

---

## 8. 错误模型

```moonbit
pub enum ErrorKind {
  Io
  Zip
  Xml
  Schema
  Semantic
  Platform
  Symbol
  FmiCall
  Abi
  Config
  Unsupported
}

pub struct FmiError {
  kind : ErrorKind
  message : String
  context : Map[String, String]
  fmi_status : Int?       // fmi2Status / fmi3Status 原始值
  rule_id : String?       // 例如 "MD-031"
}
```

要求：

- `message` 面向用户，`context` 面向调试。例如 `context` 包含 FMU 路径、平台目录、变量名、函数名、调用阶段。
- FMI 返回 `fmi2Discard` / `fmi3Discard` 不等于普通错误：主算法需要根据 `lastSuccessfulTime` 回滚并决定重试，错误对象保留原始状态码供上层判断。
- 不把底层 `dlopen` 错误码直接暴露；映射为 `Symbol` 或 `Platform`，并附原始系统消息。
- 所有公开错误类型不得依赖 native/wasm 具体实现。

---

## 9. 并发与生命周期

- 一个 `Fmu` 的模型描述不可变，可被多个实例共享读取。
- 一个 `Instance` **不是线程安全的**；主算法串行调用，符合 FMI 对实例的约定。
- 动态库句柄可在多个实例间共享；卸载必须等到所有实例释放。
- 解压目录在 `Fmu` 生命周期内保持存在；若使用临时目录，`Drop`/`close` 时清理，异常路径也要清理。
- WASM 实例的资源生命周期由 component 资源和宿主引用计数管理，不假设有 `dlclose`。

---

## 10. 构建与条件编译

- 核心包（`zip`/`xml`/`schema`/`fmi`/`sim`）不写 `#cfg`，保证所有目标可编译。
- 平台差异集中在 `backend/native` 与 `backend/wasm`，二者互不依赖。
- native 使用 `#cfg(platform="windows")` 等条件编译隔离 `LoadLibraryW` 与 `dlopen`。
- wasm 绑定放在单独包，避免 native 构建拉入 WIT/组件依赖；反之亦然。
- `cli` 是组合根，按目标裁剪命令：native 构建提供 `simulate`，wasm 构建提供 `wasm` 子命令或宿主 API。

---

## 11. 设计取舍

| 决策 | 选择 | 理由 | 替代方案 |
| --- | --- | --- | --- |
| 是否统一 FMI 2/3 API | 统一值模型 + 版本专用实例 trait | 避免万能接口；保留类型安全 | 完全分离两套 API |
| 解析器 | 现成 pull parser（`Milky2018/xml`）+ 安全策略封装 | 不重造 XML 解析器；位置信息、安全限制由封装层补齐 | 自研解析器 |
| ZIP | 现成解压库（`fzip`）+ 自写安全检查 | deflate 用库，目录与解压策略自己控制 | 全部自研 |
| XSD | 仅作 CI 外部对照，不实现 XSD 引擎 | MoonBit 无通用 XSD 校验器；共用官方 XSD 即可 | 运行时 XSD |
| 动态加载 | `tonyfettes/dl` 或等价封装 | 已有 native 支持 | 自己写 `extern "c"` |
| 结构体传参 | C shim | 避免布局/对齐不确定 | MoonBit 直接映射 |
| WASM 路径 | LS-WASM component | 标准化、可互操作 | 自定义 JS ABI |
| 导出顺序 | 源码 → WASM → native | 工具链约束 | 先 native 二进制 |

---

## 12. 相关文档

- 导入器：[`importer.md`](importer.md)
- 主算法：[`master-algorithm.md`](master-algorithm.md)
- ABI：[`ffi-and-abi.md`](ffi-and-abi.md)
- 解析与校验：[`xsd-and-validation.md`](xsd-and-validation.md)
- WASM：[`wasm-strategy.md`](wasm-strategy.md)
- 打包：[`packaging.md`](packaging.md)
- 路线图：[`../roadmap/roadmap.md`](../roadmap/roadmap.md)
