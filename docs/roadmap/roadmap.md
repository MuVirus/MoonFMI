# 阶段路线图

> 说明：周期是粗略的人周估算，假设 1–2 名熟悉 MoonBit 和 C 接口的开发者；仅供排期参考，不作为承诺。

---

## 0. 总览

| 阶段 | 主题 | 粗略周期 | 关键产物 |
| --- | --- | --- | --- |
| P0 | 先确认关键环节走得通 | 2–4 周 | 能读说明书、能拆 FMU、能调用动态库、能把 C 代码编进来、WebAssembly 试做 |
| P1 | 解析与校验 | 4–6 周 | `xml`/`zip`/`schema`、`moonfmi validate` |
| P2 | FMI 2 CS 导入（MVP） | 4–6 周 | native 后端、CS 主算法、`simulate`、真实 FMU |
| P3 | FMI 2 ME | 3–4 周 | ME 主算法、RK4、事件、参考轨迹 |
| P4 | FMI 3 CS/ME | 5–7 周 | 新类型/数组/Clock、FMI 3 后端、交叉检查 |
| P5 | CLI/诊断/打包完善 | 2–3 周 | `info`/`doctor`/`package`、JSON schema、文档 |
| P6 | 源码 FMU 导出 | 4–6 周 | IR、C 代码生成、源码 FMU、native 纯 C 路径 |
| P7 | WASM / LS-WASM | 6–10 周 | WebAssembly 版 CS FMU、浏览器/宿主试验、WASM 导出 |
| P8 | 硬化与发布 | 持续 | fuzz、安全、性能、交叉检查、release |

总计约 6–9 个月达到“FMI 2/3 native CS/ME + 源码导出”的可用状态；WebAssembly 视试验结果可能延后。

---

## P0 · 先确认关键环节走得通

> 详细执行计划（做什么 / 参考什么 / 验收标准）：[`p0-plan.md`](p0-plan.md)

### 目标

在开始写导入器之前，先确认 MoonBit 能应付五个关键环节：读说明书、拆 FMU、调用动态库、把 C 代码编进构建、编译成 WebAssembly。任何一环走不通，都要先改设计，而不是硬写。

### 要做的事

1. 建好仓库骨架：`src/{zip,xml,schema,fmi,backend,sim,export,cli}`、`tests/{data,abi,spikes}`。
2. 让每次提交自动检查格式、编译和测试，Windows 和 Linux 各跑一遍。
3. 写一个只够用的 XML 读取器，能完整读真实 `modelDescription.xml`，出错时能指到行列。
4. 写一个只读的 ZIP 读取器，能安全拆开 FMU，挡住路径穿越和压缩炸弹。
5. 用 C 写个小动态库，确认 MoonBit 能加载、调用、卸载，出错信息够用。
6. 写一层薄 C 代码，把 FMI 的结构体和可变参数隔开，确认它能编进 MoonBit 的构建。
7. 确认 FMI 2 的日志能接到 MoonBit：格式化、截断、中文不乱码、多线程不崩。
8. 记录 C 侧每种类型占几字节，并用一个 C 宿主跑真实 FMU，留下对照结果。
9. 准备 8 个真实 FMU 作为测试样品，一条命令取齐并核对校验和。
10. 试把 MoonBit 编译成 WebAssembly 组件，判断值不值得继续投入。

### 退出标准

- [ ] 能读懂真实 FMI 2/3 说明书的关键字段；
- [ ] 能安全拆开一个真实 FMU；
- [ ] 能加载、调用并卸载一个 C 动态库；
- [ ] C 代码有确定的编入方式，两个平台都能复现；
- [ ] 能收到并正确处理 FMI 2 的日志；
- [ ] WebAssembly 有明确的“能做 / 不能做”结论；
- [ ] 自动检查在 Windows 和 Linux 上稳定，真能拦住错误；
- [ ] 测试样品一条命令取齐，校验和能核对；
- [ ] 总结报告写清楚版本、踩过的坑和结论。

### 风险

- C 代码编不进去 → 缩到只处理结构体，或单独编成动态库；
- WebAssembly 走不通 → 先放下，不影响 native；
- 现成的 XML/ZIP 库不好用 → 换库，或只自己解析 ZIP 目录，deflate 仍用库。

---

