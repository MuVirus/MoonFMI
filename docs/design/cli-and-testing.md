# CLI 与测试设计

> 状态：设计提案。CLI 是“可脚本化的验证/仿真入口”，不是 GUI；输出必须稳定、可解析、可回归。

---

## 1. CLI 原则

1. **默认安全**：`validate` 不执行 FMU；只有 `simulate` 才加载动态库。
2. **机器可读**：所有命令支持 `--json`，stdout 只输出数据，诊断走 stderr。
3. **稳定退出码**：CI 可以按退出码分支，不解析自然语言。
4. **可复现**：相同输入/参数 → 相同输出（除时间戳/路径等显式元数据）。
5. **不静默降级**：后端、平台、接口选择都打印或写入 JSON。
6. **明确失败**：错误包含阶段、文件、变量、规则编号。

---

## 2. 命令集

```text
moonfmi validate <fmu|modelDescription.xml> [options]
moonfmi info <fmu> [options]
moonfmi simulate <fmu> [options]
moonfmi export <model-ir> [options]
moonfmi package <dir> [options]
moonfmi wasm <fmu|dir> [options]
moonfmi crosscheck <suite> [options]
moonfmi doctor [options]
```

### 2.1 `validate`

只做静态检查：

- ZIP 布局/路径安全；
- XML 良构/编码；
- 类型化模型；
- 语义规则 MD-xxx；
- 可选：二进制/ manifest 存在性；
- 不加载动态库。

```bash
moonfmi validate model.fmu --strict --json
```

### 2.2 `info`

输出模型摘要：

- FMI 版本、接口、能力；
- 变量数量/类型分布；
- 单位/类型定义；
- 平台二进制；
- 校验警告；
- FMU 校验和。

```bash
moonfmi info model.fmu --json
```

### 2.3 `simulate`

```bash
moonfmi simulate model.fmu \
  --interface cs \
  --start 0 --stop 10 --step 0.01 \
  --input inputs.csv \
  --output results.csv \
  --backend native
```

选项：

| 选项 | 说明 |
| --- | --- |
| `--interface cs|me|se` | 默认按能力选择 |
| `--start/--stop/--step` | 时间配置 |
| `--tolerance` | 容差 |
| `--solver euler|rk4|adaptive` | ME 求解器 |
| `--input` | CSV/JSON 输入 |
| `--output` | 结果文件 |
| `--backend native|wasm` | 后端 |
| `--platform` | 覆盖平台目录 |
| `--record` | 记录变量列表 |
| `--fail-on-warning` | 警告即失败 |
| `--max-steps` | 上限 |

### 2.4 `export`

```bash
moonfmi export model.ir.json \
  --target source \
  --fmi-version 3.0 \
  --output build/
```

### 2.5 `package`

```bash
moonfmi package build/MyModel \
  --output dist/MyModel.fmu \
  --platform x86_64-windows \
  --deterministic
```

### 2.6 `wasm`

```bash
moonfmi wasm build/MyModel --check --manifest
moonfmi wasm model.fmu --run --backend wasmtime
```

### 2.7 `crosscheck`

```bash
moonfmi crosscheck fmi-cross-check/ \
  --tool moonfmi \
  --filter BouncingBall \
  --json report.json
```

### 2.8 `doctor`

检查环境：

- MoonBit 版本；
- 动态库加载能力；
- C 编译器；
- `xmllint`/`lxml`；
- `wasm-tools`/`wit-bindgen`/`jco`；
- 测试语料路径；
- 平台映射。

---

## 3. 全局选项

| 选项 | 说明 |
| --- | --- |
| `--json` | 机器可读输出 |
| `--quiet` | 只输出错误 |
| `--verbose` | 详细日志 |
| `--no-color` | 禁用颜色 |
| `--platform <id>` | 覆盖平台 |
| `--backend <name>` | 覆盖后端 |
| `--strict` | warning 视为 error |
| `--timeout <sec>` | 子进程/仿真超时 |

