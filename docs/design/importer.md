# 导入器设计

> 状态：设计提案。本文覆盖 native 动态库导入；WASM 导入见 [`wasm-strategy.md`](wasm-strategy.md)。

---

## 1. 范围

导入器负责把磁盘上的 `.fmu` 变成可调用的 FMI 实例：

```text
.fmu 文件
  → 读取 ZIP
  → 解析 modelDescription.xml
  → 结构与语义校验
  → 选择平台二进制
  → 安全解压
  → 加载动态库并绑定符号
  → 创建实例
  → 暴露类型化读写与生命周期操作
```

导入器**不负责**主算法、输入插值、结果记录；这些在 [`master-algorithm.md`](master-algorithm.md) 中定义。

### 1.1 首版支持矩阵

| 版本 | CS | ME | SE | 状态保存 | 方向导数 |
| --- | --- | --- | --- | --- | --- |
| FMI 2.0.4 | ✅ P0 | ✅ P1 | — | 可选 | 可选 |
| FMI 3.0.2 | ✅ P0 | ✅ P1 | ⏳ P2 | 可选 | 可选 |

“可选”表示按 `modelDescription` 的能力标志和符号是否存在决定；缺失时返回 `Unsupported`，不崩溃。

---

## 2. 打开流程

### 2.1 输入形式

支持：

- `.fmu` 文件（ZIP）；
- 已解压的 FMU 目录（便于开发和调试，需显式开启）；
- 内存中的 ZIP（测试/浏览器场景，后续）。

```moonbit
pub struct OpenOptions {
  platform_override : String?
  allow_directory : Bool
  require_binary : Bool
  max_xml_bytes : Int
  max_entries : Int
  max_uncompressed_bytes : UInt64
  temp_root : String?
}
```

默认 `require_binary = false`，这样 `validate` / `info` 可以只解析模型描述；`simulate` 时再要求二进制存在。

### 2.2 步骤

1. **检查文件存在、可读、非空**，记录绝对路径和大小。
2. **打开 ZIP**，读取中央目录；拒绝加密、分卷、ZIP64 中超出限制的条目。
3. **定位 `modelDescription.xml`**：只接受 ZIP 根目录下的精确名称，不接受嵌套路径或大小写变体。
4. **读取 XML**：限制大小、禁止 DTD/外部实体，检测 BOM 与编码。
5. **解析为类型化模型**：按 `fmiVersion` 分派 FMI 2 / FMI 3 解析器。
6. **语义校验**：执行 `schema` 包的 MD 规则，收集 error/warning。
7. **选择接口**：调用方指定 `CoSimulation` / `ModelExchange` / `ScheduledExecution`；未指定时按 CS → ME → SE 的偏好选择，并在结果中报告实际选择。
8. **选择平台与二进制**：见第 4 节。
9. **安全解压**：只解压运行需要的文件，或全部解压到私有临时目录。
10. **加载动态库**：按绝对路径加载，绑定必需符号。
11. **探测版本与类型平台**：调用 `fmi2GetVersion` / `fmi3GetVersion`、`fmi2GetTypesPlatform`。
12. **返回 `Fmu`**：持有模型描述、解压目录、库句柄和符号表。

任何一步失败都必须清理临时目录和已加载的库。

### 2.3 伪代码

```moonbit
pub fn open_fmu(path : String, options : OpenOptions) -> Fmu raise FmiError {
  let archive = Zip::open(path, options.zip_limits)?
  let xml_bytes = archive.read_exact("modelDescription.xml", options.max_xml_bytes)?
  let doc = Xml::parse(xml_bytes, XmlLimits::strict())?
  let md = Schema::parse(doc)?
  let report = Validate::model_description(md)
  if report.has_errors() {
    raise FmiError::semantic(report)
  }
  let platform = Platform::select(host_triple(), options.platform_override, md.version)?
  let layout = FmuLayout::inspect(archive, md, platform)?
  let dir = archive.extract(layout.needed_entries(), options.temp_root)?
  let lib = NativeLibrary::load(dir, layout.library_path)?
  let symbols = Symbols::bind(lib, md.version, md.interfaces)?
  Fmu::new(md, dir, lib, symbols, report)
}
```

---

## 3. FMU 容器处理

### 3.1 合法布局

