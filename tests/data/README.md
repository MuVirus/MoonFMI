# 测试语料

本目录保存 P0 的测试语料清单、取件脚本和 XSD 对照样品。FMU 二进制和发布包**不进 git**，缓存到 `.cache/`（已忽略）。

---

## 1. 文件

| 文件 | 作用 |
| --- | --- |
| `manifest.json` | 8 个 Reference-FMUs 样品的来源、大小、SHA-256、接口、二进制路径 |
| `fetch-fmus.mjs` | 按清单下载、解压、缓存、校验；支持离线模式 |
| `model-description/` | 5 个 `modelDescription.xml` 样品 |
| `xsd-cases.json` | 每个 XML 样品的 XSD 预期结果 |
| `validate-xsd.ps1` | 可选的外部 XSD 对照工具（PowerShell + .NET） |

---

## 2. 取 FMU

```bash
node tests/data/fetch-fmus.mjs            # 缺什么取什么，然后全量校验
node tests/data/fetch-fmus.mjs --offline  # 绝不下载，只校验缓存
node tests/data/fetch-fmus.mjs --force    # 清空缓存后重新下载
node tests/data/fetch-fmus.mjs --list     # 打印样品 id / 版本 / 接口
```

缓存布局：

```text
tests/data/.cache/
  Reference-FMUs.zip     # 原始发布包，用于断网时重新解压
  fmi2/*.fmu
  fmi3/*.fmu
```

校验失败会给出 `size mismatch` 或 `sha256 mismatch`，并以非零退出码结束。

---

## 3. 样品来源

- 项目：<https://github.com/modelica/Reference-FMUs>
- 版本：`v0.0.42`
- 发布包 SHA-256：`b6b4a195b9c0f6bdd3459cd949cbb35fc21ee2049d6dab4cb7a3ba7da63b1e97`
- 许可证：BSD-2-Clause

FMI 2 与 FMI 3 的二进制目录不同：

| 标准 | Windows x64 | Linux x64 |
| --- | --- | --- |
| FMI 2 | `binaries/win64/<id>.dll` | `binaries/linux64/<id>.so` |
| FMI 3 | `binaries/x86_64-windows/<id>.dll` | `binaries/x86_64-linux/<id>.so` |

`manifest.json` 的 `binaries` 字段记录了每个样品的实际路径，第二周做 ZIP 测试时可直接使用。

---

## 4. XSD 对照

```bash
# Windows
powershell -NoProfile -ExecutionPolicy Bypass -File tests/data/validate-xsd.ps1

# Linux / CI
pwsh -NoProfile -File tests/data/validate-xsd.ps1

# 只跑一个 case
powershell -NoProfile -ExecutionPolicy Bypass -File tests/data/validate-xsd.ps1 -Case fmi2-valid
```

边界：

- 这是**外部对照**，不是 MoonBit 的 XSD 引擎；
- 实例文档禁止 DTD、禁止外部实体、禁止联网；
- 失败时本地检查脚本只警告，不阻塞 P0。

`xsd-cases.json` 中的 `fmi2-unknown-index` 故意期望 `pass`：XSD 只管语法，语义引用要由 P1 的语义校验器处理。

---

## 5. 相关文档

- 基础设施记录：[`../../docs/records/2026-10-30.md`](../../docs/records/2026-10-30.md)
- XSD 与校验边界：[`../../docs/design/xsd-and-validation.md`](../../docs/design/xsd-and-validation.md)
- 标准文件清单：[`../../docs/standards/schemas/README.md`](../../docs/standards/schemas/README.md)
