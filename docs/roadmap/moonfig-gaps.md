# moonfig 能力缺口清单

> 状态：**持续维护**。本文件记录 MoonFMI 集成 moonfig 过程中发现的能力缺口、MoonFMI 侧的临时替代，以及准备推给上游（MuVirus/moonfig）的改进建议。
>
> 协作方式：MoonFMI 并入 moonfig 后，本文件即成为两边共享的缺口台账——MoonFMI 侧继续按"临时替代"推进，上游侧按"上游建议"逐条处理。任何一方都可以随时往本文件追加条目。
>
> 维护规则：**条目被上游关闭后，即从本文件删除其全部内容**（清单行、逐条说明、临时替代条目一并删掉），不保留"已解决"段落；关闭记录只留在 §5 版本追踪。
>
> 当前基准：moonfig **0.2.5**（2026-11-27 13:35 UTC）。本文件只保留开放条目。

---

## 1. 背景

moonfig（MuVirus/moonfig）与 MoonFMI 同作者。集成方案见 [`../design/config-layer.md`](../design/config-layer.md)，准入评估见 [`../research/moonbit-ecosystem.md`](../research/moonbit-ecosystem.md) §13.1。

本文件的条目按"是否阻塞 MoonFMI 的配置层落地"排序。每条包含四件事：

- **现象**：moonfig 现在的实际行为（以源码或官方设计文档为准，不凭印象）；
- **影响**：对 MoonFMI 的具体影响；
- **临时替代**：MoonFMI 用自有代码绕开的做法；
- **上游建议**：希望 moonfig 增加或调整的能力。

---

## 2. 缺口清单

| 编号 | 缺口 | 优先级 | 状态 | 临时替代 | 上游建议 |
| --- | --- | --- | --- | --- | --- |
| G-02 | 数组型键只能整体覆盖，没有追加语义 | 中 | 开放 | MoonFMI 在回填阶段自己拼接 | 为列表型键提供 append / union 合并策略 |
| G-04 | 错误消息不可定制，默认不含来源 | 中 | 开放 | MoonFMI 捕获 `ConfigError` 后用 `origin_of` 重写 | 提供错误消息渲染钩子 / 默认带 origin |
| G-05 | 校验规则没有"警告"级别 | 中 | 开放 | MoonFMI 用 `snapshot()` 自己比对 | `Rule` 增加 severity 或"只收警告"模式 |
| G-06 | 没有声明式"选项规格"单一事实来源 | 中 | 开放 | MoonFMI 自建规格表 | 提供可驱动校验与文档的 schema |
| G-07 | 复合字符串数组（`name=value`）无原生支持 | 低 | 开放 | 沿用现有 `split_set_override` / `parse_connect` | 可选的 kv 数组表示 |
| G-08 | 文档里 "core module" 一词指两样东西 | 低 | 开放 | 无（按实测包依赖图判断） | 统一术语（模块 vs 包） |
| G-09 | 环境变量无法表达数组型配置 | 低 | 开放 | 数组型选项只支持配置文件与命令行 | 约定型数组变量（如 `NAME_1`、`NAME_2`）或明确声明为设计取舍 |

编号一经分配不再复用；条目关闭后按上面的维护规则删除，编号因此会留下空档，关闭记录见 §5。

---

## 3. 逐条说明

### G-02 数组型键只能整体覆盖

**现象**：`MergeRule` 只有 `LastWins`（默认）、`FirstWins`、`ByKind`、`Custom`；按键合并语义是"后加入的来源只覆盖先加入来源的同名键"，数组整体替换。

**影响**：配置文件里的 `simulate.set` 与命令行 `--set` 无法合并，只能二选一。MoonFMI 期望列表型选项是**并集**——配置文件给默认输入覆盖，命令行追加。

**临时替代**：配置层只合并标量键；数组型键（`set`、`connect`）在回填阶段由 MoonFMI 自己拼接，顺序为"配置文件在前、命令行在后"。这与字段级回填的整体设计一致，不需要动 moonfig。

