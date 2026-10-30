# 解析与校验设计

> 状态：设计提案。核心结论：**运行时用现成的 pull parser 加一层安全封装，类型化构建器和语义校验器自己写；XSD 只在 CI 中做独立的对照检查。** 背景见 [`../standards/xsd-inventory.md`](../standards/xsd-inventory.md)。

---

## 1. 为什么不运行时校验 XSD

| 原因 | 说明 |
| --- | --- |
| 生态缺失 | MoonBit 没有成熟的通用 XSD 1.0/1.1 校验器 |
| 错误质量 | XSD 错误通常是“元素 X 不允许”，难以定位到变量/字段语义 |
| 覆盖不足 | 大量规则是跨字段/跨引用，XSD 表达不了 |
| 包体与启动 | 携带 19 个 XSD 和校验引擎不划算 |
| 可控性 | 薄封装能统一错误码、行列号和修复建议，不受上游 API 风格影响 |

XSD 的价值：

1. 作为字段、顺序、枚举、默认值的权威清单；
2. 在 CI 中独立校验测试语料，区分“语料坏”与“解析器坏”；
3. 升级 FMI 版本时做差异审查。

---

## 2. 解析流水线

```text
bytes
  → 编码/BOM 检查
  → XML pull parser（禁 DTD、限大小/深度）
  → 轻量 AST（元素、属性、文本、行列号）
  → 读取根属性 fmiVersion
  → 分派 FMI 2 / FMI 3 类型化构建器
  → ModelDescription
  → 语义校验
  → Diagnostic[]
```

### 2.1 为什么用 pull parser

- 变量可能上万，DOM 会复制大量节点；
- 可以在解析过程中执行深度/数量限制；
- 可以跳过不关心的注解子树；
- 行列号容易保留；
- 不依赖第三方 DOM 实现。

代价是类型化构建器仍要自己维护元素栈和顺序检查；这部分正是它要做的。

---

## 3. XML 解析层要求

底层词法/结构解析用 `Milky2018/xml`（GitHub 仓库名是 `moonbit-community/xml-mbt`），本章的约束由 `xml` 包在它外面实现；只有库本身满足不了时，才考虑替换或自研。

### 3.1 安全

必须默认：

- 拒绝 `<!DOCTYPE ...>`（直接报错，不进入实体处理）；
- 只允许预定义实体 `&amp; &lt; &gt; &quot; &apos;` 和数字字符引用；
- 拒绝外部实体、参数实体、未定义实体；
- 限制输入字节数（默认 32 MiB，可配置）；
- 限制元素深度（默认 256）；
- 限制属性数/单属性长度；
- 限制文本节点长度；
- 拒绝 NUL 和非法 XML 字符；
- 不访问网络/文件系统。

### 3.2 编码

- 接受 UTF-8（含 BOM）；
- XML 声明为其他编码时，明确报 `UnsupportedEncoding`，不做隐式转码；
- 校验 UTF-8 合法性；
- 行号按逻辑行计算，列号按字符或字节需在文档中固定（建议按 Unicode 标量）。

### 3.3 结构

- 元素名大小写敏感；
- 属性名大小写敏感；
- 重复属性 → 错误；
- 未闭合/错配标签 → 错误；
- 文本出现在不应有文本的元素中 → 错误（除非是注解/文档）；
- 命名空间：FMI 的 XSD 没有 target namespace，`modelDescription.xml` 通常没有 `xmlns`。不要强制要求命名空间；遇到未知命名空间时，在注解区域保留，在核心元素上报错。

### 3.4 API 草案

```moonbit
pub struct XmlReader {
  // 私有
}

pub fn XmlReader::new(bytes : Bytes, limits : XmlLimits) -> XmlReader raise XmlError
pub fn XmlReader::next(self) -> XmlEvent raise XmlError

pub enum XmlEvent {
  StartElement(name~ : String, attrs~ : Array[(String, String)], line~ : Int, column~ : Int)
  EndElement(name~ : String, line~ : Int, column~ : Int)
  Text(text~ : String, line~ : Int, column~ : Int)
  Eof
}
```

