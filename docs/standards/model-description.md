# `modelDescription.xml` 解析与语义

`modelDescription.xml` 是 FMU 的元数据清单，导入器在加载二进制之前必须完整解析它。本文覆盖 FMI 2.0.4 与 FMI 3.0.2 的结构、字段、默认值和常见语义陷阱。XSD 原文见 [`schemas/`](schemas/)。

---

## 1. 总体结构

### 1.1 FMI 2.0

```xml
<?xml version="1.0" encoding="UTF-8"?>
<fmiModelDescription
    fmiVersion="2.0"
    modelName="BouncingBall"
    guid="{8c4e...}"
    generationTool="..."
    variableNamingConvention="flat">
  <CoSimulation modelIdentifier="BouncingBall" canHandleVariableCommunicationStepSize="true"/>
  <UnitDefinitions>...</UnitDefinitions>
  <TypeDefinitions>...</TypeDefinitions>
  <LogCategories>...</LogCategories>
  <DefaultExperiment startTime="0" stopTime="3" stepSize="0.01"/>
  <VendorAnnotations>...</VendorAnnotations>
  <ModelVariables>
    <ScalarVariable name="h" valueReference="0" causality="output" variability="continuous" initial="exact">
      <Real start="1" unit="m"/>
    </ScalarVariable>
    ...
  </ModelVariables>
  <ModelStructure>
    <Outputs>
      <Unknown index="1"/>
    </Outputs>
    <Derivatives>...</Derivatives>
    <InitialUnknowns>...</InitialUnknowns>
  </ModelStructure>
</fmiModelDescription>
```

元素顺序是固定的（XSD `xs:sequence`）：

```text
(ModelExchange | CoSimulation){1,2}
UnitDefinitions?
TypeDefinitions?
LogCategories?
DefaultExperiment?
VendorAnnotations?
ModelVariables
ModelStructure
```

至少要有 `ModelExchange` 或 `CoSimulation` 之一；二者可以同时存在。

### 1.2 FMI 3.0

```xml
<?xml version="1.0" encoding="UTF-8"?>
<fmiModelDescription
    fmiVersion="3.0"
    modelName="BouncingBall"
    instantiationToken="{8c4e...}"
    generationTool="..."
    variableNamingConvention="flat">
  <CoSimulation modelIdentifier="BouncingBall" canHandleVariableCommunicationStepSize="true"/>
  <UnitDefinitions>...</UnitDefinitions>
  <TypeDefinitions>...</TypeDefinitions>
  <LogCategories>...</LogCategories>
  <DefaultExperiment startTime="0" stopTime="3" stepSize="0.01"/>
  <ModelVariables>
    <Float64 name="h" valueReference="0" causality="output" variability="continuous" initial="exact" start="1" unit="m"/>
    ...
  </ModelVariables>
  <ModelStructure>
    <Output valueReference="0"/>
    <ContinuousStateDerivative valueReference="1"/>
    <InitialUnknown valueReference="0"/>
    <EventIndicator valueReference="2"/>
  </ModelStructure>
  <Annotations>...</Annotations>
</fmiModelDescription>
```

元素顺序：

```text
ModelExchange?
CoSimulation?
ScheduledExecution?
UnitDefinitions?
TypeDefinitions?
LogCategories?
DefaultExperiment?
ModelVariables
ModelStructure?
Annotations?
```

FMI 3 的 `ModelVariables` 和 `ModelStructure` 都是必需的（`ModelStructure` 在 XSD 中是必需的，即使为空也应出现）。

---

## 2. 根元素属性

### 2.1 FMI 2.0

| 属性 | 必填 | 类型 | 说明 |
| --- | --- | --- | --- |
| `fmiVersion` | 是 | 固定 `"2.0"` | 2.0.x 都写 `"2.0"` |
| `modelName` | 是 | string | 模型类名，可含 `.` |
| `guid` | 是 | normalizedString | 模型描述与二进制兼容性的指纹 |
| `description` | 否 | string | |
| `author` | 否 | string | |
| `version` | 否 | normalizedString | FMU 版本 |
| `copyright` | 否 | string | |
| `license` | 否 | string | |
| `generationTool` | 否 | normalizedString | |
| `generationDateAndTime` | 否 | dateTime | |
| `variableNamingConvention` | 否 | `flat` / `structured`，默认 `flat` | 变量命名约定 |
| `numberOfEventIndicators` | 否 | unsignedInt | ME 的事件指示器数量 |