**上游建议**：为列表型键提供显式的合并策略（append / union / 按元素去重）。注意 `MergeRule::Custom` 收到的是两个 `Value`，能否按路径区分数组与标量需要确认。

### G-04 错误消息不可定制，默认不含来源

**现象**：`ConfigError` 的默认文本是英文，例如 `key 'db.host': expected Int, got Str`、`missing key 'db.user': no source provides it`。来源信息不在文本里，要另外用 `origin_of` / `Origin::label` 查。

**影响**：MoonFMI 的错误规范要求"带阶段、文件、变量、规则"，且要映射到退出码矩阵。缺文件名的英文消息不满足要求。

**临时替代**：MoonFMI 在配置层捕获 `ConfigError`，用 `origin_of` 取出来源（`file:moonfmi.json` 或 `env:MOONFMI_*`），补上文件路径与键路径，包装成 MoonFMI 自己的错误类型再映射退出码。

**上游建议**：允许调用方提供错误消息渲染函数（formatter 钩子），或至少在默认文本里带上 origin label。

### G-05 校验规则没有"警告"级别

**现象**：`Rule` 提供 `int_range`、`string_len`、`one_of`、`allowed_keys`、`custom`；`Config::validate` 遇错即停，`validate_all` 一次列全。没有 severity 概念。

**影响**：MoonFMI 既有体系区分 warning 与 error（`src/schema` 的 MD 规则）。配置文件里的未知键应当是警告（不影响运行），而不是失败——moonfig 的 `allowed_keys` 只能二选一。

**临时替代**：MoonFMI 用 `Config::snapshot()` 取到全部键路径，与自己维护的允许键集合比对，产出 MoonFMI 风格的 warning。键集合本来就是 G-06 要求的规格表的一部分，所以这项几乎不额外增加成本。

**上游建议**：`Rule` 增加 severity，或提供"只收集警告不失败"的校验模式。

### G-06 没有声明式"选项规格"单一事实来源

**现象**：moonfig 不提供声明式规格。`FromConfig` 要逐字段手写，`Rule` 要逐条手写，文档与帮助文本不在库内。

**影响**：MoonFMI 的 `usage()`、`command_help()`、配置键清单、取值域校验目前分散在 4 处以上；引入配置层后，若各处各写一份，配置键与帮助文本必然漂移。

**临时替代**：MoonFMI 自己维护一张规格表（键名、类型、默认值、取值域、帮助文本），帮助文本、配置校验、未知键检测、来源追踪全部从它派生；moonfig 只负责"按这张表取值与合并"。规格表是 MoonFMI 自己的代码，不依赖上游。

**上游建议**：moonfig 提供声明式规格（schema），能同时驱动校验与文档生成——这会让"配置驱动的 CLI"不必在下游自建规格层。

### G-07 复合字符串数组无原生支持

**现象**：moonfig 的数组是同质值数组，没有"元素内再拆键值"的表示。

**影响**：`simulate.set`（`name=value`）与 `couple.connect`（`a.x=b.y`）的元素拆分要自己写。

**临时替代**：沿用现有的 `split_set_override` 与 `parse_connect`（已实现且有测试覆盖）。

**上游建议**：可选的低优先级能力——提供 kv 数组的表示与提取（元素按首个分隔符拆分）。

### G-08 文档里 "core module" 一词指两样东西

**现象**：moonfig **模块级**的 README（`modules/moonfig/README.md`，也就是 mooncakes 上发布的那份）仍写着 "This is the core module. It contains the sources, merging, the JSON / INI / .env formats…"，而紧接着的包表里有一个叫 `core` 的包；`file_source`、`env_source`、`cli_source` 是 `core` 的**同级包**，不在 `core` 里面。

（0.2.4 重写了仓库根的 `README.mbt.md`，不再有这句话；但发布到 mooncakes 的模块 README 仍是旧文案，歧义保留在用户实际会看到的地方。）

