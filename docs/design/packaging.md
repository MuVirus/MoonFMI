# 打包设计

> 状态：设计提案。打包是“把已验证的目录变成可移植的 ZIP”，不是简单的 `zip -r`。

---

## 1. 目标

- 生成符合 FMI 2.0.4 / 3.0.2 的 FMU 归档；
- 同一输入在不同平台上生成**逐字节一致**的 ZIP（可复现）；
- 打包前/后都能验证；
- 明确 native / WASM / 源码 FMU 的布局差异；
- 不把临时文件、绝对路径、构建垃圾带进 FMU。

---

## 2. FMU 布局

### 2.1 通用

```text
Model.fmu
├─ modelDescription.xml          必需，根目录
├─ binaries/                     可选（源码 FMU 可无）
│  └─ <platform>/
│     └─ <modelIdentifier>.<ext>
├─ resources/                    可选
├─ sources/                      可选
├─ documentation/                可选
│  └─ index.html
├─ licenses/                     推荐
│  └─ LICENSE
├─ terminalsAndIcons/            FMI 3 可选
│  └─ terminalsAndIcons.xml
└─ extra/                        可选/分层标准
   └─ org.modelica.fmi-ls-wasm/
      └─ manifest.xml
```

### 2.2 FMI 2

- `modelDescription.xml` 根目录；
- `binaries/win32|win64|linux32|linux64|darwin32|darwin64/`；
- 动态库扩展名 `.dll` / `.so` / `.dylib`；
- 源码 FMU 可只有 `sources/`；
- 没有标准 `buildDescription.xml`，用 `CMakeLists.txt`/`README` 说明构建。

### 2.3 FMI 3

- 平台目录使用 `x86_64-windows` 等标识；
- 可含 `buildDescription.xml`；
- 可含 `terminalsAndIcons/`；
- 分层标准（如 LS-WASM）放在 `extra/<reverse-dns>/`；
- `binaries/wasm32-wasip2/<modelIdentifier>.wasm` 用于 LS-WASM。

### 2.4 平台目录与扩展名

| 平台 | 目录 | 扩展名 |
| --- | --- | --- |
| Windows x64 | `x86_64-windows`（FMI 3）/ `win64`（FMI 2） | `.dll` |
| Windows x86 | `x86-windows` / `win32` | `.dll` |
| Linux x64 | `x86_64-linux` / `linux64` | `.so` |
| Linux x86 | `x86-linux` / `linux32` | `.so` |
| Linux arm64 | `aarch64-linux` | `.so` |
| macOS x64 | `x86_64-darwin` / `darwin64` | `.dylib` |
| macOS arm64 | `aarch64-darwin` | `.dylib` |
| WASM component | `wasm32-wasip2` | `.wasm` |

文件名必须严格等于 `<modelIdentifier>`，大小写敏感（即使宿主文件系统不敏感）。

---

## 3. 各目录规则

### 3.1 `binaries/`

- 每个平台一个子目录；
- 只放运行所需二进制，不放 PDB/调试符号（可放 `documentation/` 或单独分发）；
- 不混入其他平台的依赖库；
- Windows 同目录依赖 DLL 可以放一起，但必须记录；
- Linux/macOS 的依赖库要明确 `RPATH`/`install_name`，避免指向构建机绝对路径；
- 二进制必须与 `modelIdentifier` 匹配。

### 3.2 `resources/`

- FMU 运行时可读的数据；
- 通过 `resourcePath`（FMI 3，原生路径）/ `fmuResourceLocation`（FMI 2，URI）访问；
- 路径必须相对，不能指向 FMU 外部；
- 打包时保留目录结构；
- 大资源考虑压缩率，但不要改变运行时访问语义。

### 3.3 `sources/`

- 源码 FMU 的 C/C++ 源码、头文件、构建脚本；
- 不包含构建产物（`.o`、`.obj`、`.dll`）；
- 包含 `CMakeLists.txt`、`README`、许可证；
- FMI 3 额外提供 `buildDescription.xml`。

### 3.4 `documentation/`

- `index.html` 为入口；
- 可放图片、PDF、许可证；
- 不引用本地绝对路径；
- 不作为运行时依赖。

### 3.5 `extra/`

- 分层标准/厂商扩展；
- 目录名使用反向域名，避免冲突；
- LS-WASM 使用 `extra/org.modelica.fmi-ls-wasm/manifest.xml`；
- 扩展内容不能破坏核心 FMI 语义；导入器可忽略未知扩展。

### 3.6 `terminalsAndIcons/`

FMI 3 可选，入口 `terminalsAndIcons.xml`，用 `fmi3TerminalsAndIcons.xsd` 校验。打包器只复制，不生成业务内容。

---

## 4. ZIP 规范

### 4.1 必须

- 标准 ZIP（deflate 或 store）；
- 不加密；
- 文件名使用 `/`，UTF-8；
- `modelDescription.xml` 在根目录；
- 不包含绝对路径、盘符、`..`；
- 不包含符号链接/硬链接；
- CRC 正确；
- 目录条目可选，但不要依赖空目录。

### 4.2 建议

- 使用 deflate，压缩级别固定（例如 6），平衡大小与速度；
- 不把已压缩格式（PNG/MP4）再压缩；
- 单文件/总大小限制；
- 支持 ZIP64（大 FMU），但读取端要能处理；
- 不写 ZIP 注释、扩展时间戳、OS 特定权限，除非有明确需要。

### 4.3 可复现

要达到逐字节一致：

1. 条目按固定规则排序（建议：`modelDescription.xml` 第一，其余字典序）；
2. 时间戳固定（例如 `1980-01-01 00:00:00`）或由源文件 mtime 映射；
3. 权限固定（例如 `0644` 文件、`0755` 目录）；
4. 不写创建者主机名/用户名；
5. 压缩实现与级别固定；
6. 换行统一 `\n`；
7. 不把绝对构建路径写入生成文件/调试信息。

