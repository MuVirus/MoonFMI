# FMPy 研究

[FMPy](https://github.com/CATIA-Systems/FMPy) 是 Python 生态中最常用的 FMI 工具链之一，支持 FMI 1.0/2.0/3.0 的导入、仿真、校验、源码 FMU 构建和命令行。它是 MoonFMI 最重要的“行为参考实现”。

---

## 1. 为什么研究 FMPy

| 原因 | 说明 |
| --- | --- |
| 覆盖完整 | 导入、仿真、校验、构建、CLI、Web、交叉检查都有 |
| 行为成熟 | 被大量工具和教程使用，兼容性处理现实 |
| 代码可读 | Python + ctypes，逻辑直观，适合对照 |
| 测试语料多 | 自带测试 FMU，且与 fmi-cross-check 集成 |
| 文档清晰 | 每个 API 都有示例 |

MoonFMI 不需要复制 FMPy 的 Python 实现，但应复用它的**流程划分、校验规则和兼容性经验**。

---

## 2. 模块结构

FMPy 的核心模块大致如下（不同版本略有差异）：

| 模块 | 职责 |
| --- | --- |
| `fmpy/fmi1.py` | FMI 1.0 ctypes 绑定与实例类 |
| `fmpy/fmi2.py` | FMI 2.0 ctypes 绑定、`FMU2Model`、`FMU2Slave` |
| `fmpy/fmi3.py` | FMI 3.0 ctypes 绑定、ME/CS/SE 实例 |
| `fmpy/model_description.py` | `modelDescription.xml` 解析、XSD 校验、写回 |
| `fmpy/validation.py` | 语义校验：变量名、模型结构 |
| `fmpy/simulation.py` | `simulate_fmu`、`simulateCS`、`simulateME`、记录器、输入插值 |
| `fmpy/util.py` | 解压、下载、路径、平台选择、状态处理等工具 |
| `fmpy/build.py` | 源码 FMU 的 CMake 构建 |
| `fmpy/command.py` | CLI 入口（`fmpy simulate/info/validate/create/compile`） |
| `fmpy/webapp/` | Flask Web 应用 |
| `fmpy/cross_check/` | fmi-cross-check 集成 |
| `fmpy/ssp/` | SSP 支持 |
| `fmpy/result.py` | 结果容器/读写 |
| `fmpy/plotting.py` | 结果绘图 |

### 2.1 分层

```text
CLI / Web / Python API
        ↓
simulation.py（主算法、记录、输入）
        ↓
fmi1.py / fmi2.py / fmi3.py（实例、ctypes 调用）
        ↓
model_description.py（元数据）
        ↓
validation.py（语义校验）
```

这个分层与 MoonFMI 的设想高度一致：**元数据、绑定、主算法、校验、CLI 分开**。

---

## 3. 模型描述解析

### 3.1 入口

```python
from fmpy import read_model_description

md = read_model_description(
    "model.fmu",
    validate=True,
    validate_variable_names=True,
    validate_model_structure=True,
)
```

`read_model_description` 的职责：

1. 打开 FMU（zip）或目录；
2. 读取 `modelDescription.xml`；
3. 根据 `fmiVersion` 选择 FMI 1/2/3 的 XSD；
4. 用 `lxml.etree.XMLSchema` 做结构校验；
5. 把 XML 转成 Python 对象（`ModelDescription`、`ModelVariable`、`SimpleType`、`Unit` 等）；
6. 可选地调用 `validation.validate_model_description` 做语义校验；
7. 读取 `buildDescription.xml`（FMI 3）。

### 3.2 数据结构

FMPy 用普通 Python 类/数据类表示模型描述，字段与 XSD 对应。关键类包括：

- `ModelDescription`
- `ModelVariable`
- `SimpleType`
- `Unit` / `BaseUnit` / `DisplayUnit`
- `Dimension`
- `Unknown`
- `InterfaceType` / `ModelExchange` / `CoSimulation` / `ScheduledExecution`
- `BuildConfiguration` / `SourceFileSet` / `PreProcessorDefinition`

### 3.3 写回

FMPy 还提供 `write_model_description`，可以从对象生成 FMI 2/3 的 XML。这对导出器很有参考价值：

- 元素顺序必须符合 XSD；
- 默认值是否写出要一致；
- 变量顺序、类型元素、别名、数组维度都要正确；
- 生成的 XML 应能通过官方 XSD 校验。

### 3.4 对 MoonFMI 的启示

- 解析与校验分开：`read_model_description` 负责结构，`validation` 负责语义。
- 校验选项可配置：不是所有场景都需要变量名/模型结构校验。
- 写回功能应与解析共用同一套类型化模型，避免“读一套、写一套”。
- 错误信息应包含 XSD 的 `error_log` 或语义规则编号。

---

## 4. 语义校验

`fmpy/validation.py` 提供：

```python
def validate_fmu(filename) -> list[str]:
    ...

def validate_model_description(
    model_description,
    validate_variable_names=False,
    validate_model_structure=False,
) -> list[str]:
    ...
```

### 4.1 校验内容

- **变量名**：按 FMI 的 EBNF 检查（`flat`/`structured` 命名约定）。
- **模型结构**：
  - `Outputs` 是否包含所有 `causality="output"`；
  - `Derivatives` 是否只包含状态导数；
  - `InitialUnknowns` 是否按索引排序、无重复；
  - 依赖索引是否有效；
  - `dependenciesKind` 长度是否匹配。
- **FMU 层面**：
  - 必需文件是否存在；
  - 平台目录是否匹配；
  - `modelIdentifier` 与二进制文件名是否一致；
  - 资源路径是否有效。

### 4.2 对 MoonFMI 的启示

- 校验规则要独立于解析器，返回**诊断列表**而不是抛第一个异常。
- 规则要有稳定编号（MoonFMI 用 `MD-xxx`），便于测试和文档引用。
- 变量名校验应可关闭：有些真实 FMU 的名字不完全规范，但工具仍能运行。
- 校验应区分 error / warning，不要把所有问题都当致命错误。

---

## 5. 运行时绑定（以 FMI 2 为例）

### 5.1 ctypes 结构体

`fmpy/fmi2.py` 用 `ctypes.Structure` 定义：

```python
class fmi2CallbackFunctions(Structure):
    _fields_ = [
        ("logger", fmi2CallbackLogger),
        ("allocateMemory", fmi2CallbackAllocateMemory),
        ("freeMemory", fmi2CallbackFreeMemory),
        ("stepFinished", fmi2StepFinished),
        ("componentEnvironment", c_void_p),
    ]

class fmi2EventInfo(Structure):
    _fields_ = [
        ("newDiscreteStatesNeeded", c_int),
        ("terminateSimulation", c_int),
        ("nominalsOfContinuousStatesChanged", c_int),
        ("valuesOfContinuousStatesChanged", c_int),
        ("nextEventTimeDefined", c_int),
        ("nextEventTime", c_double),
    ]
```

### 5.2 实例类

- `_FMU2`：公共基类，持有 `cdll`、函数指针、回调。
- `FMU2Model`：Model Exchange 实例。
- `FMU2Slave`：Co-Simulation 实例。

方法大致对应 C API：

```python
fmu = FMU2Slave(guid, modelIdentifier, instanceName, resourceLocation)
fmu.instantiate(...)
fmu.setupExperiment(...)
fmu.enterInitializationMode()
fmu.exitInitializationMode()
fmu.doStep(...)
fmu.getReal(...)
fmu.terminate()
fmu.freeInstance()
```

### 5.3 平台选择

FMPy 根据当前 OS/架构选择 `binaries/<platform>`，并处理：

- Windows 32/64 位；
- Linux 32/64 位；
- macOS 32/64 位；
- 静态库/源码的回退；
- `modelIdentifier` 与文件名。

### 5.4 回调

- `logger` 是可变参数函数，FMPy 用 ctypes 回调实现；
- `allocateMemory` / `freeMemory` 默认用 `libc` 的 `malloc/free`；
- `stepFinished` 用于异步步进；
- `componentEnvironment` 传实例指针。

### 5.5 对 MoonFMI 的启示

- ctypes 的“结构体 + 函数指针”模式可以对照 MoonBit 的 C shim 设计。
- 回调上下文（`componentEnvironment`）必须原样保存并传回。
- 平台选择要有清晰的错误信息，不要静默回退到错误架构。
- 运行时绑定只做“薄封装”，不要在绑定层做业务逻辑。

---

## 6. 主算法

### 6.1 入口

```python
from fmpy import simulate_fmu

result = simulate_fmu(
    "model.fmu",
    start_time=0.0,
    stop_time=10.0,
    step_size=0.01,
    input=[...],
    output=["y"],
    solver="Euler",
)
```

### 6.2 CS 主循环

`simulateCS` 的核心逻辑：

```text
instantiate
setupExperiment
enterInitializationMode
applyStartValues
exitInitializationMode
while time < stopTime:
    apply inputs at time
    doStep(time, stepSize, noSetFMUStatePriorToCurrentPoint)
    handle event mode if needed
    get outputs
    record
terminate
freeInstance
```

关键点：

- 输入信号按时间插值（`Input` 类）。
- 记录器（`Recorder`）按输出变量收集数组，最后拼成 `SimulationResult`（`numpy.ndarray` 子类）。
- 支持 `step_finished` 回调、超时、事件记录。
- FMI 3 支持 early return、intermediate update、event mode。

### 6.3 ME 主循环

`simulateME` 的核心逻辑：

```text
instantiate
setupExperiment
enterInitializationMode
exitInitializationMode
enterContinuousTimeMode
while time < stopTime:
    setTime
    setContinuousStates
    getDerivatives
    solver step (ForwardEuler / CVode)
    getEventIndicators
    if event:
        enterEventMode
        loop newDiscreteStates
        enterContinuousTimeMode
    record
terminate
freeInstance
```

FMPy 内置 `ForwardEuler`，也可通过 `solver` 参数接入外部求解器（如 CVode，取决于安装的可选依赖）。

### 6.4 对 MoonFMI 的启示

- 主算法应独立于绑定层，通过抽象接口调用 FMU。
- 输入插值、结果记录、事件处理是主算法的核心，不要塞进导入器。
- CS 先做固定步长，再做变步长/事件/early return。
- ME 先做显式 Euler + 事件迭代，再考虑高阶/隐式求解器。
- 结果容器应按列存数组，而不是每步分配对象。

---

## 7. 源码 FMU 构建

FMPy 的 `build.py` 可以从源码 FMU 构建二进制：

```bash
fmpy compile model.fmu
```

流程大致：

1. 解压 FMU；
2. 读取 `modelDescription.xml` / `buildDescription.xml`；
3. 找 `sources/` 下的源文件；
4. 选择 CMake 生成器/编译器；
5. 编译成 `.dll/.so/.dylib`；
6. 放回 `binaries/<platform>/`；
7. 重新打包。

### 7.1 对 MoonFMI 的启示

- 源码 FMU 导出比 native 二进制导出更现实：MoonFMI 生成源码 + 构建描述，让外部工具编译。
- `buildDescription.xml` 是 FMI 3 的标准机制，应优先支持。
- 构建过程需要处理平台/编译器差异，不要假设 CMake 一定存在。

---

## 8. CLI 与 Web

FMPy 的 CLI 提供：

```bash
fmpy info model.fmu
fmpy validate model.fmu
fmpy simulate model.fmu --start-time 0 --stop-time 10 --output y
fmpy create ...
fmpy compile model.fmu
```

`fmpy info` 输出模型摘要，`fmpy validate` 输出校验问题，`fmpy simulate` 输出 CSV/图表。

Web 应用（`fmpy/webapp`）提供上传 FMU、配置参数、运行仿真、下载结果的界面。

### 8.1 对 MoonFMI 的启示

- CLI 是调试和 CI 的主要入口，应尽早做。
- 输出格式优先支持 CSV/JSON，便于脚本处理。
- `info` / `validate` 应可在不加载二进制的情况下运行，适合快速检查。
- Web 不是首期目标；WASM 后端稳定后再考虑。

---

## 9. 交叉检查

FMPy 提供 `cross_check` 模块，与 [fmi-cross-check](https://github.com/modelica/fmi-cross-check) 集成：

- 下载测试 FMU；
- 用 FMPy 运行；
- 与参考结果比较；
- 生成报告。

### 9.1 对 MoonFMI 的启示

- 交叉检查应作为发布前的必跑项，而不是可选项。
- 需要定义数值容差、失败分类（加载失败/初始化失败/结果偏差/超时）。
- 结果报告应可机器读取（JSON），便于 CI 判定。

---

## 10. 优点与局限

### 10.1 优点

- 覆盖完整，行为成熟；
- Python 生态易扩展；
- 校验与仿真分离；
- 支持 FMI 1/2/3；
- 有 Web、CLI、交叉检查；
- 代码结构清晰，适合学习。

### 10.2 局限

- ctypes 调用有开销，Python GIL 限制并发；
- 依赖 `lxml`/`numpy`/CMake 等外部组件；
- 不能直接运行在浏览器；
- 对恶意 FMU 没有强沙箱；
- FMI 3 的某些新特性支持可能滞后；
- 源码构建依赖本地工具链，跨平台体验一般。

### 10.3 对 MoonFMI 的取舍

| FMPy 做法 | MoonFMI 是否采用 | 说明 |
| --- | --- | --- |
| 版本专用绑定类 | ✅ | `fmi2` / `fmi3` 分包 |
| lxml + XSD 校验 | 🟡 | 运行时手写，CI 用 XSD |
| 统一 `ModelDescription` | ✅ | 公共 schema 层 |
| `simulate_fmu` 门面 | ✅ | CLI 和库 API |
| numpy 结果容器 | ❌ | 用 MoonBit 数组/列式容器 |
| ctypes 回调 | 🟡 | 用 C shim 替代可变参数/结构体 |
| CMake 构建 | 🟡 | 生成源码 + 外部构建，不强依赖 CMake |
| Web 应用 | ⬜ | 后续 |

---

## 11. 可复用的具体经验

1. **先 `info`/`validate`，再 `simulate`**：降低调试成本。
2. **解析时保留原始 XML**：便于错误定位和重新输出。
3. **平台选择显式化**：打印选中的 `binaries/<platform>` 和 `modelIdentifier`。
4. **资源路径统一构造**：FMI 2 用 `file://` + 结尾 `/` + URI 转义；FMI 3 用原生绝对路径 + 结尾分隔符。
5. **状态保存/恢复独立封装**：不要和步进逻辑混在一起。
6. **事件迭代循环要有上限**：防止 FMU 死循环。
7. **结果记录按列**：变量多时性能差异明显。
8. **输入插值单独测试**：阶跃、线性、保持、越界。
9. **错误分类**：加载/解析/校验/初始化/步进/终止，便于用户定位。
10. **交叉检查报告机器可读**：JSON + 人类可读摘要。

---

## 12. 参考

- FMPy 仓库：<https://github.com/CATIA-Systems/FMPy>
- FMPy 文档：<https://fmpy.readthedocs.io/>
- fmi-cross-check：<https://github.com/modelica/fmi-cross-check>
- MoonFMI 的导入器设计：[`../design/importer.md`](../design/importer.md)
- MoonFMI 的主算法设计：[`../design/master-algorithm.md`](../design/master-algorithm.md)
