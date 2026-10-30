# FMI Schema 资料

本目录保存 FMI 官方的 `modelDescription.xml` 及相关 XML 的 XSD 文件，作为解析器实现、语义校验和 CI 测试的权威依据。

> **这些文件来自 FMI 官方仓库，保持原样，不修改。** 如需适配 MoonFMI，请在代码或单独文档中处理，不要改 XSD。

---

## 1. 来源

| 项目 | 值 |
| --- | --- |
| 仓库 | [`modelica/fmi-standard`](https://github.com/modelica/fmi-standard) |
| FMI 2 版本 | `v2.0.4` |
| FMI 3 版本 | `v3.0.2` |
| 目录 | `schemas/fmi2/`、`schemas/fmi3/` |
| 许可证 | 2-Clause BSD（见各文件头部版权声明） |

官方规范正文（PDF/HTML）不在此目录，链接见 [`../../references/links.md`](../../references/links.md)。

---

## 2. 目录结构

```text
schemas/
├── fmi2/
│   ├── fmi2ModelDescription.xsd      # 校验入口
│   ├── fmi2ScalarVariable.xsd
│   ├── fmi2VariableDependency.xsd
│   ├── fmi2Unit.xsd
│   ├── fmi2Type.xsd
│   ├── fmi2AttributeGroups.xsd
│   └── fmi2Annotation.xsd
└── fmi3/
    ├── fmi3ModelDescription.xsd      # 校验入口
    ├── fmi3Variable.xsd
    ├── fmi3VariableDependency.xsd
    ├── fmi3Unit.xsd
    ├── fmi3Type.xsd
    ├── fmi3InterfaceType.xsd
    ├── fmi3AttributeGroups.xsd
    ├── fmi3Annotation.xsd
    ├── fmi3BuildDescription.xsd      # buildDescription.xml 入口
    ├── fmi3LayeredStandardManifest.xsd # extra manifest 入口
    ├── fmi3TerminalsAndIcons.xsd     # terminalsAndIcons 入口
    └── fmi3Terminal.xsd
```

---

## 3. 文件校验和（SHA-256）

### 3.1 FMI 2.0.4

| 文件 | SHA-256 |
| --- | --- |
| `fmi2Annotation.xsd` | `2e77259d7668f8d290eaef9048aa8ff864d5d0c151e82d05f23062acedb1a8e8` |
| `fmi2AttributeGroups.xsd` | `5d56ee3c733f148e58edbebc3127ea9c1bdf1898a738360aba44d87146cc40ed` |
| `fmi2ModelDescription.xsd` | `0a0708810b0ff430ccc532f3945171a79f44b69fb78fb00badd7cb95e871eaf7` |
| `fmi2ScalarVariable.xsd` | `2669117d5f7cac9f092b65a00b321874db1356e4056486ab0a27655ea29757be` |
| `fmi2Type.xsd` | `0a4fdf92f05a78a7a1c3e7d4851e7d645f411503e1b185eee465d6c9891b4e8d` |
| `fmi2Unit.xsd` | `58853540243fe95fb4c5eb2e467b1013a6fa1757057a07d5324ea0d877b66083` |
| `fmi2VariableDependency.xsd` | `ce00358c11d0bc83763be6b6df1746b058f11d5714145f74ec97251d304a9e24` |

### 3.2 FMI 3.0.2

| 文件 | SHA-256 |
| --- | --- |
| `fmi3Annotation.xsd` | `1f8381f3bcff84ae424aba5bcd98f1bdaf552e98ad23de0d6e6f2540e970929f` |
| `fmi3AttributeGroups.xsd` | `83a8ed2b4e6f0ab94704aba7fff42a2147be4bb8daeb00d9dca829689a517b26` |
| `fmi3BuildDescription.xsd` | `1b87259e24ef15178172aa0005a53cb75e8e21e3095593735bdab5432b3c73d9` |
| `fmi3InterfaceType.xsd` | `d8a91569d10110ad4bd9a6ad4371ce8e19765c8bfb57ab56713f569afa58c88e` |
| `fmi3LayeredStandardManifest.xsd` | `0e14a2f9e54a166754bfab47b2359ff066047dbca687140a6c66de25832d18bb` |
| `fmi3ModelDescription.xsd` | `d16d363ce0b20e2ab0b30c7d493f7b2576bb64ba57b6e340877efe33181696e4` |
| `fmi3Terminal.xsd` | `baad78c0e32c7aeed1e66f21e41b26968d10a0c102a580b27d3d5c114b4f6bf9` |
| `fmi3TerminalsAndIcons.xsd` | `fa41635468c5859eb36ff6e702842c2642e155267bc3597f16874aac5ce6ad0e` |
| `fmi3Type.xsd` | `4da1d1a1404816d99d13004a06920e13f4ed7d047dd43d33563803ecb1e7d823` |
| `fmi3Unit.xsd` | `08afc5dade4b7f243a792349f2ca1314c54af4353cbc3d9688c8b6310be30748` |
| `fmi3Variable.xsd` | `dd853edead7e73e9da9b3eec31ee5cc6798e54e26c45299f591d363cabf7c5a5` |
| `fmi3VariableDependency.xsd` | `610481c17b7822c0e5c9e818f1b5fea901c649f1394e2a533dfa36836caaab57` |

校验方法：

```powershell
Get-ChildItem -Recurse docs\standards\schemas -File |
  ForEach-Object { Get-FileHash $_.FullName -Algorithm SHA256 }
```

```bash
find docs/standards/schemas -type f -name '*.xsd' -exec sha256sum {} +
```

---

## 4. 使用方式

### 4.1 校验 `modelDescription.xml`

FMI 2：

```bash
xmllint --noout \
  --schema docs/standards/schemas/fmi2/fmi2ModelDescription.xsd \
  modelDescription.xml
```

FMI 3：

```bash
xmllint --noout \
  --schema docs/standards/schemas/fmi3/fmi3ModelDescription.xsd \
  modelDescription.xml
```

### 4.2 校验其他 XML

| 文件 | XSD |
| --- | --- |
| `buildDescription.xml` | `fmi3BuildDescription.xsd` |
| `extra/<ls>/manifest.xml` | `fmi3LayeredStandardManifest.xsd` |
| `terminalsAndIcons/terminalsAndIcons.xml` | `fmi3TerminalsAndIcons.xsd` |

### 4.3 在代码中使用

MoonFMI 运行时**不**直接依赖这些 XSD。它们用于：

- 实现时对照字段与顺序；
- CI 中独立校验测试语料；
- 代码审查时确认字段名/枚举值；
- 生成字段覆盖检查脚本。

详见 [`../xsd-inventory.md`](../xsd-inventory.md) 与 [`../../design/xsd-and-validation.md`](../../design/xsd-and-validation.md)。

---

## 5. 维护规则

1. **不修改**官方 XSD。
2. 升级版本时，整目录替换，并更新本文件的版本、文件清单和 SHA-256。
3. 如果只替换部分文件，必须确认 `xs:include` 的相对路径仍然有效。
4. 新增/删除文件时，同步更新 [`../xsd-inventory.md`](../xsd-inventory.md) 的依赖图。
5. 如果发现 XSD 与规范正文不一致，记录在 [`../model-description.md`](../model-description.md)，不要改 XSD。

---

## 6. 许可证

这些 XSD 文件由 Modelica Association Project "FMI" 以 2-Clause BSD 许可证发布。每个文件头部包含完整版权与许可声明。再分发时请保留这些声明。

- 许可证全文：<https://opensource.org/licenses/BSD-2-Clause>
- 官方仓库：<https://github.com/modelica/fmi-standard>