### 2.2 FMI 3.0

| 属性 | 必填 | 类型 | 说明 |
| --- | --- | --- | --- |
| `fmiVersion` | 是 | 匹配 `3.x` 的字符串 | 例如 `"3.0"` |
| `modelName` | 是 | string | |
| `instantiationToken` | 是 | normalizedString | 取代 FMI 2 的 `guid` |
| `description` | 否 | string | |
| `author` | 否 | string | |
| `version` | 否 | normalizedString | |
| `copyright` | 否 | string | |
| `license` | 否 | string | |
| `generationTool` | 否 | normalizedString | |
| `generationDateAndTime` | 否 | dateTime | |
| `variableNamingConvention` | 否 | `flat` / `structured`，默认 `flat` | |

FMI 3 没有根级的 `numberOfEventIndicators`；事件指示器在 `ModelStructure/EventIndicator` 中按变量声明。

### 2.3 `fmiVersion` 的解析

- FMI 2：XSD 固定为 `"2.0"`，但实际文件可能写 `"2.0.4"`？规范要求写 `"2.0"`。解析器应接受 `"2.0"` 及可选的补丁后缀，并记录原始值。
- FMI 3：XSD 允许 `3.0`、`3.1`、`3.0.2` 等。解析器应按主版本分派，再按次版本做能力检查。
- 不要用字符串相等判断 `"3.0"`；用语义版本比较。

---

## 3. 接口元素与能力标志

### 3.1 FMI 2

`ModelExchange` 和 `CoSimulation` 共有的属性：

| 属性 | 默认 | 说明 |
| --- | --- | --- |
| `modelIdentifier` | 必填 | 二进制文件名/符号前缀 |
| `needsExecutionTool` | false | 需要外部执行工具 |
| `canBeInstantiatedOnlyOncePerProcess` | false | 每进程只能实例化一次 |
| `canNotUseMemoryManagementFunctions` | false | 不能使用宿主的内存分配回调 |
| `canGetAndSetFMUstate` | false | 支持状态存取 |
| `canSerializeFMUstate` | false | 支持状态序列化 |
| `providesDirectionalDerivative` | false | 支持方向导数 |

`ModelExchange` 额外：

| 属性 | 默认 | 说明 |
| --- | --- | --- |
| `completedIntegratorStepNotNeeded` | false | 不需要 `CompletedIntegratorStep` |

`CoSimulation` 额外：

| 属性 | 默认 | 说明 |
| --- | --- | --- |
| `canHandleVariableCommunicationStepSize` | false | 支持变步长 |
| `canInterpolateInputs` | false | 支持输入插值 |
| `maxOutputDerivativeOrder` | 0 | 输出导数最大阶数 |
| `canRunAsynchronuously` | false | 支持异步（注意官方拼写是 `Asynchronuously`） |

> `canRunAsynchronuously` 的拼写是历史遗留，解析时必须按原样匹配。不要“修正”成 `Asynchronously`。

### 3.2 FMI 3

`fmi3InterfaceType` 共有：

| 属性 | 默认 | 说明 |
| --- | --- | --- |
| `modelIdentifier` | 必填 | |
| `needsExecutionTool` | false | |
| `canBeInstantiatedOnlyOncePerProcess` | false | |
| `canGetAndSetFMUState` | false | |
| `canSerializeFMUState` | false | |
| `providesDirectionalDerivatives` | false | 注意复数 |
| `providesAdjointDerivatives` | false | |
| `providesPerElementDependencies` | false | 支持数组逐元素依赖 |

`ModelExchange` 额外：

| 属性 | 默认 | 说明 |
| --- | --- | --- |
| `needsCompletedIntegratorStep` | false | |
| `providesEvaluateDiscreteStates` | false | |

`CoSimulation` 额外：

