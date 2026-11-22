# 主算法设计

> 状态：设计提案。主算法是“调度器 + 数据流”，不是求解器本身；ME 的数值积分能力有限，复杂模型应接外部求解器。

---

## 1. 目标

主算法负责把导入器暴露的 FMI 操作组织成一次可复现的仿真：

- 初始化；
- 在每个通信点设置输入、推进时间、读取输出；
- 处理事件与离散状态更新；
- 处理错误、回滚和提前终止；
- 记录结果。

它只依赖 [`architecture.md`](architecture.md) 中的 `Instance` 抽象，不直接调用动态库。

---

## 2. 公共配置

```moonbit
pub struct SimulationConfig {
  start_time : Double
  stop_time : Double
  communication_step : Double
  tolerance : Double?
  solver : SolverChoice
  record : RecordConfig
  input_source : InputSource?
  max_event_iterations : Int
  max_steps : UInt64?
  fail_on_warning : Bool
}

pub enum SolverChoice {
  FixedStep(step : Double)
  Adaptive(initial_step : Double, min_step : Double, max_step : Double)
  External(name : String)       // 后续：外部求解器
}
```

约束：

- `stop_time > start_time`；
- `communication_step > 0`，且不能大到跨越已知事件而不检查（由 FMU/模型决定）；
- `max_event_iterations` 默认 100，防止事件震荡死循环；
- `max_steps` 防止无限循环；
- 时间用 `Double`，但比较时使用容差，避免浮点累积误差。

### 2.1 时间网格

CS 的主时间网格是通信点：

```text
t0 ── h ── t1 ── h ── t2 ... ── stop
```

- 若 `canHandleVariableCommunicationStepSize = true`，允许在事件/早退后改变步长。
- 若为 `false`，必须使用固定通信步长；步长优先取配置，其次取 `DefaultExperiment`，最后报错要求用户指定。
- 最后一个步长截断到 `stop_time`。

ME 的时间网格由积分器决定，通信点只用于记录/外部输入更新。

---

## 3. CS 主循环

### 3.1 初始化

```text
instantiate
setDebugLogging（可选）
setupExperiment(start, stop?, tolerance?)
enterInitializationMode
设置初始输入/参数
exitInitializationMode
读取初始输出
```

注意：

- `fmi2SetupExperiment` 的 `stopTimeDefined` 与 `toleranceDefined` 必须与配置一致。
- 初始输入必须在 `exitInitializationMode` 前设置，否则 FMU 可能使用 `start` 值。
- 初始化失败不能被当成“从 0 开始”继续。

### 3.2 单步

```text
setInputs(t_k)
doStep(t_k, h)
if status == Discard: 回滚/报错
if terminateSimulation: 结束
if eventHandlingNeeded: 进入事件处理
getOutputs(t_{k+1})
record(t_{k+1})
t_k = t_{k+1}
```

伪代码：

```moonbit
pub fn simulate_cs(instance : &Instance, cfg : SimulationConfig) -> SimulationResult raise FmiError {
  let mut t = cfg.start_time
  let mut step_count = 0UL
  instance.enter_initialization(cfg)?
  record_initial(instance, t)
  while t < cfg.stop_time {
    if let Some(max) = cfg.max_steps {
      if step_count >= max { raise FmiError::config("max_steps exceeded") }
    }
    let h = next_step(t, cfg)
    instance.set_inputs(t, input_source)?
    let r = instance.do_step(t, h)?
    match r.status {
      Discard => handle_discard(instance, &r, t)?
      Error | Fatal => raise FmiError::fmi_call(r)
      _ => ()
    }
    if r.terminate_simulation { break }
    if r.event_handling_needed {
      handle_cs_event(instance, t + h, cfg)?
    }
    t = t + h
    record_outputs(instance, t)
    step_count = step_count + 1
  }
  instance.terminate()?
  result
}
```

### 3.3 事件处理（版本差异）

**FMI 2 CS 没有主算法可见的事件模式。** 事件由 FMU 内部处理；`fmi2EnterEventMode` / `fmi2NewDiscreteStates` 属于 ME。主算法只检查：

