# WASM 策略

> 状态：设计提案 + 待验证。LS-WASM 仍是草案，本文把工具链风险隔离在 `backend/wasm` 一个包里；导出侧的 WIT 生成留在 `export`。

---

## 1. 结论先行

1. **WASM 不是 native 导入器的替代品**，而是第二个后端：native 加载 `.dll/.so`，WASM 加载 component。
2. **唯一值得投入的标准路径是 FMI-LS-WASM**。自定义 JS ABI 只能用于内部 POC，不作为对外接口。
3. **MoonBit 的直接产物是 core wasm，不是 component**。必须经过 `wit-bindgen` + `wasm-tools component embed/new` 或等价工具链。
4. **先做宿主，再做 guest**：如果 MoonBit 作为宿主的 POC 更容易，可以先跑通 wasmtime 加载第三方 component，再反推导出需求。
5. **首期只承诺 CS/ME**；SE 依赖线程/抢占模型，后置。

---

## 2. 架构位置

```text
                    ┌─────────────────────┐
                    │ fmi                 │
                    │  Instance/Backend   │
                    └──────────┬──────────┘
             ┌─────────────────┴─────────────────┐
             │                                   │
   ┌─────────▼─────────┐               ┌─────────▼─────────┐
   │ backend/native    │               │ backend/wasm      │
   │ dlopen + C ABI    │               │ component + WIT   │
   └─────────┬─────────┘               └─────────┬─────────┘
             │                                   │
   ┌─────────▼─────────┐               ┌─────────▼─────────┐
   │ native FMU        │               │ LS-WASM FMU       │
   │ binaries/<plat>/  │               │ binaries/         │
   │                   │               │ wasm32-wasip2/    │
   └───────────────────┘               └───────────────────┘
```

`sim` 不知道后端差异；它只调用 `fmi` 中的 `Instance`。

---

## 3. 产物与工具链

### 3.1 目标格式

```text
MoonBit 源码
  → moon build --target wasm
  → core module (.wasm)
  → wit-bindgen（生成 guest 绑定/适配层）
  → wasm-tools component embed
  → wasm-tools component new
  → component (.wasm)
  → 放入 FMU 的 binaries/wasm32-wasip2/
```

关键问题不是“能不能编译成 wasm”，而是：

- MoonBit 运行时能否在 component 中初始化；
- canonical ABI 是否支持 `string`、`list<T>`、`resource`、`option<T>`；
- `wit-bindgen` 是否有可用的 MoonBit 后端；
- WASI p2 adapter 是否与 MoonBit 的导入匹配；
- 生成的 component 是否保留 MoonBit GC/内存管理。

### 3.2 工具链版本固定

WASM 工具链变化快。项目应固定：

- MoonBit 版本；
- `wasm-tools` 版本；
- `wit-bindgen` 版本；
- `jco` / wasmtime 版本；
- LS-WASM 草案 commit。

在 `docs/references/links.md` 记录来源，在 CI 中输出版本。

---

## 4. LS-WASM 映射

### 4.1 FMU 布局

```text
Model.fmu
├─ modelDescription.xml
├─ binaries/
│  └─ wasm32-wasip2/
│     └─ Model.wasm              # component
└─ extra/
   └─ org.modelica.fmi-ls-wasm/
      └─ manifest.xml            # 必需
```

规则：

- 平台目录固定 `wasm32-wasip2`；
- `.wasm` 必须是 Component Model component，不是 core module；
- 文件名必须等于接口的 `modelIdentifier`；
- manifest 必须通过 FMI 3 分层标准 manifest XSD；
- 一个 FMU 可以同时含 native 和 wasm 二进制，导入器按配置选择。

### 4.2 World

| FMU 类型 | World | Guest 导出 | Guest 导入 |
| --- | --- | --- | --- |
| ME | `fmi:fmi3/world.model-exchange-fmu` | `common`, `model-exchange` | `callbacks` |
| CS | `fmi:fmi3/world.co-simulation-fmu` | `common`, `co-simulation` | `callbacks`，可选 `intermediate-update-callbacks` |
| SE | `fmi:fmi3/world.scheduled-execution-fmu` | `common`, `scheduled-execution` | `callbacks` |
| 主算法 | `fmi:fmi3/world.master-algorithm` | `callbacks`, `intermediate-update-callbacks` | `common`, `model-exchange`, `co-simulation`, `scheduled-execution` |

设计上把 world 选择放在导出器：

```moonbit
pub fn world_for(interface : InterfaceKind) -> String {
  match interface {
    ModelExchange => "fmi:fmi3/world.model-exchange-fmu"
    CoSimulation => "fmi:fmi3/world.co-simulation-fmu"
    ScheduledExecution => "fmi:fmi3/world.scheduled-execution-fmu"
  }
}
```

### 4.3 实例资源

| FMI 类型 | Resource | 工厂 |
| --- | --- | --- |
| ME | `model-exchange-instance` | `instantiate-model-exchange` |
| CS | `co-simulation-instance` | `instantiate-co-simulation` |
| SE | `scheduled-execution-instance` | `instantiate-scheduled-execution` |