## P1 · 解析与校验

### 目标

交付一个**不执行 FMU**也能用的验证器。

### 交付物

- `xml`：封装现成 XML 读取器，补安全限制；
- `zip`：封装现成解压库，自己控制路径与解压策略；
- `schema`：FMI 2/3 类型化模型描述、索引与语义校验（含 MD-001…MD-063 规则）；
- `cli validate`：文本/JSON、退出码；
- CI 里的 XSD 独立对照检查；
- 合法、结构错误、语义错误、恶意四类测试样品。

### 退出标准

- [ ] FMI 2/3 的最小样品和完整样品全部按预期通过或失败；
- [ ] 每条已实现规则有正例和反例；
- [ ] 格式合规但语义错误的样品能被 MoonFMI 拒绝；
- [ ] 路径穿越/XXE/压缩炸弹测试通过；
- [ ] 1 万变量模型解析 + 校验在目标时间内；
- [ ] `moonfmi validate --json` schema 稳定；
- [ ] fuzz 固定种子回归无 panic/OOM。

### 非目标

- 不加载动态库；
- 不做仿真；
- 不追求 100% XSD 字段覆盖（按优先级逐步补）。

---

## P2 · FMI 2 CS 导入（MVP）

### 目标

用 MoonBit 加载并仿真一个真实 FMI 2.0.4 CS FMU。

### 交付物

- `fmi`：打开/解压、平台选择、Instance/值/回调抽象；
- `backend/native`：`dlopen`、符号绑定、薄 C 中间层；
- `sim`：CS 初始化/步进/事件/错误；
- 结果记录 CSV；
- `cli simulate` 基础版；
- 真实 FMU 集成测试。

### 退出标准

- [ ] 能加载 Reference-FMUs 的 FMI 2 CS 模型；
- [ ] `BouncingBall` 事件正确、能停止；
- [ ] `Dahlquist` 与解析解/ FMPy 在容差内；
- [ ] 输入设置/输出读取类型正确；
- [ ] 缺失平台/符号/依赖时错误可定位；
- [ ] 多实例不串状态；
- [ ] Windows x64 + Linux x64 通过；
- [ ] 退出码/JSON 输出可用于 CI。

### MVP 定义

> 能对一个合法的 FMI 2.0.4 CS FMU 执行 `validate`、`info`、`simulate`，输出可与 FMPy 对比的 CSV，并在 Windows/Linux 上稳定运行。

---

## P3 · FMI 2 ME

### 目标

补齐 FMI 2 ME 的基础仿真能力。

### 交付物

- ME 实例化/状态/导数/事件指示器绑定；
- Euler + RK4；
- 事件检测（二分/线性插值）；
- `completedIntegratorStep`；
- ME 结果记录；
- 参考轨迹测试。

### 退出标准

- [ ] `VanDerPol` / `BouncingBall` ME 与参考轨迹在容差内；
- [ ] 事件时间/次数合理；
- [ ] 状态 reinit/标称值变化处理正确；
- [ ] 不支持的能力明确报错；
- [ ] 文档声明“非通用求解器”的边界。

### 非目标

- 刚性求解器；
- 大规模 DAE；
- 高性能稀疏线性代数。

---

## P4 · FMI 3 CS/ME

### 目标

支持 FMI 3.0.2 的主流 CS/ME 模型。

### 交付物

- FMI 3 类型化模型（P1 已有）接入运行时；
- 新类型：Float32/Int8…UInt64/String/Binary/Clock；
- 数组与维度；
- 状态保存/序列化（可选能力）；
- 早退/中间更新（按可行性试验结果）；
- FMI 3 的 C 接口测试；
- Reference-FMUs FMI 3 集成。

### 退出标准

- [ ] FMI 3 CS/ME 最小模型通过；
- [ ] 数组变量读写正确；
- [ ] 布尔（1 字节）与 FMI 2（4 字节）分别测试；
- [ ] `size_t` 32/64 位测试；
- [ ] 可选能力缺失时行为明确；
- [ ] 与 FMPy/Reference 结果对比；
- [ ] SE 仅做可行性研究，不承诺。

---

## P5 · CLI/诊断/打包完善

### 目标

把工具从“能跑”变成“可日常使用”。

### 交付物