---

## 4. 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 1 | 一般错误（I/O、内部） |
| 2 | 用法错误/参数非法 |
| 3 | 校验失败（error） |
| 4 | 不支持（版本/接口/平台/能力） |
| 5 | 仿真失败（FMI error/fatal/discard 未恢复） |
| 6 | 超时/资源限制 |
| 7 | 依赖/环境缺失 |

约定：

- `validate` 有 warning 但无 error → 0（除非 `--strict`）；
- `simulate` 部分成功后失败 → 5，并写部分结果（若配置允许）；
- 参数错误不加载 FMU；
- 退出码稳定，不随语言/平台变化。

---

## 5. 输出格式

### 5.1 文本

```text
model.fmu
  FMI 3.0  CS, ME
  variables: 42 (real 30, integer 6, boolean 4, string 2)
  platforms: x86_64-windows, wasm32-wasip2
  warnings: 1

  MD-050 warning
    /fmiModelDescription/ModelVariables/ScalarVariable[7]/@unit
    unit "K" is not defined in UnitDefinitions
```

### 5.2 JSON

```json
{
  "schema": "moonfmi.validate/v1",
  "ok": false,
  "fmu": "model.fmu",
  "fmiVersion": "3.0",
  "diagnostics": [
    {
      "code": "MD-050",
      "severity": "warning",
      "message": "unit \"K\" is not defined",
      "path": "/fmiModelDescription/ModelVariables/ScalarVariable[7]/@unit",
      "line": 42,
      "column": 18
    }
  ],
  "summary": { "errors": 0, "warnings": 1 }
}
```

要求：

- 字段名稳定，带 schema 版本；
- 不输出颜色控制字符；
- 路径使用 `/`，即使 Windows；
- 浮点使用 JSON 数字，非有限值用字符串/null 并注明。

---

## 6. 测试金字塔

```text
                 ┌─────────────────────┐
                 │ 浏览器 / 跨工具交叉  │  少量、慢
                 ├─────────────────────┤
                 │ 真实 FMU 集成        │
                 ├─────────────────────┤
                 │ ABI / 后端契约       │
                 ├─────────────────────┤
                 │ golden / 快照        │
                 ├─────────────────────┤
                 │ 单元测试             │  大量、快
                 └─────────────────────┘
```

### 6.1 单元测试

- `xml`：词法/结构/限制；
- `zip`：路径/大小/CRC；
- `schema`：字段/默认值/版本；
- `schema` 的 validate 模块：每条 MD 规则正反例；
- `fmi`：值/类型/单位、平台选择；
- `sim`：时间网格/事件/错误策略；
- `export`：XML/C/WIT 生成的 golden。

### 6.2 Golden / 快照

- 诊断 JSON；
- 生成的 `modelDescription.xml`；
- 生成的 C 代码；
- 生成的 manifest；
- 打包清单。

使用 `moon test --update` 更新快照；更新必须人工审查 diff。

### 6.3 ABI 契约

- 每个平台的 `sizeof`/`offsetof`；
- 布尔/整数/字符串/二进制转换；
- 回调结构体；
- 动态库符号；
- C shim 与 MoonBit 的边界。

### 6.4 集成

真实 FMU：

- Reference-FMUs；
- fmi-cross-check；
- FMPy/fmi-rs 测试数据；
- 自造最小/恶意 FMU。

每个用例记录：

- 来源/版本/许可证；
- 平台；
- 预期接口/结果；
- 是否需要外部工具。

### 6.5 交叉工具

- FMPy：同模型、同输入、同通信步长；
- OpenModelica：ME 参考轨迹；
- fmi-rs：解析/导入行为；
- 浏览器：LS-WASM POC。

### 6.6 模糊测试

- XML/ ZIP 解析器；
- 模型描述字段变异；
- 路径/文件名；
- wasm component 校验；
- 不在 CI 中跑无限 fuzz，使用固定种子 + 时间预算。

