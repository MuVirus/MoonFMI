# FMI 3.0.2 C API

本文按“实现导入器”的顺序整理 FMI 3.0.2 的 C API，重点说明与 FMI 2.0.4 的差异。官方头文件见 [`headers/fmi3/`](headers/fmi3/)。

---

## 1. 头文件与类型

### 1.1 三个头文件

| 文件 | 作用 |
| --- | --- |
| [`fmi3PlatformTypes.h`](headers/fmi3/fmi3PlatformTypes.h) | 基础类型、布尔/时钟定义 |
| [`fmi3FunctionTypes.h`](headers/fmi3/fmi3FunctionTypes.h) | 状态码、回调、函数指针类型 |
| [`fmi3Functions.h`](headers/fmi3/fmi3Functions.h) | 导出函数声明、符号重命名宏 |

### 1.2 基础类型

| 类型 | C 定义 | 说明 | MoonBit 映射建议 |
| --- | --- | --- | --- |
| `fmi3Instance` | `void*` | 不透明实例指针 | 不透明指针 |
| `fmi3InstanceEnvironment` | `void*` | 宿主环境指针 | 不透明指针 |
| `fmi3FMUState` | `void*` | 不透明状态指针 | 不透明指针 |
| `fmi3ValueReference` | `uint32_t` | 固定 32 位 | `UInt32` |
| `fmi3Float32` | `float` | 32 位浮点 | `Float` |
| `fmi3Float64` | `double` | 64 位浮点 | `Double` |
| `fmi3Int8` | `int8_t` | 8 位有符号 | `Byte` + 符号解释，或 `Int16` 中转 |
| `fmi3UInt8` | `uint8_t` | 8 位无符号 | `Byte` |
| `fmi3Int16` / `UInt16` | `int16_t` / `uint16_t` | 16 位 | `Int16` / `UInt16` |
| `fmi3Int32` / `UInt32` | `int32_t` / `uint32_t` | 32 位 | `Int32` / `UInt32` |
| `fmi3Int64` / `UInt64` | `int64_t` / `uint64_t` | 64 位 | `Int64` / `UInt64` |
| `fmi3Boolean` | `bool` | **1 字节**（通常） | `Bool` 或 `Byte`，但数组需谨慎 |
| `fmi3Char` | `char` | 单字节 | `Byte` |
| `fmi3String` | `const char*` | UTF-8、NUL 结尾 | C 字符串 |
| `fmi3Byte` | `uint8_t` | 单字节 | `Byte` |
| `fmi3Binary` | `const uint8_t*` | 二进制数据，长度单独传递 | `Bytes` + 长度 |
| `fmi3Clock` | `bool` | 时钟激活状态 | `Bool`/`Byte` |

> ⚠️ FMI 3 的 `fmi3Boolean` 是 C `bool`，而 FMI 2 的 `fmi2Boolean` 是 `int`。同一个“布尔数组”在两个版本中的内存布局不同。不要写一个共享的 `Bool` 数组绑定同时服务两个版本。
>
> ⚠️ `fmi3Int8` 在 MoonBit 中没有完全对应的有符号 8 位类型。可以用 `Byte` 存储并按 `Int8` 解释，或用 `Int16` 做范围检查后转换。读取时要注意符号扩展。
>
> ⚠️ `size_t` 的宽度随目标平台变化（32 位为 4 字节，64 位为 8 字节）。所有 `nXxx` 参数都必须按目标平台映射，不能统一用 `UInt64`。

### 1.3 状态码

```c
typedef enum {
    fmi3OK,       // 0
    fmi3Warning,  // 1
    fmi3Discard,  // 2
    fmi3Error,    // 3
    fmi3Fatal     // 4
} fmi3Status;
```

与 FMI 2 相比**没有 `Pending`**。FMI 3 用 `earlyReturn`、`intermediateUpdate` 和状态查询来表达异步/提前返回，而不是 `Pending` 状态。

### 1.4 其他枚举

```c
typedef enum {
    fmi3Independent,
    fmi3Constant,
    fmi3Fixed,
    fmi3Tunable,
    fmi3Discrete,
    fmi3Dependent
} fmi3DependencyKind;

typedef enum {
    fmi3IntervalNotYetKnown,
    fmi3IntervalUnchanged,
    fmi3IntervalChanged
} fmi3IntervalQualifier;
```