类型化构建器只消费事件流，不直接接触字节。

---

## 4. 类型化模型

### 4.1 版本分派

先只解析根元素和 `fmiVersion`：

```moonbit
let version = read_root_version(reader)?
match version {
  "2.0" | "2.0.x" => Fmi2Parser::parse(reader)
  "3.0" | "3.0.x" => Fmi3Parser::parse(reader)
  _ => raise UnsupportedVersion(version)
}
```

版本比较按语义版本，不按字符串前缀盲判；`3.0.2`、`3.0` 都接受，`3.1` 暂不支持。

### 4.2 两套模型，不强行统一

```moonbit
pub struct Fmi2ModelDescription {
  fmi_version : String
  model_name : String
  guid : String
  model_exchange : Fmi2ModelExchange?
  co_simulation : Fmi2CoSimulation?
  unit_definitions : Array[UnitDef]
  type_definitions : Array[SimpleType]
  variables : Array[ScalarVariable]
  model_structure : Fmi2ModelStructure?
  // ...
}

pub struct Fmi3ModelDescription {
  fmi_version : String
  model_name : String
  instantiation_token : String
  model_exchange : Fmi3ModelExchange?
  co_simulation : Fmi3CoSimulation?
  scheduled_execution : Fmi3ScheduledExecution?
  variables : Array[Variable]
  model_structure : Fmi3ModelStructure?
  // ...
}
```

共享层只放与版本无关的只读查询：

```moonbit
pub trait ModelDescriptionView {
  fn version(self) -> FmiVersion
  fn model_name(self) -> String
  fn interfaces(self) -> Array[InterfaceKind]
  fn variable_count(self) -> Int
  fn find_variable(self, name : String) -> VariableView?
}
```

不要为了“统一”把 FMI 3 的数组、Clock、新类型硬塞进 FMI 2 模型。

### 4.3 保留“是否显式提供”

很多字段有 XSD 默认值，语义层还会推导默认值。必须区分：

- 用户显式写了 `false`；
- 用户没写，XSD 默认 `false`；
- 语义层根据其他字段推导出的值。

实现方式：对可选属性使用 `Option<T>` 保存原始值，在语义层再填默认值：

```moonbit
pub struct Variable {
  name : String
  causality : Causality?
  variability : Variability?
  initial : Initial?
  // ...
}
```

诊断时可以说明“使用了默认值”，避免把默认值误报成用户错误。

### 4.4 原始信息

为了错误定位和导出，建议保留：

- 元素的行列号；
- 原始 `valueReference` 文本（用于诊断）；
- 未知属性/注解（至少能跳过并保留原始 XML 片段）；
- `Annotations` 子树不解析语义，只保存或忽略。

---

## 5. 语义校验

### 5.1 阶段

| 阶段 | 内容 | 失败后 |
| --- | --- | --- |
| V0 容器 | ZIP 布局、文件存在、路径安全 | 停止 |
| V1 XML | 良构、编码、实体、大小 | 停止 |
| V2 结构 | 元素顺序、必填、枚举、类型 | 收集后停止 |
| V3 索引 | 建 name/vr/type/unit 索引 | 停止 |
| V4 语义 | 跨字段、引用、组合规则 | 收集全部 |
| V5 跨文件 | 二进制/manifest/资源存在 | 收集 |
| V6 运行时 | 能力与符号（可选） | 警告/错误按配置 |

### 5.2 规则组织

规则编号沿用 [`../standards/model-description.md`](../standards/model-description.md) 第 10 节：

- `MD-001`…`MD-007`：根与接口；
- `MD-010`…`MD-020`：变量；
- `MD-030`…`MD-036`：数组与时钟；
- `MD-040`…`MD-049`：模型结构；
- `MD-050`…`MD-054`：单位与类型；
- `MD-060`…`MD-063`：安全。

每新增规则必须：

1. 分配稳定编号；
2. 写正例/反例；
3. 说明严重级别；
4. 在 CLI 输出中包含编号；
5. 更新标准文档中的规则表。

### 5.3 典型规则的设计细节

**MD-012 causality/variability/initial 组合**