---

## 7. CI 矩阵

### 7.1 基础

| 任务 | 平台 | 内容 |
| --- | --- | --- |
| `fmt` | Linux | `moon fmt --check` |
| `info` | Linux | `moon info`，检查 `.mbti` diff |
| `test` | Windows/Linux/macOS | `moon test` |
| `test-wasm` | Linux | `moon test --target wasm` |
| `validate-fixtures` | Linux | XSD + MoonFMI 双层校验 |
| `abi` | Windows/Linux | C shim 编译 + 断言 + 冒烟 |
| `integration` | Windows/Linux | 真实 FMU |
| `wasm-poc` | Linux | `wasm-tools`/`wit-bindgen` |
| `crosscheck` | Linux | FMPy 对比（可选/定时） |

### 7.2 依赖

- MoonBit 固定版本；
- C 编译器（MSVC/GCC/Clang）；
- `xmllint` 或 Python `lxml`；
- `wasm-tools`、`wit-bindgen`、`jco`（WASM job）；
- 测试 FMU 使用固定 commit/校验和，缓存下载。

### 7.3 不做什么

- 不在每个 PR 跑完整 fmi-cross-check（太慢）；
- 不依赖网络上的浮动最新 FMU；
- 不把“工具缺失”静默跳过；应标记 skipped 并在报告中可见。

---

## 8. 交叉检查

### 8.1 数据

fmi-cross-check 的目录约定：

```text
<tool>/<version>/<platform>/<model>.fmu
<tool>/<version>/<platform>/<model>.csv
```

### 8.2 比较

- 时间点对齐（相同通信步长）；
- 数值：绝对/相对容差；
- 事件：时间/次数；
- 字符串/布尔：精确；
- 失败：记录首个偏差、时间、变量、双方值。

### 8.3 容差

按变量设置：

```text
abs_tol = 1e-9
rel_tol = 1e-6
event_tol = 1e-6
```

对刚性/混沌系统不要用统一严格容差；文档记录模型特定的容差。

### 8.4 报告

- 通过/失败/跳过；
- 差异摘要；
- 可复现命令；
- 环境（OS/编译器/FMU 哈希）。

---

## 9. 性能测试

指标：

- FMU 打开/解析时间；
- 实例化时间；
- 每步开销（CS）；
- 导数调用开销（ME）；
- 内存峰值；
- WASM 启动/跨边界开销；
- 打包时间/大小。

方法：

- 固定语料、固定迭代次数、预热；
- 输出中位数/P95；
- 与基线比较，回归超过阈值（如 20%）报警；
- 不在共享 CI runner 上做绝对性能断言，只做趋势。

---

## 10. 覆盖率

```bash
moon coverage analyze > uncovered.log
```

关注：

- 每条 MD 规则至少一个正例/反例；
- 错误分支；
- 平台选择分支；
- ABI 转换；
- 打包失败路径。

覆盖率不是目标本身；未覆盖的**安全/错误路径**优先补。

---

## 11. 发布检查清单

- [ ] `moon fmt`、`moon info`、`moon test` 全绿；
- [ ] `.mbti` diff 已审查；
- [ ] XSD 语料双层校验通过；
- [ ] Windows/Linux 至少各一个真实 FMU 冒烟；
- [ ] CLI 退出码/JSON schema 未破坏；
- [ ] 新增规则有编号/文档/测试；
- [ ] 打包产物哈希稳定；
- [ ] 依赖/工具版本记录；
- [ ] 已知限制写入 release notes。

---

## 12. 相关文档

- 架构：[`architecture.md`](architecture.md)
- 校验：[`xsd-and-validation.md`](xsd-and-validation.md)
- 导入器：[`importer.md`](importer.md)
- 主算法：[`master-algorithm.md`](master-algorithm.md)
- 打包：[`packaging.md`](packaging.md)
- 其他工具：[`../research/other-tools.md`](../research/other-tools.md)
