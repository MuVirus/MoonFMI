# FFI 与 ABI 设计

> 状态：设计提案 + 待工具链验证。原则：**C 边界只传递固定宽度、固定布局的数据；结构体、可变参数、布尔和 `size_t` 交给 C shim。**

---

## 1. 问题

FMI 的接口是 C ABI：

- 大量函数指针；
- 输出参数；
- 结构体（`fmi2CallbackFunctions`、`fmi2EventInfo`）；
- 可变参数日志；
- 版本相关的布尔/整数宽度；
- 字符串和二进制指针生命周期；
- 平台相关的调用约定和符号可见性。

MoonBit 的 `extern "c"` 可以声明 C 函数，但**不应假设 MoonBit 类型的内存布局与 C 完全一致**。因此采用两层：

```text
MoonBit 业务层
  ↕ 固定宽度标量 / 指针 / 字节缓冲区
C shim（用官方头文件编译）
  ↕ 真实 fmi2*/fmi3* 函数指针
FMU 动态库
```

---

## 2. 类型映射

### 2.1 FMI 2

| C 类型 | 典型宽度/布局 | MoonBit 侧 | 说明 |
| --- | --- | --- | --- |
| `fmi2Component` | `void*` | `@c.Pointer[Unit]` | 不透明实例 |
| `fmi2ComponentEnvironment` | `void*` | `@c.Pointer[Unit]` | 宿主上下文 |
| `fmi2FMUstate` | `void*` | `@c.Pointer[Unit]` | 不透明状态 |
| `fmi2ValueReference` | `unsigned int`，通常 32 位 | `UInt32` | shim 中断言 4 字节 |
| `fmi2Real` | `double` | `Double` | IEEE 754 binary64 |
| `fmi2Integer` | `int`，通常 32 位 | `Int32` | shim 中断言 |
| `fmi2Boolean` | `int` | `Int32` / 边界转 `Bool` | **不是** 1 字节 |
| `fmi2Char` | `char` | `Byte` | 仅作为 UTF-8 字节 |
| `fmi2String` | `const char*` | `@c.Pointer[Byte]` + 长度 | NUL 结尾 UTF-8 |
| `fmi2Byte` | `char` | `Byte` | 有符号性不要依赖 |
| `fmi2Status` | 枚举 | `Int32` | 枚举宽度由 C 实现决定 |
| `fmi2Type` | 枚举 | `Int32` | 同上 |
| `size_t` | 32/64 位 | `UInt32` / `UInt64` | 由 shim 统一转换 |

### 2.2 FMI 3

| C 类型 | 典型宽度/布局 | MoonBit 侧 | 说明 |
| --- | --- | --- | --- |
| `fmi3Instance` | `void*` | `@c.Pointer[Unit]` | 不透明实例 |
| `fmi3InstanceEnvironment` | `void*` | `@c.Pointer[Unit]` | 宿主上下文 |
| `fmi3FMUState` | `void*` | `@c.Pointer[Unit]` | 不透明状态 |
| `fmi3ValueReference` | `uint32_t` | `UInt32` | 固定 4 字节 |
| `fmi3Float32` | `float` | `Float` | binary32 |
| `fmi3Float64` | `double` | `Double` | binary64 |
| `fmi3Int8` | `int8_t` | `Byte` + 符号解释 | MoonBit 无独立 `Int8` |
| `fmi3UInt8` | `uint8_t` | `Byte` | |
| `fmi3Int16` | `int16_t` | `Int16` | |
| `fmi3UInt16` | `uint16_t` | `UInt16` | |
| `fmi3Int32` | `int32_t` | `Int32` | |
| `fmi3UInt32` | `uint32_t` | `UInt32` | |
| `fmi3Int64` | `int64_t` | `Int64` | |
| `fmi3UInt64` | `uint64_t` | `UInt64` | |
| `fmi3Boolean` | `bool`（通常 1 字节） | `Bool` / shim 中 `uint8_t` | 与 FMI 2 不同 |
| `fmi3Char` | `char` | `Byte` | UTF-8 字节 |
| `fmi3String` | `const char*` | 指针 + 长度 | NUL 结尾 UTF-8 |
| `fmi3Byte` | `uint8_t` | `Byte` | |
| `fmi3Binary` | `const uint8_t*` | 指针 + `size_t` | 长度单独传 |
| `fmi3Clock` | `bool` | `Bool` | |
| `fmi3Status` | 枚举 | `Int32` | 建议 shim 明确转 `int32_t` |
| `size_t` | 32/64 位 | `UInt32` / `UInt64` | 由 shim 转换 |

### 2.3 关键差异