不能只查枚举值，要按版本矩阵检查。例如：

- `causality="parameter"` 通常要求 `variability="fixed"` 或 `"tunable"`；
- `causality="input"` 不能是 `constant`；
- `initial` 的默认值依赖 `causality`/`variability`；
- FMI 3 的 `variability` 没有默认值，不能照搬 FMI 2。

实现为一个表驱动检查，错误信息包含实际组合和建议。

**MD-017 derivative**

- FMI 2 的 `derivative` 是变量索引（1-based），不是 `valueReference`；
- FMI 3 是 `valueReference`；
- 目标必须是连续状态；
- 类型必须兼容；
- 不能形成环（可选检查）。

**MD-031 数组维度**

- `Dimension` 的 `start` 与 `valueReference` 至少有一个；
- `valueReference` 必须指向 `structuralParameter`；
- 维度乘积不能溢出；
- 变量声明维度与类型维度要一致（FMI 3）。

**MD-040…MD-049 模型结构**

- 先建 `valueReference -> variable` 索引；
- 检查引用存在；
- 检查列表顺序/去重；
- 检查 `dependenciesKind` 长度；
- FMI 2 的 `Outputs` 必须覆盖所有 `causality="output"` 变量；
- FMI 3 的 `ContinuousStateDerivative` 只引用导数变量。

**MD-050 单位**

- 变量 `unit` 必须存在于 `UnitDefinitions`；
- `displayUnit` 必须存在且与 `unit` 兼容；
- 单位兼容性首版可用“同一 Unit 定义/可换算”判断，复杂换算后续再做；
- 缺失单位给 warning，不阻断仿真。

### 5.4 诊断对象

```moonbit
pub enum Severity { Error; Warning; Info }

pub struct Diagnostic {
  code : String            // "MD-031"
  severity : Severity
  message : String
  path : String            // "/fmiModelDescription/ModelVariables/ScalarVariable[3]"
  line : Int?
  column : Int?
  related : Array[RelatedLocation]
  hint : String?
}

pub struct ValidationReport {
  diagnostics : Array[Diagnostic]
  error_count : Int
  warning_count : Int
}
```

要求：

- 错误按文档顺序排序，稳定输出；
- 同一位置同一规则只报一次；
- `path` 使用可读的 XPath 风格，索引从 1 开始；
- 严重级别可配置（warning 可升级为 error）；
- CLI `--json` 输出机器可读格式。

### 5.5 默认策略

- 默认：error 失败，warning 不失败；
- `--strict`：warning 也失败；
- `--allow-warnings=MD-050,...`：显式豁免；
- 不提供“忽略所有错误”的开关；这会掩盖 FMU 问题。

---

## 6. XSD 在 CI 中的用法

MoonFMI 不实现 XSD 引擎。这一章描述的是 CI 里的一层可选对照检查：验证器可以是 `xmllint`、`lxml`，也可以是别的项目提供的命令行工具。P0 不依赖它开工；P1 再把它纳入固定流程。

### 6.1 双层校验

```text
fixture.fmu
  ├─ 提取 modelDescription.xml
  ├─ xmllint/lxml → XSD 结果
  └─ moonfmi validate → MoonFMI 结果
```

断言：

| 语料类型 | XSD | MoonFMI |
| --- | --- | --- |
| 合法 | 通过 | 通过 |
| XSD 非法 | 失败 | 失败（结构错误） |
| XSD 合法但语义非法 | 通过 | 失败（MD-xxx） |
| 恶意 | 失败/拒绝 | 失败（安全错误） |

### 6.2 命令

```bash
xmllint --noout \
  --schema docs/standards/schemas/fmi2/fmi2ModelDescription.xsd \
  tests/data/fmi2/minimal/modelDescription.xml
```

```bash
xmllint --noout \
  --schema docs/standards/schemas/fmi3/fmi3ModelDescription.xsd \
  tests/data/fmi3/minimal/modelDescription.xml
```

CI 还需要校验：