| 属性 | 默认 | 说明 |
| --- | --- | --- |
| `canHandleVariableCommunicationStepSize` | false | |
| `fixedInternalStepSize` | 无 | 固定内部步长 |
| `maxOutputDerivativeOrder` | 0 | |
| `recommendedIntermediateInputSmoothness` | 0 | |
| `providesIntermediateUpdate` | false | |
| `mightReturnEarlyFromDoStep` | false | |
| `canReturnEarlyAfterIntermediateUpdate` | false | |
| `hasEventMode` | false | |
| `providesEvaluateDiscreteStates` | false | |

`ScheduledExecution` 目前没有额外属性。

### 3.3 能力标志的使用原则

- 能力标志是**声明**，不是保证。实际调用仍要处理 `fmi3Discard`/`fmi2Discard` 和错误。
- 不要因为 `canGetAndSetFMUstate=false` 就完全不实现状态 API；可以在调用前检查并返回“不支持”。
- `modelIdentifier` 必须做安全校验：只允许字母、数字、下划线，禁止 `/`、`\`、`..`、`:`、NUL。

---

## 4. 变量定义

### 4.1 公共属性

FMI 2 的 `ScalarVariable` 和 FMI 3 的各类型变量共享一组语义属性：

| 属性 | 必填 | 取值 | 说明 |
| --- | --- | --- | --- |
| `name` | 是 | normalizedString | 变量名，在 `ModelVariables` 中唯一 |
| `valueReference` | 是 | unsignedInt / uint32 | 运行时句柄；FMI 2 不要求全局唯一，FMI 3 通常唯一（别名除外） |
| `description` | 否 | string | |
| `causality` | 否 | `parameter`、`calculatedParameter`、`input`、`output`、`local`、`independent`（FMI 3 加 `structuralParameter`） | 默认 `local` |
| `variability` | 否 | `constant`、`fixed`、`tunable`、`discrete`、`continuous` | FMI 2 默认 `continuous`；FMI 3 无默认值，需按规范推导 |
| `initial` | 否 | `exact`、`approx`、`calculated` | 省略时按 `causality`/`variability` 推导 |
| `canHandleMultipleSetPerTimeInstant` | 否 | boolean | 仅 ME 输入，是否允许同一时刻多次设置 |

### 4.2 类型专属属性

#### FMI 2

| 元素 | 专属属性 |
| --- | --- |
| `Real` | `declaredType`、`quantity`、`unit`、`displayUnit`、`relativeQuantity`、`min`、`max`、`nominal`、`unbounded`、`start`、`derivative`、`reinit` |
| `Integer` | `declaredType`、`quantity`、`min`、`max`、`start` |
| `Boolean` | `declaredType`、`start` |
| `String` | `declaredType`、`start` |
| `Enumeration` | `declaredType`（必填）、`quantity`、`min`、`max`、`start` |

#### FMI 3

| 元素 | 专属属性 |
| --- | --- |
| `Float32` / `Float64` | `declaredType`、`quantity`、`unit`、`displayUnit`、`relativeQuantity`、`unbounded`、`min`、`max`、`nominal`、`start`（列表）、`derivative`、`reinit` |
| `Int8` ... `UInt64` | `declaredType`、`quantity`、`min`、`max`、`start`（列表） |
| `Boolean` | `declaredType`、`start`（列表） |
| `String` | `declaredType`、`Start` 子元素（`value`） |
| `Binary` | `declaredType`、`mimeType`、`maxSize`、`Start` 子元素（`hexBinary`） |
| `Enumeration` | `declaredType`（必填）、`quantity`、`min`、`max`、`start`（列表） |
| `Clock` | `declaredType`、`canBeDeactivated`、`priority`、`intervalVariability`（必填）、`intervalDecimal`、`shiftDecimal`、`supportsFraction`、`resolution`、`intervalCounter`、`shiftCounter` |

### 4.3 FMI 3 的数组

FMI 3 变量可以带多个 `Dimension`：

```xml
<Float64 name="matrix" valueReference="10" causality="output" variability="continuous">
  <Dimension start="3"/>
  <Dimension valueReference="11"/>
</Float64>

<UInt32 name="n" valueReference="11" causality="structuralParameter"
        variability="fixed" start="4"/>