### 1.5 回调

FMI 3 没有 `fmi2CallbackFunctions` 那样的统一结构体，而是在实例化时分别传入回调：

```c
typedef void (*fmi3LogMessageCallback)(
    fmi3InstanceEnvironment instanceEnvironment,
    fmi3Status status,
    fmi3String category,
    fmi3String message);

typedef void (*fmi3ClockUpdateCallback)(
    fmi3InstanceEnvironment instanceEnvironment);

typedef void (*fmi3IntermediateUpdateCallback)(
    fmi3InstanceEnvironment instanceEnvironment,
    fmi3Float64 intermediateUpdateTime,
    fmi3Boolean intermediateVariableSetRequested,
    fmi3Boolean intermediateVariableGetAllowed,
    fmi3Boolean intermediateStepFinished,
    fmi3Boolean canReturnEarly,
    fmi3Boolean* earlyReturnRequested,
    fmi3Float64* earlyReturnTime);

typedef void (*fmi3LockPreemptionCallback)(void);
typedef void (*fmi3UnlockPreemptionCallback)(void);
```

| 回调 | 用途 | 注意 |
| --- | --- | --- |
| `logMessage` | 日志 | 固定签名，无可变参数，比 FMI 2 好处理 |
| `clockUpdate` | SE 时钟更新通知 | 只能用于 SE |
| `intermediateUpdate` | CS 中间更新/提前返回 | 可写 `earlyReturnRequested` 和 `earlyReturnTime` |
| `lockPreemption` / `unlockPreemption` | SE 临界区 | 宿主需保证不被抢占 |

`intermediateUpdate` 的 `earlyReturnRequested` 是**输出参数**：FMU 通过它请求宿主提前返回。宿主必须在回调返回前设置好，并保证实例在回调期间可用。

---

## 2. 符号与调用约定

### 2.1 导出符号

FMI 3 的符号同样有未修饰和带 `modelIdentifier` 前缀两种形式：

```c
#define fmi3FullName(name) fmi3ModelName_##name
```

动态库通常导出 `fmi3InstantiateCoSimulation` 等未修饰符号；源码/静态库使用 `<modelIdentifier>_fmi3Xxx`。导入器应同时尝试两种形式。

### 2.2 调用约定

- 与 FMI 2 一样，使用 C 调用约定。
- 结构体对齐按平台默认；FMI 3 没有 FMI 2 的 `#pragma pack(push,8)`，但仍建议用 C shim 处理跨语言结构体。
- 字符串 UTF-8、NUL 结尾。
- 数组参数通常带两个长度：`nValueReferences` 和 `nValues`。对于标量变量二者相等；对于数组变量，`nValues` 是元素总数。

### 2.3 资源路径

`fmi3Instantiate*` 的 `resourcePath` 与 FMI 2 的 `fmuResourceLocation` **语义不同**，这是从 FMI 2 迁移时最容易踩的坑：

| 版本 | 参数 | 形式 |
| --- | --- | --- |
| FMI 2 | `fmuResourceLocation` | URI，如 `file:///C:/temp/MyFMU/resources/` |
| FMI 3 | `resourcePath` | **本地绝对文件路径**，如 `C:\temp\MyFMU\resources\` |

FMI 3 规范原文：`resourcePath` 是解压后 FMU 中 `resources/` 目录的绝对文件路径，必须以文件分隔符结尾（Windows 用 `\`，POSIX 用 `/`）。

要点：

- **不是 URI**，不做百分号编码，也不要加 `file://` 前缀。
- 盘符、空格、非 ASCII 字符按宿主 OS 的原生路径规则处理（Windows 传给 FMU 的是 ANSI/UTF-8 字节串，需与实际实现一致）。
- 若 FMU 不含 `resources/`，或宿主没有文件系统（如纯 WASM 运行时），必须传 `NULL`；FMU 若离开资源目录无法工作，则应让实例化返回 `NULL`。
- 导入器仍需校验该目录位于解压根内，防止 FMU 借 `resourcePath` 越权读取宿主文件。

