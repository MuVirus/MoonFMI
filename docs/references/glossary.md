# 术语表

> 中文解释用于理解，不替代 FMI 规范中的正式定义。英文术语保留官方拼写，便于查规范。

---

## 1. 标准与版本

| 术语 | 解释 |
| --- | --- |
| **FMI** | Functional Mock-up Interface。定义模型交换/协同仿真的标准 C API 与模型描述格式。 |
| **FMU** | Functional Mock-up Unit。一个 ZIP 归档，含 `modelDescription.xml`、二进制/源码、资源等。 |
| **FMI 2.0.4** | 本项目基线之一；使用 `fmi2*` API，布尔为 C `int`。 |
| **FMI 3.0.2** | 本项目基线之一；使用 `fmi3*` API，新增数组、Clock、Binary、SE 等。 |
| **ME** | Model Exchange。FMU 提供连续状态导数/事件，主算法负责积分。 |
| **CS** | Co-Simulation。FMU 自带求解器，主算法按通信步长调用 `DoStep`。 |
| **SE** | Scheduled Execution（FMI 3）。由时钟驱动的分区执行模型。 |
| **Model Description** | `modelDescription.xml`，描述变量、接口、能力、单位、结构等。 |
| **modelIdentifier** | 接口元素上的标识，用于定位 `binaries/<platform>/<modelIdentifier>.<ext>`。 |
| **GUID / instantiationToken** | FMI 2 的 `guid` / FMI 3 的 `instantiationToken`，用于标识模型实例化契约。 |
| **Capability flag** | 接口元素上声明能力/行为的属性，如 `canHandleVariableCommunicationStepSize`。 |

---

## 2. 模型描述

| 术语 | 解释 |
| --- | --- |
| **ScalarVariable / Variable** | FMI 2 的标量变量 / FMI 3 的变量元素。 |
| **valueReference** | 运行时句柄，用于 get/set；不是数组下标，可能不连续。 |
| **causality** | 因果性：`input`、`output`、`parameter`、`independent`、`local`（FMI 3 还有 `structuralParameter` 等）。 |
| **variability** | 变化性：`constant`、`fixed`、`tunable`、`discrete`、`continuous`。 |
| **initial** | 初始化类别：`exact`、`approx`、`calculated`；决定 `start` 的语义。 |
| **start** | 变量初值/猜测值；具体含义依赖 `initial` 和 `causality`。 |
| **nominal** | 标称值，用于缩放/误差控制，不是初值。 |
| **min / max** | 变量允许范围；不等于求解器约束。 |
| **unit / displayUnit** | 单位与显示单位；`displayUnit` 需要与 `unit` 兼容。 |
| **BaseUnit** | 由 7 个基本量纲指数定义的单位。 |
| **TypeDefinition** | 可复用的变量类型（FMI 2 `SimpleType`，FMI 3 多种 Type）。 |
| **Alias** | FMI 3 中同一变量的别名，共享 `valueReference`。 |
| **Dimension** | FMI 3 数组维度；可由常量 `start` 或 `structuralParameter` 的 `valueReference` 给出。 |
| **structuralParameter** | 影响数组维度的参数；初始化后通常不可变。 |
| **Clock** | FMI 3 时钟变量；SE/CS 中用于触发/调度。 |
| **ModelStructure** | 描述输出、导数、初始未知量、事件指示器、依赖关系。 |
| **dependencies / dependenciesKind** | 变量依赖关系及依赖类型（独立、常量、固定、可调、离散、依赖）。 |
| **event indicator** | 事件指示器；其符号变化用于检测事件。 |

---

## 3. 运行时

| 术语 | 解释 |
| --- | --- |
| **Instance** | 由 `Instantiate` 创建的不透明实例；FMI 2 `fmi2Component`，FMI 3 `fmi3Instance`。 |
| **Initialization Mode** | 初始化阶段；设置参数/初值，退出后进入步进/连续时间模式。 |
| **Event Mode** | 处理离散状态/事件的模式；迭代 `NewDiscreteStates` / `UpdateDiscreteStates`。 |
| **Continuous-Time Mode** | ME 中由主算法积分的模式。 |
| **Step Mode** | CS 中调用 `DoStep` 的模式。 |
| **DoStep** | CS 推进一步；返回状态、事件、终止、早退等信息。 |
| **Communication Step** | 主算法与 CS FMU 之间的步长。 |
| **Event Iteration** | 事件模式下反复更新离散状态，直到不再需要更新。 |
| **Intermediate Update** | CS 在通信步中间向主算法提供/请求变量。 |
| **Early Return** | FMI 3 CS 提前返回，`lastSuccessfulTime` 给出确认时间。 |
| **lastSuccessfulTime** | 最近一次成功推进的时间；用于 Discard/早退后的恢复。 |
| **Discard** | 该步被丢弃，状态可能不一致；主算法需回滚/重试。 |
| **FMU State** | FMU 内部状态的不透明句柄；可保存/恢复/序列化。 |
| **Serialized FMU State** | 状态序列化后的字节串；格式由 FMU 决定。 |
| **Directional Derivative** | 方向导数；可选能力。 |
| **resourcePath / fmuResourceLocation** | 指向 FMU 内 `resources/` 的位置。FMI 2 是 URI（`file://...`），FMI 3 是原生绝对路径（可空）。 |

---

## 4. ABI 与实现

