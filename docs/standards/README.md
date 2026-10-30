# 标准资料

本目录把 FMI 标准中与实现直接相关的部分整理成可检索的中文文档，并随附官方 XSD 与 C 头文件，供实现、测试和代码审查使用。

## 1. 文件说明

| 文件 | 内容 | 主要用途 |
| --- | --- | --- |
| [`fmi-overview.md`](fmi-overview.md) | FMI 的基本概念、FMU 结构、ME/CS/SE 接口、2.0 与 3.0 的差异 | 建立整体认识 |
| [`fmi2-api.md`](fmi2-api.md) | FMI 2.0.4 C API、类型、生命周期、调用序列 | 实现 FMI 2 导入器 |
| [`fmi3-api.md`](fmi3-api.md) | FMI 3.0.2 C API、类型、数组/时钟/SE、配置模式 | 实现 FMI 3 导入器 |
| [`model-description.md`](model-description.md) | `modelDescription.xml` 的结构、字段、语义与陷阱 | 实现解析器与校验器 |
| [`xsd-inventory.md`](xsd-inventory.md) | 随附 XSD 的清单、依赖关系、校验策略 | 验证与测试 |
| [`schemas/README.md`](schemas/README.md) | XSD 文件来源、版本、校验和 | 标准资料维护 |
| [`headers/README.md`](headers/README.md) | 官方头文件来源、版本、校验和 | C ABI 绑定 |

## 2. 版本与来源

| 标准 | 版本 | 来源 | 随附内容 |
| --- | --- | --- | --- |
| FMI | 2.0.4 | `modelica/fmi-standard` 仓库 `v2.0.4` 标签 | 7 个 XSD，3 个 C 头文件 |
| FMI | 3.0.2 | `modelica/fmi-standard` 仓库 `v3.0.2` 标签 | 12 个 XSD，3 个 C 头文件 |

官方规范正文是 PDF/HTML，本目录不复制全文，只做面向实现的提炼。遇到歧义时，以官方规范正文和头文件为准。

## 3. 为什么同时保留 XSD 和头文件

- **XSD** 定义了 `modelDescription.xml` 的语法结构、元素顺序、必填/可选、默认值和枚举值。它是解析器的“字段清单”，也是测试语料的独立校验依据。
- **C 头文件** 定义了 ABI：类型宽度、函数签名、回调结构体、导出宏、状态码。它是 FFI 绑定的“唯一真相”。
- 两者都不能单独保证正确性：
  - XSD 不表达跨字段语义，也不强制所有规范约束。
  - 头文件只描述接口，不描述调用顺序和状态机。
- 因此还需要本目录的 API 文档、模型描述语义规则，以及 `design/xsd-and-validation.md` 中的校验设计。

## 4. 使用建议

### 实现解析器时

1. 先读 [`model-description.md`](model-description.md) 的结构总览。
2. 对照 [`schemas/fmi2/`](schemas/fmi2/) 或 [`schemas/fmi3/`](schemas/fmi3/) 中的 XSD 确认元素顺序和默认值。
3. 用 [`xsd-inventory.md`](xsd-inventory.md) 中的语义规则清单补足 XSD 表达不了的部分。
4. 用 `xmllint` 或 Python `lxml` 对测试 FMU 做独立的 XSD 对照检查，用来分清样品问题和解析器问题。

### 实现 FFI 时

1. 先读 [`headers/fmi2/fmi2TypesPlatform.h`](headers/fmi2/fmi2TypesPlatform.h) 或 [`headers/fmi3/fmi3PlatformTypes.h`](headers/fmi3/fmi3PlatformTypes.h)，确认类型宽度。
2. 再读 [`fmi2-api.md`](fmi2-api.md) / [`fmi3-api.md`](fmi3-api.md) 的生命周期与调用顺序。
3. 最后读 [`../design/ffi-and-abi.md`](../design/ffi-and-abi.md)，按其中的映射表和测试矩阵实现。

### 做代码审查时

- 任何对官方头文件类型的手工映射，都应能在 `headers/` 中找到依据。
- 任何对 `modelDescription.xml` 字段的假设，都应能在 XSD 或语义规则中找到依据。
- 新增的兼容性处理应写清楚“针对哪个 FMU/工具的实际行为”，避免把实现缺陷当成标准。

## 5. 版本升级流程

1. 从官方仓库拉取新版本的 XSD 与头文件，更新 `schemas/`、`headers/`。
2. 更新两个目录 `README.md` 中的版本、文件清单和 SHA-256。
3. 对比新旧 XSD/头文件，列出新增、删除、语义变化的字段与函数。
4. 更新 `fmi2-api.md` / `fmi3-api.md` / `model-description.md`。
5. 更新 `design/` 中受影响的解析、校验、ABI 设计。
6. 跑测试语料：至少覆盖 `modelica/Reference-FMUs` 与 `modelica/fmi-cross-check` 的相关子集。