因此路径构造函数要按版本分流，不能复用同一份代码：FMI 2 走 URI 构造 + 转义，FMI 3 走原生路径拼接。

---

## 3. 实例化

FMI 3 按接口类型分成三个实例化函数。

### 3.1 Model Exchange

```c
fmi3Instance fmi3InstantiateModelExchange(
    fmi3String              instanceName,
    fmi3String              instantiationToken,
    fmi3String              resourcePath,
    fmi3Boolean             visible,
    fmi3Boolean             loggingOn,
    fmi3InstanceEnvironment instanceEnvironment,
    fmi3LogMessageCallback  logMessage);
```

### 3.2 Co-Simulation

```c
fmi3Instance fmi3InstantiateCoSimulation(
    fmi3String                      instanceName,
    fmi3String                      instantiationToken,
    fmi3String                      resourcePath,
    fmi3Boolean                     visible,
    fmi3Boolean                     loggingOn,
    fmi3Boolean                     eventModeUsed,
    fmi3Boolean                     earlyReturnAllowed,
    const fmi3ValueReference        requiredIntermediateVariables[],
    size_t                          nRequiredIntermediateVariables,
    fmi3InstanceEnvironment         instanceEnvironment,
    fmi3LogMessageCallback          logMessage,
    fmi3IntermediateUpdateCallback  intermediateUpdate);
```

| 参数 | 含义 |
| --- | --- |
| `eventModeUsed` | 宿主是否使用事件模式 |
| `earlyReturnAllowed` | 宿主是否允许 FMU 提前返回 |
| `requiredIntermediateVariables` | 宿主希望在中间更新时看到的变量 |
| `intermediateUpdate` | 中间更新回调，可为空（如果不使用） |

### 3.3 Scheduled Execution

```c
fmi3Instance fmi3InstantiateScheduledExecution(
    fmi3String                      instanceName,
    fmi3String                      instantiationToken,
    fmi3String                      resourcePath,
    fmi3Boolean                     visible,
    fmi3Boolean                     loggingOn,
    fmi3InstanceEnvironment         instanceEnvironment,
    fmi3LogMessageCallback          logMessage,
    fmi3ClockUpdateCallback         clockUpdate,
    fmi3LockPreemptionCallback      lockPreemption,
    fmi3UnlockPreemptionCallback    unlockPreemption);
```

### 3.4 实例化后的公共步骤

```text
fmi3Instantiate*
  → fmi3EnterInitializationMode(toleranceDefined, tolerance, startTime,
                                stopTimeDefined, stopTime)
  → 设置参数/输入/初始值
  → fmi3ExitInitializationMode
  → 按接口进入 CS / ME / SE
  → fmi3Terminate
  → fmi3FreeInstance
```

注意 FMI 3 把 `SetupExperiment` 合并进了 `fmi3EnterInitializationMode`，没有单独的 `SetupExperiment`。

---

## 4. 生命周期与状态机

### 4.1 CS

```text
Instantiated
  → Initialization Mode
  → Step Mode
       ├─ fmi3DoStep
       ├─ fmi3EnterEventMode（如果 eventHandlingNeeded）
       │    → fmi3UpdateDiscreteStates
       │    → fmi3EnterStepMode
       └─ 中间更新/提前返回
  → Terminated
  → Freed
```

`fmi3DoStep` 签名：

```c
fmi3Status fmi3DoStep(
    fmi3Instance instance,
    fmi3Float64  currentCommunicationPoint,
    fmi3Float64  communicationStepSize,
    fmi3Boolean  noSetFMUStatePriorToCurrentPoint,
    fmi3Boolean* eventHandlingNeeded,
    fmi3Boolean* terminateSimulation,
    fmi3Boolean* earlyReturn,
    fmi3Float64* lastSuccessfulTime);
```

| 输出 | 含义 |
| --- | --- |
| `eventHandlingNeeded` | 需要进入事件模式 |
| `terminateSimulation` | FMU 请求终止 |
| `earlyReturn` | 已提前返回，`lastSuccessfulTime` 有效 |
| `lastSuccessfulTime` | 最后一次成功推进到的时间 |

