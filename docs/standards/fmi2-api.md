# FMI 2.0.4 C API

本文按“实现导入器”的顺序整理 FMI 2.0.4 的 C API。官方头文件见 [`headers/fmi2/`](headers/fmi2/)，完整函数声明以头文件为准。

---

## 1. 头文件与类型

### 1.1 三个头文件

| 文件 | 作用 |
| --- | --- |
| [`fmi2TypesPlatform.h`](headers/fmi2/fmi2TypesPlatform.h) | 基础类型、字符串编码、布尔值定义 |
| [`fmi2FunctionTypes.h`](headers/fmi2/fmi2FunctionTypes.h) | 状态码、回调、函数指针类型 |
| [`fmi2Functions.h`](headers/fmi2/fmi2Functions.h) | 导出函数声明、符号重命名宏 |

### 1.2 基础类型

| 类型 | C 定义 | 宽度/说明 | MoonBit 映射建议 |
| --- | --- | --- | --- |
| `fmi2Component` | `void*` | 不透明实例指针 | `Ptr[Unit]` / 自有 `Component` 包装 |
| `fmi2ComponentEnvironment` | `void*` | 宿主环境指针，回调时原样传回 | 不透明指针 |
| `fmi2FMUstate` | `void*` | 不透明状态指针 | 不透明指针 |
| `fmi2ValueReference` | `unsigned int` | 通常 32 位 | `UInt32` |
| `fmi2Real` | `double` | 64 位浮点 | `Double` |
| `fmi2Integer` | `int` | 通常 32 位有符号 | `Int32` |
| `fmi2Boolean` | `int` | **4 字节**，不是 `bool` | `Int32`，不要用 `Bool` |
| `fmi2Char` | `char` | 单字节 | `Byte` |
| `fmi2String` | `const char*` | NUL 结尾，UTF-8 | `CString` / `Ptr[Byte]` |
| `fmi2Byte` | `char` | 单字节 | `Byte` |

> ⚠️ `fmi2Boolean` 是 `int`。如果把 MoonBit 的 `Bool` 数组直接传给 `fmi2GetBoolean`，很可能只写了 1 字节，导致后续数据错位。必须用 `Int32` 中转，或写 C shim 做转换。

### 1.3 状态码

```c
typedef enum {
    fmi2OK,        // 0
    fmi2Warning,   // 1
    fmi2Discard,   // 2
    fmi2Error,     // 3
    fmi2Fatal,     // 4
    fmi2Pending    // 5
} fmi2Status;
```

| 状态 | 含义 | 导入器处理 |
| --- | --- | --- |
| `fmi2OK` | 成功 | 继续 |
| `fmi2Warning` | 成功但有警告 | 记录日志，继续 |
| `fmi2Discard` | 调用未完成，结果不可用 | 通常用于 `DoStep` 被取消/异步；按规范处理 |
| `fmi2Error` | 可恢复错误 | 终止当前操作，保留实例以便 `Reset`/`Terminate` |
| `fmi2Fatal` | 不可恢复错误 | 立即停止，释放实例 |
| `fmi2Pending` | 异步操作进行中 | 仅在异步 `DoStep` 场景；轮询 `fmi2GetStatus` |

### 1.4 其他枚举

```c
typedef enum { fmi2ModelExchange, fmi2CoSimulation } fmi2Type;

typedef enum {
    fmi2DoStepStatus,
    fmi2PendingStatus,
    fmi2LastSuccessfulTime,
    fmi2Terminated
} fmi2StatusKind;
```

### 1.5 回调结构体

```c
typedef struct {
    fmi2CallbackLogger         logger;
    fmi2CallbackAllocateMemory allocateMemory;
    fmi2CallbackFreeMemory     freeMemory;
    fmi2StepFinished           stepFinished;
    fmi2ComponentEnvironment   componentEnvironment;
} fmi2CallbackFunctions;
```