**影响**：下游容易误以为 `file_source` 属于 `core` 包，或误判哪些包带 IO 依赖——本次核对 MoonFMI 依赖边界时就踩到这个歧义。

**临时替代**：无（MoonFMI 侧按实测的包依赖图判断：`core`、`core/format/*`、`format_detect` 不含 IO；`file_source`、`env_source`、`cli_source` 含）。

**上游建议**：模块级 README 统一术语，把模块称作 "the moonfig module"，包名一律带 `core/` 前缀。

### G-09 环境变量无法表达数组型配置

**现象**：`env_source` 一个变量对应一个键；两个变量映射到同一个键会报 `ParseError`（"environment variables X and Y both map to Z"）。

**影响**：`simulate.set`、`couple.connect` 这类列表型选项无法用环境变量提供；`MOONFMI_SIMULATE__SET` 只能给一个字符串。

**临时替代**：数组型选项只支持配置文件与命令行，在文档里写明。

**上游建议**：这部分基本是环境变量机制的固有限制，不算缺陷。若要支持，可约定型变量名（`NAME_1`、`NAME_2`）或明确的"环境变量只承载标量"声明，避免下游反复踩。

---

## 4. 临时替代的收口

临时替代不是永久方案。每条上游能力落地后，按下面的规则回收：

| 上游能力 | 回收 MoonFMI 侧的什么 |
| --- | --- |
| G-02 列表合并 | 删掉回填阶段对 `set`/`connect` 的手工拼接，改用 `MergeRule` |
| G-04 错误渲染 | 删掉 MoonFMI 的 `ConfigError` 包装层，直接用 moonfig 的消息 |
| G-05 警告级 | 删掉 MoonFMI 用 `snapshot()` 做的未知键比对 |
| G-06 规格表 | 规格表若上移到 moonfig，MoonFMI 侧改为消费 schema |

已关闭条目的残留事项不在本表：配置文件侧的 kebab 别名归一保留、命令行解析迁到 `CliSource` 的评估，都在 [`../design/config-layer.md`](../design/config-layer.md) §5。

回收时必须重跑行为等价性测试（无 `--config` 时输出逐字节相同），确认没有回归。

---

## 5. 版本追踪

| moonfig 版本 | 发布时间 | 与本台账的关系 |
| --- | --- | --- |
| 0.2.3 | 2026-11-20 01:10 UTC | 初版方案的基准；G-01、G-03、G-08 由此发现 |
| 0.2.4 | 2026-11-20 15:11 UTC | 关闭 G-01（`with_separator`）、G-03（`CliHyphenValues`），两条已按维护规则从本文件删除；G-08 仍开 |
| 0.2.5 | 2026-11-27 13:35 UTC | 库接口相对 0.2.4 未变（上游只锁定 MoonBit 1.0 工具链并在 README 写明 1.0 要求），台账无新增条目；G-08 仍开 |

---

## 6. 上游同步节奏

- 本文件是唯一台账，MoonFMI 与 moonfig 两边都以它为准，避免口头约定丢失。
- 每条缺口按"优先级 → 影响面"排序处理；G-04 优先级最高，因为它直接影响配置层的错误质量。G-02、G-05、G-06 影响的是"好用"而非"能用"。
- 上游落地后按维护规则从本文件删除该条目，并在 §5 版本追踪里记下关闭它的版本号；同时在 [`../research/moonbit-ecosystem.md`](../research/moonbit-ecosystem.md) §13.1 的依赖记录里同步版本。
- MoonFMI 侧升级 moonfig 版本时，先看本文件是否有未回收的临时替代，再决定是否升级。

---

## 7. 相关文档

- 集成方案：[`../design/config-layer.md`](../design/config-layer.md)
- 准入评估：[`../research/moonbit-ecosystem.md`](../research/moonbit-ecosystem.md) §13
- moonfig 仓库：<https://github.com/MuVirus/moonfig>
- moonfig 决策记录：<https://github.com/MuVirus/moonfig/blob/main/docs/decisions/decisions.md>
- 外部链接：[`../references/links.md`](../references/links.md)
