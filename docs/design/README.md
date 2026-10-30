# 设计

本目录是 MoonFMI 的工程设计方案。所有文档都是**提案**，实现时应根据 POC 结果调整；任何偏离都应在对应文档中记录理由。

---

## 1. 设计原则

1. **标准优先**：以 FMI 2.0.4 / 3.0.2 官方头文件、XSD 和规范正文为准，不以某个工具的 bug 为准。
2. **分层清晰**：解析、校验、后端、主算法、导出、CLI 分包；核心包不依赖平台。
3. **native 优先**：首个可用版本是 native CS 导入；WASM 是独立后端，不污染核心。
4. **显式错误**：不吞错、不静默回退；错误带分类、上下文、原始 FMI 状态码。
5. **可测试**：每个包都能单独测试；真实 FMU 语料 + 自造边界语料。
6. **安全默认**：解压/XML 解析默认防路径穿越、XXE、压缩炸弹。
7. **可演进**：FMI 2/3 版本分派；分层标准（WASM/BUS）作为可选扩展。
8. **不追求“大一统”抽象**：允许版本专用 API，门面层只做便利封装。

---

## 2. 文档索引

| 文件 | 内容 |
| --- | --- |
| [`architecture.md`](architecture.md) | 总体架构、包布局、依赖规则、公共 API |
| [`importer.md`](importer.md) | FMU 加载、平台选择、符号绑定、实例生命周期 |
| [`master-algorithm.md`](master-algorithm.md) | CS/ME/SE 主算法、事件、输入输出、结果 |
| [`exporter.md`](exporter.md) | 源码 FMU / native FMU / WASM FMU 导出 |
| [`wasm-strategy.md`](wasm-strategy.md) | LS-WASM、component 化、浏览器/宿主 |
| [`xsd-and-validation.md`](xsd-and-validation.md) | 解析器、语义校验、诊断、CI |
| [`ffi-and-abi.md`](ffi-and-abi.md) | C ABI 映射、C shim、回调、内存 |
| [`packaging.md`](packaging.md) | FMU 打包、路径规则、可复现构建 |
| [`cli-and-testing.md`](cli-and-testing.md) | CLI、测试金字塔、CI、交叉检查 |

---

## 3. 关键决策摘要

| 决策 | 选择 | 理由 | 替代方案 |
| --- | --- | --- | --- |
| 标准版本 | FMI 2.0.4 + 3.0.2 | 存量 + 新特性 | 只做 2.0；只做 3.0 |
| 首个接口 | CS | 主算法简单、覆盖广 | ME |
| 首个后端 | native | 生态成熟、语料多 | wasm |
| 解析方式 | 手写类型化解析 + 语义校验 | MoonBit 无 XSD 校验器；错误信息可控 | 运行时 XSD |
| XSD 用途 | CI 独立对照检查 + 字段参考 | 用来分清样品问题和解析器问题 | 运行时代码生成 |
| 后端抽象 | trait + 版本分派 | 隔离平台 | 单一万能 API |
| 字符串 | UTF-8 边界层 | FMI 用 UTF-8，MoonBit 用 UTF-16 | 直接映射 |
| 布尔 | 按版本分别处理 | FMI 2 `int` vs FMI 3 `bool` | 共用 `Bool` |
| 结构体 | C shim | 布局/对齐风险 | MoonBit 直接映射 |
| 导出顺序 | 源码 → WASM → native | MoonBit 不能直接导出动态库 | 先 native |
| WASM 标准 | FMI-LS-WASM | 唯一标准 component 路径 | 自定义 ABI |

---

## 4. 里程碑与设计的关系

| 里程碑 | 用到的设计 |
| --- | --- |
| P1 解析/校验 | [`xsd-and-validation.md`](xsd-and-validation.md)、[`architecture.md`](architecture.md) |
| P2 native CS 导入 | [`importer.md`](importer.md)、[`ffi-and-abi.md`](ffi-and-abi.md)、[`master-algorithm.md`](master-algorithm.md) |
| P3 FMI 2 ME | [`master-algorithm.md`](master-algorithm.md) |
| P4 FMI 3 | [`importer.md`](importer.md)、[`master-algorithm.md`](master-algorithm.md) |
| P5 CLI | [`cli-and-testing.md`](cli-and-testing.md) |
| P6 源码导出 | [`exporter.md`](exporter.md)、[`packaging.md`](packaging.md) |
| P7 WASM | [`wasm-strategy.md`](wasm-strategy.md)、[`packaging.md`](packaging.md) |
| P8 硬化 | [`cli-and-testing.md`](cli-and-testing.md) |

---

## 5. 设计评审清单

每个设计变更至少回答：

1. 是否符合 FMI 2.0.4 / 3.0.2？
2. 是否影响 native / wasm 两个后端？
3. 是否有对应测试语料？
4. 错误信息是否可定位到变量/字段/规则？
5. 是否引入新的平台依赖？是否隔离在 backend？
6. 是否影响公开 API？`.mbti` 是否变化？
7. 是否有性能/内存风险？
8. 是否有安全风险（解压/XML/动态库）？
9. 是否记录了替代方案？
10. 是否更新了文档和路线图？