- `fmi2GetBooleanStatus(c, fmi2Terminated, ...)` 是否终止；
- `fmi2GetStatus(c, fmi2DoStepStatus, ...)` / `fmi2GetRealStatus(c, fmi2LastSuccessfulTime, ...)` 处理异步/丢弃；
- 状态码与日志。

**FMI 3 CS** 由 `eventHandlingNeeded` 触发：

```text
enterEventMode
loop:
  updateDiscreteStates
  if not discreteStatesNeedUpdate: break
  if iterations > max: error
enterStepMode
```

FMI 3 调用：

- `fmi3EnterEventMode`
- `fmi3UpdateDiscreteStates(...)`
- `fmi3EnterStepMode`

事件循环中要：

- 重新读取输出；
- 若 `valuesOfContinuousStatesChanged` / `nominalsOfContinuousStatesChanged`，更新主算法保存的状态/标称值；
- 若 `nextEventTimeDefined`，把时间推进到该事件时间之前，不跨越事件；
- 处理 `terminateSimulation`。

`StepResult.event_handling_needed` 在 FMI 2 后端恒为 `false`；不要用它判断 FMI 2 的事件。

### 3.4 早退与中间更新

FMI 3 CS 可能通过 `earlyReturn` 提前返回：

- `lastSuccessfulTime` 是 FMU 确认已推进到的时间；
- 主算法把 `t` 设为 `lastSuccessfulTime`，而不是盲目接受 `t + h`；
- 若 `canReturnEarlyAfterIntermediateUpdate`，中间更新回调可能要求设置/读取变量，必须遵守回调中的允许标志；
- 早退后剩余步长在下一个循环重新计算。

### 3.5 Discard 与回滚

`Discard` 表示该步被丢弃，FMU 状态可能处于不确定位置。**已实现**（C-11，
2026-11-18）的策略：

1. 若 FMU 支持 `canGetAndSetFMUstate`（`C-09` 原语可用）：在每个通信点前
   `begin_rollback_point` 捕获状态，Discard 后 `rollback` 恢复，步长减半重试；
   成功后 `commit_rollback_point` 释放。重试上限 5 次，减半到 `1e-12` 以下
   报错终止。
2. 若不支持状态捕获：FMI 3 的 `Discard` 携带 `lastSuccessfulTime`，主算法
   从确认时刻继续（下一个网格点用完整步长）；FMI 2 没有该报告，终止并给出
   明确诊断（不把 Discard 当成成功继续）。
3. 实现位置：`CsInstance` trait 的 `try_step` 返回 FMU 实际到达的时刻，
   `Discarded` 错误变体携带确认进度；回滚表面为
   `supports_state_capture`/`begin_rollback_point`/`rollback`/
   `commit_rollback_point` 四个方法，默认实现为"不支持"。FMI 2/FMI 3 后端
   均已覆盖；实例释放时会兜底释放未提交的捕获状态。
4. FMI 3 细节：回滚点武装期间 `fmi3DoStep` 以
   `noSetFMUStatePriorToCurrentPoint = fmi3False` 调用，因为主算法可能在本步
   之后调用 `fmi3SetFMUState` 回滚。

重试上限 5 次，避免死循环。

---

## 4. ME 主循环

### 4.1 能力边界

ME 要求主算法提供数值积分、事件检测和状态管理。MoonFMI 提供：

- 显式 Euler（仅用于冒烟/教学，不推荐生产）；
- 经典 RK4（固定步长）；
- RKF45（Fehlberg 4(5)）嵌入对的自适应步长积分，开启方式见 §4.6；
- 后续：稠密输出、外部 CVODE/IDA 适配。

**不要宣称 MoonFMI 是通用 ME 求解器。** 对刚性系统、DAE、大量事件，建议导出 FMU 到成熟工具或接外部求解器。

### 4.6 RKF45 自适应步长（ME）

当 `MeConfig.adaptive = true` 时，主算法用 Fehlberg 的 RKF4(5) 嵌入对替代固定步长的 `solver`（`solver` 仍用于事件定位的二分法积分）：