| 项目 | FMI 2 | FMI 3 |
| --- | --- | --- |
| 布尔 | C `int`（4 字节） | C `bool`（1 字节） |
| 整数 | 只有 `int` | 8/16/32/64 位有符号/无符号 |
| 二进制 | 无 | 指针 + `size_t` |
| 实例化 | 单一 `fmi2Instantiate` | 按 ME/CS/SE 分开 |
| 回调 | 一个结构体 | 多个独立函数指针 |
| 内存分配回调 | 有 | 无 |

不要写一个“通用 Bool 数组”同时服务 FMI 2/3；这是最容易踩的 ABI 坑。

---

## 3. C shim 的职责

### 3.1 导入侧

shim 负责：

1. 把 MoonBit 的固定宽度参数转换成 C 类型；
2. 构造/解析结构体（回调、事件信息）；
3. 包装函数指针调用；
4. 处理 `size_t` 和枚举宽度；
5. 处理可变参数日志；
6. 提供线程安全日志队列；
7. 在边界捕获/记录错误，不让异常穿越。

示意 API：

```c
// moonfmi_shim.h
#include <stdint.h>
#include <stddef.h>

typedef void (*moonfmi_log_fn)(int32_t status,
                               const char* category,
                               const char* message,
                               void* userdata);

typedef struct {
    moonfmi_log_fn log;
    void* userdata;
} moonfmi_callbacks;

int32_t moonfmi2_instantiate(
    void* fn,                       /* fmi2InstantiateTYPE* */
    const char* instance_name,
    int32_t fmu_type,
    const char* guid,
    const char* resource_uri,
    moonfmi_callbacks* callbacks,
    int32_t visible,
    int32_t logging_on,
    void** out_component);

int32_t moonfmi2_do_step(
    void* instance,
    void* fn,                       /* fmi2DoStepTYPE* */
    double current,
    double step,
    int32_t no_set_prior,
    int32_t* event_needed,
    int32_t* terminate,
    double* last_successful_time);
```

MoonBit 侧：

```moonbit
extern "c" fn moonfmi2_do_step(
  instance : @c.Pointer[Unit],
  fn : @c.Pointer[Unit],
  current : Double,
  step : Double,
  no_set : Int32,
  event : @c.Pointer[Int32],
  terminate : @c.Pointer[Int32],
  last : @c.Pointer[Double]
) -> Int32 = "moonfmi2_do_step"
```

### 3.2 函数指针来源

- 用 `tonyfettes/dl` 的 `symbol` / `funcref` 获取地址；
- 作为 `void*` 传给 shim；
- shim 按官方头文件转换为具体函数指针类型；
- 不在 MoonBit 侧手写 30 多个函数指针签名（容易错，且枚举/结构体难处理）。

替代方案：shim 自己 `dlopen` 并持有句柄。这样 MoonBit 不依赖 `dl`，但 shim 变成完整加载器，跨平台代码更多。首版建议复用 `dl`，只把 ABI 细节放进 shim。

### 3.3 导出侧

纯 C 生成的 FMU 不需要 MoonBit shim；C 代码直接实现 `fmi2*` / `fmi3*`。

如果未来走“MoonBit 静态库 + C shim”：

```c
// 生成/手写的 C 入口
extern int32_t moonfmi_model_do_step(void* state, double t, double h);

fmi2Status fmi2DoStep(fmi2Component c, fmi2Real t, fmi2Real h, ...) {
    return moonfmi_model_do_step(c, t, h) == 0 ? fmi2OK : fmi2Error;
}
```

前提：

- MoonBit 能导出 C 可调用符号；
- 运行时初始化/GC 可嵌入；
- 链接模型确定（静态库/目标文件）；
- 不依赖 MoonBit 主程序入口。

这些是 P0 工具链验证项，未通过前不承诺 native 二进制导出。

---

## 4. 回调

### 4.1 FMI 2 日志是可变参数

```c
typedef void (*fmi2CallbackLogger)(
    fmi2ComponentEnvironment, fmi2String instanceName,
    fmi2Status status, fmi2String category,
    fmi2String message, ...);
```

不能直接把它映射成 MoonBit 函数。C shim 的 trampoline：

1. 用 `va_list` + `vsnprintf` 格式化 `message`；
2. 限制输出长度（例如 4 KiB），防止日志炸弹；
3. 复制 `instanceName` / `category`；
4. 调用固定的 `moonfmi_log_fn`，或写入环形缓冲区；
5. 不抛异常、不长时间持锁。

### 4.2 回调策略

| 回调 | 首版策略 |
| --- | --- |
| `logger` | C 侧格式化 + 入队/直接回调 |
| `stepFinished` | 记录状态；异步 CS 后续支持 |
| `intermediateUpdate` | POC 后支持；需要同步决策 |
| `clockUpdate` / lock/unlock | SE 后置 |

### 4.3 重入与线程

