# XSD 清单与校验策略

本页列出随附的 FMI 2.0.4 / 3.0.2 XSD，说明它们的依赖关系、覆盖范围，以及 MoonFMI 应如何把 XSD 用在 CI 中而不是运行时。

---

## 1. 文件清单

### 1.1 FMI 2.0.4（7 个）

| 文件 | 作用 | 被谁 include |
| --- | --- | --- |
| [`fmi2ModelDescription.xsd`](schemas/fmi2/fmi2ModelDescription.xsd) | 根模式，定义 `fmiModelDescription` | —（校验入口） |
| [`fmi2ScalarVariable.xsd`](schemas/fmi2/fmi2ScalarVariable.xsd) | `ScalarVariable` 及 Real/Integer/Boolean/String/Enumeration | ModelDescription |
| [`fmi2VariableDependency.xsd`](schemas/fmi2/fmi2VariableDependency.xsd) | `Unknown`、依赖列表 | ModelDescription |
| [`fmi2Unit.xsd`](schemas/fmi2/fmi2Unit.xsd) | `Unit`、`BaseUnit`、`DisplayUnit` | ModelDescription |
| [`fmi2Type.xsd`](schemas/fmi2/fmi2Type.xsd) | `SimpleType` 类型定义 | ModelDescription |
| [`fmi2AttributeGroups.xsd`](schemas/fmi2/fmi2AttributeGroups.xsd) | Real/Integer 属性组 | ScalarVariable、Type |
| [`fmi2Annotation.xsd`](schemas/fmi2/fmi2Annotation.xsd) | 厂商注解 | ScalarVariable |

**依赖图：**

```text
fmi2ModelDescription.xsd
├── fmi2ScalarVariable.xsd
│   ├── fmi2Annotation.xsd
│   └── fmi2AttributeGroups.xsd
├── fmi2VariableDependency.xsd
├── fmi2Unit.xsd
└── fmi2Type.xsd
    └── fmi2AttributeGroups.xsd
```

### 1.2 FMI 3.0.2（12 个）

| 文件 | 作用 | 被谁 include |
| --- | --- | --- |
| [`fmi3ModelDescription.xsd`](schemas/fmi3/fmi3ModelDescription.xsd) | 根模式，定义 `fmiModelDescription` | —（校验入口） |
| [`fmi3Variable.xsd`](schemas/fmi3/fmi3Variable.xsd) | 15 种变量类型、数组、别名 | ModelDescription |
| [`fmi3VariableDependency.xsd`](schemas/fmi3/fmi3VariableDependency.xsd) | `fmi3Unknown`、依赖 | ModelDescription |
| [`fmi3Unit.xsd`](schemas/fmi3/fmi3Unit.xsd) | 单位与显示单位 | ModelDescription |
| [`fmi3Type.xsd`](schemas/fmi3/fmi3Type.xsd) | 类型定义（Float64Type 等） | ModelDescription |
| [`fmi3InterfaceType.xsd`](schemas/fmi3/fmi3InterfaceType.xsd) | ME/CS/SE 能力属性 | ModelDescription |
| [`fmi3AttributeGroups.xsd`](schemas/fmi3/fmi3AttributeGroups.xsd) | Real/Integer/Clock 属性组 | Variable、Type |
| [`fmi3Annotation.xsd`](schemas/fmi3/fmi3Annotation.xsd) | 注解 | 多个 |
| [`fmi3BuildDescription.xsd`](schemas/fmi3/fmi3BuildDescription.xsd) | `buildDescription.xml` | —（独立入口） |
| [`fmi3LayeredStandardManifest.xsd`](schemas/fmi3/fmi3LayeredStandardManifest.xsd) | `extra/<ls>/manifest.xml` | —（独立入口） |
| [`fmi3TerminalsAndIcons.xsd`](schemas/fmi3/fmi3TerminalsAndIcons.xsd) | `terminalsAndIcons` | —（独立入口） |
| [`fmi3Terminal.xsd`](schemas/fmi3/fmi3Terminal.xsd) | 终端定义 | TerminalsAndIcons |

**依赖图：**

```text
fmi3ModelDescription.xsd
├── fmi3VariableDependency.xsd → fmi3Annotation.xsd
├── fmi3Unit.xsd               → fmi3Annotation.xsd
├── fmi3Variable.xsd           → fmi3Annotation.xsd, fmi3AttributeGroups.xsd
├── fmi3Type.xsd               → fmi3Annotation.xsd, fmi3AttributeGroups.xsd
├── fmi3Annotation.xsd
└── fmi3InterfaceType.xsd      → fmi3Annotation.xsd

fmi3BuildDescription.xsd       → fmi3Annotation.xsd
fmi3TerminalsAndIcons.xsd      → fmi3Terminal.xsd, fmi3Annotation.xsd
fmi3Terminal.xsd               → fmi3Annotation.xsd
fmi3LayeredStandardManifest.xsd（无 include）
```