```

规则：

- `Dimension start`：固定维度。
- `Dimension valueReference`：维度由结构参数决定；该参数必须是 `causality="structuralParameter"`。
- 数组变量的 `valueReference` 仍是一个标量句柄，但 Get/Set 时 `nValues` 是元素总数。
- 维度可以是多维的，按行优先/列优先的顺序由规范定义；实现必须与 FMU 一致，不能自行假设。
- 数组元素可以单独声明依赖（`dependencies` 指向元素索引），需要 `providesPerElementDependencies=true`。

### 4.4 FMI 3 的别名

```xml
<Float64 name="speed" valueReference="20" ...>
  <Alias name="v" description="velocity alias"/>
</Float64>
```

- 别名共享同一个 `valueReference`。
- 别名有独立的 `name`，但运行时读写同一个值。
- 解析器应建立 `name -> Variable` 和 `valueReference -> Variable` 两张索引；别名指向同一个变量对象。
- 输出 `modelDescription.xml` 时，别名不能重复定义 `valueReference` 的另一份变量。

### 4.5 `causality` / `variability` / `initial` 的组合

这三个属性共同决定变量在初始化、事件、步进中的行为。常见的有效组合：

| causality | variability | initial | 含义 |
| --- | --- | --- | --- |
| `parameter` | `fixed` / `tunable` | `exact` | 参数，初始化时设置 |
| `calculatedParameter` | `fixed` / `tunable` | `calculated` | 由其他变量计算 |
| `input` | `discrete` / `continuous` | `exact` | 外部输入 |
| `output` | `constant` / `fixed` | `exact` | 输出，初始化时确定 |
| `output` | `discrete` / `continuous` | `calculated` / `approx` | 运行时计算 |
| `local` | `constant` / `fixed` | `exact` | 内部常量/固定量 |
| `local` | `discrete` / `continuous` | `calculated` / `approx` | 内部计算量 |
| `independent` | `continuous` | 通常省略 | 自变量（通常是时间） |
| `structuralParameter`（FMI 3） | `fixed` / `tunable` | `exact` | 结构参数 |

注意：

- `initial="exact"` 表示初始化时必须用 `start` 值；`approx` 表示迭代初值；`calculated` 表示由 FMU 计算。
- 省略 `initial` 时，不能一律当 `exact`。必须按规范表格推导；不同 `causality`/`variability` 组合的默认值不同。
- `independent` 变量通常只有一个，且不应有 `start` 以外的初始化语义。
- `constant` 变量在初始化后不能改变；`fixed` 在初始化后固定；`tunable` 可在外部事件间改变；`discrete` 在内部事件间不变；`continuous` 可连续变化。

### 4.6 状态、导数与事件

- FMI 2 中，`Real` 变量的 `derivative` 属性指向“它是哪个变量的导数”，值是目标变量的 `ScalarVariable` 索引（从 1 开始），不是 `valueReference`。
- FMI 2 的 `reinit=true` 表示该连续状态可以在事件时被 FMU 重新初始化。
- FMI 3 中，`derivative` 同样指向变量，但使用 `valueReference`；`reinit` 语义类似。
- FMI 3 的 `ModelStructure/ContinuousStateDerivative` 列出所有暴露的连续状态导数。
- FMI 3 的 `ClockedState` 列出时钟化状态。
- FMI 3 的 `EventIndicator` 列出事件指示器变量。

> FMI 2 的 `derivative` 用“索引”，FMI 3 的依赖/结构元素用“valueReference”。这是解析器最容易混淆的差异之一。

---

## 5. 类型定义

### 5.1 FMI 2 `TypeDefinitions/SimpleType`

```xml
<TypeDefinitions>
  <SimpleType name="Temperature">
    <Real quantity="Temperature" unit="K" min="0" nominal="300"/>
  </SimpleType>
  <SimpleType name="Mode">
    <Enumeration>
      <Item name="Off" value="0"/>
      <Item name="On" value="1"/>
    </Enumeration>
  </SimpleType>
