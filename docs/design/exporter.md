# 导出器设计

> 状态：设计提案。导出器的三个目标按可行性排序：**源码 FMU → WASM FMU → native 二进制 FMU**。不要把三者混为一个“打包”步骤。

---

## 1. 目标与边界

导出器把 MoonFMI 的模型 IR 变成符合 FMI 的 FMU。它**不是 Modelica 编译器**，首版只支持显式声明的、受限的模型形式：

- 连续状态及其导数；
- 代数输出；
- 参数、常量、输入；
- 简单离散状态/事件（后续）；
- FMI 2 CS/ME 与 FMI 3 CS/ME（SE 后续）。

明确不支持：

- 一般 DAE 指标约简；
- 复杂事件迭代的自动求解；
- 任意 Modelica 语法；
- 自动生成高效的稀疏 Jacobian。

这些能力应由上游建模工具提供，MoonFMI 负责“模型 IR → 标准 FMU”的最后一公里。

---

## 2. 三种导出目标

| 目标 | 产物 | 依赖 | 优先级 | 适用场景 |
| --- | --- | --- | --- | --- |
| 源码 FMU | `sources/` + `modelDescription.xml` + 构建脚本 | 外部 C 编译器 | P0 | 可审计、可移植、CI |
| WASM FMU | `binaries/wasm32-wasip2/*.wasm` + LS-WASM manifest | MoonBit + wasm 工具链 | P1 | 浏览器、沙箱、插件 |
| native 二进制 FMU | `binaries/<platform>/*.dll|so|dylib` | C 工具链 + MoonBit 运行时/生成 C | P2 | 传统工具链集成 |

### 2.1 关键判断

- **源码 FMU 最可行**：生成自包含 C 代码，不需要 MoonBit 能导出动态库。
- **WASM FMU 最有差异化**：MoonBit 的 wasm 目标与 component model 是天然组合，但需要工具链 POC。
- **native 二进制 FMU 最受限**：MoonBit 目前不能直接把包导出为 `.dll/.so`。可行路径是生成 C 代码（不依赖 MoonBit 运行时），或做 C shim + MoonBit 静态库（依赖工具链突破）。

---

## 3. 模型 IR

### 3.1 结构

```moonbit
pub struct ModelIr {
  name : String
  version : String
  guid : String
  description : String?
  generation_tool : String
  interfaces : Array<InterfaceSpec>
  variables : Array[VariableSpec]
  equations : Array[Equation]
  units : Array[UnitSpec]
  annotations : Array[Annotation]
}

pub struct VariableSpec {
  name : String
  value_reference : UInt32
  data_type : DataType
  causality : Causality
  variability : Variability
  initial : Initial
  start : FmiValue?
  unit : String?
  display_unit : String?
  min : Double?
  max : Double?
  nominal : Double?
  dimensions : Array[DimensionSpec]
}
```

IR 必须：

- 与 FMI 版本解耦；
- 在导出前完成语义校验（复用 `schema` 的 validate 模块）；
- 保持变量顺序稳定，便于生成可复现的 XML；
- 不包含平台相关路径。

### 3.2 方程形式

首版支持显式形式：

```text
der(x) = f(t, x, u, p)
y      = g(t, x, u, p)
```

其中表达式是受限 AST：

```moonbit
pub enum Expr {
  Const(Double)
  Var(String)
  Add(Expr, Expr)
  Sub(Expr, Expr)
  Mul(Expr, Expr)
  Div(Expr, Expr)
  Neg(Expr)
  Call(String, Array[Expr])   // sin, cos, exp, log, sqrt, ...
  If(Expr, Expr, Expr)
  Compare(CompareOp, Expr, Expr)
}
```

不支持隐式方程、事件优先级、状态选择等；这些需要上游工具先转换。

---

## 4. 源码 FMU

### 4.1 目录结构

```text
MyModel.fmu
├─ modelDescription.xml
├─ sources/
│  ├─ MyModel.c
│  ├─ MyModel.h
│  ├─ fmi2Functions.c        // 或 fmi3Functions.c
│  ├─ moonfmi_runtime.c/.h   // 生成代码的运行时辅助
│  └─ CMakeLists.txt
├─ documentation/
│  └─ index.html
└─ buildDescription.xml      // FMI 3
```

FMI 2 没有 `buildDescription.xml`；提供 `CMakeLists.txt` 和 `README` 作为构建说明。

### 4.2 生成内容

