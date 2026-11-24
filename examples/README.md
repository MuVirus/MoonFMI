# MoonFMI 示例

这个目录是 MoonFMI 的可运行证明：每个子目录是一个独立的 MoonBit 包，
演示 `MuVirus/fmi` 公开 API 的一种典型用法。代码可以直接抄进自己的工程——
每个示例只依赖 `src/` 下的公开包，不碰内部实现。

命令行工具 `moonfmi` 的速查表在本文末尾；库用法与 CLI 用法两条路都能走通
同一件事。

## 前置条件

- MoonBit 工具链（[安装](https://docs.moonbitlang.com)）；
- 一个 C 编译器：加载 FMU 时 `moon` 会编译自带的 native shim（`clang` 或 MSVC 均可）；
- 示例用到的 FMU 放在测试语料缓存里，先下载一次：

  ```bash
  moon run tests/data/fetch-fmus.mbtx --target native
  ```

  语料是 [Reference-FMUs](https://github.com/modelica/Reference-FMUs) v0.0.42
  （BSD-2-Clause），校验和会与 `tests/data/manifest.json` 逐一核对，缓存在
  `tests/data/.cache/` 下。换成自己的 FMU 只需要换路径，示例不依赖语料里的
  任何内部约定。

## 示例一览

| 目录 | 演示什么 | 需要 native |
| --- | --- | --- |
| [`common/`](common/) | 示例共用的小工具：命令行参数、失败退出、输出列收集、CSV 渲染 | 否 |
| [`validate-model/`](validate-model/) | 打开 FMU、解析并校验模型描述、打印摘要与诊断 | 否 |
| [`simulate-cs/`](simulate-cs/) | 加载 FMU、跑联合仿真（CS）、把输出写成 CSV | 是 |
| [`simulate-me/`](simulate-me/) | 模型交换（ME）仿真，Euler / RK4 积分器 | 是 |
| [`couple-fmus/`](couple-fmus/) | 多个 FMU 组成一次耦合仿真，按信号连线 | 是 |
| [`export-source-fmu/`](export-source-fmu/) | 从模型 IR 生成源码 FMU，并确定性打包成 `.fmu` | 否 |

每个目录里的 `main.mbt` 顶部都有一段注释，说明这个示例回答什么问题。
`common/` 是唯一被其他示例引用的包——抄进自己的工程时把它一起带上，
或者直接把那几个小函数收进自己的工具模块。

## 跑起来

所有示例都从仓库根目录运行，形式一致：

```bash
moon run examples/<名字> --target native -- <参数>
```

> `--target native` 写不写都行：模块的 `preferred_target` 已经是 `native`
> （2026-11-24 起）。显式写出来更保险，尤其是 CI 里。

### 校验一个 FMU

```bash
moon run examples/validate-model --target native -- \
    tests/data/.cache/fmi2/BouncingBall.fmu
```

输出模型名、FMI 版本、接口、变量数量，以及每条诊断（编号、级别、位置）。
退出码：`0` 无错误，`1` 有错误，`2` 用法错误，`3` 文件读不了。

### 跑一次联合仿真

```bash
moon run examples/simulate-cs --target native -- \
    tests/data/.cache/fmi2/BouncingBall.fmu ball.csv
```

第二个参数是 CSV 输出路径；不给就打到标准输出。CSV 第一行是
`time,<输出变量名>`，之后每行一个通信点。

### 跑一次模型交换仿真

```bash
moon run examples/simulate-me --target native -- \
    tests/data/.cache/fmi2/VanDerPol.fmu vdp.csv
```

### 耦合两个 FMU

```bash
moon run examples/couple-fmus --target native -- \
    tests/data/.cache/fmi2/Dahlquist.fmu \
    tests/data/.cache/fmi2/Feedthrough.fmu \
    coupled.csv
```

示例把 Dahlquist 的输出 `x` 连到 Feedthrough 的输入
`Float64_continuous_input`，并按拓扑序推进两个参与者。

### 导出一个源码 FMU

```bash
moon run examples/export-source-fmu --target native -- \
    .moonfmi-tmp/export-example
```

生成 `modelDescription.xml`、C 源码、`CMakeLists.txt`，以及一个确定性的
`.fmu`（同样的 IR 两次导出的 SHA-256 相同）。要真正跑起来，用生成的
`CMakeLists.txt` 编出动态库放进 `binaries/<平台>/` 再打包。

## 改成你自己的 FMU

示例只做了一件事：把命令行参数里的路径换掉。

```bash
moon run examples/simulate-cs --target native -- /path/to/MyModel.fmu out.csv
```

两处值得注意的约定：

- **临时目录**：`load_*_fmu` 把整个 FMU 解压到一个**全新的空目录**里，
  这样动态库和资源才有真实路径。示例用 `.moonfmi-tmp/run-<时间戳>`，
  `dispose()` 会连同解压出来的文件一起清掉。
- **按名字查 value reference**：示例用模型描述里的变量名反查
  value reference，而不是写死数字。value reference 只在单个模型描述内
  有意义，换模型就会错。

## 命令行速查

不想写代码时，同一套能力都在 `moonfmi` 命令里：

```bash
moon run cmd/main --target native -- <命令> [选项]
```

| 命令 | 作用 | 常用选项 |
| --- | --- | --- |
| `validate <fmu>` | 只校验模型描述，不加载二进制 | `--strict`、`--json` |
| `info <fmu>` | 打印模型描述摘要 | `--json` |
| `simulate <fmu>` | 跑 CS / ME / SE 仿真 | `--interface cs\|me\|se`、`--solver euler\|rk4`、`--start-time`、`--stop-time`、`--step-size`、`--set 名称=值`、`--output out.csv`、`--timeout 秒`、`--sha256 HEX`、`--platform 目录`、`--sandbox`、`--json`、`--config 文件` |
| `couple <fmu> ...` | 多个 FMU 组成一次耦合仿真 | `--connect 参与者.变量=参与者.变量`、`--loop-iterations N`、`--loop-tolerance T`、`--output out.csv`、`--json` |
| `package <目录>` | 从已解压目录构建确定性 `.fmu` | `--output model.fmu`、`--platform 目录`、`--json` |
| `doctor` | 检查本地环境 | — |

退出码是契约的一部分，脚本不要猜：

| 码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 1 | 模型描述无效，或（`--strict` 下）存在警告 |
| 2 | 用法错误 |
| 3 | 文件读不了 |
| 4 | 不支持的平台 / 后端 |
| 5 | 仿真失败 |
| 6 | 超时 |
| 7 | 宿主平台未知 |

加 `--json` 得到机器可读输出，字段结构是带版本号的契约，见
[`../docs/cli-json.md`](../docs/cli-json.md)。

### 配置层

`simulate` 和 `couple` 的设置可以来自文件、环境变量或命令行，优先级从低到高：

```json
{
  "simulate": { "stop_time": 3.0, "step_size": 0.01, "set": ["h=0.5"] }
}
```

```bash
moon run cmd/main --target native -- simulate model.fmu --config experiment.json
MOONFMI_SIMULATE__STOP_TIME=3 moon run cmd/main --target native -- simulate model.fmu
```

键名用下划线；文件里也接受短横线写法（`stop-time`）。未知键只在 stderr
报警告，不会让命令失败。

## 相关文档

- [`../docs/guides/quick-start.md`](../docs/guides/quick-start.md) —— 第一次
  跑通一个 FMU 的完整步骤。
- [`../docs/design/master-algorithm.md`](../docs/design/master-algorithm.md) ——
  CS / ME / SE 主算法与事件处理。
- [`../docs/design/coupling.md`](../docs/design/coupling.md) —— 耦合的连线
  语义、拓扑推进与代数环处理。
- [`../docs/design/exporter.md`](../docs/design/exporter.md) —— 源码 FMU 的
  IR 范围与代码生成。