</TypeDefinitions>
```

规则：

- `SimpleType` 的 `name` 在类型定义中唯一，且不能与任何变量名冲突。
- 变量通过 `declaredType` 引用类型，继承类型上的默认值/约束。
- 变量自身的属性覆盖类型默认值。
- `Enumeration` 的 `Item value` 在同一枚举中唯一。

### 5.2 FMI 3 `TypeDefinitions`

FMI 3 的类型定义元素是 `Float32Type`、`Float64Type`、`Int8Type`、...、`UInt64Type`、`BooleanType`、`StringType`、`BinaryType`、`EnumerationType`、`ClockType`。

```xml
<TypeDefinitions>
  <Float64Type name="Temperature" quantity="Temperature" unit="K" min="0" nominal="300"/>
  <EnumerationType name="Mode">
    <Item name="Off" value="0"/>
    <Item name="On" value="1"/>
  </EnumerationType>
</TypeDefinitions>
```

`Float64Type` 直接带 `quantity`、`unit`、`min`、`max` 等属性，没有嵌套的 `<Float64>` 子元素；`EnumerationType` 的 `Item` 是子元素。

规则：

- `EnumerationType` 必须有至少一个 `Item`，`value` 唯一。
- `BinaryType` 可带 `mimeType`、`maxSize`。
- `ClockType` 带 Clock 属性组。
- 变量通过 `declaredType` 引用类型名。

---

## 6. 单位

### 6.1 FMI 2 `UnitDefinitions/Unit`

```xml
<UnitDefinitions>
  <Unit name="m">
    <BaseUnit m="1"/>
  </Unit>
  <Unit name="km">
    <BaseUnit m="1" factor="1000"/>
    <DisplayUnit name="km" factor="1"/>
  </Unit>
</UnitDefinitions>
```

| 元素/属性 | 说明 |
| --- | --- |
| `Unit name` | 单位名，变量通过 `unit` 引用 |
| `BaseUnit` | 基本单位指数：`kg`、`m`、`s`、`A`、`K`、`mol`、`cd`、`rad`，默认 0 |
| `BaseUnit factor` / `offset` | 与基本单位的换算 |
| `DisplayUnit name` | 显示单位名 |
| `DisplayUnit factor` / `offset` | 显示换算 |

### 6.2 FMI 3

FMI 3 的单位结构与 FMI 2 基本一致，`DisplayUnit` 增加 `inverse` 属性，且可以有多个 `DisplayUnit`。`Unit` 和 `DisplayUnit` 都可以带 `Annotations`。

换算公式（FMI 2/3 通用）：

```text
value_in_display = (value_in_unit - offset) / factor
value_in_unit    = value_in_display * factor + offset
```

具体以规范定义为准；`relativeQuantity=true` 时忽略 `offset`。

---

## 7. 模型结构

### 7.1 FMI 2 `ModelStructure`

```xml
<ModelStructure>
  <Outputs>
    <Unknown index="1"/>
    <Unknown index="3" dependencies="1 2" dependenciesKind="dependent dependent"/>
  </Outputs>
  <Derivatives>
    <Unknown index="2"/>
  </Derivatives>
  <InitialUnknowns>
    <Unknown index="1"/>
  </InitialUnknowns>
</ModelStructure>
```

| 元素 | 内容 |
| --- | --- |
| `Outputs` | 所有 `causality="output"` 的变量，顺序与变量索引一致 |
| `Derivatives` | 所有暴露的连续状态导数（ME） |
| `InitialUnknowns` | 初始化模式下的未知量，按变量索引排序，不能重复 |

`Unknown` 的属性：

- `index`：变量的 `ScalarVariable` 索引（从 1 开始）。
- `dependencies`：依赖的变量索引列表，升序。
- `dependenciesKind`：与 `dependencies` 等长，取值 `dependent`、`constant`、`fixed`、`tunable`、`discrete`。

省略 `dependencies` 表示“依赖所有已知量”；空列表表示“不依赖任何已知量”。

### 7.2 FMI 3 `ModelStructure`

```xml
<ModelStructure>
  <Output valueReference="0"/>
  <ContinuousStateDerivative valueReference="1"/>
  <ClockedState valueReference="2"/>
  <InitialUnknown valueReference="0"/>
  <EventIndicator valueReference="3"/>
