# MoonFMI

[English](README.md) | 简体中文

MoonFMI 是一个实验性的 MoonBit 库与命令行工具（`moonfmi`），面向符合
FMI 2.0.4 或 3.0.2 的 FMU。它在 native 上运行联合仿真（Co-Simulation）
与模型交换（Model Exchange），支持 FMI 3 的 Scheduled Execution，还能
校验模型描述、打包 FMU，并把简单模型导出回 FMU。

mooncakes 上的模块名是 `MuVirus/fmi`；仓库仍叫 `MoonFMI`。

## 能做什么

- 按 MD-001..MD-063 规则校验 `modelDescription.xml`，并打印摘要
  （`validate`、`info`）；归档携带 WebAssembly 组件时，LS-WASM 分层标准
  manifest 一并校验。
- 运行联合仿真或模型交换仿真，输出 CSV 或 JSON；FMI 3 还可按时钟运行
  调度执行（`simulate`）；初始化前可按类型设置输入与参数
  （`--set 名称=值`）。FMI 2/3 的时间事件（`nextEventTime`）会被调度，
  Float64 数组输出按元素拆成 `name[i]` 列，FMI 3 带时钟的模型在 CS/ME
  下与 SE 一样运行。
- 把多个 FMU 耦合成一次联合仿真：类型化信号连接（Real/Integer/Boolean）、
  FMI 3 参与者之间的时钟连线（源输出时钟脉冲触发目标输入时钟）、按连接
  自动推断信号类型、可选的代数环定点求解（`couple`）。
- 从已解压目录构建确定性的 `.fmu`（`package`）。
- 把受限的显式模型导出回源码 FMU（FMI 2/3）或实验性的 WASM 组件 FMU，
  支持 FMI 3 数组与按元素展开的稠密矩阵方程。
- 加载前校验 FMU 归档摘要（`--sha256`）、在崩溃隔离的子进程中运行命令
  （`--sandbox`）、检查 CLI 二进制可复现构建（`scripts/repro-build.mbtx`）。
- 以库的方式复用同一套代码：`MuVirus/fmi/src/{fmi,sim,backend/native}`。

## 安装