- `info`、`doctor`、`package`；
- JSON schema 文档；
- 错误诊断改进（路径/行列/规则）；
- `--strict`/`--timeout`/`--backend`；
- 文档与示例；
- shell completion（可选）。

### 退出标准

- [ ] 所有命令有 `--help` 和示例；
- [ ] 退出码矩阵测试；
- [ ] JSON 输出向后兼容；
- [ ] 打包产物可被 FMPy 打开；
- [ ] 诊断信息能直接定位到字段/变量；
- [ ] 新用户按 README 能在 10 分钟内跑通一个示例。

---

## P6 · 源码 FMU 导出

### 目标

从受限模型 IR 生成可构建的源码 FMU。

### 交付物

- `export` 的 IR：模型 IR；
- `export` 的 codegen：`modelDescription.xml` + C；
- 源码 FMU 布局 + CMake；
- FMI 3 `buildDescription.xml`；
- 纯 C native 二进制路径；
- 生成 FMU 的验证/回读。

### 退出标准

- [ ] 生成 FMI 2 CS 源码 FMU，外部编译后能被 FMPy/MoonFMI 加载；
- [ ] 生成 FMI 3 CS/ME 最小模型；
- [ ] 数组/单位/类型正确；
- [ ] 生成代码可读、可调试；
- [ ] 打包可复现（哈希稳定）；
- [ ] 与手写参考 FMU 输出一致。

---

## P7 · WASM / LS-WASM

### 目标

跑通 LS-WASM 的最小 CS FMU，并评估浏览器/宿主。

### 交付物

- 五组可行性试验（POC-1…POC-5，见研究文档）；
- WIT 绑定层；
- 最小 CS component；
- FMU 布局 + manifest；
- wasmtime 宿主；
- `jco` 浏览器可行性试验；
- WASM 导出器（实验性）。

### 退出标准

- [ ] MoonBit wasm → 合法 component；
- [ ] resource 生命周期正确；
- [ ] string/list 往返正确；
- [ ] Adder CS 完成 instantiate/step/get/set/terminate；
- [ ] 浏览器可运行；
- [ ] 与 native Adder 结果一致；
- [ ] 工具链版本/限制记录；
- [ ] 失败时明确标记“实验性”，不影响 native 发布。

---

## P8 · 硬化与发布

### 目标

从“可用”到“可维护/可发布”。

### 交付物

- fuzz 语料与回归；
- 安全审查（ZIP/XML/DLL/wasm）；
- 性能基线与回归；
- 大规模交叉检查；
- 文档/示例/迁移说明；
- release checklist、SBOM、许可证审计。

### 退出标准

- [ ] 关键安全路径有测试；
- [ ] 无已知高危缺陷；
- [ ] 交叉检查覆盖主流 FMU；
- [ ] 性能无明显回归；
- [ ] 发布包可复现；
- [ ] 文档与实现一致；
- [ ] 已知限制公开。

---

## 并行工作流

| 工作流 | 可并行阶段 | 说明 |
| --- | --- | --- |
| FMI 3 解析器 | P2 期间 | 不依赖运行时 |
| XSD / 测试样品 | P1–P4 | 持续补充 |
| C 中间层 / 类型尺寸 | P0–P4 | 与运行时同步 |
| WebAssembly 可行性试验 | P0/P1 | 不阻塞 native |
| 导出 IR | P4/P5 | 复用 schema |
| 文档 | 全程 | 设计变更即时更新 |

---

## 发布节奏建议

| 版本 | 内容 |
| --- | --- |
| `0.1` | `validate` + `info`（FMI 2/3） |
| `0.2` | FMI 2 CS `simulate`（MVP） |
| `0.3` | FMI 2 ME |
| `0.4` | FMI 3 CS/ME |
| `0.5` | 打包 + 源码导出 |
| `0.6` | WASM 实验版 |
| `1.0` | 硬化、文档、交叉检查达标 |

版本号只是建议；以退出标准为准。

---

## 相关文档

- P0 详细计划：[`p0-plan.md`](p0-plan.md)
- 任务清单：[`backlog.md`](backlog.md)
- 风险：[`risks.md`](risks.md)
- 设计：[`../design/README.md`](../design/README.md)
- 测试：[`../design/cli-and-testing.md`](../design/cli-and-testing.md)
