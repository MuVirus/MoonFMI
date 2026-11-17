# FFI 与 ABI 设计

> 状态：导入侧已在 Windows/Linux 实测（第三周），见 §8.1；导出侧与 FMI 3 仍是提案。
> 原则：**C 边界只传递固定宽度、固定布局的数据；结构体、可变参数、布尔和 `size_t` 交给 C shim。**

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

- 用 `src/backend/native` 的 `DynamicLibrary::symbol` / `funcref` 获取地址；
- 作为 `void*` 传给 shim；
- shim 按官方头文件转换为具体函数指针类型；
- 不在 MoonBit 侧手写 30 多个函数指针签名（容易错，且枚举/结构体难处理）。

这一层原本打算复用 `tonyfettes/dl`，但它的 `0.1.1` 钉在 `tonyfettes/c@0.7.4`，当前工具链装不上（见 [`../research/moonbit-ecosystem.md`](../research/moonbit-ecosystem.md) §2.1.1），所以 `src/backend/native` 改为自己声明平台函数、加一个 `dl.c`，接口形状仍与 `dl` 保持相近。替代方案（shim 自己 `dlopen` 并持有句柄）不采用：那样 shim 会变成完整加载器，跨平台代码更多。

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

1. 复制 `instanceName` / `category` / `message`；
2. 把消息截断到 4 KiB，且只截在 UTF-8 字符边界上，防止日志炸弹和半个字符；
3. 调用固定的 MoonBit 回调，或写入环形缓冲区；
4. 不抛异常、不长时间持锁。

**尚未处理可变参数本身。** 标准允许 `message` 按 `printf` 格式携带额外参数，但真正的 FMU 基本只传普通字符串；对任意 FMU 的格式串调用 `vsnprintf` 意味着把对方的格式错误变成宿主的未定义行为。当前实现直接使用 `message` 原文、忽略 `...`，并在记录里登记为已知限制。以后若遇到确实使用格式化的 FMU，再按白名单格式化，而不是无条件 `vsnprintf`。

### 4.2 回调策略

| 回调 | 首版策略 |
| --- | --- |
| `logger` | C 侧格式化 + 入队/直接回调 |
| `stepFinished` | 记录状态；异步 CS 后续支持 |
| `intermediateUpdate` | POC 后支持；需要同步决策 |
| `clockUpdate` / lock/unlock | 已实现:clockUpdate 计数通知,lock/unlock 为 no-op(单线程确定性调度) |

### 4.3 重入与线程

- 日志回调可能在 FMU 内部线程触发，因此 shim 不在回调里做复杂工作：只复制、截断、调用一次；
- 当前实现**没有队列，也没有锁**：消息在 FMU 调用的线程上同步投递到 MoonBit。这样不引入跨线程队列的所有权问题，代价是回调必须很快返回；
- 实测“FMU 自建线程打一条日志”不会崩，但“多个线程同时回调同一个实例”没有验证，暂按“同一实例同一时刻只有一个线程回调”假设；
- 实例释放前先把日志接收端标记为关闭，再由 shim 调 `fmi2FreeInstance`；释放之后到达的消息被丢弃，不会调用 MoonBit；
- 退休的实例上下文保留到库卸载，避免迟到的回调写到已释放内存。

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
  ├─ native-stub 里的 C 中间层（dl.c、fmi2_shim.c）
  └─ 动态加载封装（`src/backend/native`，自研）
```

**结论：按第一条路走通了，两个平台都不需要额外的编译或链接参数。**

在 `src/backend/native/moon.pkg` 里写：

```text
supported_targets = "native"

options(
  "native-stub": [ "dl.c", "fmi2_shim.c" ],
)
```

`moon build` / `moon test` 会把这两个文件交给工具链自带的 C 编译器（Windows 上是 MSVC `cl.exe`，Linux 上是系统 `cc`），编译产物直接进最后的可执行文件。实测结果：

| 项目 | 结果 |
| --- | --- |
| Windows x86_64（MSVC `cl.exe`） | 编译、链接、运行均正常 |
| Linux x86_64（WSL，`clang`/`cc`） | 编译、链接、运行均正常 |
| 头文件包含路径 | 相对路径可用，不需要 `-I` |
| CRT 选择 | 由工具链统一决定，不需要手工对齐 `/MD`、`/MT` |
| 链接参数 | 不需要 `cc-link-flags` |
| 符号冲突 | 未出现；shim 导出符号统一加 `moonfmi_` 前缀 |

第二、三条路（先编静态库、再编独立动态库）因此没有实际尝试。它们仍是备选：一旦某个平台的原生构建不再接受 `native-stub`，或者 shim 需要链接第三方 C 库，就退到静态库。届时 CRT 一致性问题会重新出现——这正是优先选第一条路的理由。

官方头文件不复制、不重写，直接按相对路径 `#include`：