需要 [MoonBit 工具链](https://docs.moonbitlang.com) 和一个 C 编译器：
`moon` 会编译随包附带的 native shim。

```bash
moon add MuVirus/fmi
```

也可以直接从仓库使用：

```bash
git clone https://github.com/MuVirus/MoonFMI.git
cd MoonFMI
moon build --target native
```

构建产物位于 `_build/native/release/build/cmd/main/`；不单独构建时，用
`moon run cmd/main --target native -- --help` 也能运行。

## 最小示例

先下载示例与测试所用的 Reference-FMUs（BSD-2-Clause；校验和会与
`tests/data/manifest.json` 逐一核对）：

```bash
moon run tests/data/fetch-fmus.mbtx --target native
```

让小球模型运行三秒：

```bash
moon run cmd/main --target native -- simulate tests/data/.cache/fmi2/BouncingBall.fmu \
    --stop-time 3 --step-size 0.01 --output ball.csv
```

`ball.csv` 中即为 300 步的 `time,h,v`。

## 用法

只校验、查看模型描述，不执行 FMU：

```bash
moon run cmd/main --target native -- validate tests/data/.cache/fmi2/BouncingBall.fmu
moon run cmd/main --target native -- info tests/data/.cache/fmi2/BouncingBall.fmu
```

模型交换走同一个入口，FMI 3 会被自动识别：

```bash
moon run cmd/main --target native -- simulate tests/data/.cache/fmi2/VanDerPol.fmu \
    --interface me --solver rk4 --stop-time 5 --output vdp.csv
```

从已解压目录构建确定性的 `.fmu`：

```bash
moon run cmd/main --target native -- package build/MyModel --output MyModel.fmu
```

`moonfmi doctor` 检查本地环境，`moonfmi --help` 列出全部命令与退出码。
加 `--json` 可得到机器可读输出，其结构是带版本号的契约，见
[`docs/cli-json.md`](docs/cli-json.md)。

### 作为库使用

`src/` 下的包都是普通 MoonBit 包。构建时用 `--target native`，按需导入。
下面的示例还需要 `moonbitlang/x/fs` 提供文件操作；如果它还不是直接依赖，
先执行 `moon add moonbitlang/x`。

`moon.pkg` 中：

```moonbit
import {
  "MuVirus/fmi/src/backend/native" @native,
  "MuVirus/fmi/src/fmi" @fmi,
  "MuVirus/fmi/src/sim" @sim,
  "moonbitlang/core/env",
  "moonbitlang/x/fs",
}

supported_targets = "native"
```

在 `.mbt` 文件中运行一个联合仿真模型，并打印步数：

```moonbit nocheck
fn run_ball(fmu_path : String) -> Unit {
  let data = @fs.read_file_to_bytes(fmu_path) catch {
    _ => return println("cannot read " + fmu_path)
  }
  let host = @fmi.parse_host_platform(@native.host_platform_name()).unwrap()
  @fs.create_dir(".moonfmi-tmp") catch { _ => () }
  let work_dir = ".moonfmi-tmp/run-\{@env.now()}"
  let loaded = @native.load_fmi2_fmu(
    data,
    host~,
    temp_directory=work_dir,
  ) catch {
    _ => return println("load failed")
  }
  let config = @sim.CsConfig::new(
    start_time=0.0, stop_time=3.0, step_size=0.01, record=[1U, 2U],
  )
  let result = @sim.run_cs_simulation(loaded.instance(), config~) catch {
    _ => {
      loaded.dispose()
      return println("simulation failed")
    }
  }
  loaded.dispose()
  println("\{result.steps()} steps, \{result.series().length()} series")
}
```

`temp_directory` 必须是全新的空目录：加载器会把整个 FMU 解压到那里，
让动态库和资源都有真实路径。`dispose()` 负责释放实例、卸载动态库并删除
该目录。FMI 3 走同样的流程，只是换成 `load_fmi3_fmu`。

## 已知限制

- 模型交换（ME）的积分器只有定步长 Euler 与经典 RK4。MoonFMI 不是通用
  ME 求解器：刚性系统、大型 DAE 与自适应步长控制不在范围内（见
  [`docs/design/master-algorithm.md`](docs/design/master-algorithm.md)）。
- 多个 CS FMU 的耦合在库级（`MuVirus/fmi/src/sim`：参与者、连接、按拓扑
  序步进 + 常量外推、Discard 时的整网协同回滚、Integer/Boolean 信号连接、
  可选的 Jacobi 定点环求解——最小 SCC 环块 + 轮间状态回退）和
  `moonfmi couple 命令行均可用。未编译事件支持的 FMU（如语料中的
  Roberts 模型在 CS 下）经 loader 的回退以 `eventModeUsed = false`
  实例化并正常步进；intermediate-update 通道（步中回调与早退协商）
  已生效并有 MoonfmiClocks fixture 的端到端覆盖。环求解仅在捕获不可用
  时维持旧的叠加步进行为（已文档化的近似，见
  [`docs/design/coupling.md`](docs/design/coupling.md) §3.5/§5）。
- FMI 3 Scheduled Execution 支持固定、动态与 countdown 输入时钟、宿主
  触发时钟以及输出时钟级联，但不提供实时保证：priority 只决定同一时刻
  的激活顺序。
- 源码 FMU 导出器只生成受限的显式模型（连续状态、直通输出、参数与
  输入）；它不是 Modelica 编译器。FMI 3 数组变量支持按元素的方程与展开成
  逐元素求和的稠密矩阵乘法；IR 没有符号化的循环/求和构造。
- WebAssembly 后端为实验性：已验证最小 CS 组件与 LS-WASM 打包（见
  [`tests/fmu-wasm/README.md`](tests/fmu-wasm/README.md)），完整的
  LS-WASM world 与浏览器导入属于后续工作。`simulate --backend wasm`
  固定以退出码 4 结束；`validate`/`info` 会校验 LS-WASM manifest，但尚无
  任何 WASM 组件执行路径。
- `--sandbox` 只提供崩溃隔离与硬性看门狗：子进程里的 FMU 仍以宿主用户
  权限运行，它不是权限沙箱。
- FMU 线程的日志投递由 shim 内的进程级锁串行化，但 shim 不排队、不格式化
  消息：不对外部格式串执行 `vsnprintf`，4 KiB 截断，同步投递。

## 文档

- [`docs/AGENTS.md`](docs/AGENTS.md) —— 文档地图。
- [`docs/design/architecture.md`](docs/design/architecture.md) —— 包布局与
  设计决策。
- [`docs/roadmap/roadmap.md`](docs/roadmap/roadmap.md) —— 阶段划分与待办。
- [`docs/records/`](docs/records/README.md) —— 带日期、命令与证据的实施
  记录。

采用 [Apache-2.0](LICENSE) 许可。