- 系数表（出处：E. Fehlberg, "Low-Order Classical Runge-Kutta Formulas with Stepsize Control", NASA TR R-287, 1969）：节点 c = [0, 1/4, 3/8, 12/13, 1, 1/2]；四阶权重 b4 = [25/216, 0, 1408/2565, 2197/4104, -1/5, 0]；五阶权重 b5 = [16/135, 0, 6656/12825, 28561/56430, -9/50, 2/55]。每步推进五阶解 `y5`，并以 `|y5 - y4|` 估计局部截断误差。
- 容差语义：第 `i` 个状态的步被接受当且仅当
  `|y5[i] - y4[i]| <= tolerance * (|nominals[i]| + |y5[i]|)` 对全部状态成立。
  标称值（`fmi2GetNominalsOfContinuousStates`）保护近零态；若分母为 0 且差分非 0，步被拒绝，直至最小步长后报错。
- 步长控制：接受后步长按 `[1.5, 2]` 区间内的因子放大（误差越小越接近 2），受 `max_step` 上限（`None` 为不限制，仅受剩余区间限制）；拒绝后步长减半重试。`step_size` 作为初始步长，下限为 `step_size * 1e-6`，低于此即报错，避免死循环。
- 事件语义：自适应步不得跨越事件。在每一接受步内，若事件指示器在 `(t, t + h]` 上符号变化，用二分法定位事件时间，仅积分到事件点，再按常规流程 `enter_event_mode` / `newDiscreteStates` / `enter_continuous_time_mode` 处理，然后从事件时间继续下一自适应步；连续事件不推进时间时超过 `max_step_event_count` 即报错。弹跳（BouncingBall）类事件的次数与"不穿地"不变量与固定步长路径一致。
- 记录差异：固定步长在通信网格点记录；自适应步长在**每一接受步的实际时刻**记录，因此 `SimulationResult.times` 是不规则网格，`steps` 为接受步数，最后一步仍截断到 `stop_time`。数值结果（终态、事件次数）与固定路径等价，但记录时刻不同。
- 安全：每步检查导数/状态的有限性，NaN 或 Inf 直接报错而非静默发散。

稠密输出和外部 CVODE/IDA 适配仍属后续工作。

### 4.2 初始化

```text
instantiate(ME)
setupExperiment
enterInitializationMode
exitInitializationMode
enterContinuousTimeMode
```

初始化后：

- `getContinuousStates` 得到 `x0`；
- `getNominalsOfContinuousStates` 得到标称值（用于误差控制）；
- 初始事件：进入 EventMode，迭代离散状态，直到稳定。

### 4.3 连续步

```text
setTime(t)
setContinuousStates(x)
getDerivatives(k1)
... RK4 ...
completedIntegratorStep(...)
if enterEventMode: handle event
```

RK4 示意：

```text
k1 = f(t, x)
k2 = f(t + h/2, x + h/2 * k1)
k3 = f(t + h/2, x + h/2 * k2)
k4 = f(t + h,   x + h   * k3)
x_next = x + h/6 * (k1 + 2k2 + 2k3 + k4)
```

每次求值都需要：

- `setTime`；
- `setContinuousStates`；
- `getDerivatives`；
- 可能还要处理 `fmi2GetEventIndicators`。

### 4.4 事件检测

1. 在步长两端读取事件指示器 `g(t)`、`g(t+h)`。
2. 若符号变化，使用二分法/ Brent 法定位根，得到事件时间 `t_e`。
3. 把状态积分到 `t_e`，进入 EventMode。
4. `newDiscreteStates` / `updateDiscreteStates` 迭代。
5. 若连续状态被 reinit，读取新状态；若标称值变化，更新。
6. 返回 ContinuousTimeMode，继续。

边界情况：

- 指示器恰好为 0；
- 多个事件同时发生；
- 事件后立即再次触发（chattering）；
- 事件时间与停止时间重合；
- FMU 声明 `nextEventTime`（FMI 3）时优先使用。

### 4.5 状态与步长

- 保存 `x`、`dx`、时间、事件指示器；
- 自适应步长时用局部误差估计，标称值归一化；
- 拒绝步长后恢复 FMU 状态（若支持），否则重新 `setTime` + `setContinuousStates`；
- 不在事件点之间跨越 `nextEventTime`。

---

## 5. SE 主循环（FMI 3）