```c
/* src/backend/native/fmi2_shim.c */
#include "../../../docs/standards/headers/fmi2/fmi2Functions.h"
```

`tests/abi/*.c` 在更深一层，写成 `../../docs/...`。这样头文件只有一份，标准升级时不会出现“shim 还在用旧结构体”的漂移。

### 8.1.1 C 调用 MoonBit 闭包

日志回调需要从 C 反调到 MoonBit，实测可行，但有两处与直觉不同：

1. **闭包以 `void*` 传入，调用要走一个 `FuncRef` 适配函数。** MoonBit 侧把一个 `(Int32, Bytes, Bytes, Bytes) -> Unit` 闭包和一个 `FuncRef[(closure, ...) -> Unit]` 一起传给 C；C 保存闭包指针，需要回调时调用适配函数，并把闭包作为第一个参数传回去。C 不能直接按 C 函数指针调用一个 MoonBit 闭包。
2. **C 传给 MoonBit 的参数是借用的，C 仍持有所有权。** 这与“传进去就归被调用方”的直觉相反。shim 每次回调会造三个 `Bytes`（实例名、类别、消息），调用适配函数之后必须自己 `moonbit_decref`：

   ```c
   instance->log_thunk(instance->log_closure, (int32_t)status, name, kind, text);
   moonbit_decref(name);
   moonbit_decref(kind);
   moonbit_decref(text);
   ```

   少写这三行，5 万条 4 KB 日志会让常驻内存涨 225 MB；补上之后同一测试稳定在噪声范围内。这个结论是实测出来的，不是文档里写的。

反过来，MoonBit 传给 C 的闭包由 C 持有：shim 把它存进实例上下文，释放实例时 `moonbit_decref`。两边方向相反，容易记反。

### 8.1.2 句柄与生命周期

`fmi2Library`（C 侧结构体）持有动态库句柄、11 个已解析的函数指针和一份“已退休实例”链表；`Fmi2Library`（MoonBit）只持有指向它的指针。实例释放时：

- 先由 MoonBit 关掉日志接收端，再由 shim 调 `fmi2FreeInstance`，释放 `log_closure`，把实例标成 `freed` 并挂到退休链表；
- 退休的上下文不立即 `free`，而是等库卸载时统一释放。这样即使 FMU 在 `fmi2FreeInstance` 返回后仍然从别的线程打日志，写到的也是有效内存，最多是日志被丢弃。

### 8.1.3 尚未解决的问题

- 只有 `x86_64` + MSVC/Clang 的实测数据，macOS、aarch64、32 位 Windows 未验证；
- `fmi2_shim.c` 目前只覆盖 CS 必需的 11 个函数，ME 的 `fmi2GetContinuousStates` 等尚未接入；
- 回调里再调回 FMU 这类重入场景没有测试。

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

`fmi2_shim.c` 只用负长度数组做断言，不用 `_Static_assert`——后者在 MSVC 的 C 模式下取决于 `/std:` 版本，而数组长度为负在所有 C 编译器上都是硬错误：

```c
typedef char moonfmi_assert_boolean_is_int[sizeof(fmi2Boolean) == 4 ? 1 : -1];
typedef char moonfmi_assert_value_reference_is_int[
  sizeof(fmi2ValueReference) == 4 ? 1 : -1];
typedef char moonfmi_assert_real_is_double[sizeof(fmi2Real) == 8 ? 1 : -1];
typedef char moonfmi_assert_logger_is_first[
  offsetof(fmi2CallbackFunctions, logger) == 0 ? 1 : -1];
```

这四条覆盖 CS 路径上最容易错位的四件事。断言失败时不是运行期读到错数据，而是编译直接报错。

编译期断言只覆盖“已经接入”的类型。完整的尺寸清单由 `tests/abi/probe.c` 打印，Windows 和 Linux 各有一份基准：

| 文件 | 内容 |
| --- | --- |
| `tests/abi/baselines/x86_64-windows.json` | MSVC 下的 FMI 2 + FMI 3 类型尺寸、回调字段偏移、枚举值 |
| `tests/abi/baselines/x86_64-linux.json` | 同一份清单在 Linux/clang 下的结果 |

两份文件内容目前完全相同，但分开保存：它们记录的是“这个平台实际是什么”，不是“我们认为应该相同”。`tests/abi/check-abi.mbtx` 逐字段比较，差异会打印成可读的行，`scripts/check.mbtx` 会调用它。

FMI 3 的 `fmi3Boolean` 在这些平台上实测 1 字节、`fmi3ValueReference` 4 字节，与 FMI 2 的 4 字节布尔形成对照。FMI 3 的 shim 还没写，但尺寸基线已经就位。

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