主算法必须检查这些输出，不能只看返回码。

### 4.2 ME

```text
Instantiated
  → Initialization
  → Continuous Time Mode
       ├─ SetTime / SetContinuousStates
       ├─ GetContinuousStateDerivatives
       ├─ GetEventIndicators
       ├─ CompletedIntegratorStep
       └─ 事件：
            EnterEventMode
            UpdateDiscreteStates（循环直到 discreteStatesNeedUpdate=false）
            EnterContinuousTimeMode
  → Terminated
  → Freed
```

`fmi3CompletedIntegratorStep`：

```c
fmi3Status fmi3CompletedIntegratorStep(
    fmi3Instance instance,
    fmi3Boolean  noSetFMUStatePriorToCurrentPoint,
    fmi3Boolean* enterEventMode,
    fmi3Boolean* terminateSimulation);
```

它直接告诉宿主是否需要进入事件模式，比 FMI 2 的隐式事件检测更明确。

### 4.3 SE

```text
Instantiated
  → Initialization
  → 调度器注册时钟/分区
  → 循环：
       等待时钟触发
       fmi3ActivateModelPartition(clockReference, activationTime)
       读取输出/更新时钟
  → Terminated
  → Freed
```

`fmi3ActivateModelPartition`：

```c
fmi3Status fmi3ActivateModelPartition(
    fmi3Instance instance,
    fmi3ValueReference clockReference,
    fmi3Float64 activationTime);
```

时钟的间隔/偏移通过 `fmi3GetIntervalDecimal/Fraction`、`fmi3GetShiftDecimal/Fraction` 和对应的 `Set` 函数查询/设置。

---

## 5. 变量读写

### 5.1 按类型分组

| 类型 | Get / Set |
| --- | --- |
| Float32 | `fmi3GetFloat32` / `fmi3SetFloat32` |
| Float64 | `fmi3GetFloat64` / `fmi3SetFloat64` |
| Int8 / UInt8 | `fmi3GetInt8` / `fmi3SetInt8` 等 |
| Int16 / UInt16 | 同上 |
| Int32 / UInt32 | 同上 |
| Int64 / UInt64 | 同上 |
| Boolean | `fmi3GetBoolean` / `fmi3SetBoolean` |
| String | `fmi3GetString` / `fmi3SetString` |
| Binary | `fmi3GetBinary` / `fmi3SetBinary` |
| Clock | `fmi3GetClock` / `fmi3SetClock` |

### 5.2 数组参数

FMI 3 的 Get/Set 统一带两个长度：

```c
fmi3Status fmi3GetFloat64(
    fmi3Instance instance,
    const fmi3ValueReference valueReferences[],
    size_t nValueReferences,
    fmi3Float64 values[],
    size_t nValues);
```

- 对于标量变量：`nValueReferences == nValues`。
- 对于数组变量：一个 `valueReference` 对应多个元素，`nValues` 是总元素数。
- 调用方必须根据 `modelDescription.xml` 中的 `Dimension` 计算每个变量的元素个数，并保证 `values` 缓冲区足够大。

### 5.3 Binary

```c
fmi3Status fmi3GetBinary(
    fmi3Instance instance,
    const fmi3ValueReference valueReferences[],
    size_t nValueReferences,
    size_t sizes[],
    fmi3Binary values[],
    size_t nValues);
```

Binary 是“指针 + 长度”的形式。`fmi3GetBinary` 返回的指针由 FMU 持有，下一次调用可能失效；需要立即复制。`fmi3SetBinary` 的指针只需在调用期间有效。

### 5.4 Clock

Clock 的值是 `fmi3Clock`（`bool`），但 Clock 的语义远不止布尔值：

- Clock 变量有 `intervalVariability`、`intervalDecimal`、`intervalCounter`、`intervalResolution`、`shiftDecimal`、`shiftCounter`、`shiftResolution` 等属性。
- 时钟化变量通过 `clocks` 属性关联到一个或多个 Clock。
- 输入 Clock 由宿主设置，输出 Clock 由 FMU 激活并通过 `clockUpdate` 通知宿主。

不要只把 Clock 当成普通 Boolean 变量。

---

## 6. 状态、导数与依赖