- `buildDescription.xml` → `fmi3BuildDescription.xsd`；
- `extra/<ls>/manifest.xml` → `fmi3LayeredStandardManifest.xsd`；
- `terminalsAndIcons.xml` → `fmi3TerminalsAndIcons.xsd`。

### 6.3 字段覆盖对比

写一个维护脚本（可用 Python）：

1. 解析 XSD，收集所有元素/属性；
2. 解析 MoonBit 类型化模型源码，收集字段；
3. 输出差异报告；
4. CI 中只报告，不自动改代码。

目的：升级 FMI 版本时发现遗漏字段，而不是等用户踩坑。

---

## 7. 测试策略

### 7.1 单元测试

- XML：BOM、UTF-8、非法字符、未闭合标签、重复属性、DTD、实体、深度/大小限制；
- 版本：`2.0`、`2.0.4`、`3.0`、`3.0.2`、`3.1`、空值；
- 结构：元素顺序错误、缺少必填、未知元素；
- 默认值：显式/隐式、`initial` 推导；
- 数值：`INF`、`NaN`、溢出、负数维度；
- 字符串：转义、Unicode、空字符串；
- 诊断：行列号、路径、排序、去重。

### 7.2 golden 测试

每个合法/非法 fixture 对应一份稳定的诊断快照：

```text
tests/data/fmi3/invalid-array-dimension/
  modelDescription.xml
  expected.json
```

用 `moon test --update` 更新快照前必须人工审查。

### 7.3 模糊测试

- 随机字节/随机 XML 变异，确保不 panic、不 OOM、不无限循环；
- 针对属性值/数字/嵌套深度做定向变异；
- 在 CI 外运行长时间 fuzz，CI 中跑固定种子回归。

### 7.4 真实语料

- Reference-FMUs；
- fmi-cross-check；
- FMPy/fmi-rs 测试 FMU；
- 自造边界/恶意 FMU。

对每个语料记录：来源、FMI 版本、接口、预期结果、XSD 结果。

---

## 8. 性能目标

参考目标（native，非硬性承诺）：

- 1 万变量模型描述解析 + 校验 < 100 ms；
- 内存峰值 < 输入大小的 10 倍；
- 不因变量数增加出现 O(n²) 行为。

实现要点：

- 单遍解析，索引构建 O(n)；
- 避免为每个变量复制大字符串；
- 重复名称/单位用字符串驻留（可选）；
- 不在错误路径之外构造诊断字符串；
- 大数组维度用 `UInt64` 计算并检查溢出。

---

## 9. 实现顺序

| 步骤 | 内容 | 验收 |
| --- | --- | --- |
| P1.1 | XML pull parser + 安全限制 | 单元测试 + fuzz 回归 |
| P1.2 | FMI 2 类型化解析 | 最小/完整 fixture 通过 |
| P1.3 | FMI 3 类型化解析 | 同上，含数组/Clock |
| P1.4 | 索引与语义规则 | MD-001…MD-063 覆盖 |
| P1.5 | `moonfmi validate` | 文本/JSON 输出、退出码 |
| P1.6 | CI 中的 XSD 独立对照检查 | 四类样品断言 |
| P1.7 | 字段覆盖脚本 | 版本升级检查 |

---

## 10. 待解决问题

1. MoonBit 标准库是否提供足够稳定的 UTF-8/字节处理；若不稳，是否引入小型依赖。
2. XML 解析器是否需要支持注释/CDATA/PI；FMI 语料中可能出现，需确认。
3. FMI 3 `anyAttribute` 的保留策略：丢弃还是原样保存供导出。
4. 单位兼容性检查的精度：首版只做引用存在性，还是做量纲换算。
5. 是否需要在解析阶段就拒绝未知元素，还是允许 `--lenient`。
6. 大模型的内存上限默认值。

---

## 11. 相关文档

- XSD 清单：[`../standards/xsd-inventory.md`](../standards/xsd-inventory.md)
- 模型描述字段：[`../standards/model-description.md`](../standards/model-description.md)
- 导入器：[`importer.md`](importer.md)
- 架构：[`architecture.md`](architecture.md)
- FMPy 校验实现：[`../research/fmpy.md`](../research/fmpy.md)