- 日志回调可能在 FMU 内部线程触发；
- shim 用互斥锁保护队列/上下文；
- 回调中不调用 MoonBit 复杂逻辑，只复制数据；
- MoonBit 侧消费队列时避免与 FMU 调用并发；
- 实例释放前先停止回调并清空队列。

### 4.4 `componentEnvironment`

指向 C 侧分配的上下文：

```c
typedef struct {
    moonfmi_callbacks callbacks;
    moonfmi_log_queue* queue;
    /* ... */
} moonfmi_instance_env;
```

不能指向可能被 MoonBit GC 移动的对象。上下文生命周期覆盖实例。

---

## 5. 字符串与二进制

### 5.1 字符串

| 方向 | 规则 |
| --- | --- |
| MoonBit → C | UTF-16 → UTF-8，追加 NUL，缓冲区在调用期间有效 |
| C → MoonBit | 立即复制，找 NUL 时有最大长度限制；再 UTF-8 解码 |
| 返回值 | 不释放、不缓存指针；下一次调用可能失效 |
| 数组 | `const char* values[]` 需要单独的指针数组 |
| 非法 UTF-8 | 默认报错；可选 `decode_lossy` 并警告 |

### 5.2 二进制

- FMI 3 的 `fmi3Binary` 是 `const uint8_t*`；
- 长度由单独的 `size_t valueSizes[]` 提供；
- `size = 0` 时指针可为 `NULL`；
- 读取后复制到 `Bytes`；
- 写入时保证缓冲区在调用期间有效；
- 不把二进制当 NUL 结尾字符串。

### 5.3 所有权

| 对象 | 所有者 | 释放 |
| --- | --- | --- |
| `fmi2Component` / `fmi3Instance` | 宿主 | `FreeInstance` |
| `fmi2FMUstate` / `fmi3FMUState` | FMU | `FreeFMUState` |
| getter 返回的字符串 | FMU | 不释放，立即复制 |
| getter 返回的二进制 | FMU | 不释放，立即复制 |
| setter 传入的字符串/二进制 | 宿主 | 调用返回后由宿主释放 |
| `fmi2CallbackFunctions` 结构体 | 宿主 | shim 持有到实例释放 |

---

## 6. 结构体与数组

### 6.1 `fmi2CallbackFunctions`

字段顺序固定：

```c
typedef struct {
    fmi2CallbackLogger         logger;
    fmi2CallbackAllocateMemory allocateMemory;
    fmi2CallbackFreeMemory     freeMemory;
    fmi2StepFinished           stepFinished;
    fmi2ComponentEnvironment   componentEnvironment;
} fmi2CallbackFunctions;
```

要求：

- shim 用官方头文件，不手写重复定义；
- 编译期 `offsetof` 断言；
- 不把 MoonBit struct 直接 reinterpret 成它；
- `allocateMemory`/`freeMemory` 使用与 FMU 约定一致的分配器（通常 `malloc/free`）；
- 若 `canNotUseMemoryManagementFunctions = true`，FMU 不应调用它们，但仍提供安全实现。

### 6.2 `fmi2EventInfo`

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

shim 负责读取字段并转换为 MoonBit 的 `EventInfo`；不要在 MoonBit 侧计算偏移。

### 6.3 数组

- FMI 2 的“数组”通常是多个标量变量，按 `valueReference` 批量调用。
- FMI 3 有真正的数组：`nValueReferences` 是变量数，`nValues` 是展开后的元素数。
- 分配输出缓冲区时按 `nValues`，不能只用 `nValueReferences`。
- 多维数组按行优先/列优先以规范为准；不要假设内存布局可直接映射。
- 维度乘积用 `UInt64` 计算并检查溢出。

---

## 7. 调用约定与符号

### 7.1 调用约定

- FMI 头文件没有显式 `__stdcall`，按平台默认 C 调用约定（Windows 上通常 `__cdecl`）。
- MoonBit `extern "c"` 对应 C 调用约定。
- 32 位 Windows 要特别测试；首版只承诺 64 位。
- 函数指针转换通过 shim 完成，避免 MoonBit 侧签名不匹配。

### 7.2 符号可见性

- 导入：`dlsym` / `GetProcAddress` 取符号，大小写敏感。
- 导出（native FMU）：Windows 需要 `.def` 或 `__declspec(dllexport)`；Linux 默认导出；macOS 注意 `install_name`。
- 不导出 MoonBit 运行时内部符号，避免冲突。
- 生成的 C 函数名必须是 `fmi2*` / `fmi3*`，不能加前缀。

### 7.3 枚举

C 枚举宽度由实现决定（可能是 `int`、`unsigned int` 或更小）。因此：

- shim 内部把 `fmi2Status` / `fmi3Status` 转成 `int32_t`；
- MoonBit 只接收 `Int32`；
- 不把枚举直接映射成 MoonBit enum 并假设 4 字节；
- 编译期用 `sizeof` 断言记录实际值。

