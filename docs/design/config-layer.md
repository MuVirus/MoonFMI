# CLI 配置层设计（moonfig 集成）

> 状态：**已实现（0.9.0 发布）**。moonfig `0.2.5` 已引入 `moon.mod`（锁版本），配置层落在 [`src/cli/config.mbt`](../../src/cli/config.mbt)。S1–S3 已完成；S4（命令行解析迁到 `CliSource`）按本文 §5 暂不实施。
>
> 实现与本文的差异：`validate`、`info`、`package`、`doctor` 仍是纯命令行（配置段只覆盖 `simulate` 与 `couple`）；来源追踪子命令（§4.7）未做；未知键只报警告（§4.4）。本版按 moonfig **0.2.5** 重新核对——0.2.4 修掉了初版方案里的两条关键缺口（环境变量键映射、命令行负数值；台账编号见 [`../roadmap/moonfig-gaps.md`](../roadmap/moonfig-gaps.md) §5，已按维护规则从台账中删除），0.2.5 相对 0.2.4 **库接口未变**（上游只把 CI 锁到 MoonBit 1.0 发布候选版并在 README 写明 1.0 要求）。

---

## 1. 动机

MoonFMI 的 CLI 只有命令行一种输入通道：

- 17 个长选项分散在 6 个手写解析点（[`src/cli/cli.mbt`](../../src/cli/cli.mbt) 的 `parse_flags`、`parse_simulate_options`、`parse_couple_options`，以及 `package_cmd.mbt`、`doctor.mbt`、`sandbox.mbt`），取值域靠逐条字符串比较；
- 没有配置文件入口；
- 环境变量只用于 `doctor` 读 `PATH` 和 `--sandbox` 的子进程标记，不参与业务配置。

后果是"一套仿真实验规格"无法存盘：CI 里只能把一长串参数抄进命令行，实验不可复现、不可审阅、不可共享。

`moonfig`（MuVirus/moonfig，同作者）提供多来源合并、类型化提取、来源追踪与校验。本文回答两个问题：它该不该进 MoonFMI，以及怎么进。

---

## 2. 结论摘要

| 决策 | 选择 | 理由 | 替代方案 |
| --- | --- | --- | --- |
| 来源层次 | 命令行 > 环境变量 > 配置文件 > 内置默认 | 命令行最显式，环境变量便于 CI 注入，配置文件是可审阅的规格 | 只加文件；只加环境变量 |
| 命令行解析 | 第一阶段保留 MoonFMI 自己的解析器，后续可迁移 | 0.2.4 已解除表达能力限制；保留的理由是行为兼容性（退出码与消息是对外契约） | 立即整体迁移到 `CliSource`（§5） |
| 合并方式 | 字段级回填 | 现有结构体已用 `Option` 表达"未指定"，可直接复用 | 统一翻译成 moonfig 键空间再合并 |
| 键名 | 内部统一 snake_case | 环境变量靠 `with_separator("__")` 原生映射；旗标靠一次机械替换 | 用 kebab-case 做内部键（环境变量侧无法表达） |
| 依赖范围 | `core` + `core/format/json_format` + `file_source`/`env_source`/`format_detect` | 零新增传递依赖；JSON/INI/dotenv 都在 core 内 | 加 `moonfig-toml@0.2.0`/`moonfig-yaml@0.2.0`（多两个传递依赖） |
| 枚举字段 | `interface`/`solver`/`backend` 改成 `String?` | 否则无法区分"命令行显式给了 cs"与"没给"，优先级无法实现 | 另设一个"出现过哪些旗标"的数组 |
| 错误处理 | moonfig `ConfigError` → 退出码 2 | 与"用法错误"同族，且都发生在加载 FMU 之前 | 新增退出码（破坏退出码矩阵） |
| JSON 输出 | 不注入来源追踪 | [`../cli-json.md`](../cli-json.md) 契约锁定 | 加 `config` 字段（需升 schema） |

---

## 3. 依赖与准入信息