---

## 2. 各文件覆盖的内容

### 2.1 FMI 2

| 文件 | 覆盖 |
| --- | --- |
| `fmi2ModelDescription` | 根属性、ME/CS 接口、单位、类型、日志、默认实验、厂商注解、变量、模型结构 |
| `fmi2ScalarVariable` | `ScalarVariable` 的 5 种类型、`causality`/`variability`/`initial`、类型专属属性 |
| `fmi2VariableDependency` | `Outputs`/`Derivatives`/`InitialUnknowns` 中的 `Unknown`，依赖列表 |
| `fmi2Unit` | `Unit`、`BaseUnit` 的 8 个基本量纲、`DisplayUnit` |
| `fmi2Type` | `SimpleType`（Real/Integer/Boolean/String/Enumeration） |
| `fmi2AttributeGroups` | Real/Integer 的 quantity/unit/min/max/nominal 等 |
| `fmi2Annotation` | `Annotations` / `VendorAnnotations` 的宽松结构 |

### 2.2 FMI 3

| 文件 | 覆盖 |
| --- | --- |
| `fmi3ModelDescription` | 根属性、ME/CS/SE、单位、类型、日志、默认实验、变量、模型结构、注解 |
| `fmi3Variable` | Float32/64、Int8..UInt64、Boolean、String、Binary、Enumeration、Clock；Dimension；Alias |
| `fmi3VariableDependency` | `fmi3Unknown`（valueReference、dependencies、dependenciesKind） |
| `fmi3Unit` | 单位、BaseUnit、DisplayUnit（含 inverse） |
| `fmi3Type` | 15 种类型定义、EnumerationType 的 Item、ClockType |
| `fmi3InterfaceType` | 抽象接口类型、ME/CS/SE 能力 |
| `fmi3AttributeGroups` | Real/Integer/Clock 属性组 |
| `fmi3Annotation` | 注解 |
| `fmi3BuildDescription` | 源码 FMU 的构建配置、源文件集、编译器/库/平台 |
| `fmi3LayeredStandardManifest` | 分层标准的 manifest |
| `fmi3TerminalsAndIcons` | 终端与图标 |
| `fmi3Terminal` | 单个终端定义 |

---

## 3. XSD 不能表达的内容

XSD 能保证：

- 元素名、顺序、出现次数；
- 属性名、类型、枚举值、默认值；
- 必填/可选；
- 部分数值范围（如 `xs:unsignedInt`）。

XSD **不能**保证：

- `causality` / `variability` / `initial` 的跨字段组合；
- `ModelStructure` 引用是否指向正确的变量；
- `derivative` 是否指向合法的状态；
- `declaredType` 是否存在、类型是否匹配；
- 数组维度是否与结构参数一致；
- Clock 的 interval 语义；
- `modelIdentifier` 是否安全、二进制是否存在；
- 单位是否与变量类型兼容；
- 依赖列表是否升序、是否与 `dependenciesKind` 等长；
- 变量名/类型名是否唯一；
- XML 外部实体、大小、深度等安全问题。

这些必须由语义校验器实现，规则清单见 [`model-description.md`](model-description.md) 第 10 节。

---

## 4. 推荐校验策略

### 4.1 运行时：类型化解析 + 语义校验

```text
XML bytes
  → 安全 XML 解析（禁 DTD/外部实体，限制大小/深度）
  → 原始 AST（保留行列号）
  → 版本分派（2 / 3）
  → 类型化 ModelDescription
  → 语义校验（MD-xxx 规则）
  → 诊断列表（error/warning/info）
```

不在运行时调用 XSD 校验器，原因：

1. MoonBit 没有成熟的通用 XSD 1.0/1.1 校验器。
2. XSD 校验的错误信息对用户不友好，难以定位到具体变量/字段。
3. XSD 无法覆盖大量语义规则，最终仍要写语义校验。
4. 运行时携带一整套 XSD 会增加包体和加载开销。

### 4.2 CI：XSD 作为独立的对照检查

在 CI 中对测试样品做两层检查：

1. **XSD 校验**：确认测试 FMU 的 `modelDescription.xml` 本身符合官方 XSD。
2. **MoonFMI 校验**：确认 MoonFMI 的解析器和语义校验器给出预期结果。

这样可以把“测试样品本身不合法”和“MoonFMI 解析错误”区分开。

#### 使用 `xmllint`