| 术语 | 解释 |
| --- | --- |
| **ABI** | Application Binary Interface；函数调用、类型布局、符号、调用约定等二进制契约。 |
| **C ABI** | C 语言的二进制接口；FMI 的官方接口。 |
| **C shim** | 用 C 写的一层薄封装，处理结构体、回调、`size_t`、布尔等 ABI 细节。 |
| **calling convention** | 调用约定（参数传递、寄存器/栈、清理责任），如 `__cdecl`。 |
| **struct layout / alignment** | 结构体字段偏移与对齐；跨语言直接映射的主要风险。 |
| **opaque pointer** | 不透明指针；调用方不关心内部布局。 |
| **UTF-8 / UTF-16** | 字符编码；FMI 字符串用 UTF-8 + NUL，MoonBit `String` 内部为 UTF-16。 |
| **NUL-terminated** | 以 `\0` 结尾的 C 字符串。 |
| **Binary** | FMI 3 的字节串，带显式长度，不以 NUL 结尾。 |
| **size_t** | C 的无符号大小类型；32/64 位宽度不同。 |
| **mangling** | C++ 符号名修饰；FMI 用 `extern "C"` 避免。 |
| **symbol binding** | 从动态库解析 `fmi2*`/`fmi3*` 函数地址。 |
| **dlopen / LoadLibrary** | POSIX/Windows 动态库加载 API。 |

---

## 5. WebAssembly

| 术语 | 解释 |
| --- | --- |
| **WASM** | WebAssembly；可移植字节码。 |
| **core module** | 传统 wasm 模块；不是 Component Model component。 |
| **Component Model** | WASM 组件模型；带接口类型、资源、组合能力。 |
| **WIT** | WebAssembly Interface Types；描述 component 接口的语言。 |
| **world** | WIT 中的接口集合，定义 guest 导入/导出。 |
| **canonical ABI** | Component Model 定义的值如何跨边界传递（字符串、list、resource 等）。 |
| **resource** | Component Model 的可拥有句柄；LS-WASM 用来映射 FMI 实例。 |
| **guest / host** | 组件（FMU）/ 调用方（主算法/运行时）。 |
| **LS-WASM** | FMI Layered Standard for WASM；把 FMI 3 映射到 component。 |
| **wasm32-wasip2** | WASI Preview 2 的 wasm 目标；LS-WASM 平台目录。 |
| **jco** | 把 component 转译为 JS 的工具。 |
| **wasmtime** | 支持 component 的 native 运行时。 |
| **sandbox** | WASM 的隔离执行环境；只能访问显式导入的能力。 |

---

## 6. 解析与安全

| 术语 | 解释 |
| --- | --- |
| **XSD** | XML Schema Definition；描述 XML 结构/类型/顺序。 |
| **well-formed** | XML 语法正确；不等于符合 XSD。 |
| **semantic validation** | 跨字段/跨引用校验；XSD 无法表达。 |
| **pull parser** | 按事件逐个读取 XML 的解析器；内存占用低。 |
| **XXE** | XML External Entity；外部实体注入攻击。 |
| **DTD** | Document Type Definition；本项目默认拒绝。 |
| **Zip Slip** | 利用 `../` 等路径穿越解压目录的攻击。 |
| **Zip bomb** | 压缩比极高、解压后耗尽磁盘/内存的归档。 |
| **TOCTOU** | Time-of-check to time-of-use；检查与使用之间的竞态。 |
| **reproducible build** | 相同输入产生逐字节一致的产物。 |
| **SBOM** | Software Bill of Materials；依赖/组件清单。 |

---

## 7. 数值与仿真

| 术语 | 解释 |
| --- | --- |
| **ODE** | Ordinary Differential Equation；常微分方程。 |
| **DAE** | Differential-Algebraic Equation；微分代数方程。 |
| **state** | 连续状态变量；ME 中由主算法积分。 |
| **derivative** | 状态导数；FMI 2 用索引，FMI 3 用 `valueReference`。 |
| **integrator** | 数值积分器（Euler、RK4、变步长等）。 |
| **zero-crossing** | 事件指示器过零；事件检测的基础。 |
| **chattering** | 事件反复触发/震荡。 |
| **stiff** | 刚性系统；显式积分器需要极小步长。 |
| **tolerance** | 求解容差；初始化/积分使用。 |
| **nominal value** | 用于缩放的状态/变量标称值。 |
| **fixed step / adaptive step** | 固定步长/自适应步长。 |
| **dense output** | 步内插值输出；ME 高级能力。 |

---

## 8. 项目术语

| 术语 | 解释 |
| --- | --- |
| **MoonFMI** | 本项目：用 MoonBit 构建的 FMI 工具链。 |
| **core packages** | 跨 target 的纯 MoonBit 包：`zip`、`xml`、`schema`、`fmi`、`sim`。 |
| **backend** | 平台相关实现：`backend/native`、`backend/wasm`，按 `supported_targets` 隔离。 |
| **master algorithm** | 初始化、步进、事件、输入输出的调度器。 |
| **IR** | Intermediate Representation；导出器使用的模型中间表示。 |
| **MVP** | Minimum Viable Product；本项目指 P2 的 FMI 2 CS 导入。 |
| **DoD** | Definition of Done；任务完成标准。 |
| **spike** | 为验证技术可行性做的小型实验。 |
| **POC** | Proof of Concept；本文档中特指 WASM 工具链验证。 |

---

## 9. 相关文档

- 参考资料索引：[`README.md`](README.md)
- 外部链接：[`links.md`](links.md)
- 标准总览：[`../standards/fmi-overview.md`](../standards/fmi-overview.md)
- 设计索引：[`../design/README.md`](../design/README.md)