§13.3 规则 1 要求先告知以下各项，规则 4 要求把评估过程写进 [`../research/moonbit-ecosystem.md`](../research/moonbit-ecosystem.md)。

| 项 | 值 |
| --- | --- |
| 模块 | `MuVirus/moonfig@0.2.4` |
| 许可证 | Apache-2.0 |
| 发布时间 | 2026-11-20 15:11 UTC（23:11 GMT+8） |
| 下载量 / 依赖者 | 285 / 0（MoonFMI 将是第一个消费者） |
| 传递依赖 | 仅 `moonbitlang/x@0.5.7`（本项目已锁同一版本） |
| preferred_target | native |
| checksum | `cbc53b3ab6e7e5d86a4de974e083e2c9cfc11e03513956ff8005a401200ac3c3` |

0.2.4 相对 0.2.3 是破坏性变更（上游标了 `feat!`），两处都与本方案直接相关：

- **环境变量分隔符改为按需开启**：默认只按 `.` 分层，`APP_DB_PORT` 是平键 `db_port`；`with_separator("_")` 恢复旧行为，`with_separator("__")` 让双下划线分层、单个下划线留在键名里。
- **`CliSource` 接受负数值**：`CliHyphenValues` 引入，`Separate` 下形似负数的参数默认算值。

MoonFMI 尚未使用 moonfig，没有迁移成本；但方案必须锁 `@0.2.4`——锁 0.2.3 会得到不同的环境变量语义。

不引入的后果：配置层缺口保留，实验规格无法存盘；CLI 取值解析继续分散在 6 处。替代方案是自研最小配置读取（约 200–300 行），但合并、校验、来源追踪都要重造，且与同作者的库分叉。

---

## 4. 分层设计

### 4.1 键空间

配置文件按命令分节，节名即命令名；键名用 snake_case：

```json
{
  "simulate": { "stop_time": 10.0, "interface": "cs", "set": ["a=1", "b=2"] },
  "couple": { "loop_iterations": 50, "loop_tolerance": 1e-6 }
}
```

命令行旗标是 kebab-case（`--stop-time`），内部统一成 snake_case（`stop_time`），靠一次机械替换完成，不维护映射表。配置文件也接受 kebab-case 写法，读入后同样归一。

环境变量用 `MOONFMI_` 前缀、双下划线分层：`MOONFMI_SIMULATE__STOP_TIME` → `simulate.stop_time`。这正是 moonfig 0.2.4 `EnvSource::with_separator("__")` 的语义（双下划线分层，单个下划线留在键名里）。0.2.4 起环境变量默认只按 `.` 分层——不写 `with_separator` 会得到平键 `simulate__stop_time`，配置静默不生效。

数组型选项（`set`、`connect`）无法用环境变量表达：一个变量一个值，且两个变量映射到同一个键会报 `ParseError`。这两项只能来自配置文件或命令行。

### 4.2 字段级回填

`SimulateOptions` 的 `start_time : Double?` 等字段为 `None` 即"命令行没给"；`interface`/`solver`/`backend` 目前是带默认值的非可选字段。合并因此可以就地表达：

1. 解析命令行，得到 `SimulateOptions`；
2. 读配置（文件 + 环境变量），得到全字段可空的配置结构；
3. 命令行是 `Some` 的字段保留，否则取配置值；
4. 都没有则用内置默认。

第 4 步的"都没有"推迟到消费点才解析，因此 `interface`/`solver`/`backend` 改成 `String?`。改动集中在 [`src/cli/cli.mbt`](../../src/cli/cli.mbt)：3 处赋值 + 6 处读取。

配置侧读取必须用 `opt_*`（缺失或 null 都给 `None`），不能用 `*_or` 的默认值——否则配置文件里写错的 `"interface": "nope"` 会被默认值掩盖。

### 4.3 类型与后处理

