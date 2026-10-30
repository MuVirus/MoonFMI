# FMI 标准概览

本文用实现者的视角梳理 FMI 的核心概念、FMU 的文件结构、三种接口类型，以及 FMI 2.0.4 与 3.0.2 的主要差异。具体的函数签名和字段定义分别见 [`fmi2-api.md`](fmi2-api.md)、[`fmi3-api.md`](fmi3-api.md)、[`model-description.md`](model-description.md)。

---

## 1. FMI 是什么

**FMI（Functional Mock-up Interface）** 是一个与工具无关的标准，用于交换和协同仿真动态系统模型。一个符合 FMI 的模型被打包成 **FMU（Functional Mock-up Unit）**，通常是一个 ZIP 文件，里面包含：

- `modelDescription.xml`：模型的元数据、变量、接口能力、结构信息。
- 二进制动态库（`binaries/`）：实现 FMI C API 的 `.dll` / `.so` / `.dylib`，或 WASM 模块。
- 源码（`sources/`，可选）：用于源码 FMU 的 C/C++ 源码。
- 资源（`resources/`，可选）：查表数据、配置文件等。
- 文档（`documentation/`，可选）。
- 扩展（`extra/`，FMI 3）：分层标准（layered standard）的附加文件。

FMI 只规定**接口和行为**，不规定模型内部如何实现。因此同一个 FMU 可以被不同仿真工具加载，只要它们遵守相同的 API 和状态机。

### 1.1 角色

| 角色 | 职责 |
| --- | --- |
| FMU 提供方 | 生成 `modelDescription.xml` 和实现 FMI API 的动态库/源码 |
| 导入工具（importer） | 加载 FMU、解析模型描述、调用 C API、驱动仿真 |
| 主算法（master algorithm） | 决定步长、输入输出、事件处理、结果记录 |
| 导出工具（exporter） | 把模型包装成 FMU |
| 交叉检查工具 | 用多个导入器/导出器验证互操作性 |

MoonFMI 同时定位为**导入工具 + 主算法 + 导出工具**，但分阶段实现。

---

## 2. 三种接口类型

FMI 2.0 定义两种接口，FMI 3.0 增加第三种。

### 2.1 Model Exchange（ME）

FMU 只提供**连续时间模型**（状态、导数、事件指示器），不包含积分器。导入工具负责：

- 提供数值积分器；
- 设置时间、连续状态；
- 获取导数、事件指示器；
- 处理事件迭代（event iteration）；
- 在事件后重新初始化。

ME 适合需要自定义求解器、联合仿真精度要求高的场景。导入工具的实现复杂度最高。

### 2.2 Co-Simulation（CS）

FMU 自带**求解器/通信步进逻辑**，导入工具只需要：

- 设置输入；
- 调用 `DoStep` 推进到下一个通信点；
- 读取输出；
- 处理可能的事件模式、early return、intermediate update（FMI 3）。

CS 是工具间联合仿真最常用的形式，也是 MoonFMI 首个导入目标。

### 2.3 Scheduled Execution（SE，仅 FMI 3）

FMU 暴露**模型分区（model partition）**和**时钟（clock）**，由外部调度器按时钟激活分区：

- FMU 不控制时间推进；
- 调度器决定哪个分区在什么时刻执行；
- 适合实时系统、时钟同步、任务调度类模型。

SE 的实现依赖 Clock 语义和 `fmi3ActivateModelPartition`，建议在 FMI 3 CS/ME 稳定后再做。

---

## 3. FMU 的文件结构

### 3.1 FMI 2.0

```text
MyModel.fmu
├── modelDescription.xml
├── binaries/
│   ├── win32/MyModel.dll
│   ├── win64/MyModel.dll
│   ├── linux32/MyModel.so
│   ├── linux64/MyModel.so
│   ├── darwin32/MyModel.dylib
│   └── darwin64/MyModel.dylib
├── sources/
│   ├── MyModel.c
│   └── ...
├── resources/
│   └── ...
└── documentation/
    └── index.html
```

FMI 2 的平台目录是固定的几个名称。实际存在的目录取决于 FMU 支持哪些平台；导入器应选择与当前进程匹配的目录，并给出清晰的“不支持当前平台”错误。

### 3.2 FMI 3.0

