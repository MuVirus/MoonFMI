# WASM 与 FMI 研究

本文研究“在 WebAssembly 上运行/导出 FMU”的可行路径，重点是可移植、可在浏览器运行的方案。结论是：**FMI-LS-WASM 是最有前景的标准路径，但目前仍是草案，需要 POC 验证；Bodylight.js / OpenModelica 的 Emscripten 路线可作为工程参考，但不是标准 component 模型。**

---

## 1. 为什么关心 WASM

| 动机 | 说明 |
| --- | --- |
| 跨平台 | 同一份 `.wasm` 可在 Windows/Linux/macOS/浏览器运行 |
| 沙箱 | 只能访问宿主显式授予的能力 |
| 浏览器 | 无需安装 native 依赖，适合在线演示/教学/轻量工具 |
| 分发 | 比 `.dll/.so` 更容易做签名、版本管理、CDN 分发 |
| MoonBit | 项目 `preferred_target = "wasm"`，WASM 是自然目标 |

但 WASM 不是“免费的可移植性”：

- native FMU 的动态库不能直接在浏览器加载；
- WASM 需要宿主提供运行时；
- FMI 的回调、字符串、数组、状态在 component 边界需要重新映射；
- 性能、调试、线程、文件访问都有限制。

---

## 2. 浏览器里运行 FMU 的三种路径

### 2.1 路径 A：Emscripten 编译 native FMU 的 C 代码

```text
FMU 的 C 源码
  → Emscripten (emcc)
  → .wasm + .js glue
  → JS 主算法通过 C ABI/JS 桥接调用
```

特点：

- 不是 FMI 标准的一部分；
- 需要 FMU 提供源码，或把二进制反编译（不现实）；
- 每个 FMU 都要重新编译；
- JS 侧需要模拟 `fmi2*`/`fmi3*` 符号和回调；
- 兼容性取决于 Emscripten 对 C 特性的支持。

代表项目：

- **Bodylight.js**：面向生理模型的 Web 仿真框架，把 Modelica/FMU 的 C 代码编译为 WebAssembly，并用 JS 主算法驱动。它更接近“自定义 wasm 运行时”，不是 FMI-LS-WASM component。
- **OpenModelica 生态的浏览器 FMU 实验**：同样多采用 Emscripten/JS 桥接路线，具体实现随项目而异。

### 2.2 路径 B：FMI-LS-WASM（WebAssembly Component Model）

```text
FMI 3.0 C API
  → WIT 接口
  → WebAssembly Component
  → 宿主（浏览器/Node/wasmtime）通过 component 接口调用
```

特点：

- 标准草案，定义了 FMU 归档布局、WIT world、manifest；
- 组件是自描述的，宿主不需要知道 C 符号；
- 资源（resource）管理实例生命周期；
- 回调通过 imported interface 实现；
- 需要支持 Component Model 的运行时/工具链。

这是 MoonFMI 应重点跟踪的路径。

### 2.3 路径 C：自定义 ABI

```text
MoonBit 模型
  → 自定义 wasm 导出（如 moonfmi_step）
  → MoonBit/JS 宿主直接调用
```

特点：

- 实现简单，完全可控；
- 不是 FMI 标准，不能与第三方工具互通；
- 适合 MoonFMI 内部 POC 或“MoonBit 到 MoonBit”的场景；
- 不建议作为长期对外接口。

---

## 3. FMI-LS-WASM 详解

