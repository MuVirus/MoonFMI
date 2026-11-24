# 快速上手：跑通第一个 FMU

## 适用场景

你拿到了一个 FMU（或想用 Reference-FMUs 样品试工具），要在几分钟内完成
校验、信息查看与第一次仿真。设计取舍、算法细节不在本篇——主算法见
[`../design/master-algorithm.md`](../design/master-algorithm.md)。

## 前置条件

- MoonBit 工具链与一个 C 编译器（`moon` 会编译自带的原生 shim）。
- 本地检出仓库并完成一次构建：`moon build --target native`。
- 测试语料（示例命令都基于它，BSD-2-Clause，SHA-256 对清单校验）：

  ```bash
  moon run tests/data/fetch-fmus.mbtx --target native
  ```

## 完成标准

- `validate` 对一个 FMU 报告 0 诊断；
- `simulate` 产出一个 CSV，行数与步数一致；
- `simulate --json` 输出以 `moonfmi.simulate/v1` 开头的机器可读结果。

## 步骤

1. 校验与查看模型描述（`--json` 得到版本化 JSON 契约，字段只增不改）：

   ```bash
   moon run cmd/main --target native -- validate tests/data/.cache/fmi2/BouncingBall.fmu
   moon run cmd/main --target native -- info tests/data/.cache/fmi2/BouncingBall.fmu --json
   ```

2. 跑 Co-Simulation：三秒、步长 0.01，输出 CSV（`time,h,v` 共 300 步）：

   ```bash
   moon run cmd/main --target native -- simulate tests/data/.cache/fmi2/BouncingBall.fmu \
       --stop-time 3 --step-size 0.01 --output ball.csv
   ```

3. 跑 Model Exchange（同一入口，FMI 3 自动识别）：

   ```bash
   moon run cmd/main --target native -- simulate tests/data/.cache/fmi2/VanDerPol.fmu \
       --interface me --solver rk4 --stop-time 5 --output vdp.csv
   ```

4. 仿真前置输入与参数（按变量类型解析，先于初始化写入）：

   ```bash
   moon run cmd/main --target native -- simulate tests/data/.cache/fmi3/Feedthrough.fmu \
       --set Float64_continuous_input=0.5 --set Int8_input=-7 --output ft.csv
   ```

5. 装成库使用：`moon add MuVirus/fmi` 后按 README「Use as a library」一节
   import `src/{fmi,sim,backend/native}`；脱离仓库目录时用已发布的
   mooncakes 版本。

6. 看可运行示例：仓库根目录的 [`../../examples/`](../../examples/README.md)
   有五个可执行示例（校验模型描述、CS 仿真、ME 仿真、多 FMU 耦合、导出
   源码 FMU），外加一份 `moonfmi` 命令行速查表。示例只依赖 `src/` 下的
   公开 API，可以直接抄进自己的工程：

   ```bash
   moon run examples/simulate-cs --target native -- \
       tests/data/.cache/fmi2/BouncingBall.fmu ball.csv
   ```

## 常见坑与下一步

- `preferred_target` 是 native（2026-11-24 起）：`moon run cmd/main` 默认就走
  native，`src/cli` 会参与编译；CI 里仍然显式写 `--target native`，避免以后
  规范后端再变时踩坑。
- `simulate` 加载的 FMU 解包到临时目录，`dispose` 时删除；目录必须为空。
- 退出码、JSON 契约字段见 [`../cli-json.md`](../cli-json.md)——两个数字
  是契约的一部分，脚本不要猜。
- FMI 3 数组输出在 CSV 里按 `name[i]` 展开为多列；时钟模型
  （Clocks.fmu）只有 Scheduled Execution 接口，用 `--interface se` 跑。
- 下一步：多 FMU 耦合用 `couple`（信号连接与跨 FMU 时钟连线见
  [`../design/coupling.md`](../design/coupling.md)）；把模型导出回 FMU 用
  `package`/导出器（见 [`../design/exporter.md`](../design/exporter.md)）。