</ModelStructure>
```

子元素顺序固定为：

```text
Output*
ContinuousStateDerivative*
ClockedState*
InitialUnknown*
EventIndicator*
```

`fmi3Unknown` 的属性：

- `valueReference`：变量句柄。
- `dependencies`：依赖的 `valueReference` 列表。
- `dependenciesKind`：`dependent`、`constant`、`fixed`、`tunable`、`discrete`。

FMI 3 允许逐元素依赖：如果变量是数组，`dependencies` 可以指向具体元素索引，配合 `providesPerElementDependencies`。

---

## 8. 日志类别与默认实验

### 8.1 `LogCategories`

```xml
<LogCategories>
  <Category name="logEvents" description="..."/>
</LogCategories>
```

- `Category name` 唯一。
- 标准类别名包括 `logEvents`、`logSingularLinearSystems`、`logNonlinearSystems`、`logDynamicStateSelection`、`logStatusWarning`、`logStatusDiscard`、`logStatusError`、`logStatusFatal`、`logStatusPending`、`logAll`。
- 宿主通过 `SetDebugLogging` 选择类别；未知类别应忽略或报警，不应失败。

### 8.2 `DefaultExperiment`

| 属性 | 含义 |
| --- | --- |
| `startTime` | 默认开始时间 |
| `stopTime` | 默认结束时间 |
| `tolerance` | 默认相对容差 |
| `stepSize` | 默认步长（ME 固定步长 / CS 通信步长） |

这些值只是建议，宿主可以覆盖。缺少 `stopTime` 时不要假设无限仿真，应在 UI/CLI 中要求用户提供。

---

## 9. 解析流程建议

```text
读取 XML（UTF-8，保留位置）
  → 检查根元素名 fmiModelDescription
  → 读取 fmiVersion，分派 FMI 2 / FMI 3
  → 解析根属性
  → 解析接口元素（至少一个；记录能力）
  → 解析 UnitDefinitions / TypeDefinitions
  → 解析 LogCategories / DefaultExperiment
  → 解析 ModelVariables（保持顺序）
  → 解析 ModelStructure（校验引用）
  → 解析 Annotations（原样保留）
  → 语义校验
  → 构建索引：name -> var, valueReference -> var, index -> var (FMI 2)
```

### 9.1 解析器的数据结构

```moonbit
enum FmiVersion {
  V2
  V3
}