### 6.1 FMU 状态

| 函数 | 说明 |
| --- | --- |
| `fmi3GetFMUState(instance, fmi3FMUState* FMUState)` | 获取状态 |
| `fmi3SetFMUState(instance, fmi3FMUState FMUState)` | 恢复状态 |
| `fmi3FreeFMUState(instance, fmi3FMUState* FMUState)` | 释放状态 |
| `fmi3SerializedFMUStateSize` | 查询序列化大小 |
| `fmi3SerializeFMUState` | 序列化 |
| `fmi3DeserializeFMUState` | 反序列化 |

与 FMI 2 类似，但函数名和拼写不同（`Deserialize` 不是 `DeSerialize`）。

### 6.2 方向导数与伴随导数

```c
fmi3Status fmi3GetDirectionalDerivative(
    fmi3Instance instance,
    const fmi3ValueReference unknowns[], size_t nUnknowns,
    const fmi3ValueReference knowns[], size_t nKnowns,
    const fmi3Float64 seed[], size_t nSeed,
    fmi3Float64 sensitivity[], size_t nSensitivity);

fmi3Status fmi3GetAdjointDerivative(...);
```

能力标志是 `providesDirectionalDerivatives` 和 `providesAdjointDerivatives`（注意复数形式）。

### 6.3 变量依赖查询

```c
fmi3Status fmi3GetNumberOfVariableDependencies(
    fmi3Instance instance,
    fmi3ValueReference valueReference,
    size_t* nDependencies);

fmi3Status fmi3GetVariableDependencies(
    fmi3Instance instance,
    fmi3ValueReference dependent,
    size_t elementIndicesOfDependent[],
    fmi3ValueReference independents[],
    size_t elementIndicesOfIndependents[],
    fmi3DependencyKind dependencyKinds[],
    size_t nDependencies);
```

这允许宿主在运行时查询依赖关系，而不只依赖 `modelDescription.xml` 的静态声明。对数组变量尤其有用。

---

## 7. 配置模式与结构参数

FMI 3 引入了**配置模式**：

```c
fmi3Status fmi3EnterConfigurationMode(fmi3Instance instance);
fmi3Status fmi3ExitConfigurationMode(fmi3Instance instance);
```

用途：

- 修改 `structuralParameter`（结构参数）；
- 改变数组维度；
- 重新配置模型结构。

约束：

- 只能在初始化之前或特定状态下进入；
- 进入后不能调用步进/求值函数；
- 修改结构参数后，可能影响 `modelDescription.xml` 中声明的维度，宿主需要重新计算缓冲区大小；
- 不是所有 FMU 都支持；看 `canHandle...`/规范约束。

结构参数在 `modelDescription.xml` 中的 `causality="structuralParameter"`，其 `variability` 通常为 `fixed` 或 `tunable`。数组维度可以通过 `Dimension valueReference` 引用结构参数。

---

## 8. 中间更新与提前返回

### 8.1 中间更新

当 `fmi3InstantiateCoSimulation` 的 `intermediateUpdate` 非空，FMU 可以在 `DoStep` 内部调用它，报告中间时刻的变量值：

```c
void intermediateUpdate(
    fmi3InstanceEnvironment env,
    fmi3Float64 time,
    fmi3Boolean setRequested,
    fmi3Boolean getAllowed,
    fmi3Boolean stepFinished,
    fmi3Boolean canReturnEarly,
    fmi3Boolean* earlyReturnRequested,
    fmi3Float64* earlyReturnTime);
```

宿主可以：

- 在 `getAllowed` 时读取中间变量；
- 在 `setRequested` 时设置输入（需谨慎，可能影响 FMU 内部状态）；
- 在 `canReturnEarly` 时请求提前返回（写 `earlyReturnRequested=true`，并设置 `earlyReturnTime`）。

### 8.2 提前返回

`fmi3DoStep` 返回后，如果 `earlyReturn=true`，宿主应：

1. 读取 `lastSuccessfulTime`；
2. 把仿真时间推进到该时刻；
3. 处理事件/中间更新；
4. 从该时刻继续下一步。

不要假设 `currentCommunicationPoint + communicationStepSize` 一定已经到达。