| 字段 | 配置类型 | 说明 |
| --- | --- | --- |
| `start_time`/`stop_time`/`step_size` | 浮点 | 用 `get.opt_float`，整数自动加宽（配置里写 `1` 表示 1 秒） |
| `loop_iterations` | 整数 | `get.opt_int32` |
| `timeout` | 浮点秒 | **秒 → 绝对截止时间的转换必须移到回填之后**：现有代码在解析时就把秒转成 `UInt64` 截止时间，配置层要保持同一语义 |
| `sha256` | 字符串 | 仍走现有 `normalize_sha256` 校验 |
| `set`/`connect` | 字符串数组 | 拆分沿用现有 `split_set_override`/`parse_connect` |

### 4.4 校验

- 取值域集合是唯一事实来源，定义在 MoonFMI 侧；命令行的取值域检查**保留现状**（消息与退出码 2 不变），配置侧用 moonfig `Rule::one_of` 校验同一组常量，错误消息带来源（文件路径或环境变量名）。
- 未知键检查（`Rule::allowed_keys`）默认关闭：配置文件里放注释性字段不应导致运行失败。是否开启见 §9。

### 4.5 错误与退出码映射

| 情况 | 退出码 |
| --- | --- |
| 配置文件不存在 | 1 |
| 格式无法识别（`UnknownFormat`） | 2 |
| 语法错误（`ParseError`） | 2 |
| 类型不符（`TypeMismatch`） | 2 |
| 取值越界 | 2 |

统一为 2 的理由：这类错误与"参数非法"同族，都发生在加载 FMU 之前；新增退出码会破坏 [`cli-and-testing.md`](cli-and-testing.md) §4 的退出码矩阵稳定性。moonfig 自带消息是英文且不带文件名，需要包一层，形态形如：

```text
配置文件 moonfmi.json: simulate.interface 取值非法，期望 cs/me/se，实际 "nope"
```

### 4.6 平台边界

moonfig 只进 [`src/cli`](../../src/cli)（该包已声明 `supported_targets = "native"`）。[`src/fmi`](../../src/fmi) 不引入 moonfig——它被 wasm 后端共用。

需要澄清的事实：`moonbitlang/x/fs` 与 `moonbitlang/core/env` 都有 js / native / wasm 三套实现，所以"moonfig 只能在 native 跑"并不成立；真正的约束来自 MoonFMI 自己的包分层。

### 4.7 来源追踪

moonfig 的 `Config::snapshot()` 能给出每个键的来源。第一版**不做**：把来源写进 `--json` 会动 [`../cli-json.md`](../cli-json.md) 的 schema 契约。若以后需要，作为独立子命令（`moonfmi config`）输出，不改现有命令的 JSON。

---

## 5. 命令行解析：第一阶段自有，后续可迁移

moonfig 0.2.3 及以前，`CliSource` 有两条限制让"命令行交给 moonfig"不可行：源只能一种值风格（MoonFMI 用 `Separate`），且 `Separate` 下以 `-` 开头的值被当作下一个选项——`moonfmi simulate m.fmu --start-time -1` 会丢值，而负的起始时间是当前实现允许的输入（`parse_simulation_double` 不禁止负数）。

0.2.4 的 `CliHyphenValues` 解掉了第二条：`Separate` 下形似负数的参数（`-1`、`-1.5`、`-1e3`）默认就算值，`Always` 可放宽到任意 `-` 开头，`Never` 恢复旧边界。**该缺口因此关闭，迁移路径打开。**

第一阶段（S1–S3）仍保留 MoonFMI 自己的命令行解析器，但理由变了——不再是"moonfig 表达不了"，而是**行为兼容性**：现有错误消息文本与退出码是对外契约（`src/cli/cli_wbtest.mbt` 锁定退出码），moonfig 的 `ConfigError` 语义不同（见 G-04）。

迁移到 `CliSource` 的前提与注意点：