Scheduled Execution 把模型划分为由时钟驱动的分区。主算法职责更接近“调度器”。

### 5.1 已实现语义（`src/sim/se.mbt`）

1. 加载时从模型描述收集输入 Clock 的 `intervalVariability`、`intervalDecimal`、`shiftDecimal`、`priority`（`SeClock`，见 `fmu_loader.mbt`）；输出 Clock 单独记录，只观察不驱动。
2. 调度器在 `start + shift + k*period` 激活 `constant` 时钟；`countdown`/动态时钟每轮通过 `fmi3GetIntervalDecimal` 轮询，`Changed` 时按 `t + interval` 重新定时，`NotYetKnown` 时跳过。
3. 到点调用 `fmi3ActivateModelPartition(clockReference, activationTime)`。
4. 同一时刻到期的多个分区按 `priority` 升序执行（值小者优先，符合 3.0.2 §2.4.2“Smaller values signal higher priorities”）。
5. `triggered` 输入时钟由宿主策略决定：`SeConfig::trigger` 回调在给定仿真时刻返回要触发的时钟值引用；`trigger_all_each_step` 是“每步全触发”的确定性默认策略。
6. 每轮激活后轮询输出 Clock（`fmi3GetClock`）；Reference 实现读即清零，因此 `SimulationResult.events` 记录分区激活次数，`clock_update_count` 单独暴露 FMU 的 `clockUpdate` 通知数。
7. 分区可能激活其它时钟（Clocks 参考模型在 t=4 由分区 1 武装 countdown 时钟），调度器在同一网格点内做多轮结算，`max_rounds` 上限防死循环。

### 5.2 约束与边界

- 无实时性保证：`priority` 只决定同刻激活顺序，不映射到 OS 优先级；
- 输入时钟必须声明 `priority`（SE FMU 里缺失由 MD-037 报错）；输出时钟不得声明（MD-036）；
- `fmi3SetClock` 支持显式激活/去激活（`SeInstance::set_clock`），CLI 暂不暴露脚本化触发通道；
- 与 CS/ME 的变量交换一致性仍由模型侧保证，调度器只负责按时激活；
- 记录器支持 Float64 标量与 Float64 数组输出（数组按元素拆 `name[i]` 列）；Int32 等其它类型不在记录器内（Clocks 的计数器是 Int32，因此 CLI JSON 的 `outputs` 为空，属已知限制，测试用类型化通道读取）。

### 5.3 CS/ME 复用同一调度（0.8.1 引入，0.8.2 有真 FMU 证据）

激活轮次提炼为 `run_clock_rounds`（`src/sim/clocks.mbt`），基于闭包结构的
`ClockScheduling`。CS 主算法在每个通信点前跑轮次并观察输出时钟；ME 在
初始事件与每次事件结算后（仍在事件模式内）跑轮次——ME 的 constant 时钟
按“事件点追及”语义补跑错过的刻（每网格点轮次属于 SE/CS 语义）。
CS 的 `fmi3DoStep` 同时消费 `nextEventTime`，不跨越 FMU 声明的时间事件。
带时钟的 CS/ME-only FMU 导出的 `fmi3GetIntervalDecimal` /
`fmi3ActivateModelPartition` 独立于 Scheduled Execution 解析。

验证分两层：mock 白盒（`src/sim/clocks_wbtest.mbt`）覆盖轮次语义，自建
fixture MoonfmiClocks（`tests/clock-fmu/`，CS+ME 接口 + 输入/输出时钟 +
intermediate-update 早退协商）经 `tests/integration/clock_fmu_wbtest.mbt`
提供真 FMU 端到端证据——CS 网格激活时间线、ME 事件模式轮次、couple 跨
FMU 时钟连线。

### 5.4 验收

`tests/integration/se_wbtest.mbt`：
- Reference-FMUs `Clocks.fmu`（SE-only；constant/triggered/countdown 输入时钟 + 输出时钟）驱动 10 s：分区激活 15 次（inClock1 10 + inClock2 4 + inClock3 1），计数器 10/4/1/15 与模型描述中的参考时间线一致，`clock_update` 通知 4 次；
- mock 单测：同刻激活按 priority 排序、countdown 级联、非法配置拒绝。

