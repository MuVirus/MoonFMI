# MoonBit 生态评估

本文评估 MoonFMI 在 MoonBit 上落地所需的语言能力、标准库/第三方库和工具链。结论是：**核心解析与主算法可以用纯 MoonBit 实现；系统边界（动态加载、C ABI、字符串/布尔/结构体）需要 C shim 或谨慎封装；WASM component 化需要 POC。**

> 工具链版本：`moon 0.1.20261023`。第三方包请在 [mooncakes.io](https://mooncakes.io) 上确认最新版本与维护状态。

---

## 1. 目标平台

`moon build --target` 支持：

```text
wasm, wasm-gc, js, native, llvm, all
```

| target | 用途 | 对 MoonFMI 的意义 |
| --- | --- | --- |
| `native` | 桌面/服务器 | 加载 native FMU 动态库（首选） |
| `wasm` | WASI/服务端 wasm | 未来 LS-WASM guest/host |
| `wasm-gc` | 浏览器/JS GC | 浏览器 UI/轻量逻辑，不是 LS-WASM |
| `js` | Node/浏览器 | CLI 替代、Web 前端 |
| `llvm` | LLVM 后端 | 性能敏感场景，后续评估 |

项目 `moon.mod` 当前设置：

```toml
preferred_target = "wasm"
```

这意味着默认构建偏向 wasm。对 native 导入器，需要在开发/CI 中显式 `--target native`，或在包级别做 target 条件编译。

---

## 2. 动态加载

### 2.1 候选库：`tonyfettes/dl`

从本地源码可以确认它提供：

```moonbit
struct DynamicLibrary(@c.Pointer[Unit])

pub fn DynamicLibrary::open(path : String) -> DynamicLibrary raise DynamicLibraryError
pub fn DynamicLibrary::try_open(path : String) -> DynamicLibrary?
pub fn DynamicLibrary::symbol(self, symbol : String) -> @c.Pointer[Unit] raise ...
pub fn DynamicLibrary::try_symbol(self, symbol : String) -> @c.Pointer[Unit]?
pub fn[T] DynamicLibrary::funcref(self, symbol : String) -> FuncRef[T] raise ...
pub fn[T] DynamicLibrary::unsafe_funcref(self, symbol : String) -> FuncRef[T]
pub fn DynamicLibrary::close(self) -> Unit raise ...
```

底层 C：

- Windows：`LoadLibraryW` / `GetProcAddress` / `FreeLibrary`；
- POSIX：`dlopen` / `dlsym` / `dlclose`；
- Windows 路径用 `String`（UTF-16）传给 `LoadLibraryW`；
- POSIX 路径用 `Bytes`（UTF-8）。

### 2.1.1 版本现状（2026-11-01 核实）

mooncakes 上只有 `0.1.0` 和 `0.1.1`，最后一次发布是 2026-02-03。`0.1.1` 把依赖钉在 `tonyfettes/c@0.7.4`，这个版本的 `moon.mod.json` 当前工具链已经不再支持，所以安装会直接失败：

```text
$ moon add tonyfettes/dl
Downloading tonyfettes/c@0.7.4
Error: When installing packages
Caused by:
    `moon.mod.json` at '.mooncakes/tonyfettes/c' is no longer supported.
    Run `moon fmt` to migrate to `moon.mod`.
```

“库存在”不等于“能用”。即使手工把缓存里的 `moon.mod.json` / `moon.pkg.json` 迁移成新格式（只是为了验证，不代表可复现的方案），还有第二道坎：它的 `dl.c` 无条件 `#include <dlfcn.h>`，没有任何 `_WIN32` 分支，在 Windows 上编译直接失败：

```text
dl.c(1): fatal error C1083: 无法打开包括文件: “dlfcn.h”: No such file or directory
```

P0 的两个目标平台里 Windows 是主力，这一条就足够判定不可用。此外它的能力也不够：错误只有一种 `DynamicLibraryError(String)`，分不出“缺依赖”和“缺符号”；没有“已卸载”状态，关闭后再取符号会拿到悬空指针；没有按错误码诊断，非英文 Windows 的错误文本里找不到 `126`。

P0 第二周因此没有采用它，改为在 `src/backend/native/dl.c` 里直接声明平台函数（通过 `native-stub` 编进构建），MoonBit 侧封装成 `src/backend/native/dynamic_library.mbt`。这样一来 `tonyfettes/dl` 从“默认方案”变成“它恢复维护后可以回来替换的可选项”，替换成本被限制在一个文件内。

同类的库里没有替代品：`tonyfettes/epoxy` 名字接近，但它是 OpenGL 函数指针分发，不是通用动态加载器。

### 2.2 对 MoonFMI 的意义

- native FMU 加载路径可行；
- 需要自己实现：
  - 平台目录选择；
  - 符号名（有无 `modelIdentifier_` 前缀）；
  - 函数签名绑定；
  - 错误信息（`dlerror` / `GetLastError`）；
  - 库的生命周期（FMU 实例释放后才能 `close`）。

### 2.3 注意事项

- `dlclose` 后不能再调用任何函数指针；MoonFMI 必须保证 `Instance` 先销毁。
- Windows 上 DLL 的依赖搜索路径可能影响加载；需要设置 `SetDllDirectory` 或使用绝对路径。
- macOS 的 `.dylib` 可能有 `@rpath` 依赖；需要测试。
- 某些 FMU 的动态库依赖同目录的其他库；解压后要保持目录结构。

---

## 3. C FFI

### 3.1 基本语法

MoonBit 用 `extern "c"` 声明 C 函数，例如（来自 `dl`）：

```moonbit
#borrow(path)
extern "c" fn dlopen(path : Bytes, flags : Int) -> @c.Pointer[Unit] = "moonbit_dlopen"
```

关键点：

- `extern "c"`：C 调用约定；
- `= "symbol"`：实际 C 符号名；
- `#borrow(x)`：告诉运行时该参数只借用、不转移所有权；
- `@c.Pointer[T]`：C 指针；
- `FuncRef[T]`：函数指针；
- `#cfg(platform="windows")`：平台条件编译。

### 3.2 结构体与回调是难点

FMI 2 的 `fmi2CallbackFunctions`、`fmi2EventInfo`，FMI 3 的多个输出参数，都涉及：

- 结构体布局/对齐；
- 函数指针；
- 可变参数日志；
- 输出指针。

MoonBit 直接映射这些结构体风险较高。推荐 **C shim**：

```c
// moonfmi_shim.c
#include "fmi2Functions.h"

MOONBIT_FFI_EXPORT
int32_t moonfmi_fmi2_get_boolean(void* c, const uint32_t* vr, size_t n, int32_t* out) {
    return (int32_t)fmi2GetBoolean((fmi2Component)c, (const fmi2ValueReference*)vr, n, (fmi2Boolean*)out);
}
```

MoonBit 侧只与固定宽度、固定布局的 shim 函数交互。shim 负责：

- `size_t` 转换；
- `fmi2Boolean`（int）与 `fmi3Boolean`（bool）转换；
- 字符串/二进制生命周期；
- 回调 dispatcher；
- 结构体字段读写。

### 3.3 回调 dispatcher

不要在 MoonBit 侧直接创建 C 可变参数函数。推荐：

```text
C shim 持有 fmi2CallbackFunctions
  → logger 把 message 复制到固定缓冲区
  → 调用 MoonBit 导出的 moonfmi_on_log(level, category, message)
  → MoonBit 侧解析并记录
```

这样：

- 避开可变参数；
- 避免 MoonBit 函数指针 ABI 不确定性；
- 可以在 C 侧做线程/重入保护。

### 3.4 导出 native 动态库

当前 MoonBit native 后端对“把包导出为 `.dll/.so`”的支持有限（`foreign_library` 产物和导出符号需按工具链版本实测）。这直接影响 native 二进制 FMU 导出：

- 不能假设 `moon build --target native` 直接产出可被 `LoadLibrary` 加载的 FMU 动态库；
- 可行路径是生成 C 包装层 + 用外部 C 编译器链接 MoonBit 生成的 C/静态库；
- 这条路径需要处理运行时初始化、GC、符号可见性、内存管理，工程成本高。

**结论：native 导入优先，native 二进制导出后置。**

---

## 4. 字符串与编码

### 4.1 事实

- MoonBit `String` 内部是 UTF-16。
- FMI 字符串是 UTF-8、NUL 结尾的 `const char*`。
- `@encoding/utf8` 提供 `encode` / `decode` / `decode_lossy`。
- `Bytes` 是字节数组。

### 4.2 转换策略

**MoonBit → C（SetString）：**

```text
String
  → @encoding/utf8.encode
  → 追加 NUL
  → Bytes（保证在调用期间存活）
  → 传 @c.Pointer[Byte]
```

**C → MoonBit（GetString）：**

```text
const char*
  → 找到 NUL（有最大长度限制）
  → 复制为 Bytes
  → @encoding/utf8.decode（或 decode_lossy）
  → String
```

注意：

- `fmi2GetString` / `fmi3GetString` 返回的指针由 FMU 持有，下一次调用可能失效；必须立即复制。
- `fmi2SetString` / `fmi3SetString` 的指针只需在调用期间有效；不要把临时 `Bytes` 提前释放。
- 非 ASCII 字符要测（中文、emoji、组合字符）。
- 非法 UTF-8 要有明确策略：报错或 `decode_lossy`，不要静默产生乱码。
- FMI 字符串不允许内嵌 NUL；导出时应拒绝或截断并报警。

### 4.3 资源路径

- **FMI 2** 的 `fmuResourceLocation` 是 **URI**（`file://...`）：Windows 盘符写成 `file:///C:/.../resources/`，空格、`#`、`?`、非 ASCII 需百分号编码。
- **FMI 3** 的 `resourcePath` 是 **原生绝对路径**（`C:\...\resources\`，结尾带分隔符），不做转义；无资源目录或无文件系统时传 `NULL`。
- 两套构造逻辑必须分开，用同一个“资源定位”抽象在内部统一成解压根内的相对路径。
- 不要直接把 MoonBit `String` 当 OS 路径传给 `LoadLibraryW`；`dl` 已经用 `OsString` 处理了这一点。FMI 3 的原生路径同样建议经 OS 层转换，避免编码问题。

---

## 5. 数值类型

MoonBit 可用：

```text
Int16, UInt16, Int32, UInt32, Int64, UInt64, Byte (UInt8), Float, Double
```

注意：

- **没有独立的 `Int8`**。FMI 3 的 `fmi3Int8` 用 `Byte` 存储 + 符号解释，或用 `Int16` 中转。
- `Int` 的宽度不要假设；跨 ABI 时用固定宽度类型。
- `size_t` 在 32 位目标 4 字节、64 位目标 8 字节；需要按 target 条件编译或在 C shim 中转换。
- `fmi2Boolean` 是 `int`（4 字节）；`fmi3Boolean` 是 `bool`（通常 1 字节）。不要共用 `Bool` 数组。
- `fmi3ValueReference` 是 `uint32_t`；用 `UInt32`。
- `fmi2ValueReference` 是 `unsigned int`；通常 32 位，但仍建议按头文件/平台确认。

### 5.1 建议的值容器

```moonbit
enum Value {
  F32(Float)
  F64(Double)
  I8(Byte)       // 按有符号解释
  U8(Byte)
  I16(Int16)
  U16(UInt16)
  I32(Int32)
  U32(UInt32)
  I64(Int64)
  U64(UInt64)
  Bool(Bool)
  Str(String)
  Binary(Bytes)
  Enum(Int64, String)  // 值 + 类型名
  Clock(Bool)
}
```

但主算法内部不建议每一步都用 `Value` 装箱；按类型列存数组更快。

---

## 6. XML

### 6.1 候选

| 包 | 类型 | 特点 | 风险 |
| --- | --- | --- | --- |
| `Milky2018/xml`（GitHub 仓库 `moonbit-community/xml-mbt`） | pull parser | 全后端、UTF-8、保留源码位置、实体展开有上限、跑过 W3C 1821 条一致性测试、Apache-2.0 | 整文档缓冲；不限制深度/属性长度（由封装层补） |
| `moonbit-community/XMLParser` | DOM / 解析器组合子 | 使用简单，带 `Location` | 大文件内存开销高；位置只在最后更新 |

注意：`Milky2018/xml` 的 mooncakes 包名和 GitHub 仓库名不一致，仓库叫 `moonbit-community/xml-mbt`。**它们是同一个库，不是两个候选。**

**默认选 `Milky2018/xml`**：它已经把 XML 本身最难的部分（实体、命名空间、编码、错误位置）做完了。我们再写一个只会在边界情况上栽跟头。

### 6.2 需求

MoonFMI 需要的 XML 能力：

- UTF-8、BOM、XML 声明；
- 元素/属性/文本；
- 命名空间（FMI 通常无 namespace，但要能处理）；
- 实体（只支持内置实体，禁外部实体）；
- 位置（行/列）用于诊断；
- 大小/深度限制；
- 保留未知属性/注解。

### 6.3 不建议依赖通用 DOM

- FMU 的 `modelDescription.xml` 可能很大（上万变量），DOM 内存开销高；
- pull parser 更适合流式构建类型化模型；
- 但 `Annotations` 需要保留子树，pull parser 要能捕获原始片段。

### 6.4 XSD

- MoonBit 没有成熟的 XSD 1.0/1.1 校验器；
- 不要试图在运行时实现完整 XSD；
- 用 XSD 作为字段清单，并在 CI 中做独立对照检查；
- 语义规则手写。

2026-11-01 查到的唯一相关包是 `ouoankang/moonbit-xsd-datatypes@0.1.2`（2026-10-30 发布，当日下载量两位数）。它只做 XSD 内置简单类型的词法解析和 facet 检查，不读 `.xsd` 文件、不做元素顺序和出现次数校验，因此达不到“校验一份 `modelDescription.xml`”的要求；新建、下载量低、API 未稳定，也不适合在 P0 引入。P0 仍按原计划用外部工具（`xmllint` / `lxml`）做对照。

详见 [`../design/xsd-and-validation.md`](../design/xsd-and-validation.md)。

---

## 7. ZIP

### 7.1 候选

| 包 | 特点 | 风险 |
| --- | --- | --- |
| `hustcer/fzip` | deflate、ZIP、Zip64、路径穿越防护、Apache-2.0 | ZIP 部分较年轻（2026-03 起），需实测条目/压缩比控制能力 |
| `bobzhang/zip` | 2026-10-29 发布，读写齐全，独立实现 | 才到 `0.1.2`，下载量低，未经过完整 FMU 语料验证 |
| `moonbit-community/flate` / `zipc` | deflate/zip 基础 | 功能覆盖需确认 |
| `moonbitstack/moonzip` | 社区 zip | 同上 |
| 自研目录解析 + 库解压 | 自己控制安全策略，deflate 用库 | 只写几百行，作为 `fzip` 不满足时的退路 |

### 7.2 FMU 的需求

- 读取 ZIP central directory；
- 支持 store 和 deflate；
- 支持 Zip64（大 FMU）；
- 路径安全（拒绝 `..`、绝对路径、盘符、NUL）；
- 解压到临时目录或内存；
- 保留文件权限（POSIX）不是必需；
- 加密 ZIP 不支持（FMI 不使用）；
- 符号链接：拒绝或安全处理。

### 7.3 建议

- 先评估 `fzip`，写一个 spike：解压 Reference-FMUs 的全部 FMU，校验文件数/大小/哈希。
- 如果 API 不合适，再考虑 `flate` + 自写 zip 容器。
- 不要用“解压到用户指定目录”作为默认行为；用临时目录，并在 `Import` 对象销毁时清理。
- 对压缩炸弹（高压缩比、超大解压）设置上限。

---

## 8. WASM 与 Component Model

### 8.1 MoonBit 产物

- `moon build --target wasm` 产出 core wasm；
- `wasm-gc` 产出依赖 GC 扩展的 wasm，适合浏览器，但不是 WASI p2 component；
- `js` 产出 JS；
- `native` 产出 native 可执行/库。

### 8.2 LS-WASM 要求

- `wasm32-wasip2` component；
- WIT world；
- resource、string、list、record 的 canonical ABI；
- imported callbacks。

### 8.3 工具链

- `wasm-tools` ≥ 1.200：`component wit`、`component embed`、`component new`、`validate`；
- `wit-bindgen`：生成 guest/host 绑定；0.63.0 的 MoonBit 后端可用，已支持 `resource` 的导出与 `[dtor]`；
- `jco`：浏览器端 component 转译；
- `preview2-shim`：WASI p2 的 JS 实现。

P0 第四周实际使用的版本：`wasm-tools 1.263.0`、`wit-bindgen 0.63.0`、`wasmtime 50.0.1`、`jco 1.40.0`、`moon 0.1.20261023`。探针与命令见 [`../../tests/spikes/wasm-component/`](../../tests/spikes/wasm-component/README.md)。

### 8.4 待验证

1. ✅ MoonBit wasm 模块能被 `wasm-tools component embed/new` 正确处理；`component embed` 必须加 `--encoding utf16`（MoonBit `String` 是 UTF-16）。
2. 🟡 `wit-bindgen` MoonBit 后端支持导出的 `resource`（构造、方法、`[dtor]`）；imported interface / 宿主回调尚未验证。
3. ✅ MoonBit 运行时在 component 中的初始化/分配可用；`cabi_realloc` 在 10 万字符和 1 MiB 字节数组上正常。
4. ✅ `string`、`list<u8>`、record 的 canonical ABI 与 MoonBit 内存布局兼容；wasmtime 和 jco/Node 两条路径往返一致。
5. 🟡 产物大小已记录（adder component 3.2 KB、codec 19.6 KB）；只有 jco/Node 的调用开销初测，没有 native 同模型对照。

详见 [`wasm-fmi.md`](wasm-fmi.md) 与 [`../design/wasm-strategy.md`](../design/wasm-strategy.md)。

---

## 9. 构建、测试与发布

### 9.1 构建

```bash
moon build --target native
moon build --target wasm
moon test
moon info
moon fmt
```

`moon.pkg` 当前用新语法：

```moonbit
pkgtype(kind: "executable")

import {
  "MuVirus/fmi" @lib,
}
```

### 9.2 测试

- 单元测试：`_test.mbt`（黑盒）、`_wbtest.mbt`（白盒）；
- 快照测试：`inspect` / `debug_inspect`；
- 覆盖率：`moon coverage analyze > uncovered.log`；
- 集成测试：加载真实 FMU，跑 CS/ME；
- 交叉检查：与 FMPy/OMSimulator 对比。

### 9.3 包管理

- 依赖在 `moon.mod` 的 `import` 中声明；
- 优先选择维护活跃、全后端可用的包；
- 核心包尽量零依赖或少依赖；
- 平台相关依赖放在后端包，避免 wasm 构建被 native 依赖污染。

### 9.4 发布

- `moon.mod` 的 `version`、`readme`、`repository`、`license` 要完整；
- 生成的 `.mbti` 要提交，便于审查 API 变化；
- 发布前跑 `moon info && moon fmt && moon test`；
- 二进制测试语料不要进包，使用下载脚本。

---

## 10. 依赖风险

| 依赖 | 风险 | 缓解 |
| --- | --- | --- |
| XML 库 | API 不成熟/不保留位置 | 默认 `Milky2018/xml`；不满足再自研 |
| ZIP 库 | Zip64/路径安全缺陷 | 默认 `fzip`；安全策略自己控制，必要时自写目录解析 |
| `dl` | 平台行为差异；`tonyfettes/dl` 已停止维护且装不上 | 自研 `dl.c` 封装；`tonyfettes/dl` 恢复维护再评估 |
| C shim | 构建/链接复杂 | 最小化 shim；CI 多平台 |
| `wit-bindgen` | MoonBit 后端不完整 | POC；手写 canonical ABI |
| `wasm-tools` | 版本要求高 | 固定版本；CI 缓存 |
| MoonBit 工具链 | 语法/后端变化 | 固定版本；升级时跑全量测试 |

---

## 11. 建议的实验

| 实验 | 目标 | 验收 |
| --- | --- | --- |
| E-01 | 用 `dl` 加载一个 C 共享库并调用函数 | 返回值正确 |
| E-02 | 用 MoonBit 实现 C 回调，被 C 调用 | 日志/回调正确 |
| E-03 | 解析 1000 个真实 `modelDescription.xml` | 无崩溃、错误可定位 |
| E-04 | 解压 100 个真实 FMU | 路径安全、哈希一致 |
| E-05 | MoonBit → wasm → component | `wasm-tools validate` 通过 |
| E-06 | MoonBit component 被 wasmtime 调用 | 结果正确 |
| E-07 | MoonBit component 被浏览器 `jco` 调用 | 结果正确 |
| E-08 | 32/64 位 ABI 测试 | 布尔/`size_t`/字符串正确 |

每个实验的代码/结果应记录在 `research` 或 issue 中，避免“文档说可行但没人验证”。

---

## 12. 参考

- MoonBit 文档：<https://docs.moonbitlang.com>
- MoonBit 包仓库：<https://mooncakes.io>
- `tonyfettes/dl`：<https://github.com/moonbit-community/tonyfettes-dl>
- `wasm-tools`：<https://github.com/bytecodealliance/wasm-tools>
- `wit-bindgen`：<https://github.com/bytecodealliance/wit-bindgen>
- MoonFMI 的 ABI 设计：[`../design/ffi-and-abi.md`](../design/ffi-and-abi.md)
- MoonFMI 的架构：[`../design/architecture.md`](../design/architecture.md)

---

## 13. 依赖清单与准入规则（2026-11-01 核实）

### 13.1 已在用的第三方依赖

版本号对照 mooncakes 的模块接口（`https://mooncakes.io/api/v0/modules/<用户>/<模块>`）逐个查过，下面五个都已经是最新发布版本，没有可升级项。

| 依赖 | 锁定版本 | mooncakes 最新 | 许可证 | 用在哪 | 备注 |
| --- | --- | --- | --- | --- | --- |
| `Milky2018/xml` | 0.6.1 | 0.6.1 | Apache-2.0 | `src/xml` | 无传递依赖；pull 模式；位置信息完整 |
| `hustcer/fzip` | 0.8.8 | 0.8.8 | Apache-2.0 | `src/zip` | 无传递依赖；只用来解压，安全策略自写 |
| `moonbitlang/async` | 0.22.9 | 0.22.9 | Apache-2.0 | `scripts/check.mbtx`（frontmatter 锁定，不进 `moon.mod`） | 官方异步运行时；门禁脚本靠它的 `@process` 派生工具链子进程（仅 native 后端），2026-11-10 发布，Windows 走 IOCP 实现 |
| `moonbitlang/x` | 0.5.7 | 0.5.7 | Apache-2.0 | `src/xml`（`encoding`）、native 后端与集成测试（`fs`） | 官方实验包，接口可能变 |
| `tonyfettes/c` | 0.8.0 | 0.8.0 | Apache-2.0 | `src/backend/native`、集成测试 | 传递依赖 `tonyfettes/nat@0.1.2` |

`moonbitlang/core` 随工具链发布，不在 `moon.mod` 里，版本由 `moon` 的版本固定。

**2026-11-15 评估：`moonbitlang/async` 进入 `scripts/check.mbtx`。** 背景：`scripts/check.sh`/`check.ps1` 两份门禁脚本需要手工保持同步，改用 MoonBit 单文件脚本（`.mbtx`，moonc v0.10.19 起格式改进、语言服务支持）统一为一份。选型过程：`.mbtx` 只能通过 `moonbitlang/async` 的 `@process` 派生子进程（wasm 后端没有该包，必须 `--target native`），core 无进程 API，`tonyfettes/dl` 装不上（见 §13.2），无替代品。版本经 mooncakes API 核实为最新（0.22.9，未 yanked），Apache-2.0，官方维护。frontmatter 逐包锁 `@0.22.9`，因脚本模式的无版本导入会解析到"本地索引最新"，违反锁版纪律。该依赖只服务于开发者/CI 工具脚本，不进产品代码路径，`moon.mod` 不受影响。实测（Windows 11、moon 0.1.20261104）：子进程/退出码/stdin 继承、文件 IO、目录遍历全部通过，依赖缓存后脚本启动约 1 秒。

**2026-11-15 追记：阶段 1 完成，node 从工具链中移除。** tools/check-deps.mbtx、tests/abi/{check-abi,check-host,build-fixture,run-fmi2-host}.mbtx、tests/data/fetch-fmus.mbtx 全部落位，check.sh/check.ps1 与全部 .mjs/.sh/.ps1 辅助脚本删除（validate-xsd.ps1 保留——它用 .NET 的 XSD 引擎做独立交叉验证，转成 MoonBit 会失去独立性）。fetch-fmus 内置了自实现的 SHA-256（core 无 crypto 包），9 个 FMU 的 manifest 哈希作为黄金向量逐字节校验通过；解压改用项目已有的 hustcer/fzip。网络备注（2026-11-16 补跑验证时）：本机 DNS 把 release-assets.githubusercontent.com 解析成 127.0.0.1/::1（污染），导致任何客户端的 GitHub release 资产下载都在 302 跳转后"连接被拒"；github.com 本体与 gitee/gitcode/mooncakes 可达。恢复手段是 curl --resolve 钉住真实 IP（185.199.108-111.133）下载后交给 fetch-fmus.mbtx 校验解压——bundle 的 SHA-256 使任何下载渠道都安全。CI 在 GitHub 托管 runner 上不受此影响。
注意事项：native 正则引擎不支持 s 类简写（unsafe_from_string 直接 panic），脚本一律用显式字符类 [ 	]；@env.args()[0] 是编译出的可执行文件自身路径，解析用户参数从下标 1 开始。

**2026-11-19 评估：`moonbitlang/async@0.22.9` 从"仅门禁脚本"提升为产品依赖（用户批准）。** 背景：0.7.0 的 `--sandbox` 崩溃隔离需要 CLI 派生子进程（重执行自身 + 超时强杀），产品代码无进程 API（§13.2），`@process` 是唯一能力。版本仍为 0.22.9（mooncakes 最新，未 yanked），Apache-2.0，官方维护；2026-11-15 起已在 `scripts/check.mbtx` 实战（子进程/退出码/超时 kill 均验证过）。变更：`moon.mod` import 加锁 `@0.22.9`，`src/cli` 包导入 `@process`；仅 native 后端（`src/cli` 本就 `supported_targets = "native"`），wasm 目标构建不受影响。边界如实记录：这是崩溃隔离 + 超时强杀，不是权限沙箱——子进程 FMU 仍以宿主用户身份运行。

**2026-11-20 已引入：`MuVirus/moonfig@0.2.4` 进入 `moon.mod`（锁版本），仅 `src/cli` 包导入**（该包 `supported_targets = "native"`，wasm 构建不受影响）。用途：`simulate`/`couple` 的配置文件与环境变量入口——JSON/INI/dotenv 三种格式由 `format_detect` 按后缀与内容判定，环境变量用 `MOONFMI_` 前缀加双下划线分层。传递依赖仍只有 `moonbitlang/x@0.5.7`，**没有新增传递依赖**；`moon info` 的 `.mbti` diff 为空（配置层全部是包内私有项，公开 API 未变）。实现细节与取舍见 [`../design/config-layer.md`](../design/config-layer.md)，集成中发现的库能力缺口与临时替代见 [`../roadmap/moonfig-gaps.md`](../roadmap/moonfig-gaps.md)。

**2026-11-20 评估：`MuVirus/moonfig@0.2.4`（第一方自有库）。** 背景：CLI 只有命令行一种输入通道——17 个长选项分散在 6 个手写解析点，没有配置文件入口，环境变量只用于 `doctor` 读 `PATH` 与 `--sandbox` 的子进程标记；实验规格无法存盘、无法进 CI 复现。`moonfig` 是同作者（MuVirus）的 MoonBit 原生配置库，提供多来源合并、类型化提取、来源追踪与校验。版本 0.2.4 经 mooncakes API 核实为最新（2026-11-20 15:11 UTC 发布，未 yanked，build_status success），Apache-2.0，下载量 285，依赖者 0（MoonFMI 将是第一个消费者）；传递依赖仅 `moonbitlang/x@0.5.7`，与本项目已锁版本一致，**不引入新的传递依赖**。0.2.x 相对 0.1.x 是破坏性重构（包路径由 `core/source/*` 改为 `core/format/*`，TOML/YAML/XML/CBOR/serde 拆成独立适配器模块），0.2.4 相对 0.2.3 同样是破坏性变更（环境变量分隔符改为按需开启、`CliSource` 接受负数值），接入须锁 `@0.2.4` 且只用 core 稳定面（`Config`/`Getter`/`Rule`）。替代方案：自研最小配置读取（约 200–300 行），但合并、校验、来源追踪都要重造并与同作者的库分叉。不引入的后果：配置层缺口保留，CLI 取值解析继续分散在 6 处。方案与取舍见 [`../design/config-layer.md`](../design/config-layer.md)，集成过程中发现的库能力缺口与临时替代见 [`../roadmap/moonfig-gaps.md`](../roadmap/moonfig-gaps.md)。关于 §13.3 规则 5（发布不足一个月不进核心路径）：该条针对未审计的第三方包，moonfig 是第一方自有库，风险性质不同——但 0.2.x 当天两次破坏性变更且无依赖者，接入会替上游试错，因此设计按阶段落地并保留行为等价性测试作闸门。

### 13.2 计划需要、但生态里没有（或不能用）的能力

| 能力 | 生态现状 | 处理 |
| --- | --- | --- |
| 动态库加载 | 只有 `tonyfettes/dl@0.1.1`，钉在 `tonyfettes/c@0.7.4`，当前工具链装不上（见 §2.1.1）；`tonyfettes/epoxy` 是 OpenGL 分发，不可替代 | 自研 `src/backend/native/dl.c` + `dynamic_library.mbt` |
| 通用 XSD 校验 | 只有 `ouoankang/moonbit-xsd-datatypes@0.1.2`，仅覆盖内置简单类型 | 不引入；CI 用外部 `xmllint` / `lxml` 对照 |
| FMI/FMU 本身 | mooncakes 搜不到任何 FMI 实现 | 自研，这本来就是项目目标 |
| ZIP 写入（导出阶段才需要） | `fzip` 支持；另有 `bobzhang/zip@0.1.2` | 暂不引入新包，`fzip` 够用就继续用 |

### 13.3 准入规则

1. **引入前先告知**：用途、锁定版本、是否最新、许可证、维护状态（最后发布时间、下载量）、替代方案、不引入的后果，得到确认再改 `moon.mod`。
2. **升级同样要告知**：已用依赖从 A 升到 B，也要先说明变了什么、为什么要升。
3. 能用手头的库或标准库解决，就不新增依赖；安全边界（路径、大小、压缩比、实体）永远自己写，不外包给库的“默认行为”。
4. 引入或升级后，更新 §13.1 的表格并锁版本；评估过程写在本文件，不写进代码注释。
5. 发布不足一个月、下载量极低的包，不进核心路径；只能用于试验，并准备自研退路。