> 来源：[`modelica/fmi-ls-wasm`](https://github.com/modelica/fmi-ls-wasm)。当前是**原型草案**，明确说明“非规范性、可能随时变化”。

### 3.1 目标

把 FMI 3.0 C API 映射到 **WebAssembly Component Model** 的 WIT 接口，使 FMU 成为可移植、可沙箱的 component。

### 3.2 FMU 归档布局

```text
<modelName>.fmu  (ZIP)
├── modelDescription.xml                      # FMI 3.0
├── binaries/
│   └── wasm32-wasip2/
│       └── <modelIdentifier>.wasm            # WebAssembly component
└── extra/
    └── org.modelica.fmi-ls-wasm/
        └── manifest.xml                      # 必需
```

规则：

- 平台目录固定为 `binaries/wasm32-wasip2/`；
- `.wasm` 必须是合法的 Component Model component；
- `<modelIdentifier>` 来自 `modelDescription.xml` 的接口元素；
- FMU 可以同时包含 native 二进制和 wasm component，导入器可自行选择；
- `manifest.xml` 必须符合 FMI 3.0 分层标准 manifest schema。

### 3.3 WIT 包与 world

WIT 包名为 `fmi:fmi3@3.0.0`。每种 FMU 类型对应一个 world：

| FMU 类型 | World | 导出 | 导入 |
| --- | --- | --- | --- |
| Model Exchange | `fmi:fmi3/world.model-exchange-fmu` | `common`, `model-exchange` | `callbacks` |
| Co-Simulation | `fmi:fmi3/world.co-simulation-fmu` | `common`, `co-simulation` | `callbacks`，可选 `intermediate-update-callbacks` |
| Scheduled Execution | `fmi:fmi3/world.scheduled-execution-fmu` | `common`, `scheduled-execution` | `callbacks` |
| 主算法（宿主） | `fmi:fmi3/world.master-algorithm` | `callbacks`, `intermediate-update-callbacks` | `common`, `model-exchange`, `co-simulation`, `scheduled-execution` |

### 3.4 实例即资源

FMI 的 `fmi3Instance` 是不透明指针。LS-WASM 把它映射成三种 **resource**：

| FMU 类型 | Resource | 静态工厂 |
| --- | --- | --- |
| ME | `model-exchange-instance` | `instantiate-model-exchange` |
| CS | `co-simulation-instance` | `instantiate-co-simulation` |
| SE | `scheduled-execution-instance` | `instantiate-scheduled-execution` |

资源拥有完整生命周期：

- 静态工厂负责实例化；
- 所有公共/接口特有方法都是资源方法；
- 资源 drop 时自动调用 `fmi3FreeInstance`，不需要显式 free；
- 宿主不会持有“通用 instance”句柄，因此不可能在 CS 句柄上调用 ME 方法。

### 3.5 回调映射

FMI 3 的 C 回调：

```c
fmi3LogMessageCallback
fmi3IntermediateUpdateCallback
fmi3ClockUpdateCallback
fmi3LockPreemptionCallback / Unlock
```

映射为 WIT **imported interfaces**：

- `callbacks`：日志、时钟更新、抢占锁；
- `intermediate-update-callbacks`：中间更新，单独接口，便于简单 CS FMU 省略；
- `fmi3InstanceEnvironment` 被去掉，Component Model 的闭包/资源语义承载每实例上下文。

### 3.6 类型映射

| FMI 3.0 C | WIT | 说明 |
| --- | --- | --- |
| `fmi3ValueReference` | `u32` | 直接别名 |
| `fmi3Float64` | `f64` | |
| `fmi3Float32` | `f32` | |
| `fmi3Int8/16/32/64` | `s8/s16/s32/s64` | |
| `fmi3UInt8/16/32/64` | `u8/u16/u32/u64` | |
| `fmi3Boolean` | `bool` | 见下方说明 |
| `fmi3String` | `string` | 去掉 NUL，长度前缀 |
| `fmi3Binary` | `list<u8>` | 长度内建 |
| `fmi3Clock` | `bool` | true = tick |
| `fmi3FMUState` | `list<u8>` | 直接序列化，不暴露句柄 |
| `fmi3Instance` | resource | 每种接口一个 resource |
| `fmi3Status` | `enum status` | 5 个变体 |
| `fmi3IntervalQualifier` | `enum interval-qualifier` | 3 个变体 |
| `fmi3DependencyKind` | `enum dependency-kind` | 5 个变体 |

其他映射约定：

- 并行 C 数组 → `list<T>`；成对数组（如 `vrs[]` + `orders[]`）→ `list<tuple<...>>`，避免长度不一致；
- `toleranceDefined` + `tolerance` → `option<f64>`；
- 多输出参数 → 返回 record；
- `fmi3GetBinary` 的多变量 → `list<list<u8>>`。

### 3.7 一个需要澄清的矛盾：`fmi3Boolean` 的宽度

LS-WASM 的 README/说明中有一句“FMI 3.0 defines `fmi3Boolean` as `int`-sized (for C ABI compatibility)”，但官方 [`fmi3PlatformTypes.h`](../standards/headers/fmi3/fmi3PlatformTypes.h) 实际定义是：

```c
typedef bool fmi3Boolean;
```

两者矛盾。处理原则：

- **native C ABI**：以头文件为准，`fmi3Boolean` 是 C `bool`（通常 1 字节）；不要按 `int` 处理。
- **WIT/component**：用 `bool` 是正确的，与 C 宽度无关。
- **文档/实现**：在代码注释和测试中记录这一差异，避免有人按草案 prose 写 native 绑定。

这也说明：草案文本不能替代头文件，ABI 必须以官方头文件为准。

### 3.8 已知限制

- `modelDescription.xml` 仍由 FMI 3 定义，LS-WASM 只覆盖运行时 API；
- SE 的线程/抢占模型依赖 Component Model threading 扩展，尚未稳定；
- WASI 文件/时钟访问未在 LS-WASM 中规定，由 FMU 自行声明；
- `wasm32-wasip2` 工具链仍在演进；
- 草案可能变更，不能作为稳定承诺。

---

## 4. 工具链

### 4.1 需要的能力

| 能力 | 工具 |
| --- | --- |
| 编译到 wasm | MoonBit `moon build --target wasm`、Rust `wasm32-wasip2`、C `wasi-sdk` |
| WIT 绑定生成 | `wit-bindgen`（Rust/C/MoonBit 等后端） |
| component 封装 | `wasm-tools component embed` / `wasm-tools component new` |
| component 校验 | `wasm-tools validate`、`wasm-tools component wit` |
| 宿主运行 | wasmtime、wasmer、Node + `jco`、浏览器 + `jco`/preview2-shim |
| 打包 | zip + manifest 校验 |

### 4.2 MoonBit 的位置

MoonBit 当前 target：

```text
wasm, wasm-gc, js, native, llvm
```

- `wasm`：面向 WASI 的 core wasm（具体是 WASI Preview 1 还是可配置，需要按工具链版本文档确认）。
- `wasm-gc`：面向浏览器/JS 的 GC 扩展，不是 WASI p2 component。
- `js`：JS 后端。
- `native`：C/LLVM 后端。

LS-WASM 要求 `wasm32-wasip2` **component**。MoonBit 的直接产物是 core module，需要：

1. 用 `wit-bindgen` 生成 guest 绑定；
2. 用 `wasm-tools component embed` 嵌入 WIT；
3. 用 `wasm-tools component new` + WASI adapter 生成 component；
4. 用 `wasm-tools validate` 校验。

这条路可行，但需要确认：

- MoonBit 的 `wasm` 后端是否支持 Component Model 所需的 canonical ABI（尤其是 string/list/resource）；
- `wit-bindgen` 的 MoonBit 后端是否支持 resource、async、imported interface；
- MoonBit 运行时（GC、内存）在 component 中的初始化方式；
- WASI p2 adapter 是否能与 MoonBit 的 wasm 导入匹配。

### 4.3 浏览器宿主

浏览器原生不支持 Component Model 的 JS API。常见做法：

- 用 **`jco`** 把 component 转译为 JS + core wasm，配合 `@bytecodealliance/preview2-shim` 提供 WASI p2；
- 或把 component 编译成 core wasm + 自定义 JS 胶水（更复杂）。

需要注意：

- `jco` 的组件支持程度随版本变化；
- 浏览器没有文件系统，`resources/` 需要映射到虚拟文件系统或内存；
- 大模型/大数组的内存和 GC 压力；
- 调试体验不如 native。

### 4.4 native 宿主

- wasmtime 的 component API 可以加载 LS-WASM component；
- 适合在 MoonFMI native CLI 中“用 wasm 后端跑 wasm FMU”；
- 需要把 host callbacks 实现为 component imports；
- 性能低于 native 动态库，但沙箱更好。

---

## 5. 可行性矩阵

| 场景 | 可行性 | 依赖 | 风险 |
| --- | --- | --- | --- |
| native 导入 FMI 2/3 CS | 高 | `dl` + C shim | ABI/平台 |
| native 导入 FMI 2/3 ME | 高 | 同上 + 求解器 | 事件/数值 |
| 浏览器导入 LS-WASM FMU | 中 | component 运行时 + `jco` | 工具链/草案 |
| native 导入 LS-WASM FMU | 中高 | wasmtime component | 回调/资源 |
| 导出源码 FMU | 中高 | C 代码生成 + 外部编译器 | 构建环境 |
| 导出 native 二进制 FMU | 低 | C 包装 + `.dll/.so` 导出 | MoonBit 不支持直接导出 |
| 导出 LS-WASM FMU | 中 | MoonBit wasm + 组件化 | POC 未做 |
| MoonBit↔MoonBit 自定义 wasm | 高 | 自定义 ABI | 不兼容 FMI |

### 5.1 结论

- **导入**：native 优先；WASM 作为独立后端，先支持 LS-WASM。
- **导出**：源码 FMU 优先；WASM FMU 作为差异化；native 二进制 FMU 暂缓。
- **浏览器**：只有在 LS-WASM 工具链 POC 成功后才投入。

---

## 6. POC 计划

### POC-1：MoonBit core wasm + component 化

目标：确认 MoonBit 产物能否变成合法 component。

步骤：

1. 写一个最小 MoonBit 函数（如 `add(a: Int, b: Int) -> Int`），编译到 `wasm`；
2. 用 `wasm-tools component embed` 嵌入一个最小 WIT world；
3. 用 `wasm-tools component new` 生成 component；
4. `wasm-tools validate` 通过；
5. 用 wasmtime/Node 调用，结果正确。

验收：

- component 可被 wasmtime 加载；
- 函数调用返回值正确；
- 记录产物大小、构建时间。

### POC-2：最小 LS-WASM `common` 接口

目标：实现 `get-version` 和最基本的生命周期。

步骤：

1. 用 `wit-bindgen` 生成 MoonBit guest 绑定；
2. 实现 `common` 的 `get-version`；
3. 生成 component，校验 world 为 `fmi:fmi3/world.co-simulation-fmu`（可先只实现部分接口，确认工具链行为）；
4. 用 Rust/C 参考 runner 加载。

验收：

- `wasm-tools component wit` 显示正确 world；
- 参考 runner 能调用 `get-version`；
- 记录绑定生成/编译的坑。

### POC-3：最小 CS FMU（Adder）

目标：完整的 `instantiate → enter-initialization → exit → do-step → get/set → terminate`。

步骤：

1. 实现 `co-simulation` resource 和 `common` 变量读写；
2. 实现 `callbacks` 的日志；
3. 生成 component；
4. 打包 FMU：`modelDescription.xml` + `binaries/wasm32-wasip2/Adder.wasm` + `extra/org.modelica.fmi-ls-wasm/manifest.xml`；
5. 用 LS-WASM 参考 runner 跑通；
6. 用 `wasm-tools` 和 manifest XSD 校验。

验收：

- 参考 runner 能实例化、步进、读输出；
- 结果与 native Adder 一致；
- FMU 结构符合草案；
- 记录性能/大小。

### POC-4：浏览器运行

目标：在浏览器中加载 POC-3 的 FMU。

步骤：

1. 用 `jco` 转译 component；
2. 提供 `preview2-shim` 的 WASI 能力；
3. 用 JS 主算法调用；
4. 处理 `resources/` 虚拟文件系统；
5. 测内存/启动时间。

验收：

- Chrome/Firefox 可运行；
- 无原生依赖；
- 结果与 native 一致；
- 记录兼容性问题。

### POC-5：MoonBit 作为宿主

目标：MoonBit native 通过 wasmtime 加载 LS-WASM component。

步骤：

1. 用 wasmtime C API 或 MoonBit 绑定加载 component；
2. 实现 host callbacks；
3. 调用 CS 接口；
4. 与 native FMU 的结果对比。

验收：

- 能加载并步进；
- 回调正确；
- 性能可接受（或明确记录差距）。

---

## 7. 风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| LS-WASM 草案变更 | 返工 | 把 WIT 映射隔离在 `wasm` 后端；跟踪上游 |
| MoonBit 组件化不支持 resource | 无法实现实例生命周期 | 先做 core wasm + 自定义 ABI；或等工具链 |
| `wit-bindgen` MoonBit 后端不成熟 | 绑定生成失败 | 手写 canonical ABI 绑定，或先用 C/Rust 做 host |
| WASI p2 支持不完整 | 浏览器/宿主跑不起来 | 用 `jco`/preview2-shim；限制 FMU 的 WASI 依赖 |
| 性能差 | 不适合大模型 | 基准测试；native 优先；wasm 仅用于轻量/浏览器 |
| 调试困难 | 开发效率低 | 保留 native 路径；用 WAT/日志；分阶段 POC |
| 二进制体积大 | 加载慢 | 裁剪运行时；`wasm-opt -Oz`；按需分包 |
| `fmi3Boolean` 文档矛盾 | ABI 错误 | 以头文件为准；测试覆盖 |
| 线程/SE 不支持 | SE 不可用 | 首期只做 CS/ME；SE 后置 |

---

## 8. 设计建议

1. **不要把 WASM 逻辑塞进 native 导入器**。定义 `Backend` 抽象，native 和 wasm 各自实现。
2. **WIT 映射单独维护**。不要在 MoonBit 代码里散落字符串/数组转换。
3. **先做宿主，再做 guest**。如果 MoonBit 作为宿主的 POC 更容易，可以先跑通 wasmtime 加载第三方 component，再反推 guest 需求。
4. **FMU 打包与 manifest 校验独立**。即使运行时未完成，也可以先做 `pack`/`validate` 工具。
5. **保留 native 回退**。浏览器不支持时，CLI 仍可用 native FMU。
6. **明确非目标**：首期不做“浏览器加载任意 native FMU”，也不做“WASM FMU 全功能 SE”。

---

## 9. 参考

- FMI-LS-WASM：<https://github.com/modelica/fmi-ls-wasm>
- 规范草案：<https://modelica.github.io/fmi-ls-wasm/main/>
- Component Model：<https://component-model.bytecodealliance.org/>
- WIT：<https://component-model.bytecodealliance.org/design/wit.html>
- WASI Preview 2：<https://github.com/WebAssembly/WASI/tree/wasi-0.2>
- `wasm-tools`：<https://github.com/bytecodealliance/wasm-tools>
- `wit-bindgen`：<https://github.com/bytecodealliance/wit-bindgen>
- `jco`：<https://github.com/bytecodealliance/jco>
- Bodylight.js：<https://github.com/creative-connections/Bodylight.js>
- MoonFMI 的 WASM 设计：[`../design/wasm-strategy.md`](../design/wasm-strategy.md)