| 字段 | 作用 | 注意 |
| --- | --- | --- |
| `logger` | FMU 输出日志 | 可变参数 `...`，需要 C shim 或固定签名的包装 |
| `allocateMemory` | FMU 申请内存 | 必须与 `freeMemory` 配套；默认可用 `malloc/free` |
| `freeMemory` | 释放内存 | 不能混用不同分配器 |
| `stepFinished` | 异步步进完成通知 | 同步场景可为空 |
| `componentEnvironment` | 宿主上下文 | 回调时原样传回，通常放实例/日志器指针 |

> 可变参数 `logger` 是最容易出问题的回调之一。MoonBit 侧不要直接实现可变参数 C 函数；建议写一个固定签名的 C 包装（只转发 `message`），或使用 `vsnprintf` 在 C 侧格式化。

### 1.6 `fmi2EventInfo`

```c
typedef struct {
    fmi2Boolean newDiscreteStatesNeeded;
    fmi2Boolean terminateSimulation;
    fmi2Boolean nominalsOfContinuousStatesChanged;
    fmi2Boolean valuesOfContinuousStatesChanged;
    fmi2Boolean nextEventTimeDefined;
    fmi2Real    nextEventTime;
} fmi2EventInfo;
```

注意字段是 `fmi2Boolean`（`int`），不是 1 字节布尔。结构体布局必须与 C 完全一致；建议用 C shim 读写，避免 MoonBit 结构体布局差异。

---

## 2. 符号与调用约定

### 2.1 导出符号

FMI 2 的符号有两种形式：

- **动态库**：导出未修饰的 `fmi2Instantiate`、`fmi2DoStep` 等。
- **静态库/源码**：通过 `fmi2Functions.h` 中的 `fmi2FullName` 宏加 `modelIdentifier` 前缀，例如 `MyModel_fmi2Instantiate`。

```c
#define fmi2FullName(name) fmi2ModelName_##name
```

导入器加载动态库时，应先尝试无前缀符号；源码 FMU 编译出的静态库才需要前缀。实际实现中建议：

1. 读取 `modelIdentifier`；
2. 先查 `fmi2Xxx`；
3. 找不到再查 `<modelIdentifier>_fmi2Xxx`；
4. 记录实际使用的符号，便于诊断。

### 2.2 调用约定

- Windows：FMI 2 使用 `__cdecl`（默认 C 调用约定），导出宏为 `__declspec(dllexport)`。
- Linux/macOS：默认 C 调用约定。
- 结构体按 8 字节对齐（头文件中有 `#pragma pack(push,8)`）。
- 所有字符串为 UTF-8、NUL 结尾。
- 数组参数通常为“值引用数组 + 数量 + 输出/输入数组”。

### 2.3 资源路径

`fmi2Instantiate` 的 `fmuResourceLocation` 是 FMU 内 `resources/` 目录的 URI。规范要求：

- 以 `file://` 开头（本地文件）；
- 以 `/` 结尾；
- 路径中的特殊字符做 URI 转义；
- Windows 盘符形式如 `file:///C:/path/to/resources/`。

不正确的资源路径是 FMU 初始化失败的常见原因。导入器应提供统一的路径构造与测试。

---

## 3. 生命周期与状态机

### 3.1 通用流程

```text
                    fmi2Instantiate
                           │
                           ▼
                    Instantiated
                           │
                 fmi2SetupExperiment
                           │
                           ▼
                 fmi2EnterInitializationMode
                           │
                           ▼
                    Initialization
                           │
                 fmi2ExitInitializationMode
                           │
             ┌─────────────┴─────────────┐
             ▼                           ▼
      Co-Simulation                 Model Exchange
      (Step mode)              (Continuous time / Event)
             │                           │
             └─────────────┬─────────────┘
                           ▼
                     fmi2Terminate
                           │
                           ▼
                    fmi2FreeInstance
```

`fmi2Reset` 可以把实例恢复到初始化后的状态，但不会释放实例。

### 3.2 最小 CS 调用序列

