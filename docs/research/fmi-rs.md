# fmi-rs 研究

[fmi-rs](https://github.com/jondo2010/rust-fmi)（crate 名 `fmi`）是 Rust 生态中较完整的 FMI 2.0/3.0 实现，包含原始绑定、模型描述、导入、仿真、导出和打包。它的分层方式非常适合 MoonFMI 借鉴。

---

## 1. 为什么研究 fmi-rs

| 原因 | 说明 |
| --- | --- |
| 分层清晰 | `fmi-sys` / `fmi-schema` / `fmi` / `fmi-sim` / `fmi-export` 职责分明 |
| 强类型 | 用 Rust 类型系统表达 FMI 2/3 的差异 |
| 导入 + 导出 | 不只做 importer，还做 exporter |
| 测试语料 | `fmi-test-data` 提供参考 FMU |
| 现代工程实践 | feature flags、CI、文档、错误类型 |

它和 FMPy 形成互补：FMPy 偏“工具链完整性”，fmi-rs 偏“类型安全与可组合性”。

---

## 2. Crate 结构

| Crate | 职责 | 关键依赖/技术 |
| --- | --- | --- |
| `fmi` | 高层导入 API、实例、trait、错误类型 | `libloading`、`zip`、`tempfile` |
| `fmi-sys` | 原始 C 绑定 | `bindgen`，从官方头文件生成 |
| `fmi-schema` | `modelDescription.xml` 解析 | `serde` + `hard-xml`，强类型模型 |
| `fmi-sim` | 仿真主算法/CLI（WIP） | 复用 `fmi` |
| `fmi-test-data` | 测试 FMU | 参考 FMU |
| `fmi-export` | 导出 FMU 的 trait/辅助类型 | 过程宏、C ABI 包装 |
| `fmi-export-derive` | 导出宏 | `proc-macro` |
| `cargo-fmi` | Cargo 子命令，打包 FMU | 调用 `fmi-export` |
| `fmi-ls-bus` | FMI-LS-BUS 支持 | 分层标准 |

### 2.1 依赖方向

```text
fmi-sys（原始 C）
   ↑
fmi-schema（XML 模型）
   ↑
fmi（导入 + 实例 + 安全 API）
   ↑
fmi-sim（主算法）     fmi-export（导出） → cargo-fmi（打包）
```

`fmi-schema` 不依赖 `fmi-sys`，因此可以单独用于“只解析不加载”的场景。这一点对 MoonFMI 很重要：`info`/`validate` 不应依赖动态加载后端。

### 2.2 映射到 MoonFMI

| fmi-rs | MoonFMI | 差异 |
| --- | --- | --- |
| `fmi-schema` | `schema` | 同样把 FMI 2/3 类型化模型与校验放在一个包内，版本差异用文件拆 |
| `quick-xml` / `zip`（外部库） | `xml` / `zip` | 对应 `Milky2018/xml` / `fzip`，我们只包一层安全策略 |
| `fmi-sys` | `backend/native` | 原始 ABI 与 C shim 隔离在 native-only 包 |
| `fmi` | `fmi` | 打开 FMU、平台选择、`Instance` 抽象 |
| `fmi-export` + `fmi-export-derive` | `export` | MoonBit 没有过程宏，IR 与代码生成放在同一包 |
| `fmi-sim` | `sim` | 只保留主算法，CLI 拆到 `cli` |
| `fmi-test-data` | `tests/data` | 语料外部化，不入库 |

最大的结构差异来自工具链：Rust 用 feature flag 在 crate 内切换后端，MoonBit 只能靠包级 `supported_targets`，所以 `backend/native` 与 `backend/wasm` 必须分开。完整对照与理由见 [`../design/architecture.md`](../design/architecture.md) §3.2。

---

## 3. 导入流程

`fmi::import` 的核心流程（从源码注释和 API 可以确认）：

```text
from_path(path)
  → 打开 zip
  → 读取 modelDescription.xml（peek_descr 可只读元数据）
  → 解析 FMI 版本
  → 解压到临时目录（tempfile）
  → 定位 binaries/<platform>/<modelIdentifier>.{dll,so,dylib}
  → libloading::Library 加载
  → 解析 fmi2*/fmi3* 符号
  → 构造 Fmi2Import / Fmi3Import
  → instantiate_me / instantiate_cs / instantiate_se
```

### 3.1 轻量探测

```rust
let model_desc = import::peek_descr_path("model.fmu")?;
match model_desc.major_version()? {
    MajorVersion::FMI2 => { /* load as FMI 2 */ }
    MajorVersion::FMI3 => { /* load as FMI 3 */ }
    _ => { /* unsupported */ }
}
```

`peek_descr` 只读 `modelDescription.xml`，不解压整个 FMU。这对 CLI 的 `info`/`validate` 很有用。

### 3.2 内存导入

```rust
let bytes = std::fs::read("model.fmu")?;
let import: Fmi3Import = import::new(Cursor::new(bytes))?;
```

支持从 `Read + Seek` 导入，适合网络流、嵌入式资源、测试。

### 3.3 临时目录与生命周期

- 解压到 `tempfile::TempDir`；
- `FmiImport` 持有 `TempDir`，drop 时自动清理；
- 动态库必须在临时目录存在期间保持加载；
- 实例 drop 时调用 `fmi3FreeInstance` / `fmi2FreeInstance`。

### 3.4 对 MoonFMI 的启示

- `peek` / `info` 与完整导入分离。
- 解压目录的生命周期要绑定到 import 对象，不能提前删除。
- 支持从文件、内存、目录三种来源。
- 先解析版本，再决定加载哪套绑定，避免“先加载再发现版本不支持”。

---

## 4. Schema 设计

### 4.1 强类型模型

`fmi-schema` 用 Rust 结构体/枚举表达 FMI 2/3 的模型描述，典型做法：

- `ModelDescription` 是版本枚举或带版本字段的公共结构；
- 变量用枚举区分 Float64/Int32/...；
- 可选字段用 `Option<T>`；
- 枚举值用 Rust `enum`；
- XML 反序列化用 `serde` 派生（`hard-xml`）。

### 4.2 版本分派

```rust
pub enum ModelDescription {
    Fmi2(fmi2::ModelDescription),
    Fmi3(fmi3::ModelDescription),
}
```

或者用 trait：

```rust
pub trait FmiModelDescription {
    fn fmi_version(&self) -> &str;
    fn model_name(&self) -> &str;
    fn variables(&self) -> &[ModelVariable];
}
```

### 4.3 对 MoonFMI 的启示

- 用 MoonBit 的 `enum` 表达变量类型和版本，避免“大结构体 + 可选字段”。
- `Option<T>` 对应 MoonBit 的 `Option[T]`；默认值在解析后显式填充。
- 保留原始 XML/注解，便于写回和诊断。
- schema 包不依赖运行时后端，可单独测试。

---

## 5. 导入 API 与 trait

fmi-rs 用 trait 抽象导入和实例：

```rust
pub trait FmiImport {
    type ModelDescription;
    type Instance;
    fn model_description(&self) -> &Self::ModelDescription;
    fn instantiate_me(&self, name: &str, visible: bool, logging: bool) -> Result<Self::Instance>;
    fn instantiate_cs(&self, ...) -> Result<Self::Instance>;
}
```

实例 trait 提供：

- `get_version`、`set_debug_logging`；
- `enter_initialization_mode`、`exit_initialization_mode`；
- `get_*` / `set_*`（按类型）；
- `do_step`；
- `get_derivatives`、`get_event_indicators`；
- `get_fmu_state` / `set_fmu_state`；
- `terminate` / `reset`。

### 5.1 类型安全的值引用

fmi-rs 用 `ValueRef` 新类型包装 `u32`，避免和普通整数混淆。MoonFMI 可以借鉴：

```moonbit
struct ValueRef(UInt32) derive(Eq, Hash)
```

但要注意：FMI 2 的 `valueReference` 不要求全局唯一，不能假设 `ValueRef` 可以唯一标识变量；变量名/索引仍需要单独索引。

### 5.2 错误类型

fmi-rs 用 `thiserror` 风格的错误枚举，区分：

- IO/zip 错误；
- XML/schema 错误；
- 不支持的版本；
- 平台/二进制缺失；
- 符号缺失；
- FMI 调用失败（状态码）；
- 生命周期错误。

MoonFMI 应有类似的错误分类，且保留原始 FMI 状态码与日志。

---

## 6. 主算法（fmi-sim）

`fmi-sim` 是 WIP，但目标明确：

- 支持 ME/CS/SE；
- 读取输入、设置输出；
- 固定步长/变步长；
- 结果输出（CSV 等）；
- 复用 `fmi` 的导入 API。

### 6.1 对 MoonFMI 的启示

- 主算法不要和 CLI 绑死；先做库，再做 CLI。
- 结果输出格式和变量选择应是配置，不是硬编码。
- ME 的求解器可以插件化；首期只做显式 Euler。

---

## 7. 导出（fmi-export / cargo-fmi）

### 7.1 设计

`fmi-export` 提供 trait（类似）：

```rust
pub trait FmuModel {
    fn model_description(&self) -> ModelDescription;
    fn instantiate(&mut self) -> ...;
    fn do_step(&mut self, ...);
    // ...
}
```

`fmi-export-derive` 用过程宏生成：

- `modelDescription.xml`；
- C ABI 导出函数（`fmi3Instantiate...` 等）；
- 变量 get/set 的样板代码；
- 打包所需的元数据。

`cargo-fmi` 负责：

- 编译 `cdylib`；
- 生成 FMU 目录结构；
- 复制二进制/资源；
- 打包 zip。

### 7.2 对 MoonFMI 的启示

- 导出器的核心是“模型 trait + 代码生成 + 打包”，不是手写一堆 C 函数。
- MoonBit 没有 Rust 的过程宏生态，但可以用：
  - 显式 trait/struct；
  - 构建时代码生成（MoonBit 脚本/模板）；
  - 或手写少量样板。
- 首期导出“源码 FMU”时，C 包装层可以由模板生成，避免每个模型手写。

### 7.3 与 MoonBit 的差异

| 能力 | Rust | MoonBit | 影响 |
| --- | --- | --- | --- |
| 过程宏 | 成熟 | 有限/需确认 | 导出样板不能完全自动生成 |
| `cdylib` 导出 | 原生支持 | 当前不能直接导出 `.dll/.so` | native 二进制 FMU 受限 |
| 泛型/trait | 成熟 | 有 trait/泛型，但生态不同 | API 设计需简化 |
| C ABI | `extern "C"` + `#[no_mangle]` | `extern "C"` + C 包装 | 需要 shim |
| 测试数据 | `fmi-test-data` | 需自建/复用 | 直接复用 Reference-FMUs |

---

## 8. 测试与 CI

fmi-rs 的测试策略：

- `fmi-test-data` 提供参考 FMU；
- 单元测试覆盖 schema 解析、版本分派；
- 集成测试加载真实 FMU，跑 ME/CS；
- CI 多平台（Linux/Windows/macOS）；
- 文档测试（doctest）。

### 8.1 对 MoonFMI 的启示

- 测试 FMU 不要放进主仓库的大二进制；用下载脚本/子模块/LFS。
- CI 至少覆盖 Windows + Linux；macOS 可选。
- schema 解析测试应包含非法/边界语料，不只“happy path”。
- 集成测试要有超时，避免 FMU 死循环拖垮 CI。

---

## 9. 优点与局限

### 9.1 优点

- 分层极清晰，适合大型项目；
- 强类型，编译期排除大量错误；
- 导入/导出/打包一体化；
- 现代 Rust 工程实践；
- 测试数据可复用。

### 9.2 局限

- `fmi-sim` 仍是 WIP，主算法不完整；
- 导出依赖过程宏，学习曲线陡；
- 动态库加载依赖平台，跨平台仍需测试；
- 对 FMI 3 的某些新特性（SE/Clock）支持程度需逐项确认；
- 不是浏览器方案。

### 9.3 对 MoonFMI 的取舍

| fmi-rs 做法 | MoonFMI 是否采用 | 说明 |
| --- | --- | --- |
| `fmi-sys` / `schema` / `fmi` 分层 | ✅ | 对应 `backend/native` / `schema` / `fmi` |
| 强类型枚举 | ✅ | MoonBit enum |
| trait 抽象导入/实例 | ✅ | 但避免过度泛型 |
| 过程宏导出 | 🟡 | 用模板/代码生成替代 |
| 临时目录解压 | ✅ | 生命周期绑定 |
| `cargo-fmi` 打包 | 🟡 | 做 `moonfmi pack` |
| 测试数据 crate | ✅ | 复用 Reference-FMUs |

---

## 10. 可复用的具体经验

1. **先 `peek` 再加载**：版本不匹配时快速失败。
2. **临时目录生命周期绑定 import**：避免悬垂库路径。
3. **值引用新类型**：减少“整数混用”错误。
4. **错误分类**：IO/XML/版本/平台/符号/FMI 状态。
5. **schema 包独立**：支持只解析不加载。
6. **实例 drop 时释放**：RAII 思路，MoonBit 可用显式 `close`/`defer` 或资源包装。
7. **导出用 trait + 模板**：减少样板。
8. **测试 FMU 外部化**：不要污染仓库。
9. **按 target 拆包**：MoonBit 没有 feature flag，用独立包 + `supported_targets` 代替。
10. **文档与示例并重**：降低贡献者门槛。

---

## 11. 参考

- 仓库：<https://github.com/jondo2010/rust-fmi>
- `fmi` crate：<https://crates.io/crates/fmi>
- `fmi-schema`：<https://crates.io/crates/fmi-schema>
- `fmi-export`：<https://crates.io/crates/fmi-export>
- MoonFMI 的架构：[`../design/architecture.md`](../design/architecture.md)
- MoonFMI 的导出器：[`../design/exporter.md`](../design/exporter.md)
