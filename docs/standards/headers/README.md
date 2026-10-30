# FMI C 头文件

本目录保存 FMI 官方 C API 头文件，作为 MoonBit FFI 绑定、C shim 和 ABI 测试的权威依据。

> **这些文件来自 FMI 官方仓库，保持原样，不修改。**

---

## 1. 来源

| 项目 | 值 |
| --- | --- |
| 仓库 | [`modelica/fmi-standard`](https://github.com/modelica/fmi-standard) |
| FMI 2 版本 | `v2.0.4` |
| FMI 3 版本 | `v3.0.2` |
| 目录 | `headers/fmi2/`、`headers/fmi3/` |
| 许可证 | 2-Clause BSD（见各文件头部） |

---

## 2. 文件清单

### 2.1 FMI 2.0.4

| 文件 | 作用 | 关键内容 |
| --- | --- | --- |
| [`fmi2TypesPlatform.h`](fmi2/fmi2TypesPlatform.h) | 基础类型 | `fmi2Component`、`fmi2ValueReference`、`fmi2Real`、`fmi2Boolean`、`fmi2String` |
| [`fmi2FunctionTypes.h`](fmi2/fmi2FunctionTypes.h) | 函数指针与回调 | `fmi2Status`、`fmi2CallbackFunctions`、`fmi2EventInfo`、所有 `fmi2XxxTYPE` |
| [`fmi2Functions.h`](fmi2/fmi2Functions.h) | 导出声明 | `FMI2_Export`、`fmi2FullName`、所有函数声明 |

### 2.2 FMI 3.0.2

| 文件 | 作用 | 关键内容 |
| --- | --- | --- |
| [`fmi3PlatformTypes.h`](fmi3/fmi3PlatformTypes.h) | 基础类型 | `fmi3Instance`、`fmi3ValueReference`（uint32）、`fmi3Float32/64`、`fmi3Int8..UInt64`、`fmi3Boolean`（bool）、`fmi3Binary`、`fmi3Clock` |
| [`fmi3FunctionTypes.h`](fmi3/fmi3FunctionTypes.h) | 函数指针与回调 | `fmi3Status`、`fmi3LogMessageCallback`、`fmi3IntermediateUpdateCallback`、`fmi3ClockUpdateCallback`、所有 `fmi3XxxTYPE` |
| [`fmi3Functions.h`](fmi3/fmi3Functions.h) | 导出声明 | `FMI3_Export`、`fmi3FullName`、所有函数声明 |

---

## 3. 校验和（SHA-256）

| 文件 | SHA-256 |
| --- | --- |
| `fmi2/fmi2Functions.h` | `99a96ab899c9245ed95f61a6f27bf255da4aacf5ecea250b43c93c714b1475a2` |
| `fmi2/fmi2FunctionTypes.h` | `b61f44eb767e566b507a22f36453ecafa41fd89fb4c2db3a99bf66491d8a927f` |
| `fmi2/fmi2TypesPlatform.h` | `838fb87c1f1c4a74c2c6a66716378c9c6db4900bb8c614d3ace38e90a682d7b6` |
| `fmi3/fmi3Functions.h` | `038358fb0209c3547fe8c6f03b80582960c93ce0a7d342b0d9348c8ce6137784` |
| `fmi3/fmi3FunctionTypes.h` | `d247d1c5fbf58e32379f1d38e7f73990709e0501fc4a9b3901ce3f9638503a0f` |
| `fmi3/fmi3PlatformTypes.h` | `1aa81efddeb84b0d9425f9226969525bd034cb63848c086b6696655179500616` |

校验方法：

```powershell
Get-ChildItem -Recurse docs\standards\headers -File |
  ForEach-Object { Get-FileHash $_.FullName -Algorithm SHA256 }
```

```bash
find docs/standards/headers -type f -name '*.h' -exec sha256sum {} +
```

---

## 4. 关键类型对照

### 4.1 FMI 2 vs FMI 3

| 概念 | FMI 2 | FMI 3 |
| --- | --- | --- |
| 实例 | `void* fmi2Component` | `void* fmi3Instance` |
| 值引用 | `unsigned int fmi2ValueReference` | `uint32_t fmi3ValueReference` |
| 实数 | `double fmi2Real` | `float fmi3Float32` / `double fmi3Float64` |
| 整数 | `int fmi2Integer` | `int8_t` ... `int64_t` / `uint8_t` ... `uint64_t` |
| 布尔 | `int fmi2Boolean`（4 字节） | `bool fmi3Boolean`（通常 1 字节） |
| 字符 | `char fmi2Char` | `char fmi3Char` |
| 字符串 | `const char* fmi2String` | `const char* fmi3String` |
| 字节 | `char fmi2Byte` | `uint8_t fmi3Byte` |
| 二进制 | 无 | `const uint8_t* fmi3Binary` + 长度 |
| 时钟 | 无 | `bool fmi3Clock` |
| 状态 | `void* fmi2FMUstate` | `void* fmi3FMUState` |
| 状态码 | `fmi2Status`（含 `Pending`） | `fmi3Status`（无 `Pending`） |
| 回调 | `fmi2CallbackFunctions` 结构体 | 实例化时分别传回调 |

### 4.2 最容易错的三个点

1. **布尔宽度**
   - FMI 2：`fmi2Boolean` 是 `int`，数组元素 4 字节。
   - FMI 3：`fmi3Boolean` 是 `bool`，通常 1 字节。
   - 不要用同一个 MoonBit `Bool` 数组绑定两个版本。

2. **`size_t`**
   - 32 位目标 4 字节，64 位目标 8 字节。
   - MoonBit 侧不能统一写 `UInt64`；要按 target 选择，或在 C shim 中转换。

3. **字符串所有权**
   - `fmi2GetString` / `fmi3GetString` 返回的指针由 FMU 持有。
   - 下一次调用可能覆盖；必须立即复制成 MoonBit `String`。
   - `fmi2SetString` / `fmi3SetString` 的指针只需在调用期间有效。

---

## 5. 导出宏与符号

### 5.1 `FMI2_Export` / `FMI3_Export`

头文件根据平台定义导出宏：

- Windows：`__declspec(dllexport)`
- GCC/Clang：`__attribute__((visibility("default")))`
- 其他：空

FMU 构建时通常还会定义 `FMI2_FUNCTION_PREFIX` 或 `FMI3_FUNCTION_PREFIX`，把函数名加上 `modelIdentifier_` 前缀：

```c
#define FMI2_FUNCTION_PREFIX MyModel_
#include "fmi2Functions.h"
```

导入器加载动态库时，优先查找无前缀符号；源码/静态库场景再查 `<modelIdentifier>_fmi2Xxx`。

### 5.2 版本字符串

- `fmi2Version` 定义为 `"2.0"`。
- `fmi3Version` 定义为 `"3.0"`。

运行时仍应调用 `fmi2GetVersion` / `fmi3GetVersion` 获取实际版本，不要只信编译期宏。

---

## 6. 在 MoonBit 中使用

### 6.1 不直接翻译头文件

不要试图把头文件逐行“翻译”成 MoonBit 的 `extern` 声明。建议：

1. 只绑定实际用到的函数。
2. 对结构体（`fmi2CallbackFunctions`、`fmi2EventInfo`）使用 C shim，避免布局差异。
3. 对数组/字符串/布尔做显式转换，不让 MoonBit 运行时类型直接跨边界。
4. 用 C 测试程序对同一 FMU 调用，作为 ABI 对照。

### 6.2 C shim 的职责

推荐为每个版本写一个小型 C shim（编译进 MoonFMI 的 native 后端或作为测试夹具）：

```c
// fmi2_shim.c
#include "fmi2Functions.h"

int moonfmi_fmi2_get_boolean(void* c, const fmi2ValueReference* vr, size_t n, int* out) {
    // 调用 fmi2GetBoolean，把 int 数组原样传出
    return (int)fmi2GetBoolean((fmi2Component)c, vr, n, out);
}
```

shim 负责：

- 固定宽度/符号；
- 可变参数日志回调的格式化；
- 结构体字段读写；
- 字符串/二进制生命周期；
- 平台差异（`size_t`、调用约定）。

MoonBit 侧只与 shim 的稳定 ABI 交互，降低直接绑定官方头文件的风险。

### 6.3 绑定测试

至少覆盖：

- 每个类型的 Get/Set 往返；
- 布尔数组的宽度；
- 字符串 UTF-8 往返（含非 ASCII）；
- 空数组、单元素、多元素；
- `size_t` 在 32/64 位目标的行为；
- 回调日志；
- 错误码转换；
- 实例释放后的悬垂指针检测（调试构建）。

---

## 7. 维护规则

1. **不修改**官方头文件。
2. 升级版本时整目录替换，更新版本、清单和 SHA-256。
3. 如果头文件与规范正文冲突，以头文件为准（ABI 以头文件为唯一真相），并在设计文档中记录。
4. 新增绑定前，先确认对应的 `fmiXxxTYPE` 签名，不要凭记忆写。
5. 每次修改 ABI 绑定，跑一遍 C shim 对照测试。

---

## 8. 参考

- FMI 2 API 说明：[`../fmi2-api.md`](../fmi2-api.md)
- FMI 3 API 说明：[`../fmi3-api.md`](../fmi3-api.md)
- ABI 设计：[`../../design/ffi-and-abi.md`](../../design/ffi-and-abi.md)
- 官方仓库：<https://github.com/modelica/fmi-standard>
