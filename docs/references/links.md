# 外部链接

> 访问日期：2026-10-29。优先固定版本/tag；标注“滚动”的链接可能变化。

---

## 1. FMI 标准

| 名称 | URL | 用途 | 备注 |
| --- | --- | --- | --- |
| FMI 官网 | <https://fmi-standard.org/> | 标准入口、新闻 | 滚动 |
| FMI 3.0.2 规范 | <https://fmi-standard.org/docs/3.0.2/> | FMI 3 正文 | 基线 |
| FMI 2.0.4 规范 | <https://github.com/modelica/fmi-standard/releases/tag/v2.0.4> | FMI 2 正文/发布包 | 基线；官网无独立 2.0.4 docs 页 |
| fmi-standard 仓库 | <https://github.com/modelica/fmi-standard> | 规范、XSD、头文件 | 滚动 |
| FMI 3.0.2 发布 | <https://github.com/modelica/fmi-standard/releases/tag/v3.0.2> | 固定版本 | 基线 |
| FMI 2.0.4 发布 | <https://github.com/modelica/fmi-standard/releases/tag/v2.0.4> | 固定版本 | 基线 |
| FMI 3 schema | <https://github.com/modelica/fmi-standard/tree/v3.0.2/schema> | XSD 来源 | 已随附 |
| FMI 2 schema | <https://github.com/modelica/fmi-standard/tree/v2.0.4/schema> | XSD 来源 | 已随附 |
| FMI 3 headers | <https://github.com/modelica/fmi-standard/tree/v3.0.2/headers> | C 头文件 | 已随附 |
| FMI 2 headers | <https://github.com/modelica/fmi-standard/tree/v2.0.4/headers> | C 头文件 | 已随附 |

> 本仓库随附的 XSD/头文件来源与 SHA-256 见 [`../standards/schemas/README.md`](../standards/schemas/README.md)、[`../standards/headers/README.md`](../standards/headers/README.md)。

---

## 2. 分层标准与扩展

| 名称 | URL | 用途 | 备注 |
| --- | --- | --- | --- |
| FMI-LS-WASM | <https://github.com/modelica/fmi-ls-wasm> | WASM component 映射 | 草案 |
| FMI-LS-WASM 规范 | <https://modelica.github.io/fmi-ls-wasm/main/> | WIT/world/manifest | 滚动草案 |
| FMI-LS-BUS | <https://github.com/modelica/fmi-ls-bus> | 总线仿真 | 参考 |
| SSP | <https://ssp-standard.org/> | 系统结构/SSD | 后续集成 |

---

## 3. 参考实现与工具

| 名称 | URL | 用途 | 备注 |
| --- | --- | --- | --- |
| FMPy | <https://github.com/CATIA-Systems/FMPy> | Python 导入/仿真/校验/构建 | 主要参考 |
| FMPy 文档 | <https://fmpy.readthedocs.io/> | API/用法 | 滚动 |
| fmi-rs | <https://github.com/jondo2010/rust-fmi> | Rust FMI 2/3 实现 | 主要参考 |
| `fmi` crate | <https://crates.io/crates/fmi> | 高层 API | 滚动 |
| `fmi-schema` crate | <https://crates.io/crates/fmi-schema> | 模型描述解析 | 滚动 |
| `fmi-export` crate | <https://crates.io/crates/fmi-export> | 导出器 | 滚动 |
| OMSimulator | <https://github.com/OpenModelica/OMSimulator> | 多 FMU 协同仿真 | 参考 |
| OpenModelica | <https://github.com/OpenModelica/OpenModelica> | Modelica 编译器/ME 参考 | 参考 |
| pythonfmu | <https://github.com/NTNU-IHB/PythonFMU> | Python FMU 导出 | 参考 |
| fmi4cpp | <https://github.com/NTNU-IHB/FMI4cpp> | C++ FMI 2 封装 | 参考 |
| Bodylight.js | <https://github.com/creative-connections/Bodylight.js> | 浏览器生理模型仿真 | Emscripten 路线 |

---

## 4. 测试语料

| 名称 | URL | 用途 | 备注 |
| --- | --- | --- | --- |
| Reference-FMUs | <https://github.com/modelica/Reference-FMUs> | 官方参考 FMU | 固定 commit |
| fmi-cross-check | <https://github.com/modelica/fmi-cross-check> | 跨工具结果 | 固定 commit |
| FMPy 测试 FMU | <https://github.com/CATIA-Systems/FMPy/tree/master/tests> | CS/ME 基础 | 随 FMPy |
| fmi-rs 测试数据 | <https://github.com/jondo2010/rust-fmi/tree/main/fmi-test-data> | Rust 生态语料 | 随仓库 |