---

## 8. 构建集成

### 8.1 导入侧

```text
moonfmi (native executable)
  ├─ MoonBit 核心/运行时
  ├─ C shim 静态库（libmoonfmi_shim.a / .lib）
  └─ tonyfettes/dl（或等价）
```

需要确认：

- MoonBit native 构建能否链接外部 C 静态库/目标文件；
- 头文件包含路径；
- CRT 一致（MSVC `/MD` vs `/MT`）；
- 异常模型一致；
- 符号冲突。

若不能直接链接，退路：

- 把 shim 编成独立动态库，MoonBit 通过 `dl` 加载并调用；
- 或减少 shim 范围，只对结构体/可变参数使用。

### 8.2 导出侧

纯 C FMU：

```text
生成的 C 源码 + 官方 fmi2Functions.h/fmi3Functions.h
  → CMake/cc
  → <modelIdentifier>.dll/.so/.dylib
```

不依赖 MoonBit 运行时，ABI 风险最低。

MoonBit 运行时 FMU：

```text
MoonBit 静态库 + C shim + 官方头文件
  → 链接为动态库
```

需要额外的运行时初始化和符号导出验证。

### 8.3 编译期断言

shim 中至少：

```c
_Static_assert(sizeof(fmi2Boolean) == sizeof(int), "fmi2Boolean must be int-sized");
_Static_assert(sizeof(fmi3Boolean) == 1, "fmi3Boolean must be 1 byte");
_Static_assert(sizeof(fmi3ValueReference) == 4, "valueReference must be 32-bit");
_Static_assert(sizeof(fmi2ValueReference) == 4, "fmi2ValueReference must be 32-bit");
_Static_assert(offsetof(fmi2CallbackFunctions, logger) == 0, "callback layout");
_Static_assert(offsetof(fmi2CallbackFunctions, componentEnvironment) > 0, "callback layout");
```

这些断言在 CI 的每个平台上编译一次；失败说明 ABI 假设不成立。

---

## 9. 错误处理

- shim 函数统一返回 `int32_t` 状态或错误码；
- 不使用 C++ 异常；
- 不把 MoonBit 异常抛过 C 边界；
- 空指针、长度不匹配、未知枚举在 shim 入口检查；
- 段错误/栈溢出无法在进程内捕获，必要时用子进程隔离；
- 日志队列满时丢弃最旧或最新记录，并设置溢出标志。

---

## 10. 测试矩阵

### 10.1 平台

| 平台 | 编译器 | 优先级 |
| --- | --- | --- |
| Windows x86_64 | MSVC | P0 |
| Linux x86_64 | GCC/Clang | P0 |
| macOS arm64 | Clang | P1 |
| Linux aarch64 | GCC | P1 |
| Windows x86 | MSVC | P2（仅 32 位验证） |

### 10.2 ABI 测试

- `sizeof`/`offsetof` 断言；
- 布尔数组转换：FMI 2 int 数组 vs FMI 3 bool 数组；
- `size_t` 在 32/64 位的长度参数；
- 枚举值往返；
- 字符串 UTF-8（中文、emoji、空串、最大长度）；
- 二进制长度 0/非 0；
- 回调结构体字段顺序；
- 变参日志格式化；
- 函数指针调用（每个接口至少一个 CS/ME 函数）；
- 实例/状态/字符串生命周期；
- 多实例并发日志。

### 10.3 对照测试

- 用 C 参考程序直接调用同一 FMU，比较返回值；
- 用 FMPy 跑同一模型，比较输出；
- 用 `nm`/`dumpbin` 检查导出符号；
- 用 WAT/反汇编检查 wasm 边界（WASM 后端）。

---

## 11. 待验证问题

1. MoonBit native 构建如何链接外部 C 静态库/目标文件？
2. `FuncRef[T]` 能否安全表示所有 FMI 函数指针并跨 shim 传递？
3. MoonBit 函数能否被 C 以固定签名回调（用于同步中间更新）？
4. Windows 32 位的调用约定/结构体对齐是否与 64 位一致？
5. `fmi3Boolean` 在目标编译器上是否恒为 1 字节？
6. C shim 与 MoonBit 运行时的 CRT/异常模型如何统一？
7. 回调线程与 MoonBit 运行时线程安全边界在哪里？

这些问题的答案应记录在 P0 spike 报告中，并更新本文。

---

## 12. 相关文档

- 导入器：[`importer.md`](importer.md)
- 主算法：[`master-algorithm.md`](master-algorithm.md)
- 导出器：[`exporter.md`](exporter.md)
- 官方头文件：[`../standards/headers/README.md`](../standards/headers/README.md)
- MoonBit 生态：[`../research/moonbit-ecosystem.md`](../research/moonbit-ecosystem.md)