```text
model.fmu
├─ modelDescription.xml         必需，根目录
├─ binaries/
│  ├─ win64/Model.dll
│  ├─ linux64/Model.so
│  └─ ...
├─ resources/                   可选
├─ sources/                     可选
├─ documentation/               可选
└─ terminalsAndIcons/           可选（FMI 3）
```

FMI 3 还允许 `buildDescription.xml`、`extra/` 等扩展内容。导入器只依赖 `modelDescription.xml` 和 `binaries/<platform>/`，其余文件保留但不主动执行。

### 3.2 安全解压

ZIP 是不可信输入。必须：

- 拒绝绝对路径、盘符、UNC、以 `/` 或 `\` 开头的条目；
- 拒绝任何 `..` 路径段；
- 拒绝 NUL、控制字符和非法 UTF-8 文件名；
- 拒绝符号链接/硬链接（ZIP 外部属性）；
- 限制条目数、单文件大小、总解压大小和压缩比；
- 不覆盖已存在文件；解压到新建私有目录；
- 规范化后再次确认目标路径位于解压根目录内；
- 失败时删除整个临时目录。

Windows 还要注意：

- 大小写不敏感导致的覆盖；
- 保留设备名（`CON`、`NUL`、`COM1` 等）；
- 尾随空格/点；
- `\\?\` 前缀。

### 3.3 解压策略

| 策略 | 用途 | 说明 |
| --- | --- | --- |
| 全部解压 | 首版、调试 | 简单，但大 FMU 成本高 |
| 按需解压 | 优化 | 至少解压所选平台目录、`resources/`、`modelDescription.xml` |
| 不解压 | `validate` / `info` | 直接从 ZIP 读取 XML，不加载库 |

首版建议全部解压，配合大小限制；后续再实现按需解压。`resources/` 必须一起解压，因为 FMU 可能通过 `resourcePath` 读取文件。

---

## 4. 平台选择

### 4.1 平台标识

| 版本 | 目录名 | 库扩展名 |
| --- | --- | --- |
| FMI 2 | `win32` / `win64` | `.dll` |
| FMI 2 | `linux32` / `linux64` | `.so` |
| FMI 2 | `darwin32` / `darwin64` | `.dylib` |
| FMI 3 | `x86_64-windows` / `x86-windows` / `aarch64-windows` | `.dll` |
| FMI 3 | `x86_64-linux` / `x86-linux` / `aarch64-linux` | `.so` |
| FMI 3 | `x86_64-darwin` / `aarch64-darwin` | `.dylib` |

FMI 3 的完整平台列表以规范为准；上表是当前需要支持的主机组合。不要用模糊匹配（例如把 `win64` 当成 `x86_64-windows`），版本与目录命名必须严格对应。

### 4.2 选择规则

1. 若提供 `platform_override`，只接受精确匹配，找不到直接报错。
2. 否则由编译目标确定 OS + 架构，映射到唯一目录名。
3. 只在该目录下查找 `<modelIdentifier>.<ext>`。
4. 若目录存在但文件缺失，报 `Platform` 错误并列出可用平台目录。
5. 若没有任何二进制，但 `sources/` 存在，报错时提示“该 FMU 需要先编译源码”。

### 4.3 modelIdentifier 安全

`modelIdentifier` 直接参与文件名拼接，必须：

- 非空；
- 不含 `/`、`\`、`:`、NUL；
- 不等于 `.` 或 `..`；
- 不含路径段；
- 建议限制为 `[A-Za-z_][A-Za-z0-9_]*`，但以规范为准。

校验失败对应规则 `MD-004` / `MD-062`，绝不允许“修复后继续”。

---

## 5. 动态库加载

### 5.1 加载方式

- 使用 `tonyfettes/dl` 或等价的 `dlopen` / `LoadLibraryW` 封装。
- 传入**绝对路径**，不使用裸文件名。
- POSIX：`RTLD_NOW | RTLD_LOCAL`，让符号解析错误尽早暴露，并避免污染全局符号表。
- Windows：优先 `LoadLibraryExW` + 安全搜索标志；若 FMU 依赖同目录 DLL，将该目录加入受限搜索路径，而不是修改全局 `PATH`。
- 不使用 `RTLD_GLOBAL`，除非某个 FMU 明确要求且用户显式开启。

### 5.2 依赖解析

FMU 可能依赖：

- 同目录下的其他 DLL/so；
- 系统运行库（MSVC、libgcc、libstdc++ 等）；
- `resources/` 中的数据文件（不是库依赖）。

策略：

1. 先把所选 `binaries/<platform>/` 加入**本次加载**的依赖搜索路径。
2. 加载失败时保留系统原始错误消息。
3. 提供诊断：缺失的依赖名、搜索过的目录、建议安装的运行库。
4. 不允许从当前工作目录或 `PATH` 任意位置加载同名库（防劫持）。

### 5.3 符号绑定

FMI 2 与 FMI 3 的函数名都是固定的 `fmi2*` / `fmi3*`，不使用 `modelIdentifier` 前缀。

必需符号（按接口）：

| 阶段 | FMI 2 | FMI 3 |
| --- | --- | --- |
| 元信息 | `fmi2GetVersion`, `fmi2GetTypesPlatform` | `fmi3GetVersion` |
| 生命周期 | `fmi2Instantiate`, `fmi2FreeInstance`, `fmi2SetupExperiment`, `fmi2EnterInitializationMode`, `fmi2ExitInitializationMode`, `fmi2Terminate`, `fmi2Reset` | `fmi3Instantiate*`, `fmi3FreeInstance`, `fmi3EnterInitializationMode`, `fmi3ExitInitializationMode`, `fmi3Terminate`, `fmi3Reset` |
| 读写 | `fmi2GetReal/Integer/Boolean/String`, `fmi2SetReal/Integer/Boolean/String` | `fmi3GetFloat32/Float64/Int8/.../String/Binary/Clock`, 对应 `Set*` |
| CS | `fmi2DoStep`, `fmi2CancelStep`, `fmi2GetStatus`, `fmi2GetRealStatus`, `fmi2GetIntegerStatus`, `fmi2GetBooleanStatus`, `fmi2GetStringStatus` | `fmi3EnterStepMode`, `fmi3DoStep` |
| ME | `fmi2SetTime`, `fmi2SetContinuousStates`, `fmi2GetDerivatives`, `fmi2GetEventIndicators`, `fmi2GetContinuousStates`, `fmi2GetNominalsOfContinuousStates`, `fmi2EnterEventMode`, `fmi2NewDiscreteStates`, `fmi2EnterContinuousTimeMode`, `fmi2CompletedIntegratorStep` | `fmi3SetTime`, `fmi3SetContinuousStates`, `fmi3GetContinuousStateDerivatives`, `fmi3GetEventIndicators`, `fmi3GetContinuousStates`, `fmi3GetNominalsOfContinuousStates`, `fmi3EnterEventMode`, `fmi3UpdateDiscreteStates`, `fmi3EnterContinuousTimeMode`, `fmi3CompletedIntegratorStep` |
| SE | — | `fmi3ActivateModelPartition`, `fmi3GetIntervalDecimal/Fraction`, `fmi3SetInterval*`, `fmi3GetShift*`, `fmi3SetShift*` |

可选符号：

- 状态保存：`fmi2GetFMUstate` 等 / `fmi3GetFMUState` 等；
- 方向导数：`fmi2GetDirectionalDerivative` / `fmi3GetDirectionalDerivative`；
- 输入/输出导数：`fmi2SetRealInputDerivatives`、`fmi2GetRealOutputDerivatives` / `fmi3GetOutputDerivatives`；
- 异步 CS：`fmi2SetRealInputDerivatives` 相关能力、`fmi3` 的早退回调；
- 中间更新回调（FMI 3）。

绑定策略：

1. 先绑定必需符号；任何缺失 → `Symbol` 错误，列出缺失函数。
2. 可选符号按能力标志延迟绑定；调用前检查 `Option`。
3. 不把 `dlsym` 返回的空指针当成可调用函数。
4. 保存符号表，避免每次调用重复 `dlsym`。

### 5.4 版本探测

加载后立即调用：

- FMI 2：`fmi2GetVersion()` 必须返回 `"2.0"` 兼容字符串；`fmi2GetTypesPlatform()` 必须返回 `"default"`。
- FMI 3：`fmi3GetVersion()` 必须返回 `3.0.x`。

若与 `modelDescription.xml` 的 `fmiVersion` 不一致，报 `Abi` / `Unsupported`，不继续实例化。

---

## 6. 实例生命周期

### 6.1 FMI 2 CS

```text
Instantiated
  → SetupExperiment
  → InitializationMode
  → StepMode（DoStep 循环）
  → Terminated
  → Freed
