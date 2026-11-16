# MuVirus/MoonFMI

[English](README.md) | 简体中文

一个面向符合 FMI 标准的 FMU 的实验性 MoonBit 接口（支持 FMI 2.0.4 与
FMI 3.0.2，覆盖联合仿真 Co-Simulation 与模型交换 Model Exchange）。

## 快速上手（10 分钟）

1. 安装 MoonBit 并获取代码：

   ```bash
   # 工具链安装见 https://docs.moonbitlang.com
   git clone https://github.com/MuVirus/MoonFMI.git
   cd MoonFMI
   moon test --target native   # 110 个测试，应全部通过
   ```

2. 下载测试用 FMU（来自 Reference-FMUs，BSD-2-Clause 许可；一条命令即可，
   校验和与 `tests/data/manifest.json` 逐一核对）：

   ```bash
   moon run tests/data/fetch-fmus.mbtx --target native
   ```

3. 校验、查看信息、仿真 —— 三个日常命令：

   ```bash
   moon run cmd/main --target native -- validate tests/data/.cache/fmi2/BouncingBall.fmu
   # → 0 error(s), 0 warning(s)

   moon run cmd/main --target native -- info tests/data/.cache/fmi2/BouncingBall.fmu
   # → modelName: BouncingBall，接口、变量类型、支持平台、sha256

   moon run cmd/main --target native -- simulate tests/data/.cache/fmi2/BouncingBall.fmu \
       --stop-time 3 --step-size 0.01 --output ball.csv
   # → 300 步；ball.csv 中是 time,h,v 三列

   moon run cmd/main --target native -- simulate tests/data/.cache/fmi2/VanDerPol.fmu \
       --interface me --solver rk4 --stop-time 5 --output vdp.csv
   ```

   对 `tests/data/.cache/fmi3/` 下的 FMI 3 FMU 同样适用（`simulate`
   会自动检测版本）。需要机器可读输出时加 `--json` —— 其结构是带版本号
   的契约，见 [docs/cli-json.md](docs/cli-json.md)。

4. 从目录打包你自己的 FMU：

   ```bash
   moon run cmd/main --target native -- package build/MyModel --output MyModel.fmu
   # 确定性打包：相同输入 → 相同字节（输出中含 sha256）
   ```

提示：`moon build --target native` 会在
`_build/native/release/build/cmd/main/main.exe` 下生成独立可执行文件；
运行 `moonfmi --help` 查看完整命令集与退出码表。`moonfmi doctor`
可检查本地环境。

## 已知限制

- 模型交换（ME）的积分器只有定步长 Euler 与经典 RK4。MoonFMI
  **不是通用 ME 求解器**：刚性系统、大型 DAE 与自适应步长控制不在
  范围内，这类需求请使用外部求解器（见 `docs/design/master-algorithm.md`
  §4.1）。
- 每次运行只支持单个 FMU；多 FMU 耦合（连接、代数环）属于后续工作
  （见 `docs/design/master-algorithm.md` §8 路线图）。
- FMI 3 Scheduled Execution 目前仅有可行性说明文档，尚未实现。
- `package` 的输出由 MoonFMI 自己的读取器校验；建议再用 FMPy
  （`python -m fmpy <file>.fmu`）做一次外部校验。

## 目录结构

- `src/{xml,zip,schema}` —— 加固的 XML/ZIP 读取器、带类型的模型描述、
  语义规则 MD-001..MD-063；
- `src/fmi` —— FMU 容器层，`CsInstance`/`MeInstance` trait；
- `src/backend/native` —— FMI 2/3 动态库绑定（C shim）；
- `src/sim` —— CS 主控算法，以及带事件检测的 ME Euler/RK4 主控；
- `src/cli` —— `moonfmi` 命令行（入口在 `cmd/main`）；
- `docs/roadmap` —— 分阶段路线图与待办；`docs/design` —— 设计文档；
  `docs/records` —— 带日期的实现记录。