```c
fmi2Component c = fmi2Instantiate(
    "instance1", fmi2CoSimulation, guid, resourcePath, &callbacks, fmi2False, fmi2True);

fmi2SetupExperiment(c, fmi2False, 0.0, startTime, fmi2True, stopTime);
fmi2EnterInitializationMode(c);
// 设置参数、输入初值
fmi2ExitInitializationMode(c);

while (time < stopTime) {
    fmi2SetReal(c, vrs, n, values);
    fmi2DoStep(c, time, stepSize, fmi2True);
    fmi2GetReal(c, outVrs, nOut, outValues);
    time += stepSize;
}

fmi2Terminate(c);
fmi2FreeInstance(c);
```

### 3.3 最小 ME 调用序列

```c
fmi2Component c = fmi2Instantiate(
    "instance1", fmi2ModelExchange, guid, resourcePath, &callbacks, fmi2False, fmi2True);

fmi2SetupExperiment(c, fmi2False, 0.0, startTime, fmi2True, stopTime);
fmi2EnterInitializationMode(c);
// 设置参数、输入初值
fmi2ExitInitializationMode(c);

fmi2EnterContinuousTimeMode(c);

while (time < stopTime) {
    fmi2SetTime(c, time);
    fmi2SetContinuousStates(c, x, nx);
    fmi2GetDerivatives(c, dx, nx);

    // 积分器推进，得到 time + h 和新的 x
    // 检测事件指示器过零
    fmi2GetEventIndicators(c, indicators, ni);

    if (eventDetected) {
        fmi2EnterEventMode(c);
        fmi2EventInfo info;
        do {
            fmi2NewDiscreteStates(c, &info);
        } while (info.newDiscreteStatesNeeded);
        fmi2EnterContinuousTimeMode(c);
    }
}

fmi2Terminate(c);
fmi2FreeInstance(c);
```

> ME 的 `fmi2CompletedIntegratorStep` 必须在每个积分步成功后调用，告诉 FMU“这一步完成了”，以便它处理状态选择、事件等。不要省略。

---

## 4. 函数分组

### 4.1 公共函数

| 函数 | 作用 | 备注 |
| --- | --- | --- |
| `fmi2GetTypesPlatform` | 返回类型平台字符串 | 应为 `"default"` |
| `fmi2GetVersion` | 返回 FMI 版本 | 应为 `"2.0"` |
| `fmi2SetDebugLogging` | 设置日志类别 | 初始化前后均可调用 |
| `fmi2Instantiate` | 创建实例 | 参数最多，重点 |
| `fmi2FreeInstance` | 释放实例 | 之后不得再调用其他函数 |
| `fmi2SetupExperiment` | 设置实验参数 | 起止时间、容差 |
| `fmi2EnterInitializationMode` | 进入初始化 | |
| `fmi2ExitInitializationMode` | 退出初始化 | 之后进入步进/连续时间 |
| `fmi2Terminate` | 正常终止 | 之后仍可 `FreeInstance` |
| `fmi2Reset` | 重置到初始化后状态 | 可复用实例 |

### 4.2 变量读写

| 函数 | 类型 |
| --- | --- |
| `fmi2GetReal` / `fmi2SetReal` | `fmi2Real`（double） |
| `fmi2GetInteger` / `fmi2SetInteger` | `fmi2Integer`（int） |
| `fmi2GetBoolean` / `fmi2SetBoolean` | `fmi2Boolean`（**int**） |
| `fmi2GetString` / `fmi2SetString` | `fmi2String`（UTF-8 C 字符串） |

批量接口的签名统一为：

```c
fmi2Status fmi2GetXxx(fmi2Component c,
                      const fmi2ValueReference vr[],
                      size_t nvr,
                      Xxx value[]);
```

### 4.3 FMU 状态

| 函数 | 作用 |
| --- | --- |
| `fmi2GetFMUstate` | 获取内部状态句柄（`fmi2FMUstate*`） |
| `fmi2SetFMUstate` | 恢复状态 |
| `fmi2FreeFMUstate` | 释放状态句柄 |
| `fmi2SerializedFMUstateSize` | 查询序列化大小 |
| `fmi2SerializeFMUstate` | 序列化到字节数组 |
| `fmi2DeSerializeFMUstate` | 从字节数组恢复 |