记录：ZIP 工具版本、压缩级别、排序规则。

---

## 5. 打包流程

```text
输入目录 / 生成器输出
  → 预检查（必需文件、路径、平台、文件名）
  → 生成/校验 modelDescription.xml
  → 生成 buildDescription/manifest（如需要）
  → 收集文件（白名单）
  → 计算清单/校验和
  → 写 ZIP（确定性）
  → 后检查（重新打开、条目校验、XSD、冒烟加载）
  → 输出 .fmu + 报告
```

### 5.1 白名单

只打包：

- `modelDescription.xml`；
- `binaries/` 下选定平台；
- `resources/`；
- `sources/`（源码 FMU）；
- `documentation/`；
- `licenses/`；
- `terminalsAndIcons/`；
- `extra/`（明确允许的扩展）。

默认排除：

- `.git/`、`.github/`；
- 构建目录、临时文件；
- `.pdb`、`.ilk`、`.o`、`.obj`；
- 本机绝对路径文件；
- 测试夹具（除非明确需要）。

### 5.2 清单

生成 `manifest.json`（不放进 FMU 根目录，除非作为扩展）记录：

- 文件路径、大小、SHA-256；
- 平台；
- FMI 版本；
- 工具版本；
- 打包时间（可复现构建时固定/省略）。

清单可用于供应链校验；不要把它伪装成 FMI 标准文件。

---

## 6. 验证

### 6.1 打包前

- `modelDescription.xml` 存在且可解析；
- XSD 校验（CI）；
- 语义校验（MD-xxx）；
- 每个声明的接口有对应二进制/源码；
- 平台目录与二进制扩展名匹配；
- 文件名等于 `modelIdentifier`；
- 没有路径穿越/绝对路径/符号链接；
- 资源路径存在。

### 6.2 打包后

- 重新打开 ZIP，验证条目；
- 解压到临时目录，检查布局；
- 再次解析/校验 `modelDescription.xml`；
- 若为 native，尝试加载并实例化（冒烟）；
- 若为 WASM，`wasm-tools validate` + manifest XSD；
- 比较打包前后文件哈希。

### 6.3 失败处理

- 任何 error 都不生成“半成品 FMU”；
- 生成 `.partial` 临时文件，成功后原子重命名；
- 失败时保留诊断报告，删除临时归档。

---

## 7. 源码 FMU 的构建描述（FMI 3）

`buildDescription.xml` 用 `fmi3BuildDescription.xsd` 校验，至少包含：

```xml
<fmiBuildDescription fmiVersion="3.0">
  <BuildConfiguration modelIdentifier="MyModel" platform="x86_64-windows">
    <SourceFileSet language="C" compiler="msvc">
      <SourceFile name="sources/MyModel.c"/>
      <SourceFile name="sources/fmi3Functions.c"/>
      <IncludeDirectory name="sources"/>
    </SourceFileSet>
    <Library name="m"/>
  </BuildConfiguration>
</fmiBuildDescription>
```

要求：

- `modelIdentifier` 与模型描述一致；
- `platform` 与目标平台一致；
- 源文件路径相对 FMU 根目录；
- 不写构建机绝对路径；
- `Library` 只列真实依赖。

FMI 2 没有该文件，用 `CMakeLists.txt` + `README.md` 说明。

---

## 8. 签名与供应链

FMI 标准不规定签名。建议：

- 在 FMU 外部提供 detached signature（如 `.fmu.sig`）；
- 在 `extra/` 放 SBOM/来源信息，但不要影响核心解析；
- 记录构建工具版本、依赖版本、源码 commit；
- 导入器可选校验签名/哈希，但默认不强制（生态未统一）。

---

## 9. 打包 API

```moonbit
pub struct PackageOptions {
  output_path : String
  platform : String?
  include_sources : Bool
  include_documentation : Bool
  deterministic : Bool
  compression_level : Int
  license_file : String?
}

pub fn package_fmu(dir : String, options : PackageOptions) -> PackageResult raise FmiError
```

`PackageResult`：

- `.fmu` 路径；
- 条目清单；
- 大小/压缩率；
- 校验和；
- 验证诊断。

---

## 10. 测试

### 10.1 单元

- 路径穿越/绝对路径/符号链接；
- 大小写冲突；
- 文件名与 `modelIdentifier` 不一致；
- 平台目录缺失；
- 错误的扩展名；
- ZIP 时间戳/顺序/权限；
- 同一输入两次打包哈希一致；
- 空目录/空文件；
- Unicode 文件名。

### 10.2 集成

- FMI 2 CS 最小 FMU；
- FMI 2 ME 最小 FMU；
- FMI 3 CS/ME，含数组/Clock；
- 源码 FMU + 外部 CMake 构建；
- LS-WASM FMU + manifest；
- 用 FMPy 打开打包结果；
- 用 MoonFMI 自己回读。

### 10.3 负例

- 加密 ZIP；
- ZIP 炸弹；
- 损坏 CRC；
- 重复条目；
- 根目录缺少 `modelDescription.xml`；
- `modelIdentifier` 含 `../`；
- manifest 缺失/不合法。

---

## 11. 相关文档

- 导出器：[`exporter.md`](exporter.md)
- WASM：[`wasm-strategy.md`](wasm-strategy.md)
- 校验：[`xsd-and-validation.md`](xsd-and-validation.md)
- XSD 清单：[`../standards/xsd-inventory.md`](../standards/xsd-inventory.md)
- 模型描述：[`../standards/model-description.md`](../standards/model-description.md)