1. **`modelDescription.xml`**：变量、类型、单位、模型结构、接口能力。
2. **模型实现 C**：状态、参数、导数、输出方程。
3. **FMI 入口 C**：实现 `fmi2Instantiate`、`fmi2DoStep` 等，或 FMI 3 对应函数。
4. **构建脚本**：CMake 为主，输出到 `binaries/<platform>/`。
5. **文档/许可**：生成工具版本、模型说明、第三方许可。

### 4.3 C 代码生成原则

- 生成可读、可调试的 C99，不生成难以维护的宏魔法。
- 所有变量用 `fmi2ValueReference` / `fmi3ValueReference` 常量，不靠运行时字符串。
- 状态数组长度编译期确定；数组变量展开为固定长度。
- 浮点运算显式 `double` / `float`，不依赖隐式转换。
- 错误路径返回标准状态码，并调用日志回调。
- 不动态分配内存（除非模型需要），减少 `allocateMemory` 依赖。
- 生成代码带“DO NOT EDIT”标记和源 IR 哈希。

### 4.4 代码示例（示意）

```c
typedef struct {
    double x[2];
    double p[3];
    double u[1];
} MyModel;

static void compute_derivatives(MyModel* m, double t, double dx[2]) {
    dx[0] = m->p[0] * m->x[1] - m->p[1] * m->x[0] + m->u[0];
    dx[1] = -m->p[2] * m->x[0];
}

fmi2Status fmi2DoStep(fmi2Component c, fmi2Real current,
                      fmi2Real step, fmi2Boolean noSet,
                      fmi2Boolean* event, fmi2Boolean* terminate) {
    MyModel* m = (MyModel*)c;
    double t = current;
    double h = step;
    /* 简化：显式 Euler；实际生成 RK4 或调用共享积分器 */
    double dx[2];
    compute_derivatives(m, t, dx);
    m->x[0] += h * dx[0];
    m->x[1] += h * dx[1];
    *event = fmi2False;
    *terminate = fmi2False;
    return fmi2OK;
}
```

生产代码必须处理初始化、事件、状态保存、输入范围和错误码；示例只展示结构。

### 4.5 构建

- 生成 `CMakeLists.txt`，支持 Windows/MSVC、Linux/GCC、macOS/Clang。
- 输出名严格为 `<modelIdentifier>.<ext>`。
- 导出器本身不调用编译器；`moonfmi export --build` 可以可选调用。
- 构建结果用 `moonfmi validate` 和导入器回读验证。

---

## 5. native 二进制 FMU

### 5.1 路径 A：纯 C 生成（推荐先做）

如果模型逻辑能由 IR 生成 C，则 native FMU 与源码 FMU 共用同一套 C 代码，只是多一步编译：

```text
IR → C 源码 → 外部 C 编译器 → binaries/<platform>/<id>.dll|so|dylib → 打包
```

优点：不依赖 MoonBit 导出动态库；缺点：导出器必须实现 C 代码生成（与源码 FMU 相同）。

### 5.2 路径 B：MoonBit 静态库 + C shim

```text
MoonBit 模型核心 → 静态库/目标文件 → C shim 导出 fmi2*/fmi3* → 链接为动态库
```

需要验证：

- MoonBit native 后端是否能产出可链接的静态库/目标文件；
- 运行时初始化/GC/异常如何嵌入；
- 符号可见性与调用约定；
- Windows DLL 导出表；
- 许可证与运行时分发。

在这些问题解决前，路径 B 标记为**实验性**，不进入路线图的关键路径。

### 5.3 路径 C：C shim 调用外部进程（不推荐）

把 MoonBit 仿真器作为独立进程，通过 IPC 提供 FMI 接口。可以快速做原型，但：

- 延迟高；
- 状态同步复杂；
- 不符合典型 FMU 使用方式；
- 部署麻烦。

仅作为演示，不作为正式方案。

---

## 6. WASM FMU

详见 [`wasm-strategy.md`](wasm-strategy.md)。导出器侧需要：

1. 从 IR 生成 MoonBit 模型代码或直接生成 WIT 导出实现。
2. 编译为 `wasm32-wasip2` component。
3. 实现 LS-WASM 规定的 world（CS/ME/SE）。
4. 生成 `extra/org.modelica.fmi-ls-wasm/manifest.xml`。
5. 按 LS-WASM 布局放入 `binaries/wasm32-wasip2/<modelIdentifier>.wasm`。
6. 保留 `modelDescription.xml`，并确保平台/能力声明与 WASM 实现一致。

导出器不应生成“只有 wasm 没有 manifest”的半成品；导入器应能拒绝这种 FMU 并给出明确诊断。

