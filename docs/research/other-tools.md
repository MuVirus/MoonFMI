# 其他 FMI 工具与测试生态

本文梳理 MoonFMI 可以直接复用的测试语料、参考实现和交叉验证工具。重点不是“再造一个工具”，而是**用别人的 FMU 和结果验证自己**。

---

## 1. 测试语料

### 1.1 `modelica/Reference-FMUs`

- 仓库：<https://github.com/modelica/Reference-FMUs>
- 维护方：Modelica Association
- 内容：一组官方参考 FMU 的 C 源码 + 构建脚本，覆盖 FMI 2.0/3.0、ME/CS/SE、各种变量类型、数组、时钟、状态、事件。
- 用途：
  - 验证导入器的 API 调用顺序；
  - 验证模型描述解析；
  - 验证数值结果；
  - 作为“最小可靠语料”。

优点：

- 代码可读，行为明确；
- 覆盖标准特性；
- 有 CMake，可自行构建不同平台；
- 适合做单元/集成测试。

注意：

- 不同版本/分支可能对应不同 FMI 版本；
- 部分示例依赖特定编译器/平台；
- 不要把二进制直接塞进主仓库，用脚本下载/构建。

### 1.2 `modelica/fmi-cross-check`

- 仓库：<https://github.com/modelica/fmi-cross-check>
- 内容：大量工具导出的 FMU + 参考结果 + 交叉检查规则。
- 用途：
  - 验证真实世界 FMU 的兼容性；
  - 对比不同导入器的结果；
  - 发现“标准允许但实现差异”的边界。

典型结构：

```text
fmi-cross-check/
├── FMUs/
│   └── <tool>/<version>/<platform>/<model>.fmu
├── results/
│   └── <tool>/<version>/<platform>/<model>.csv
└── ...
```

注意：

- 结果有容差和格式约定；
- 不是所有 FMU 都能在所有平台运行；
- 需要区分“加载失败/初始化失败/结果偏差/超时”。

### 1.3 fmi-rs `fmi-test-data`

- 仓库：<https://github.com/jondo2010/rust-fmi>
- 内容：Rust 生态的测试 FMU。
- 用途：补充 Reference-FMUs 未覆盖的场景；验证跨语言兼容性。

### 1.4 FMPy 测试 FMU

- FMPy 仓库自带/下载的测试 FMU。
- 用途：验证与 Python 生态的行为一致性；特别是 CS/ME 的边界情况。

### 1.5 自造 FMU

用途：

- 边界条件（空数组、极大/极小值、非法字段）；
- 安全测试（路径穿越、XXE、压缩炸弹）；
- 可控的失败注入（返回 `fmi3Error`、超时、日志）。

建议用 C 写一个“可配置的坏 FMU”测试夹具，而不是依赖真实工具的 bug。

---

## 2. 导入/仿真工具

### 2.1 OMSimulator

- 仓库：<https://github.com/OpenModelica/OMSimulator>
- 类型：CLI + 库，支持 FMI 2.0/3.0、SSP、TLM 等。
- 用途：
  - 作为 MoonFMI 的对照实现；
  - 验证 SSP/FMU 组合；
  - 交叉检查结果。

优点：

- 命令行友好，适合 CI；
- 支持 SSP；
- 开源。

注意：

- 依赖 OpenModelica 生态；
- 某些功能仅 Linux 稳定；
- 版本差异较大。

### 2.2 OpenModelica

- 仓库：<https://github.com/OpenModelica/OpenModelica>
- 类型：Modelica 编译器/仿真环境，可导出 FMU。
- 用途：
  - 生成测试 FMU；
  - 作为参考仿真器；
  - 验证 ME/CS 语义。

注意：

- 安装体积大；
- 导出 FMU 的选项多，需固定配置；
- 不同版本行为可能不同。

### 2.3 Dymola / SimulationX

- 商业工具，广泛用于工业 FMU 导出。
- 用途：验证与商业工具的互操作性。
- 注意：需要许可证；CI 中通常只用预生成的 FMU。

### 2.4 fmi4cpp

- 仓库：<https://github.com/NTNU-IHB/FMI4cpp>
- 类型：C++ FMI 库。
- 用途：参考 C++ 的 RAII/异常处理设计；FMI 2.0 为主，3.0 支持需确认。
- 注意：不要直接复用其代码（许可证/风格），只借鉴设计。

### 2.5 FMI.jl / FMIKit-Simulink

- Julia / MATLAB 生态的 FMI 集成。
- 用途：了解不同语言如何封装 FMI；验证跨语言行为。
- 注意：依赖各自运行时，不适合作为 MoonFMI 的直接依赖。

---

## 3. 导出工具

### 3.1 pythonfmu

- 仓库：<https://github.com/NTNU-IHB/PythonFMU>
- 类型：用 Python 类定义模型，打包成 FMU。
- 用途：
  - 参考“用户友好”的导出 API；
  - 参考 Python 运行时的打包方式；
  - 生成测试 FMU。

优点：