struct ModelDescription {
  version : FmiVersion
  model_name : String
  instantiation_token : String
  interfaces : Array[Interface]
  units : Map[String, Unit]
  types : Map[String, TypeDefinition]
  variables : Array[Variable]       // 保持文档顺序
  structure : ModelStructure
  annotations : XmlNode
}
```

`Variable` 建议用枚举表达类型：

```moonbit
enum VariableType {
  Float32
  Float64
  Int8
  UInt8
  Int16
  UInt16
  Int32
  UInt32
  Int64
  UInt64
  Boolean
  String
  Binary
  Enumeration
  Clock
}
```

不要用“一个结构体 + 大量可选字段”表达所有类型；类型专属字段用子结构或枚举载荷，减少无效状态。

### 9.2 顺序与索引

- FMI 2：`ModelVariables/ScalarVariable` 的顺序决定索引（第一个为 1）。必须保留顺序。
- FMI 3：变量顺序不再用于 `ModelStructure` 引用（用 `valueReference`），但仍应保留，便于输出和调试。
- `ModelStructure` 中的引用必须在解析后统一解析，不能边解析边假设顺序。

### 9.3 默认值

XSD 的 `default` 属性不会自动被所有解析器应用。实现必须在类型化模型构建阶段显式填充默认值：

- `causality` 默认 `local`。
- FMI 2 `variability` 默认 `continuous`。
- FMI 3 `variability` 无默认值（按规范语义处理）。
- `relativeQuantity`、`unbounded`、`reinit`、`canBeDeactivated`、`supportsFraction` 等默认 `false`。
- `factor` 默认 `1`，`offset` 默认 `0`。
- `mimeType` 默认 `application/octet-stream`。
- `variableNamingConvention` 默认 `flat`。

建议在解析层保留“是否显式提供”，在语义层再填默认值，这样诊断信息可以区分“用户写了 false”和“默认 false”。

---

## 10. 语义校验规则

XSD 只能保证结构和枚举值合法。以下规则必须由语义校验器实现。规则编号供实现和测试引用。

### 10.1 根与接口

| 编号 | 规则 | 严重级别 |
| --- | --- | --- |
| MD-001 | 根元素必须是 `fmiModelDescription` | error |
| MD-002 | `fmiVersion` 必须是支持的 2.0.x 或 3.0.x | error |
| MD-003 | 至少有一个接口元素（FMI 2：ME/CS；FMI 3：ME/CS/SE） | error |
| MD-004 | 每个接口的 `modelIdentifier` 非空且安全 | error |
| MD-005 | `modelName` 非空 | error |
| MD-006 | FMI 2 的 `guid` / FMI 3 的 `instantiationToken` 非空 | error |
| MD-007 | `variableNamingConvention` 只能是 `flat`/`structured` | error |

### 10.2 变量

| 编号 | 规则 | 严重级别 |
| --- | --- | --- |
| MD-010 | 变量 `name` 在 `ModelVariables` 中唯一（别名单独处理） | error |
| MD-011 | `valueReference` 在非别名变量中唯一（FMI 3） | error |
| MD-012 | `causality`/`variability`/`initial` 组合合法 | error |
| MD-013 | `initial="exact"` 的变量应有 `start`（或类型默认值） | warning |
| MD-014 | `min <= max`，`nominal > 0` | error |
| MD-015 | `Enumeration` 必须有 `declaredType`，且类型存在 | error |
| MD-016 | `declaredType` 引用的类型存在，且类型匹配 | error |
| MD-017 | `derivative` 引用的变量存在，且类型兼容 | error |
| MD-018 | `reinit=true` 只能用于连续状态 | error |
| MD-019 | `canHandleMultipleSetPerTimeInstant` 只能用于 ME 输入 | error |
| MD-020 | 别名 `name` 唯一，且不能与普通变量名冲突 | error |

### 10.3 数组与时钟（FMI 3）

| 编号 | 规则 | 严重级别 |
| --- | --- | --- |
| MD-030 | `Dimension` 的 `start` 与 `valueReference` 不能同时缺失 | error |
| MD-031 | `Dimension valueReference` 引用的变量必须是 `structuralParameter` | error |
| MD-032 | 数组维度和元素总数不能溢出 | error |
| MD-033 | `Clock` 必须有 `intervalVariability` | error |
| MD-034 | `clocks` 引用的 Clock 变量存在 | error |
| MD-035 | `intervalVariability="triggered"` 时不应有固定 interval | warning |
| MD-036 | Clock 的 `priority` 在合法范围 | warning |

### 10.4 模型结构

| 编号 | 规则 | 严重级别 |
| --- | --- | --- |
| MD-040 | FMI 2 `Outputs` 恰好包含所有 `causality="output"` 的变量 | error |
| MD-041 | FMI 2 `Derivatives` 只包含状态导数，且索引有效 | error |
| MD-042 | FMI 2 `InitialUnknowns` 按索引升序且无重复 | error |
| MD-043 | FMI 2 `dependencies` 索引有效且升序 | error |
| MD-044 | FMI 2 `dependenciesKind` 与 `dependencies` 等长 | error |
| MD-045 | FMI 3 `ModelStructure` 引用的 `valueReference` 存在 | error |
| MD-046 | FMI 3 `ContinuousStateDerivative` 只引用导数变量 | error |
| MD-047 | FMI 3 `EventIndicator` 只引用事件指示器变量 | error |
| MD-048 | FMI 3 `InitialUnknown` 不重复 | error |
| MD-049 | `dependenciesKind` 取值合法，且与 `dependencies` 等长 | error |

### 10.5 单位与类型

| 编号 | 规则 | 严重级别 |
| --- | --- | --- |
| MD-050 | 变量 `unit` 引用的单位存在 | warning |
| MD-051 | 变量 `displayUnit` 引用存在，且与 `unit` 兼容 | warning |
| MD-052 | `BaseUnit` 指数为整数 | error |
| MD-053 | `TypeDefinitions` 名称唯一，且不与变量名冲突 | error |
| MD-054 | `Enumeration` 的 `Item value` 唯一 | error |

### 10.6 安全

| 编号 | 规则 | 严重级别 |
| --- | --- | --- |
| MD-060 | 拒绝 XML 外部实体（XXE） | error |
| MD-061 | 限制 XML 大小/深度/实体展开 | error |
| MD-062 | `modelIdentifier` 不含路径分隔符/`..` | error |
| MD-063 | 所有文件引用在 FMU 根目录内 | error |

---

## 11. 常见陷阱

1. **`valueReference` 不是数组下标**：它是运行时句柄，可能不连续、可能重复（FMI 2 允许、FMI 3 别名允许）。不要用数组下标直接索引。
2. **FMI 2 的 `derivative` 是索引，FMI 3 是 `valueReference`**：混用会导致导数关系错误。
3. **默认 `initial` 不是恒为 `exact`**：必须按规范推导。
4. **`variability` 在 FMI 3 没有默认值**：不能照搬 FMI 2 的 `continuous`。
5. **`numberOfEventIndicators` 只在 FMI 2 根级**：FMI 3 用 `ModelStructure/EventIndicator`。
6. **`fmiVersion` 字符串比较**：`"3.0"`、`"3.0.2"`、`"3.1"` 都可能出现，按语义版本处理。
7. **元素顺序**：XSD 是 `xs:sequence`，顺序错误应报错；不要用“宽松解析”掩盖。
8. **未知属性**：FMI 3 的接口类型有 `xs:anyAttribute`，允许扩展；解析器应保留或忽略，不应失败。
9. **命名空间**：FMI 的 XSD 没有 target namespace，`modelDescription.xml` 通常也没有 `xmlns`。不要强制要求命名空间。
10. **BOM 与编码**：XML 声明可能是 UTF-8；处理 BOM，拒绝非 UTF-8 或做明确转码。
11. **实体与 DTD**：禁止外部实体，防止 XXE 和实体膨胀。
12. **大文件**：变量可能上万，解析器要避免 O(n²) 的索引构建。

---

## 12. 示例：最小 FMI 2 CS 模型

```xml
<?xml version="1.0" encoding="UTF-8"?>
<fmiModelDescription
    fmiVersion="2.0"
    modelName="Adder"
    guid="{00000000-0000-0000-0000-000000000000}"
    generationTool="MoonFMI"
    variableNamingConvention="flat">
  <CoSimulation modelIdentifier="Adder" canHandleVariableCommunicationStepSize="true"/>
  <ModelVariables>
    <ScalarVariable name="u" valueReference="0" causality="input" variability="continuous" initial="exact">
      <Real start="0"/>
    </ScalarVariable>
    <ScalarVariable name="y" valueReference="1" causality="output" variability="continuous" initial="calculated">
      <Real/>
    </ScalarVariable>
  </ModelVariables>
  <ModelStructure>
    <Outputs>
      <Unknown index="2" dependencies="1"/>
    </Outputs>
    <InitialUnknowns>
      <Unknown index="2"/>
    </InitialUnknowns>
  </ModelStructure>