已覆盖：

| 项目 | 方式 | 状态 |
| --- | --- | --- |
| `sizeof`/`offsetof` | `probe.c` + 两份平台基准 | ✅ |
| 枚举值往返 | 基准文件 + `FmiStatus::from_int32` | ✅ |
| 回调结构体字段顺序 | 编译期断言 + 基准偏移 | ✅ |
| 变参日志格式化 | 假 FMU 的 7 种消息 | ✅ |
| 字符串 UTF-8（中文、emoji、截断） | 中文/emoji 往返、4 KB 边界退让 | ✅ |
| 实例/字符串生命周期 | 释放后无迟到回调、长消息不泄漏 | ✅ |
| 函数指针调用（CS） | BouncingBall 全流程 | ✅ |

未覆盖：

- FMI 2 int 数组与 FMI 3 bool 数组的批量转换（FMI 3 shim 未实现）；
- `size_t` 在 32 位目标上的行为；
- 二进制长度 0/非 0；
- ME 函数指针（SE 函数指针已覆盖）；
- 多实例并发日志（目前只测了单实例 + FMU 自身线程）。

### 10.3 对照测试

已建立一条完整的 C 对照链：

```text
tests/abi/fmi2_host.c         独立的 C 宿主，只用官方头文件
  → 加载 BouncingBall.fmu 里的 DLL/SO
  → 300 步 × 10 ms，每 0.5 s 采样 (time, h, v)
  → tests/abi/baselines/fmi2-bouncingball.json
  → tests/abi/check-host.mbtx 逐样本比较（相对误差 1e-9）
```

MoonBit 侧跑同一个模型，把六组采样和同一份基准逐个比较（时间误差 1e-9，变量误差 1e-12），见 `tests/integration/fmi2_wbtest.mbt`。C 宿主和 MoonBit 后端是两条独立路径，结果一致才说明 shim 没有读错位置。

尚未做：用 FMPy 跑同一模型交叉验证；用 `nm`/`dumpbin` 自动检查导出符号。

---

## 11. 待验证问题

P0 结束时的状态：1、3、5、6 已答；2、7 部分已答；4 明确留到支持 32 位时再答。未答项都不阻塞 P1 的 64 位 native 路径。

1. MoonBit native 构建如何链接外部 C 静态库/目标文件？
   **已答（第三周）**：不需要静态库——`native-stub` 直接把 C 文件编进包里，两个平台都通；详见 §8.1。
2. `FuncRef[T]` 能否安全表示所有 FMI 函数指针并跨 shim 传递？
   **部分已答**：`FuncRef` 用于 C→MoonBit 回调可行（§8.1.1）；FMU 返回的 CCS 函数指针仍由 shim 按官方头文件转换，不经 `FuncRef`。没有发现必须把 FMU 函数指针暴露给 MoonBit 的场景。
3. MoonBit 函数能否被 C 以固定签名回调（用于同步中间更新）？
   **已答**：能，闭包以 `void*` 传入，经 `FuncRef` 适配函数调用；参数是借用的，C 要自己 `moonbit_decref`。尚未测试在回调里再调回 FMU 的重入场景。
4. Windows 32 位的调用约定/结构体对齐是否与 64 位一致？
   **未答，首版只承诺 64 位**。32 位需要单独的 ABI 基线和测试样品，现有工具链也没有 32 位构建。
5. `fmi3Boolean` 在目标编译器上是否恒为 1 字节？
   **在已测平台上是**：Windows/MSVC 与 Linux/clang 的基线都是 1 字节；其他平台仍需基线确认。
6. C shim 与 MoonBit 运行时的 CRT/异常模型如何统一？
   **已答（native-stub 路线）**：C 文件由同一个构建、同一个编译器、同一套运行库编译，不存在两套 CRT；C++ 异常不参与，shim 只用返回码。
7. 回调线程与 MoonBit 运行时线程安全边界在哪里？
   **部分已答**：FMU 自有线程打日志不会崩（有测试）；日志是同步投递，不排队，回调里不能做阻塞操作。仍然不清楚多个线程同时回调时的 MoonBit 运行时保证，目前按“一个实例同一时刻只从一个线程回调”假设；P0 没有增加多线程并发验证。

---

## 12. 相关文档

- 导入器：[`importer.md`](importer.md)
- 主算法：[`master-algorithm.md`](master-algorithm.md)
- 导出器：[`exporter.md`](exporter.md)
- 官方头文件：[`../standards/headers/README.md`](../standards/headers/README.md)
- MoonBit 生态：[`../research/moonbit-ecosystem.md`](../research/moonbit-ecosystem.md)