> 下载后记录 commit、校验和、许可证；不要把大语料直接提交到仓库。

---

## 5. WebAssembly

| 名称 | URL | 用途 | 备注 |
| --- | --- | --- | --- |
| Component Model | <https://component-model.bytecodealliance.org/> | 组件模型概念 | 滚动 |
| WIT 设计 | <https://component-model.bytecodealliance.org/design/wit.html> | WIT 语法 | 滚动 |
| WASI Preview 2 | <https://github.com/WebAssembly/WASI/tree/wasi-0.2> | WASI p2 规范/接口 | 分支 wasi-0.2 |
| wasm-tools | <https://github.com/bytecodealliance/wasm-tools> | embed/new/validate | 固定版本 |
| wit-bindgen | <https://github.com/bytecodealliance/wit-bindgen> | 生成 guest/host 绑定 | 固定版本 |
| jco | <https://github.com/bytecodealliance/jco> | component → JS | 固定版本 |
| Wasmtime | <https://github.com/bytecodealliance/wasmtime> | native component 宿主 | 固定版本 |
| Wasmer | <https://github.com/wasmerio/wasmer> | 备选运行时 | 备选 |

---

## 6. MoonBit

| 名称 | URL | 用途 | 备注 |
| --- | --- | --- | --- |
| MoonBit 文档 | <https://docs.moonbitlang.com> | 语言/工具链 | 滚动 |
| Mooncakes | <https://mooncakes.io> | 包索引 | 滚动 |
| `tonyfettes/dl` | <https://github.com/moonbit-community/tonyfettes-dl> | 动态库加载 | 社区镜像；mooncakes 包名 `tonyfettes/dl` |
| MoonBit 仓库 | <https://github.com/moonbitlang> | 工具链/核心库 | 滚动 |

---

## 7. C ABI / 系统

| 名称 | URL | 用途 | 备注 |
| --- | --- | --- | --- |
| System V ABI | <https://refspecs.linuxfoundation.org/elf/x86_64-abi-0.99.pdf> | x86_64 Linux ABI | PDF |
| Microsoft x64 调用约定 | <https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention> | Windows x64 ABI | 滚动 |
| Microsoft DLL 搜索 | <https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-search-order> | 依赖/安全 | 滚动 |
| `dlopen` | <https://man7.org/linux/man-pages/man3/dlopen.3.html> | POSIX 动态加载 | man page |
| `LoadLibraryExW` | <https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-loadlibraryexw> | Windows 加载 | 滚动 |

---

## 8. XML / ZIP / 安全

| 名称 | URL | 用途 | 备注 |
| --- | --- | --- | --- |
| XML 1.0 | <https://www.w3.org/TR/xml/> | XML 语法 | 标准 |
| XML Schema 1.0 | <https://www.w3.org/TR/xmlschema-1/> | XSD 结构 | 标准 |
| libxml2 | <https://gitlab.gnome.org/GNOME/libxml2> | `xmllint`/XSD | CI 工具 |
| ZIP APPNOTE | <https://pkwaredownloads.blob.core.windows.net/pem/APPNOTE.txt> | ZIP 格式 | 6.3.10 |
| ZIP 规范（Common ZIP） | <https://commonzip.org/spec/> | ZIP 常见实现子集 | 补充参考 |
| OWASP XXE | <https://owasp.org/www-community/vulnerabilities/XML_External_Entity_(XXE)_Processing> | XXE 防护 | 参考 |
| OWASP Zip Slip | <https://owasp.org/www-community/attacks/Path_Traversal> | 路径穿越 | 参考 |

---

## 9. 链接检查

建议脚本：

```text
读取 links.md
  → 提取 http(s) URL
  → HEAD/GET（带超时、UA）
  → 记录状态码/重定向
  → 404/410 报警，其他网络错误仅警告
```

不要把链接检查放进阻塞 PR 的必过项；网络不稳定会造成假失败。

---

## 10. 相关文档

- 参考资料索引：[`README.md`](README.md)
- 术语表：[`glossary.md`](glossary.md)
- 标准资料：[`../standards/README.md`](../standards/README.md)
- 研究：[`../research/README.md`](../research/README.md)