| 事项 | 说明 |
| --- | --- |
| argv 形态 | MoonFMI 的 `run(argv, ...)` 收到的 argv[0] 是子命令而非程序名，因此用 `CliSource::from_args(argv, program_name=false)` |
| 位置参数 | `with_positional(0, "command")`、`with_positional(1, "model")`（位置只数非选项参数） |
| 可重复选项 | `--set`、`--connect` 用 `with_array("set")`、`with_array("connect")`，元素按首个 `=` 拆分沿用现有 `split_set_override`/`parse_connect` |
| 布尔开关 | `--json`/`--strict`/`--sandbox` 用 `with_long_flag` 登记 |
| 负数值 | `Separate` + 默认 `NegativeNumbers` 即可；注意它是形状判断（`-1abc` 也当值），不是完整数值解析 |
| 错误消息 | moonfig 的 `ConfigError` 要映射到 MoonFMI 的退出码与消息，与 G-04 共用同一套包装层 |

迁移的额外收益：命令行参数也纳入来源追踪（`cli:argv[N]`），三层合并变一层。但这是可选项，不是第一阶段的前提。

---

## 6. 代码落点

| 文件 | 职责 |
| --- | --- |
| [`src/cli/config.mbt`](../../src/cli)（新） | 读配置、合并、校验、错误映射 |
| [`src/cli/config_wbtest.mbt`](../../src/cli)（新） | 配置层单测：优先级、类型错误、未知格式 |
| [`src/cli/cli.mbt`](../../src/cli) | 增加 `--config <path>`；回填；枚举字段改 `String?` |
| [`src/cli/moon.pkg`](../../src/cli) | 增加 moonfig 包导入 |
| [`moon.mod`](../../moon.mod) | 锁定 `MuVirus/moonfig@0.2.4` |

`src/cli/moon.pkg` 需要新增的导入：

```text
import {
  "MuVirus/moonfig/core" @config,
  "MuVirus/moonfig/core/format/json_format" @jsonfmt,
  "MuVirus/moonfig/file_source" @filesrc,
  "MuVirus/moonfig/env_source" @envsrc,
  "MuVirus/moonfig/format_detect" @detect,
}
```

环境变量源必须显式开分隔符，否则 0.2.4 的默认行为会给出平键：

```moonbit nocheck
let env = @envsrc.EnvSource::new("MOONFMI_").with_separator("__")
```

配置侧结构体与现有选项结构体分开，避免把"可空"传染到消费点：

```moonbit nocheck
///| 配置层读出的值；全字段可空，None 表示"这一层没给"。
///|
priv struct SimulateConfig {
  start_time : Double?
  stop_time : Double?
  step_size : Double?
  output : String?
  platform_override : String?
  interface : String?
  solver : String?
  backend : String?
  timeout_seconds : Double?
  sha256 : String?
  sets : Array[String]
}
```

回填函数保持单向：只把 `None` 填上，不覆盖命令行已有的值。

---

## 7. 实施步骤与验收

| 步骤 | 内容 | 验收 | 状态 |
| --- | --- | --- | --- |
| S0 准入 | 告知与确认 → `moon.mod` 锁 `@0.2.4`、`moon.pkg` 加导入、更新 §13.1 | `moon build` 通过；`moon info` 的 `.mbti` diff 只含新依赖 | ✅ 完成；`.mbti` 无变化（公开 API 未变） |
| S1 配置读取 | `src/cli/config.mbt`：文件 + 环境变量 + 合并 + 错误映射 | 单测覆盖优先级、类型错误、未知格式；退出码符合 §4.5 | ✅ 完成，16 个新用例 |
| S2 回填接入 | `simulate`/`couple` 接入回填；枚举字段改 `String?` | **现有测试全绿**；行为等价性用例：无 `--config` 时输出逐字节相同 | ✅ 完成；native 220 / wasm 115 全绿 |
| S3 文档 | README、[`../cli-json.md`](../cli-json.md)（若涉及）、本文件状态更新 | 新用户按 README 能跑通一次带配置文件的仿真 | ✅ 完成 |
| S4（可选） | 命令行解析迁移到 `CliSource` | 退出码与消息不变；`--start-time -1` 等负数值用例通过；来源追踪覆盖 CLI | ⬜ 未做（见 §5） |