```

调用顺序：

1. `fmi2Instantiate(...)`
2. `fmi2SetupExperiment(...)`
3. `fmi2EnterInitializationMode()`
4. 设置初始输入/参数
5. `fmi2ExitInitializationMode()`
6. 循环：设置输入 → `fmi2DoStep(...)`
7. 用 `fmi2GetBooleanStatus(c, fmi2Terminated, ...)` 检查终止；用 `fmi2GetRealStatus(c, fmi2LastSuccessfulTime, ...)` 处理 Discard/异步
8. `fmi2Terminate()` → `fmi2FreeInstance()`

FMI 2 CS **没有主算法可见的事件模式**：事件由 FMU 内部处理，`fmi2EnterEventMode` / `fmi2NewDiscreteStates` 属于 ME。不要按 FMI 3 CS 的事件循环调用它们。

### 6.2 FMI 2 ME

```text
Instantiated
  → SetupExperiment
  → InitializationMode
  → ContinuousTimeMode
  → (EventMode → ContinuousTimeMode)*
  → Terminated
```

连续时间循环：

1. `fmi2SetTime(t)`
2. `fmi2SetContinuousStates(x)`
3. `fmi2GetDerivatives(dx)`
4. 积分器推进
5. `fmi2CompletedIntegratorStep(...)`
6. 事件发生时进入 EventMode，调用 `fmi2NewDiscreteStates`

### 6.3 FMI 3

FMI 3 的状态更多，必须按接口区分：

- CS：`fmi3EnterStepMode` / `fmi3DoStep`，事件模式下 `fmi3EnterEventMode` → `fmi3UpdateDiscreteStates` → `fmi3EnterStepMode`。
- ME：`fmi3EnterContinuousTimeMode`、`fmi3SetTime`、`fmi3SetContinuousStates`、`fmi3GetContinuousStateDerivatives`、`fmi3CompletedIntegratorStep`。
- SE：不使用 CS 的 `DoStep`，而由主算法按时钟调用 `fmi3ActivateModelPartition`；具体状态转换以 FMI 3 规范 SE 状态机为准。

FMI 3 的实例化函数按接口区分：

- `fmi3InstantiateModelExchange`
- `fmi3InstantiateCoSimulation`
- `fmi3InstantiateScheduledExecution`

导入器根据 `InterfaceKind` 选择，不能混用。

### 6.4 实例化参数

FMI 2：

```c
fmi2Component fmi2Instantiate(
    fmi2String instanceName,
    fmi2Type fmuType,              // fmi2ModelExchange / fmi2CoSimulation
    fmi2String fmuGUID,
    fmi2String fmuResourceLocation,// file:// URI
    const fmi2CallbackFunctions* functions,
    fmi2Boolean visible,
    fmi2Boolean loggingOn);