```bash
xmllint --noout \
  --schema docs/standards/schemas/fmi2/fmi2ModelDescription.xsd \
  path/to/modelDescription.xml
```

FMI 3：

```bash
xmllint --noout \
  --schema docs/standards/schemas/fmi3/fmi3ModelDescription.xsd \
  path/to/modelDescription.xml
```

#### 使用 Python `lxml`

```python
from lxml import etree

schema = etree.XMLSchema(etree.parse("docs/standards/schemas/fmi3/fmi3ModelDescription.xsd"))
doc = etree.parse("path/to/modelDescription.xml")
if not schema.validate(doc):
    for error in schema.error_log:
        print(error.line, error.message)
```

`lxml` 会自动处理 `xs:include` 的相对路径。若从其他目录运行，建议先 `cd` 到 XSD 所在目录，或使用自定义 resolver。

#### 使用 .NET（Windows CI）

```powershell
$schemas = [System.Xml.Schema.XmlSchemaSet]::new()
$schemas.Add($null, "docs/standards/schemas/fmi3/fmi3ModelDescription.xsd") | Out-Null
$reader = [System.Xml.XmlReader]::Create("path/to/modelDescription.xml")
$settings = [System.Xml.XmlReaderSettings]::new()
$settings.ValidationType = [System.Xml.ValidationType]::Schema
$settings.Schemas = $schemas
$settings.ValidationEventHandler += { param($s, $e) Write-Host $e.Message }
while ($reader.Read()) {}
```

### 4.3 其他文件的校验入口

| 文件 | XSD 入口 |
| --- | --- |
| `modelDescription.xml`（FMI 2） | `fmi2ModelDescription.xsd` |
| `modelDescription.xml`（FMI 3） | `fmi3ModelDescription.xsd` |
| `buildDescription.xml` | `fmi3BuildDescription.xsd` |
| `extra/<ls>/manifest.xml` | `fmi3LayeredStandardManifest.xsd` |
| `terminalsAndIcons/terminalsAndIcons.xml` | `fmi3TerminalsAndIcons.xsd` |

---

## 5. 代码生成？不建议

理论上可以从 XSD 生成 MoonBit 类型，但不建议作为主路径：

| 方案 | 优点 | 缺点 |
| --- | --- | --- |
| 手写类型化模型 | 可控、错误信息好、可表达语义 | 工作量大 |
| 从 XSD 生成 | 字段覆盖全、升级快 | 生成代码可读性差、难以加入语义校验、MoonBit 生态缺少成熟 XSD 代码生成器 |
| 混合：生成骨架 + 手写语义 | 兼顾覆盖与质量 | 工具链复杂 |

建议：

- 用 XSD 作为**字段清单和审查依据**，手写类型化模型。
- 用脚本对比 XSD 与手写模型的字段覆盖，发现遗漏。
- 如果未来字段量继续增长，再考虑生成“原始 AST → 类型化模型”的映射骨架。

---

## 6. 测试语料

XSD 校验应覆盖以下语料：

| 语料 | 用途 |
| --- | --- |
| `modelica/Reference-FMUs` | 官方参考 FMU，覆盖 ME/CS/SE、FMI 2/3 |
| `modelica/fmi-cross-check` | 大量工具生成的 FMU，覆盖真实世界差异 |
| FMPy 测试 FMU | CS/ME 基础场景 |
| fmi-rs `fmi-test-data` | Rust 生态的测试 FMU |
| 自造最小 FMU | 边界条件、非法字段、极端值 |

测试分层：

1. **合法语料**：XSD 通过，MoonFMI 也应通过。
2. **XSD 非法语料**：XSD 失败，MoonFMI 应给出对应错误。
3. **XSD 合法但语义非法**：XSD 通过，MoonFMI 语义校验应失败。
4. **模糊/恶意语料**：XXE、超大文件、深嵌套、路径穿越。

---

## 7. 维护

- XSD 文件来自官方仓库，保持原样；不要为了“让测试通过”修改 XSD。
- 升级版本时，先替换文件、更新校验和，再跑语料，最后更新语义规则。
- 如果发现 XSD 与规范正文冲突，以规范正文为准，并在 [`model-description.md`](model-description.md) 中记录差异。
- 如果发现某工具生成的 FMU 不符合 XSD，先确认是否为工具 bug；不要默认放宽解析器。

---

## 8. 参考

- 文件来源与校验和：[`schemas/README.md`](schemas/README.md)
- 头文件清单：[`headers/README.md`](headers/README.md)
- 语义规则：[`model-description.md`](model-description.md)
- 校验器设计：[`../design/xsd-and-validation.md`](../design/xsd-and-validation.md)
- FMPy 的校验实现：[`../research/fmpy.md`](../research/fmpy.md)