S1 可独立回滚；S2 的等价性测试是进入 S3 的闸门；S4 不做也不影响前三步交付。

---

## 8. 风险

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| moonfig 仍在快速迭代（0.2.3→0.2.4 一天内两次破坏性变更） | 上游 API 变动频繁 | 锁 `@0.2.4`；只用 core 稳定面（`Config`/`Getter`/`Rule`）；升级前查缺口台账 |
| 0.2.4 的环境变量默认语义与 0.2.3 不同 | 锁错版本会得到平键，配置静默不生效 | 锁 `@0.2.4` 并显式 `with_separator("__")`；加一条断言"环境变量确实落到 `simulate.stop_time`"的测试 |
| moonfig 发布于当天、无依赖者 | 上游缺陷会直接暴露在 MoonFMI | 分阶段落地；S2 的等价性测试作为回归闸门 |
| 配置文件与命令行两套取值域校验 | 规则漂移 | 取值域集合定义为单一常量，两处引用 |
| 枚举字段改 `String?` 触及消费点 | 回归风险 | 改动集中在 6 处读取，同步加等价性测试 |
| `timeout` 的"秒 → 绝对截止时间"转换位置 | 配置层的 timeout 会被误当作已转换值 | 转换统一移到回填之后（§4.3） |
| moonfig 的其余能力缺口（列表合并、错误消息、警告级校验等 5 条） | 配置层的可用性与错误质量 | 缺口清单与临时替代见 [`../roadmap/moonfig-gaps.md`](../roadmap/moonfig-gaps.md) |

---

## 9. 拍板结果

第一版按下列默认值落地，不逐项征求确认：

| 问题 | 决定 | 理由 |
| --- | --- | --- |
| 配置文件格式范围 | JSON + INI + dotenv 三种 | 三种都在 moonfig core 内，零新增传递依赖；格式由 `format_detect` 按后缀与内容判定。TOML/YAML 需要独立的适配器模块（`moonfig-toml@0.2.0`/`moonfig-yaml@0.2.0`），不进核心路径 |
| 环境变量层是否开放 | 开放，用 `MOONFMI_` 前缀 | 前缀已有先例（`MOONFMI_SANDBOX_CHILD`、`MOONFMI_WASM_BIN`），不必发明；业务键限定在 `simulate`/`couple` 两段，撞名面可控 |
| 配置文件路径 | 只支持显式 `--config <path>` | 自动发现与用户级路径留到后续；显式指定可预期，不会被 cwd 下的文件意外影响 |
| 未知键检查 | 默认只警告，不失败 | 配置文件里放注释性字段不应导致运行失败；只检查 `simulate`/`couple` 两段，其它 `MOONFMI_*` 根键属别的工具 |
| 来源追踪 | 第一版不做 | 会动 [`../cli-json.md`](../cli-json.md) 的 schema 契约；需要时再做独立子命令 `moonfmi config` |
| S4 是否推进 | 暂不推进 | 保留自研命令行解析是行为兼容性选择，不是表达能力限制；迁移收益（CLI 来源追踪）暂不足以抵消改动面 |

对应的能力缺口与临时替代记在 [`../roadmap/moonfig-gaps.md`](../roadmap/moonfig-gaps.md)。

---

## 10. 相关文档

- CLI 与测试：[`cli-and-testing.md`](cli-and-testing.md)
- 架构与包分层：[`architecture.md`](architecture.md)
- 依赖准入：[`../research/moonbit-ecosystem.md`](../research/moonbit-ecosystem.md) §13
- 能力缺口清单：[`../roadmap/moonfig-gaps.md`](../roadmap/moonfig-gaps.md)
- JSON 契约：[`../cli-json.md`](../cli-json.md)
- 外部链接：[`../references/links.md`](../references/links.md)
- moonfig 仓库：<https://github.com/MuVirus/moonfig>
- moonfig 决策记录（0.2.4 的取舍依据）：<https://github.com/MuVirus/moonfig/blob/main/docs/decisions/decisions.md>