注意：

- `fmi2GetFMUstate` 的输出参数是 `fmi2FMUstate*`，即“指向不透明指针的指针”。
- 状态句柄由 FMU 分配，必须用 `fmi2FreeFMUstate` 释放。
- 序列化格式是 FMU 私有的，不能跨 FMU/版本假设兼容。
- 不是所有 FMU 都支持；先看 `canGetAndSetFMUstate` / `canSerializeFMUstate`。

### 4.4 方向导数

```c
fmi2Status fmi2GetDirectionalDerivative(
    fmi2Component c,
    const fmi2ValueReference vUnknown_ref[],
    size_t nUnknown,
    const fmi2ValueReference vKnown_ref[],
    size_t nKnown,
    const fmi2Real dvKnown[],
    fmi2Real dvUnknown[]);
```

用于计算 `d(unknown)/d(known) * dvKnown`。需要 `providesDirectionalDerivative=true`。

### 4.5 Co-Simulation 函数

| 函数 | 作用 |
| --- | --- |
| `fmi2DoStep` | 推进一个通信步 |
| `fmi2CancelStep` | 取消当前异步步 |
| `fmi2GetStatus` | 查询异步状态 |
| `fmi2GetRealStatus` / `Integer` / `Boolean` / `String` | 查询特定状态值 |
| `fmi2SetRealInputDerivatives` | 设置输入导数 |
| `fmi2GetRealOutputDerivatives` | 获取输出导数 |

`fmi2DoStep` 签名：

```c
fmi2Status fmi2DoStep(fmi2Component c,
                      fmi2Real currentCommunicationPoint,
                      fmi2Real communicationStepSize,
                      fmi2Boolean noSetFMUStatePriorToCurrentPoint);
```

`noSetFMUStatePriorToCurrentPoint=fmi2True` 表示宿主承诺不再回退到当前点之前的状态，FMU 可以释放旧状态、优化内存。只有在主算法确定不做回滚时才传 `true`。

### 4.6 Model Exchange 函数

| 函数 | 作用 |
| --- | --- |
| `fmi2EnterEventMode` | 进入事件模式 |
| `fmi2NewDiscreteStates` | 事件迭代，更新离散状态 |
| `fmi2EnterContinuousTimeMode` | 回到连续时间模式 |
| `fmi2CompletedIntegratorStep` | 通知积分步完成 |
| `fmi2SetTime` | 设置当前时间 |
| `fmi2SetContinuousStates` | 设置连续状态 |
| `fmi2GetDerivatives` | 获取状态导数 |
| `fmi2GetEventIndicators` | 获取事件指示器 |
| `fmi2GetContinuousStates` | 获取连续状态 |
| `fmi2GetNominalsOfContinuousStates` | 获取状态名义值 |

`fmi2NewDiscreteStates` 的 `fmi2EventInfo` 输出决定是否继续事件迭代：

```c
do {
    status = fmi2NewDiscreteStates(c, &info);
    if (status != fmi2OK && status != fmi2Warning) break;
    // 处理 info.terminateSimulation
    // 处理 info.valuesOfContinuousStatesChanged
    // 处理 info.nominalsOfContinuousStatesChanged
} while (info.newDiscreteStatesNeeded);
```

### 4.7 状态查询

`fmi2GetStatus` 等函数用于异步 `DoStep`。同步实现通常返回 `fmi2Discard` 或直接不支持。导入器可以只在检测到 `fmi2Pending` 时轮询。

---

## 5. 调用约束与常见错误

### 5.1 模式约束

| 操作 | 允许的模式 |
| --- | --- |
| `fmi2SetReal` 等 | 初始化、步进、事件模式（取决于变量） |
| `fmi2DoStep` | CS 步进模式，初始化完成后 |
| `fmi2GetDerivatives` | ME 连续时间模式 |
| `fmi2NewDiscreteStates` | ME 事件模式 |
| `fmi2Terminate` | 初始化完成后 |
| `fmi2Reset` | 任意已实例化状态 |
| `fmi2FreeInstance` | 任意已实例化状态 |