```text
MyModel.fmu
├── modelDescription.xml
├── buildDescription.xml          # 可选，源码 FMU 的构建描述
├── binaries/
│   ├── x86_64-linux/MyModel.so
│   ├── aarch64-linux/MyModel.so
│   ├── x86_64-windows/MyModel.dll
│   ├── aarch64-windows/MyModel.dll
│   ├── x86_64-darwin/MyModel.dylib
│   ├── aarch64-darwin/MyModel.dylib
│   └── wasm32-wasip2/MyModel.wasm   # FMI-LS-WASM
├── sources/
├── resources/
├── documentation/
├── terminalsAndIcons/            # 可选，终端与图标
└── extra/
    └── org.modelica.fmi-ls-wasm/
        └── manifest.xml
```

FMI 3 的平台标识更接近目标三元组（target triple），并允许分层标准定义额外的目录（例如 WASM）。导入器不应硬编码完整的平台列表，而应：

1. 枚举 `binaries/` 下的目录；
2. 用“当前 OS + 架构 + 运行时能力”匹配；
3. 对无法识别的目录忽略，而不是报错。

### 3.3 路径规则

- ZIP 内路径统一使用 `/`。
- 路径相对于 FMU 根目录。
- 不允许绝对路径、`..` 越界、盘符、NUL 字符。
- 大小写敏感性取决于宿主文件系统；解析时不要依赖大小写。
- `modelIdentifier` 用于拼接二进制文件名，必须做安全校验（禁止路径分隔符、`..` 等）。

---

## 4. `modelDescription.xml` 的角色

它是 FMU 的“自描述清单”，导入器在加载二进制之前必须先解析它。核心内容包括：

| 部分 | 作用 |
| --- | --- |
| 根属性 | `fmiVersion`、`modelName`、`guid`/`instantiationToken`、生成工具、命名约定等 |
| 接口元素 | `ModelExchange` / `CoSimulation` / `ScheduledExecution`，声明能力与 `modelIdentifier` |
| `UnitDefinitions` | 单位定义，供变量引用 |
| `TypeDefinitions` | 命名类型（Real/Integer/... 或 Float64/Int32/...） |
| `LogCategories` | 日志类别 |
| `DefaultExperiment` | 默认起止时间、容差、步长 |
| `ModelVariables` | 变量列表，顺序即索引（从 1 开始） |
| `ModelStructure` | 输出、状态导数、初始未知量、事件指示器等的依赖关系 |
| `VendorAnnotations` / `Annotations` | 工具特定信息，标准不解释 |

解析器必须保留**元素顺序**和**变量顺序**：FMI 2 的 `ScalarVariable` 顺序决定索引，`ModelStructure` 中的依赖用索引引用变量。

---

## 5. FMI 2.0.4 与 3.0.2 的主要差异

| 维度 | FMI 2.0.4 | FMI 3.0.2 |
| --- | --- | --- |
| 接口类型 | ME、CS | ME、CS、SE |
| 实例标识 | `guid` | `instantiationToken` |
| 变量类型 | Real、Integer、Boolean、String、Enumeration | Float32、Float64、Int8/16/32/64、UInt8/16/32/64、Boolean、String、Binary、Enumeration、Clock |
| 数组 | 不支持（用多个标量变量表达） | 支持 `Dimension`，可静态或由结构参数决定 |
| 别名 | 不支持 | `Alias` 元素，多个名字共享 `valueReference` |
| 时钟 | 无 | Clock 变量、时钟化状态、SE |
| 二进制 | 无 | `Binary` 类型，带 `mimeType`、`maxSize` |
| 实例化 API | 单一 `fmi2Instantiate` | 按接口分为 `fmi3InstantiateModelExchange` / `CoSimulation` / `ScheduledExecution` |
| 回调 | `fmi2CallbackFunctions` 结构体 | 实例化时分别传 `logMessage`、`logCategories`、`intermediateUpdate`、`clockUpdate` 等回调 |
| 布尔类型 | `int` | `bool` |
| 状态码 | OK/Warning/Discard/Error/Fatal/Pending | OK/Warning/Discard/Error/Fatal（无 Pending） |
| 异步/回退 | `fmi2DoStep` + `fmi2CancelStep` + `fmi2GetStatus` | early return + intermediate update + `fmi3GetInterval...` |
| 配置模式 | 无 | `fmi3EnterConfigurationMode` / `Exit`，可改结构参数 |
| 导数 | 仅方向导数 | 方向导数 + 伴随导数 |
| 变量依赖查询 | 无 | `fmi3GetNumberOfVariableDependencies` / `fmi3GetVariableDependencies` |
| 构建描述 | 无 | `buildDescription.xml` |
| 分层标准 | 有限 | `extra/` 目录与 manifest |