### 8.3 与 FMI 2 的差异

| 能力 | FMI 2 | FMI 3 |
| --- | --- | --- |
| 异步步进 | `fmi2Pending` + `fmi2GetStatus` + `fmi2CancelStep` | `earlyReturn` + `intermediateUpdate` |
| 中间变量 | 不支持 | `intermediateUpdate` |
| 事件模式 | CS 可选 | CS 可选，`eventModeUsed` |
| 事件输出 | 无 | `eventHandlingNeeded` |

---

## 9. 函数分组速查

### 9.1 公共

`fmi3GetVersion`、`fmi3SetDebugLogging`、`fmi3Instantiate*`、`fmi3FreeInstance`、`fmi3EnterInitializationMode`、`fmi3ExitInitializationMode`、`fmi3EnterEventMode`、`fmi3Terminate`、`fmi3Reset`。

### 9.2 变量

`fmi3GetFloat32/64`、`fmi3GetInt8/UInt8/.../UInt64`、`fmi3GetBoolean/String/Binary/Clock` 及对应 `Set`。

### 9.3 状态与导数

`fmi3GetFMUState`、`fmi3SetFMUState`、`fmi3FreeFMUState`、`fmi3SerializedFMUStateSize`、`fmi3SerializeFMUState`、`fmi3DeserializeFMUState`、`fmi3GetDirectionalDerivative`、`fmi3GetAdjointDerivative`、`fmi3GetNumberOfVariableDependencies`、`fmi3GetVariableDependencies`。

### 9.4 配置与时钟

`fmi3EnterConfigurationMode`、`fmi3ExitConfigurationMode`、`fmi3GetIntervalDecimal/Fraction`、`fmi3SetIntervalDecimal/Fraction`、`fmi3GetShiftDecimal/Fraction`、`fmi3SetShiftDecimal/Fraction`、`fmi3EvaluateDiscreteStates`、`fmi3UpdateDiscreteStates`。

### 9.5 ME

`fmi3EnterContinuousTimeMode`、`fmi3CompletedIntegratorStep`、`fmi3SetTime`、`fmi3SetContinuousStates`、`fmi3GetContinuousStateDerivatives`、`fmi3GetEventIndicators`、`fmi3GetContinuousStates`、`fmi3GetNominalsOfContinuousStates`、`fmi3GetNumberOfEventIndicators`、`fmi3GetNumberOfContinuousStates`。

### 9.6 CS

`fmi3EnterStepMode`、`fmi3GetOutputDerivatives`、`fmi3DoStep`。

### 9.7 SE

`fmi3ActivateModelPartition`。

---

## 10. 常见错误

1. **把 `fmi3Boolean` 当 4 字节**：FMI 3 是 `bool`，通常 1 字节；与 FMI 2 相反。
2. **数组长度只传变量数**：FMI 3 的 Get/Set 需要 `nValueReferences` 和 `nValues` 两个长度。
3. **忽略 `eventHandlingNeeded`**：`DoStep` 返回 OK 但需要事件处理。
4. **忽略 `earlyReturn`**：把未到达的时间当成已到达。
5. **在 `intermediateUpdate` 中做重入调用**：回调期间实例处于特殊状态，只能做规范允许的操作。
6. **Clock 当普通 Boolean**：忽略时钟属性、时钟化变量和调度语义。
7. **结构参数修改后不重算维度**：缓冲区大小与实际数组不匹配。
8. **`fmi3FMUState` 生命周期错误**：状态由 FMU 分配，必须用 `fmi3FreeFMUState` 释放。
9. **`size_t` 宽度错误**：32/64 位目标混用。
10. **字符串/二进制指针跨调用保存**：指针由 FMU 持有，下一次调用可能失效。

---

## 11. 参考

- 官方头文件：[`headers/fmi3/`](headers/fmi3/)
- FMI 3.0.2 规范：见 [`../references/links.md`](../references/links.md)
- 模型描述字段：[`model-description.md`](model-description.md)
- WASM 映射：[`../design/wasm-strategy.md`](../design/wasm-strategy.md)
- ABI 细节：[`../design/ffi-and-abi.md`](../design/ffi-and-abi.md)