```

FMI 3：

```c
fmi3Instance fmi3InstantiateCoSimulation(
    fmi3String instanceName,
    fmi3String instantiationToken,
    fmi3String resourcePath,
    fmi3Boolean visible,
    fmi3Boolean loggingOn,
    fmi3Boolean eventModeUsed,
    const fmi3ValueReference requiredIntermediateVariables[],
    size_t nRequiredIntermediateVariables,
    fmi3InstanceEnvironment instanceEnvironment,
    fmi3LogMessageCallback logMessage,
    fmi3IntermediateUpdateCallback intermediateUpdate);
```

实现要点：

- `instanceName` 非空，默认使用 FMU 文件名去掉扩展名。
- FMI 2 的 `fmuResourceLocation` 是 URI，必须正确转义路径；Windows 盘符路径要转成 `file:///C:/...`。
- FMI 3 的 `resourcePath` 是**原生绝对路径**（`C:\...\resources\`，结尾带分隔符），不是 URI；无 `resources/` 目录或无文件系统时传 `NULL`。不要复用 FMI 2 的 URI 构造函数。
- 无论哪种形式，都要验证资源目录位于解压根内；`NULL` 只允许在确实没有资源时出现，不能因为实现偷懒而省略。
- `guid` / `instantiationToken` 从模型描述读取，不自行生成。
- `visible` 默认 `false`；无 UI 的 CLI 不应弹窗。
- `loggingOn` 由配置决定；日志回调必须始终提供，避免 FMU 在错误路径解引用空指针。

### 6.5 回调环境

FMI 2 的 `fmi2CallbackFunctions` 是一个结构体，包含：

```c
void* (*allocateMemory)(size_t);
void  (*freeMemory)(void*);
void  (*logger)(fmi2ComponentEnvironment, fmi2String instanceName,
                fmi2Status status, fmi2String category, fmi2String message, ...);