具体约束以规范中的状态机图为准。实现时建议用一个 `InstanceState` 枚举在调试构建中断言。

### 5.2 常见错误

1. **把 `fmi2Boolean` 当 `Bool`**：宽度错误，数组越界/错位。
2. **字符串生命周期错误**：`fmi2SetString` 的字符串只需在调用期间有效；`fmi2GetString` 返回的指针由 FMU 持有，下一次调用可能失效。需要立即复制。
3. **资源路径错误**：缺少 `file://`、缺少结尾 `/`、Windows 路径未转义。
4. **忽略 `fmi2Discard`**：异步/取消场景下把无效结果当有效。
5. **事件迭代不完整**：`newDiscreteStatesNeeded` 仍为 true 就回到连续时间模式。
6. **忘记 `fmi2CompletedIntegratorStep`**：ME 的事件/状态选择可能不正确。
7. **在 `fmi2FreeInstance` 后继续使用指针**：悬垂指针。
8. **跨线程调用同一实例**：FMI 2 不保证线程安全；除非规范/工具明确支持，否则串行化。
9. **状态句柄泄漏**：`fmi2GetFMUstate` 后未 `fmi2FreeFMUstate`。
10. **假设所有 FMU 都支持可选能力**：先读 `modelDescription.xml` 的能力标志。

---

## 6. 导入器实现建议

### 6.1 函数表

不要在每个调用点 `dlsym`。启动时解析一次，存入函数表：

```moonbit
struct Fmi2Functions {
  instantiate : Ptr[Unit]
  free_instance : Ptr[Unit]
  setup_experiment : Ptr[Unit]
  enter_initialization_mode : Ptr[Unit]
  exit_initialization_mode : Ptr[Unit]
  terminate : Ptr[Unit]
  reset : Ptr[Unit]
  get_real : Ptr[Unit]
  set_real : Ptr[Unit]
  // ...
}
```

实际类型应使用 MoonBit 的 `FuncRef`/`extern` 声明，而不是裸 `Ptr[Unit]`；上面只是示意。

### 6.2 封装层次

```text
RawBindings      // 逐个 C 函数，只做参数/返回值转换
    ↓
Instance         // 生命周期、状态断言、错误转换
    ↓
TypedAccess      // 按变量元数据处理 Real/Integer/Boolean/String
    ↓
MasterAlgorithm  // 步进、事件、结果记录
```

### 6.3 错误转换

把 `fmi2Status` 转成 MoonBit 的 `FmiError`：

```moonbit
enum FmiError {
  Warning(String)
  Discard(String)
  Error(String)
  Fatal(String)
  Pending
  Unsupported(String)
} derive(Debug)
```

日志回调中的消息应带上实例名、类别、状态，便于定位。

### 6.4 资源路径构造

```text
FMU 解压目录/
  resources/        ← fmuResourceLocation 指向这里
```

构造规则：

1. 取解压目录的绝对路径；
2. 转成 `file://` URI；
3. 确保以 `/` 结尾；
4. Windows 盘符前加 `/`，例如 `file:///D:/tmp/fmu/resources/`；
5. 对空格、`#`、`?`、非 ASCII 做百分号编码。

注意：以上仅适用于 FMI 2。FMI 3 的 `resourcePath` 是原生绝对路径，不构造 URI，见 [`fmi3-api.md`](fmi3-api.md) 的“资源路径”一节。

---

## 7. 参考

- 官方头文件：[`headers/fmi2/`](headers/fmi2/)
- FMI 2.0.4 规范：见 [`../references/links.md`](../references/links.md)
- FMPy 的 ctypes 封装： [`../research/fmpy.md`](../research/fmpy.md)
- fmi-rs 的绑定分层： [`../research/fmi-rs.md`](../research/fmi-rs.md)
- ABI 细节：[`../design/ffi-and-abi.md`](../design/ffi-and-abi.md)