CLI：`moonfmi simulate <fmu> --interface se --start-time 0 --stop-time 10 --step-size 1`。

---

## 6. 输入与输出

### 6.1 输入源

```moonbit
pub trait InputSource {
  fn value_at(self, name : String, time : Double) -> FmiValue?
}
```

内置：

- 常量；
- 线性插值表；
- 回调函数；
- CSV 列。

规则：

- 只对 `causality="input"` 的变量写值；
- 类型必须匹配，整数做范围检查；
- 输入时间超出范围时明确报错或按配置保持边界值；
- CS 的输入在通信点设置；若 FMU 支持输入插值，可按 `maxOutputDerivativeOrder` 提供导数，首版可只做零阶保持。

### 6.2 输出

- 默认记录所有 `causality="output"` 变量；
- 可配置记录内部变量（调试）；
- 按类型批量读取；
- 字符串/二进制结果需要明确序列化格式（CSV 中用 base64 或十六进制）。

### 6.3 结果模型

```moonbit
pub struct SimulationResult {
  time : Array[Double]
  variables : Map[String, Array[FmiValue]]
  events : Array[EventRecord]
  stats : SimulationStats
  warnings : Array[String]
}
```

记录器与仿真解耦，支持内存、CSV、回调三种 sink。

---

## 7. 错误策略

| 情况 | 默认行为 | 可配置 |
| --- | --- | --- |
| `Warning` | 记录并继续 | `fail_on_warning` |
| `Discard` | 回滚/重试，失败则终止 | 重试次数 |
| `Error` | 终止，保留部分结果 | 是否输出部分结果 |
| `Fatal` | 立即终止并释放实例 | — |
| 事件迭代超限 | 终止 | 上限 |
| 步数超限 | 终止 | 上限 |
| 输入类型不匹配 | 终止 | 严格/宽松 |
| 输出读取失败 | 终止 | 跳过该变量（不推荐） |

错误对象必须包含：时间、步长、FMU 状态码、最后成功时间、事件迭代次数、FMU 日志尾部。

---

## 8. 确定性与可复现性

- 相同 FMU、配置、输入、平台 → 相同结果（浮点运算顺序固定）。
- 不依赖哈希表遍历顺序；变量按模型描述顺序或显式排序。
- 记录时间、步长、事件时间时使用统一格式。
- 结果文件写入元数据：FMU 校验和、平台、FMI 版本、MoonFMI 版本、配置。
- 并行执行多个 FMU 时，每个实例独立，结果按确定顺序合并。

---

## 9. 性能

- 批量 get/set，避免逐变量跨 ABI。
- 预分配输出缓冲区，复用数组。
- 结果记录可选缓冲，避免每步同步写盘。
- ME 的导数调用是热点；缓存变量引用，避免按名字查找。
- 不在主循环中做字符串拼接/日志格式化，除非日志级别开启。
- 对大模型（上万变量）使用索引数组，不用 `Map` 做每步查找。

---

## 10. 测试

### 10.1 单元

- 时间网格：固定步长、最后一步截断、事件时间对齐；
- 事件迭代上限；
- Discard 重试；
- 输入插值边界；
- 结果记录顺序；
- 浮点容差比较。

### 10.2 集成

- FMI 2 CS `BouncingBall`：事件、弹跳、停止；
- FMI 2 CS `Dahlquist`：固定步长与解析解对比；
- FMI 2 ME `VanDerPol`：RK4 与参考轨迹对比；
- FMI 3 CS：事件模式、早退、二进制/字符串变量；
- FMI 3 SE：固定周期时钟的最小模型。

### 10.3 交叉检查

与 FMPy / OpenModelica 对同一 FMU、同一输入、同一通信步长比较：

- 时间点一致；
- 输出在容差内；
- 事件次数/时间接近；
- 差异要能解释（求解器、步长、事件定位）。

---

## 11. 相关文档

- 导入器：[`importer.md`](importer.md)
- ABI：[`ffi-and-abi.md`](ffi-and-abi.md)
- CLI 与测试：[`cli-and-testing.md`](cli-and-testing.md)
- FMPy 主算法参考：[`../research/fmpy.md`](../research/fmpy.md)