void  (*stepFinished)(fmi2ComponentEnvironment, fmi2Status);
fmi2ComponentEnvironment componentEnvironment;
```

导入器需要提供：

- 内存分配/释放：优先使用 C `malloc/free`，或按规范使用宿主分配器；必须与 FMU 预期一致。
- 日志：复制 `message`，不要保存指向 FMU 缓冲区的指针。
- `stepFinished`：用于异步 CS；同步模式下记录状态即可。
- `componentEnvironment`：指向宿主上下文，保证在实例生命周期内有效。

FMI 3 把回调拆成独立参数，结构更清晰，但同样要求生命周期覆盖实例。

---

## 7. 类型化访问

### 7.1 读写规则

- **输入**：只允许写 `causality="input"` 或可调参数；具体约束由主算法和校验器保证。
- **输出**：只允许读 `causality="output"`；但规范允许读取其他变量，导入器不强制，调试 API 可放宽。
- **参数**：初始化模式或可调窗口内写入。
- **离散状态/事件指示器**：通过专用 API 读取，不混入普通 getter。

### 7.2 批量调用

按类型分组，减少 ABI 次数：

```moonbit
pub fn get_reals(self, refs : Array[UInt32]) -> Array[Double] raise FmiError {
  let out = Array::make(refs.length(), 0.0)
  let status = self.symbols.get_real(self.handle, refs, refs.length(), out, refs.length())
  self.check_status(status, "fmi2GetReal")?
  out
}
```

FMI 2 / FMI 3 的 getter 都要求 `nValueReferences` 与 `nValues` 匹配；数组变量需要按维度展开或使用专用批量接口。

### 7.3 字符串

- 读取：FMU 返回的 `fmi2String` / `fmi3String` 指针只在调用期间有效，立即复制并转成 MoonBit `String`。
- 写入：把 MoonBit UTF-16 字符串编码为 UTF-8，追加 NUL，缓冲区在调用期间保持有效。
- 不缓存 FMU 返回的指针。
- 不假设字符串可写。

### 7.4 二进制

- FMI 3 的 `fmi3Binary` 是 `const uint8_t*`，长度由单独的 `size_t valueSizes[]` 给出。
- 读取时复制 `size` 字节；`size = 0` 允许 `NULL`。
- 写入时传指针 + 长度，不追加 NUL。
- 长度使用 `size_t` 映射，注意 32/64 位差异。

### 7.5 布尔

- FMI 2：`fmi2Boolean` 是 `int`，`fmi2True = 1`、`fmi2False = 0`。
- FMI 3：`fmi3Boolean` 是 C `bool`，头文件定义 `true/false`。
- MoonBit 内部统一 `Bool`；边界层按版本转换，不能把 `Bool` 数组直接 reinterpret 成 `int` 数组。

### 7.6 整数

- FMI 2 只有 32 位 `fmi2Integer`；MoonBit 用 `Int32` 或带范围检查的 `Int`。
- FMI 3 有 `Int8`…`UInt64`；MoonBit 没有独立的 `Int8`，用 `Byte` 存储并做有符号解释，或通过 C shim 处理。
- 写入越界值必须报错，不做静默截断。

---

## 8. 状态保存与恢复

按能力标志启用：

- `canGetAndSetFMUstate`
- `canSerializeFMUstate`

流程：

1. `get_fmu_state()` 得到不透明句柄；
2. 可选 `serialize_fmu_state()` 得到字节串；
3. `set_fmu_state()` 恢复；
4. `free_fmu_state()` 释放。

要求：

- 状态句柄绑定实例，不能跨实例使用；
- 序列化字节带版本/校验信息由上层决定，FMI 本身不定义格式；
- `free_fmu_state` 失败也要避免泄漏；
- 不支持时返回 `Unsupported`，主算法可选择“从时间 0 重放”而不是假装成功。

---

## 9. 错误与诊断

### 9.1 错误阶段

| 阶段 | 典型错误 | 建议错误类型 |
| --- | --- | --- |
| 打开 ZIP | 文件损坏、加密、超限 | `Zip` |
| 读取 XML | 编码错误、XXE、格式错误 | `Xml` |
| 解析模型 | 未知元素、类型错误 | `Schema` |
| 语义校验 | 引用不存在、组合非法 | `Semantic` |
| 选择平台 | 无匹配目录、缺二进制 | `Platform` |
| 加载库 | 依赖缺失、架构不匹配 | `Platform` / `Abi` |
| 绑定符号 | 必需函数缺失 | `Symbol` |
| 实例化 | 返回 NULL、日志报错 | `FmiCall` |
| 运行时调用 | 状态码 `Error`/`Fatal` | `FmiCall` |

### 9.2 日志捕获

实例化失败时，FMI 往往只返回 `NULL`，原因在日志回调里。导入器必须：

- 在调用 `instantiate` 前安装日志回调；
- 保存最近的日志（环形缓冲区，限制条数/总字节）；
- 失败时把日志附加到错误上下文；
- 不把日志直接打印到 stdout，避免污染 CLI 的 JSON 输出。

### 9.3 状态码

```moonbit
pub enum FmiStatus {
  Ok
  Warning
  Discard
  Error
  Fatal
}
```

- `Warning` 记录但继续；
- `Discard` 抛可恢复错误，附 `lastSuccessfulTime`（CS）或当前状态；
- `Error` 抛错误，实例进入不可继续状态；
- `Fatal` 立即终止，建议销毁实例。

---

## 10. 多实例与线程

- 同一 `Fmu` 可以创建多个实例（除非 `canBeInstantiatedOnlyOncePerProcess = true`）。
- 每个实例有独立的 `fmi2Component` / `fmi3Instance`。
- 动态库句柄共享，引用计数管理。
- FMI 实例默认非线程安全；导入器不添加全局锁，主算法负责串行化。
- 若 FMU 声明支持异步 CS，回调可能来自其他线程；回调边界只做线程安全入队。

---

## 11. 安全边界

**加载 native FMU 等于执行任意本机代码。** 导入器只能防止路径穿越、符号混淆和意外崩溃，不能把不可信 FMU 变成安全输入。

建议：

1. CLI 默认只加载用户显式指定的 FMU，并打印将要加载的库路径。
2. 提供 `--dry-run` / `validate`，只解析不执行。
3. 提供 `--sandbox`（后续）：在子进程中加载，超时/崩溃隔离。
4. 文档明确“不要运行来源不明的 FMU”。
5. WASM 后端利用 wasm 沙箱，作为不可信场景的长期方案。

---

## 12. 测试清单

### 12.1 单元测试

- ZIP 路径穿越、绝对路径、`..`、符号链接、超大条目；
- XML BOM、编码、DTD、外部实体、深层嵌套；
- 平台映射：每个 host triple 对应唯一目录；
- `modelIdentifier` 非法字符；
- 符号表缺失、可选符号缺失；
- 布尔/int 转换、UTF-8 往返、二进制长度 0；
- 状态码到错误对象的映射。

### 12.2 集成测试

使用真实 FMU：

- FMI 2 CS：`BouncingBall`、`Dahlquist`、`Feedthrough`；
- FMI 2 ME：`BouncingBall`、`VanDerPol`；
- FMI 3 CS/ME：Reference-FMUs 中对应版本；
- 缺少二进制、只有源码的 FMU；
- 依赖同目录 DLL 的 Windows FMU。

### 12.3 ABI 测试

- 32/64 位 `size_t`；
- FMI 2 `int` 布尔 vs FMI 3 `bool`；
- 结构体回调布局；
- 字符串指针生命周期；
- 数组长度与维度。

---

## 13. 相关文档

- 标准 API：[`../standards/fmi2-api.md`](../standards/fmi2-api.md)、[`../standards/fmi3-api.md`](../standards/fmi3-api.md)
- ABI 细节：[`ffi-and-abi.md`](ffi-and-abi.md)
- 主算法：[`master-algorithm.md`](master-algorithm.md)
- 校验：[`xsd-and-validation.md`](xsd-and-validation.md)
- 竞品实现：[`../research/fmpy.md`](../research/fmpy.md)、[`../research/fmi-rs.md`](../research/fmi-rs.md)