</fmiModelDescription>
```

## 13. 示例：最小 FMI 3 CS 模型

```xml
<?xml version="1.0" encoding="UTF-8"?>
<fmiModelDescription
    fmiVersion="3.0"
    modelName="Adder"
    instantiationToken="{00000000-0000-0000-0000-000000000000}"
    generationTool="MoonFMI"
    variableNamingConvention="flat">
  <CoSimulation modelIdentifier="Adder" canHandleVariableCommunicationStepSize="true"/>
  <ModelVariables>
    <Float64 name="u" valueReference="0" causality="input" variability="continuous" initial="exact" start="0"/>
    <Float64 name="y" valueReference="1" causality="output" variability="continuous" initial="calculated"/>
  </ModelVariables>
  <ModelStructure>
    <Output valueReference="1"/>
    <InitialUnknown valueReference="1"/>
  </ModelStructure>
</fmiModelDescription>
```

---

## 14. 参考

- XSD 清单与校验：[`xsd-inventory.md`](xsd-inventory.md)
- FMI 2 API：[`fmi2-api.md`](fmi2-api.md)
- FMI 3 API：[`fmi3-api.md`](fmi3-api.md)
- 解析器与校验器设计：[`../design/xsd-and-validation.md`](../design/xsd-and-validation.md)
- FMPy 的模型描述实现：[`../research/fmpy.md`](../research/fmpy.md)
- fmi-rs 的 schema crate：[`../research/fmi-rs.md`](../research/fmi-rs.md)