`fmi3Instance` 不暴露为整数句柄；resource 的 `drop` 自动释放实例。宿主持有的类型就是具体接口类型，因此不可能在 CS 实例上误调 ME 方法。

MoonBit 侧映射：

```moonbit
pub struct CsInstance {
  inner : CoSimulationState
}

pub fn CsInstance::do_step(
  self : CsInstance,
  current : Double,
  step : Double,
  no_set_prior : Bool
) -> DoStepResult raise FmiError {
  // 调用 WIT 生成的 guest 接口
}
```

### 4.4 类型映射

| FMI 3 C | WIT | MoonBit |
| --- | --- | --- |
| `fmi3ValueReference` | `u32` | `UInt32` |
| `fmi3Float64` | `f64` | `Double` |
| `fmi3Float32` | `f32` | `Float` |
| `fmi3Int8` | `s8` | `Byte` + 有符号解释 |
| `fmi3UInt8` | `u8` | `Byte` |
| `fmi3Int16` | `s16` | `Int16` |
| `fmi3UInt16` | `u16` | `UInt16` |
| `fmi3Int32` | `s32` | `Int32` |
| `fmi3UInt32` | `u32` | `UInt32` |
| `fmi3Int64` | `s64` | `Int64` |
| `fmi3UInt64` | `u64` | `UInt64` |
| `fmi3Boolean` | `bool` | `Bool` |
| `fmi3String` | `string` | `String`（UTF-8 边界） |
| `fmi3Binary` | `list<u8>` | `Bytes` |
| `fmi3Clock` | `bool` | `Bool` |
| `fmi3FMUState` | `list<u8>` | `Bytes` |
| `fmi3Status` | `enum status` | `FmiStatus` |
| `fmi3IntervalQualifier` | `enum interval-qualifier` | `IntervalQualifier` |
| `fmi3DependencyKind` | `enum dependency-kind` | `DependencyKind` |

约定：

- 并行数组（`vrs[]` + `values[]`）→ `list<tuple<u32, T>>` 或 record，避免长度不一致。
- `toleranceDefined + tolerance` → `option<f64>`。
- 多输出参数 → record。
- 字符串不做 NUL 结尾；WIT 长度前缀，MoonBit 侧注意 UTF-16 → UTF-8。
- `fmi3Boolean` 在 native 头文件中是 `bool`，WIT 也是 `bool`；不要按 `int` 处理。

### 4.5 回调

| C 回调 | WIT import | 说明 |
| --- | --- | --- |
| `fmi3LogMessageCallback` | `callbacks.log-message` | status/category/message |
| `fmi3ClockUpdateCallback` | `callbacks.clock-update` | SE 时钟 |
| `fmi3LockPreemptionCallback` | `callbacks.lock-preemption` | SE |
| `fmi3UnlockPreemptionCallback` | `callbacks.unlock-preemption` | SE |
| `fmi3IntermediateUpdateCallback` | `intermediate-update-callbacks.intermediate-update` | CS 可选 |

`fmi3InstanceEnvironment` 在 component 中由资源/闭包语义取代，不传递裸指针。

---

## 5. 导入 LS-WASM FMU

### 5.1 检测

`Fmu::open` 时：

1. 解析 `modelDescription.xml`；
2. 如果用户指定 `Backend::Wasm`，要求存在 `binaries/wasm32-wasip2/<id>.wasm`；
3. 如果自动选择，优先 native（若平台匹配），否则回退 wasm；
4. 若两者都没有，报错并列出可用后端。

不要仅凭扩展名判断；必须校验 component 结构和 manifest。

### 5.2 校验

- `wasm-tools validate` 或运行时 API 校验；
- `wasm-tools component wit` 检查 world 是否符合 LS-WASM；
- manifest XSD 校验；
- `modelDescription.xml` 的 `modelIdentifier` 与文件名一致；
- FMI 版本为 3.0.x；
- 组件导入的 WASI 接口是否在宿主能力范围内。

### 5.3 宿主实现

**native 宿主（wasmtime）**

```text
MoonFMI CLI
  → wasmtime component API
  → 加载 component
  → 实现 callbacks imports
  → 调用 resource 方法
```

需要：

- 将 MoonBit 的回调对象注册为 host functions；
- 处理字符串/数组的 canonical ABI 复制；
- 资源句柄生命周期；
- 错误/trap 转换为 `FmiError`；
- 限制内存/执行时间（fuel/epoch）。

**浏览器宿主**

```text
component
  → jco transpile
  → JS + core wasm
  → preview2-shim（WASI）
  → JS 主算法
```

需要：

- `resources/` 映射到虚拟文件系统或内存；
- 纯浏览器环境没有文件系统，向 FMU 传 `resourcePath` 时应按规范传 `NULL`，改由 WASI 预打开目录（`preview1`）或虚拟 FS（`preview2`）提供 `resources/`；
- 大数组避免频繁跨边界复制；
- Web Worker 隔离重计算；
- 不支持同步阻塞文件 I/O。