### 5.1 兼容性策略

MoonFMI 不应试图用一套“万能 API”抹平 2.0 和 3.0 的差异。推荐：

- **公共层**：变量元数据、单位、类型、诊断、FMU 容器、值容器（`Value`）。
- **版本层**：`fmi2` 和 `fmi3` 各自的状态机、函数表、实例类型。
- **门面层**：`Fmu` / `Instance` 枚举，按版本分派；调用方可以选择只用版本层。

这样既避免抽象泄漏，又能在主算法中复用大部分逻辑。

---

## 6. 典型执行流程

### 6.1 Co-Simulation

```text
打开 FMU（zip）
  → 解析 modelDescription.xml
  → 校验 + 选择平台
  → 加载动态库
  → 解析 fmi2*/fmi3* 符号
  → Instantiate
  → SetupExperiment（FMI 2） / EnterInitializationMode（FMI 3 带参数）
  → 设置参数/输入
  → ExitInitializationMode
  → 循环：
       设置输入
       DoStep / fmi3DoStep
       读取输出
       记录结果
  → Terminate
  → FreeInstance
```

### 6.2 Model Exchange

```text
初始化（同上）
  → EnterContinuousTimeMode
  → 循环：
       设置时间、连续状态
       获取导数
       积分器推进
       检测事件指示器过零
       如有事件：
         EnterEventMode
         NewDiscreteStates / UpdateDiscreteStates
         读取离散状态/输出
         回到连续时间模式
  → Terminate
  → FreeInstance
```

### 6.3 Scheduled Execution

```text
初始化
  → 注册时钟/分区
  → 循环：
       推进全局时间
       对到期的分区调用 ActivateModelPartition
       读取输出/更新时钟
  → Terminate
  → FreeInstance
```

---

## 7. 分层标准（Layered Standards）

FMI 3 允许在核心标准之上定义**分层标准**，通过 FMU 的 `extra/` 目录携带附加文件。常见的有：

- **FMI-LS-BUS**：总线仿真（CAN、LIN 等）。
- **FMI-LS-WASM**：把 FMI 3 API 映射到 WebAssembly Component Model。
- **SSP**：系统结构参数化（不是 FMI 的分层标准，但常与 FMI 一起使用）。

MoonFMI 的关注点：

- 核心导入器只处理 FMI 核心标准，分层标准作为可选扩展。
- WASM 是唯一会深度影响架构的分层标准，单独在 [`../research/wasm-fmi.md`](../research/wasm-fmi.md) 和 [`../design/wasm-strategy.md`](../design/wasm-strategy.md) 讨论。
- 遇到未知的 `extra/` 内容应忽略，不应导致加载失败。

---

## 8. 范围决策

| 项目 | 决策 | 理由 |
| --- | --- | --- |
| FMI 1.0 | 不支持 | API 差异大，生态占比低，维护成本高 |
| FMI 2.0.4 | 支持 | 存量 FMU 最多，工具兼容性最好 |
| FMI 3.0.2 | 支持 | 新标准，数组/时钟/WASM 的基础 |
| ME | 第二阶段 | 需要积分器和事件处理，复杂度高 |
| CS | 第一阶段 | 主算法简单，覆盖面广 |
| SE | 第三阶段 | 依赖 Clock 语义，使用场景较窄 |
| Native 导入 | 第一阶段 | 生态最成熟，测试语料最多 |
| WASM 导入 | 第三阶段 | 浏览器场景有价值，但工具链待验证 |
| Native 导出 | 暂缓 | MoonBit 不能直接导出动态库 |
| 源码 FMU 导出 | 第二阶段 | 可行，能复用 C 后端 |
| WASM FMU 导出 | 第三阶段 | 差异化最大，但需要 POC |

---

## 9. 延伸阅读

- FMI 2.0.4 规范与头文件：[`fmi2-api.md`](fmi2-api.md)
- FMI 3.0.2 规范与头文件：[`fmi3-api.md`](fmi3-api.md)
- 模型描述字段与语义：[`model-description.md`](model-description.md)
- 官方资料链接：[`../references/links.md`](../references/links.md)