---

## 7. `modelDescription.xml` 生成

### 7.1 规则

- 使用模板 + 结构化写入，不拼接字符串。
- XML 转义：`& < > " '`；属性值统一双引号。
- 元素顺序严格遵守 XSD 的 `xs:sequence`。
- 布尔值写 `true` / `false`。
- 浮点数使用可往返的最短表示（`Double::to_string` 的 round-trip 格式），避免 `0.30000000000000004`。
- `fmiVersion` 写 `2.0` 或 `3.0`；不要写工具内部版本。
- `guid` / `instantiationToken` 稳定生成（同一 IR + 版本 → 同一值），便于复现。
- 变量 `valueReference` 稳定分配，不因排序变化而漂移。

### 7.2 FMI 2 与 FMI 3 差异

| 项目 | FMI 2 | FMI 3 |
| --- | --- | --- |
| 根属性 | `guid` | `instantiationToken` |
| 接口 | `CoSimulation` / `ModelExchange` | 增加 `ScheduledExecution` |
| 变量 | `ScalarVariable` + `Real/Integer/...` | `Float32/Float64/Int8/...` |
| 数组 | 无 | `Dimension` |
| 时钟 | 无 | `Clock` |
| 结构 | `ModelStructure/Outputs/...` | `ModelStructure/ContinuousStateDerivative/...` |
| 构建 | 无标准描述 | `buildDescription.xml` |

### 7.3 能力声明

只声明实际实现的能力：

- `canHandleVariableCommunicationStepSize`
- `canInterpolateInputs`
- `maxOutputDerivativeOrder`
- `canGetAndSetFMUstate`
- `canSerializeFMUstate`
- `providesDirectionalDerivative`
- `needsCompletedIntegratorStep`
- FMI 3 的 `hasEventMode`、`canReturnEarlyAfterIntermediateUpdate` 等

虚报能力比不声明更危险：导入器/主算法会按声明调用，导致运行时失败。

---

## 8. 导出 API

```moonbit
pub struct ExportOptions {
  target : ExportTarget
  fmi_version : FmiVersion
  output_dir : String
  model_identifier : String?
  embed_sources : Bool
  deterministic : Bool
  license : String?
}

pub enum ExportTarget {
  Source
  Native(platform : String)
  Wasm
}

pub fn export_model(ir : &ModelIr, options : ExportOptions) -> ExportResult raise FmiError
```

`ExportResult` 包含：

- 输出目录/FMU 路径；
- 生成的文件清单；
- 校验报告；
- IR 哈希与工具版本；
- 未实现能力的警告。

---

## 9. 可复现构建

- 固定文件顺序（字典序，`modelDescription.xml` 优先）。
- ZIP 时间戳使用固定值（例如 1980-01-01）或源文件 mtime 的可复现映射。
- 不写入绝对路径、用户名、临时目录。
- 生成代码中的注释不包含当前时间。
- `guid` 由 IR 内容哈希派生，而不是随机 UUID。
- 同一输入在 Windows/Linux 上生成的 XML/C 应逐字节一致（换行统一 `\n`）。

---

## 10. 验证

导出后必须：

1. 用 XSD 校验 `modelDescription.xml`（CI）。
2. 用 MoonFMI 自己的解析器/语义校验器回读。
3. 若生成二进制，用导入器加载并跑最小仿真。
4. 与手写参考 FMU 对比输出。
5. 检查 ZIP 布局、文件名、平台目录。
6. 检查 FMI 版本与接口能力一致。

---

## 11. 分阶段实现

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| E0 | IR + XML 生成 | 生成合法 FMI 2 CS 模型描述，XSD 通过 |
| E1 | 源码 FMU + C 代码生成 | 外部编译后能被 FMPy/MoonFMI 加载 |
| E2 | FMI 3 源码 FMU | 数组/新类型最小模型 |
| E3 | native 二进制（纯 C 路径） | Windows/Linux 各一个可加载 DLL/so |
| E4 | WASM POC | 浏览器/Wasmtime 能实例化并步进 |
| E5 | WASM FMU 正式导出 | LS-WASM manifest + 交叉测试 |

---

## 12. 相关文档

- WASM：[`wasm-strategy.md`](wasm-strategy.md)
- 打包：[`packaging.md`](packaging.md)
- ABI：[`ffi-and-abi.md`](ffi-and-abi.md)
- 模型描述：[`../standards/model-description.md`](../standards/model-description.md)
- fmi-rs 导出器参考：[`../research/fmi-rs.md`](../research/fmi-rs.md)