### 5.4 主算法复用

`sim` 只依赖 `fmi` 中的 `Instance`，因此：

- native CS 主算法可直接驱动 wasm CS 实例；
- 结果记录、输入源、事件循环无需重写；
- 差异只在后端初始化和错误映射。

---

## 6. 导出 LS-WASM FMU

### 6.1 流程

```text
ModelIr
  → 生成 MoonBit guest 源码
  → 编译为 wasm
  → 生成/嵌入 WIT
  → component 化
  → 生成 manifest.xml
  → 生成/复用 modelDescription.xml
  → 打包 ZIP
  → 校验
```

### 6.2 Guest 代码生成

每个接口生成：

- `common`：版本、实例化 token、变量读写、状态；
- `co-simulation`：`do-step`、早退、事件；
- `model-exchange`：连续状态、导数、事件指示器；
- `callbacks`：日志等导入调用。

生成代码必须：

- 不依赖文件系统（除非显式声明 WASI 能力）；
- 不依赖线程（首版）；
- 所有数组长度来自模型描述，越界返回错误；
- 资源 `drop` 时释放所有内存；
- 捕获 MoonBit 异常，转成 `status`，不让 trap 穿越边界。

### 6.3 manifest

manifest 至少包含：

- 标准版本/实现版本；
- world 名称；
- 组件入口；
- 能力声明（CS/ME/SE、回调、WASI 依赖）；
- 校验和（可选）。

必须用 `fmi3LayeredStandardManifest.xsd` 校验。

### 6.4 `modelDescription.xml`

WASM FMU 仍然是 FMI 3 FMU：

- `fmiVersion="3.0"`；
- 接口能力与 guest 实现一致；
- `modelIdentifier` 与 `.wasm` 文件名一致；
- 不声明 native-only 能力；
- 可以在 `extra/` 中放实现说明。

---

## 7. 安全模型

WASM 的优势是沙箱，但要注意：

- 组件只能访问宿主显式提供的 imports；
- 文件访问通过 WASI 能力授予，默认不授予任意路径；
- 限制内存上限和执行时间（fuel/epoch）；
- 不把宿主回调能力暴露成任意文件/网络访问；
- 组件仍可能通过算法耗尽 CPU，需要超时；
- 第三方 component 的供应链仍需签名/校验和。

与 native 导入相比，WASM 更适合运行不可信 FMU；但 LS-WASM 草案本身不定义权限模型，需要宿主补充。

---

## 8. POC 门槛

按 [`../research/wasm-fmi.md`](../research/wasm-fmi.md) 的 POC-1…POC-5 执行。进入正式实现前必须通过：

| 门槛 | 通过标准 |
| --- | --- |
| G1 component 化 | 最小 MoonBit 函数 → 合法 component → wasmtime 调用 |
| G2 resource | MoonBit guest 能实现并导出 resource，宿主能 drop |
| G3 string/list | UTF-8 字符串与 `list<u8>` 往返正确 |
| G4 最小 CS | Adder FMU 完成 instantiate/step/get/set/terminate |
| G5 浏览器 | `jco` 转译后在 Chrome/Firefox 跑通 |
| G6 回调 | 日志/中间更新回调正确跨边界 |
| G7 性能 | 记录启动、步进、内存；与 native 对比 |

任何一项失败，WASM 导出保持“实验性”，不阻塞 native 路线。

---

## 9. 备选与降级

| 方案 | 何时使用 | 代价 |
| --- | --- | --- |
| LS-WASM component | 标准路径 | 工具链风险 |
| 自定义 core wasm ABI | 内部 POC | 不兼容 FMI |
| Emscripten 转译 C 源码 | 有源码的 FMU | 非标准、每 FMU 重编译 |
| JS 重实现 | 教学/演示 | 与 FMU 语义脱节 |

降级原则：**不把非标准 ABI 伪装成 FMI**。若使用自定义 ABI，FMU 中必须明确标注扩展，导入器默认拒绝。

---

## 10. 决策记录

| 决策 | 选择 | 理由 | 替代 |
| --- | --- | --- | --- |
| WASM 标准 | LS-WASM | 唯一标准化 component 路径 | 自定义 ABI |
| 首期接口 | CS/ME | SE 线程模型不成熟 | 全接口 |
| 组件化工具 | `wasm-tools` + `wit-bindgen` | 生态标准 | 手写 canonical ABI |
| 浏览器 | `jco` | 成熟度较高 | 自研 JS glue |
| native 宿主 | wasmtime | component 支持好 | wasmer |
| 后端隔离 | 独立 `backend/wasm` 包 | MoonBit 无 feature flag，只能靠包级 target 隔离 | 条件编译混在一起 |

---

## 11. 相关文档

- 研究：[`../research/wasm-fmi.md`](../research/wasm-fmi.md)
- 导出器：[`exporter.md`](exporter.md)
- 打包：[`packaging.md`](packaging.md)
- 架构：[`architecture.md`](architecture.md)
- 工具链评估：[`../research/moonbit-ecosystem.md`](../research/moonbit-ecosystem.md)