- API 简单；
- 支持 FMI 2/3；
- 适合快速造测试模型。

注意：

- 依赖 Python 运行时；
- 性能/分发不如原生；
- 不是 MoonFMI 的直接实现路径。

### 3.2 FMU SDK（Qtronic）

- 类型：C 示例 FMU + 构建脚本。
- 用途：最小 C FMU 参考；理解 `modelDescription.xml` 与 C 函数的对应关系。
- 注意：较老，主要覆盖 FMI 2.0。

### 3.3 fmi-export / cargo-fmi

- 见 [`fmi-rs.md`](fmi-rs.md)。
- 用途：参考 trait + 代码生成 + 打包的导出器设计。

---

## 4. SSP（System Structure and Parameterization）

- 官网：<https://ssp-standard.org/>
- 内容：把多个 FMU 组合成系统，描述连接、参数、资源。
- 文件：`.ssp`（ZIP），含 `SystemStructureDescription.xml`、`resources/` 等。
- 工具：OMSimulator、FMPy（部分）、商业工具。

MoonFMI 的决策：

- 首期不支持 SSP；
- 导入器/导出器稳定后，再评估是否做 SSP 解析/组合；
- 如果做，应复用 FMU 容器/XML/ZIP 基础设施，但不要和 FMU 模型描述混淆。

---

## 5. FMI-LS-BUS

- 仓库：<https://github.com/modelica/fmi-ls-bus>
- 内容：FMI 3 分层标准，用于总线仿真（CAN、LIN 等）。
- 与 MoonFMI 的关系：
  - 不是首期目标；
  - 如果未来做“FMU + 总线”联合仿真，需要单独的 layered standard 支持；
  - 核心导入器应忽略未知 `extra/` 内容，不应因 LS-BUS 文件失败。

---

## 6. 工具对比

| 工具 | 语言 | 导入 | 导出 | CLI | 浏览器 | 测试语料 | 适合借鉴 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| FMPy | Python | ✅ | ✅（源码） | ✅ | ❌ | ✅ | 全流程、校验、主算法 |
| fmi-rs | Rust | ✅ | ✅ | 🟡 | ❌ | ✅ | 分层、类型安全、导出 |
| OMSimulator | C++ | ✅ | ❌ | ✅ | ❌ | ✅ | SSP、CLI、交叉检查 |
| OpenModelica | C++/Meta | ✅ | ✅ | ✅ | 🟡 | ✅ | 生成 FMU、语义参考 |
| Dymola | 商业 | ✅ | ✅ | 🟡 | ❌ | ✅ | 工业兼容性 |
| pythonfmu | Python | ❌ | ✅ | 🟡 | ❌ | ✅ | 导出 API |
| FMU SDK | C | ✅ | ✅ | ❌ | ❌ | ✅ | 最小 C FMU |
| fmi4cpp | C++ | ✅ | ❌ | ❌ | ❌ | 🟡 | RAII/异常设计 |
| MoonFMI | MoonBit | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | — |

图例：✅ 支持，🟡 部分/计划，❌ 不支持。

---

## 7. 对 MoonFMI 的具体建议

### 7.1 测试

1. **第一层**：用 Reference-FMUs 做单元/集成测试，覆盖 ME/CS、FMI 2/3。
2. **第二层**：用 fmi-cross-check 的 20–50 个 FMU 做兼容性测试。
3. **第三层**：和 FMPy/OMSimulator 对同一 FMU 的结果做数值对比。
4. **第四层**：自造坏 FMU 做安全和错误处理测试。
5. **第五层**：WASM FMU 用 LS-WASM 参考 runner + 浏览器测试。

### 7.2 工具复用

- 下载脚本复用 fmi-cross-check 的目录结构；
- 结果格式对齐 fmi-cross-check 的 CSV，便于比较；
- 不直接依赖 OMSimulator/FMPy 运行时，只在 CI 中作为外部命令；
- 许可证要兼容（FMPy 是 BSD? fmi-rs 是 MIT/Apache；使用前确认）。

### 7.3 不要做的事

- 不要只测自己导出的 FMU；
- 不要把“能加载”当成“语义正确”；
- 不要忽略失败分类；
- 不要在 CI 中跑没有超时的 FMU；
- 不要把商业 FMU 提交到公共仓库（许可证）。

---

## 8. 参考链接

- Reference-FMUs：<https://github.com/modelica/Reference-FMUs>
- fmi-cross-check：<https://github.com/modelica/fmi-cross-check>
- OMSimulator：<https://github.com/OpenModelica/OMSimulator>
- OpenModelica：<https://github.com/OpenModelica/OpenModelica>
- pythonfmu：<https://github.com/NTNU-IHB/PythonFMU>
- fmi4cpp：<https://github.com/NTNU-IHB/FMI4cpp>
- SSP：<https://ssp-standard.org/>
- FMI-LS-BUS：<https://github.com/modelica/fmi-ls-bus>
- FMPy：<https://github.com/CATIA-Systems/FMPy>
- fmi-rs：<https://github.com/jondo2010/rust-fmi>
