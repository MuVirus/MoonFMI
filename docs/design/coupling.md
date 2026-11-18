# 耦合主算法(多 FMU 联合仿真)

> 状态:已实现(library 级 MVP,2026-11-18)。实现位于 `src/sim/coupling.mbt`,
> mock 测试 `src/sim/coupling_wbtest.mbt`,端到端测试
> `tests/integration/coupling_wbtest.mbt`。

## 1. 目标与边界

在此之前 MoonFMI 一次只跑一个 FMU(README「Known limits」)。本设计把联合
仿真的最小闭环放进 `sim` 包:多个 CS 参与者共享一个通信网格,按连接图
顺序步进,信号沿连接传播。

**MVP 边界(有意不做):**

- 只支持 Real 标量信号(与 `CsInstance` trait 的读写面一致);
- 常量外推(constant extrapolation):消费方在整个通信步内使用生产方在
  通信点读到的输出,不做高阶外推或迭代;
- **代数环不支持**:连接图成环(含自环)直接报 `Config` 错误,不做环打断
  (迭代/延迟一拍都不做,避免引入语义含糊);
- 参与者只借出(`CsInstance` 借用),加载与 `dispose()` 仍归调用方;
- CLI 不暴露 `couple` 命令(library-only),`--json` 契约不变。

## 2. 数据模型

- `CoupledParticipant`:参与者名(唯一)+ 借用的 `CsInstance` +
  `record`(每通信点记录的值引用,同时是"可被连接引用的输出集合");
- `Coupling`:有向边 `(from, out_vr) → (to, in_vr)`;
- `CoupledConfig`:网格参数 + 参与者 + 连接 + 可选墙钟 deadline。

结果复用 `SimulationResult`:`series` 按参与者声明顺序拼接各自的
`record` 列表(调用方自己知道布局)。

## 3. 主算法

1. **校验**:网格参数;参与者名唯一;连接端点存在;自环/环 → `Config`
   错误(环检测用 Kahn 拓扑排序失败判定)。
2. **拓扑序**:Kahn 算法,按声明顺序稳定(多个可执行参与者时取最靠前的)。
3. **初始化**:按声明顺序对每个参与者 `setup_experiment` + `initialize`;
   读一遍所有 `record` 值引用作为初始输出;按拓扑序把初始输出写入下游
   输入;记录 t0 行(记录时重读,直接馈通模型因此能反映已写入的初始输入)。
4. **每通信步**(t → t+h,末步截断到 stop_time):
   - 按拓扑序遍历参与者:先写它的输入(取生产方本步已更新的输出 —— 常量
     外推),再 `step(t, h)`,再读 `record` 更新输出快照;
   - 因为按拓扑序执行,消费方看到的是**同一通信点**的生产方输出——无
     一拍滞后;
   - deadline 检查与单 FMU 主算法一致。
5. **收尾**:按声明顺序对每个参与者 `finish()`。

`Discard` 的处理沿用单 FMU 主算法(`try_step`/回滚)的语义:参与者的
`step` 失败即整体失败;回滚只覆盖单个参与者,不做多参与者协同回滚
(记录在遗留问题)。

## 4. 验收

- mock:链式传播无滞后、菱形图拓扑序、环/自环/重名/未知端点/不可观测
  源拒绝、末步截断(`src/sim/coupling_wbtest.mbt`);
- 端到端:导出的 `MoonfmiDahlquist`(生成器)+ 新导出的 `MoonfmiGain`
  (y = k·u,k=2 直馈)经 clang 编译、加载、耦合,记录值与解析解
  `y_n = 2·(1-h)^n` 逐点一致(`tests/integration/coupling_wbtest.mbt`)。

## 5. 遗留问题

- 多参与者协同回滚(Discard 时按拓扑逆序整体回退)未实现;
- Integer/Boolean 信号连接(等 `CsInstance` 类型化读写面扩展);
- 代数环求解(iterative coupling)与高阶外推;
- CLI/JSON 输出暴露耦合运行。
