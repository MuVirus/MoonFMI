# 耦合主算法(多 FMU 联合仿真)

> 状态:已实现(library 级 MVP,2026-11-18;C-20 follow-up 增加协同回滚、
> 类型化信号连接与代数环定点求解;2026-11-18 晚些时候 `moonfmi couple`
> 命令行落地,2026-11-19 补齐信号类型推断、环求解旗标与端到端测试)。
> 实现位于 `src/sim/coupling.mbt` 与 `src/cli/cli.mbt`(couple 命令),
> mock 测试 `src/sim/coupling_wbtest.mbt`,端到端测试
> `tests/integration/coupling_wbtest.mbt` 与 `couple_cli_wbtest.mbt`。

## 1. 目标与边界

在此之前 MoonFMI 一次只跑一个 FMU(README「Known limits」)。本设计把联合
仿真的最小闭环放进 `sim` 包:多个 CS 参与者共享一个通信网格,按连接图
顺序步进,信号沿连接传播。

**边界(当前状态):**

- Real 标量信号为主;Integer/Boolean 信号通过连接上的 `signal~` 可选参数
  按连接启用(默认 `Real`),走 `CsInstance` 的类型化读写面;
- 常量外推(constant extrapolation):消费方在整个通信步内使用生产方在
  通信点读到的输出,不做高阶外推;
- **代数环默认拒绝**;`CoupledConfig::max_loop_iterations = Some(n)` 开启后,
  用 Jacobi 定点迭代求解(简单实现:Kahn 未放置集合整体作为一个块,见 §3.5);
  CLI 侧通过 `--loop-iterations N` / `--loop-tolerance T` 暴露;
- 参与者只借出(`CsInstance` 借用),加载与 `dispose()` 仍归调用方;
- CLI 通过 `moonfmi couple` 暴露:`--connect p.var=q.var` 按生产者声明类型
  自动推断信号类型并校验两端一致,Real/Integer/Boolean 均可连接。

## 2. 数据模型

- `CoupledParticipant`:参与者名(唯一)+ 借用的 `CsInstance` +
  `record`(每通信点记录的 Real 值引用,同时是"可被 Real 连接引用的输出
  集合";Integer/Boolean 连接直接经类型化读观测输出,不要求在 `record` 里);
- `Coupling`:有向边 `(from, out_vr) → (to, in_vr)` + `signal`(信号类型,
  默认 `Real`);
- `SignalType`:`Real | Integer | Boolean`;
- `CoupledConfig`:网格参数 + 参与者 + 连接 + 可选墙钟 deadline +
  `max_loop_iterations`(默认 `None` = 拒绝环)+ `loop_tolerance`(默认
  1e-9)。

结果复用 `SimulationResult`:`series` 按参与者声明顺序拼接各自的
`record` 列表(调用方自己知道布局;`record` 仍是 Real 记录面)。

## 3. 主算法

### 3.1 校验与调度

1. 网格参数(`stop_time > start_time`、`step_size > 0`);
2. 环求解参数:`max_loop_iterations` 为 `Some(n)` 时必须 `n > 0`;
   `loop_tolerance` 不得为负;
3. 参与者名唯一;连接端点存在;
4. **自连接**:`max_loop_iterations = None` 时直接报 `Config`(algebraic
   loop);开启环求解后允许——它成为单成员环块,由定点迭代求解;
5. **同一输出被不同信号类型的连接引用** → `Config`(一个变量只有一种
   类型,混用是配置错误);
6. **拓扑调度**:Kahn 算法,按声明顺序稳定。调度单元是
   `Single(参与者)`;Kahn 停滞(存在未放置者)时:
   - `max_loop_iterations = None`(默认)→ 报 `Config` 错误(维持原行为);
   - `Some(n)` → 不报错,把**全部未放置参与者**作为一个 `LoopBlock`
     追加到调度尾部(见 §3.5 的方案与限制)。

### 3.2 初始化

按声明顺序对每个参与者 `setup_experiment` + `initialize`;读一遍所有
`record` 值引用作为 Real 输出快照,再按连接表把 Integer/Boolean 连接的
源输出经类型化读入对应快照;按调度序把初始输出写入下游输入(**环块在
t0 不做定点求解**——t0 不步进,没有迭代对象,初始输出按常量外推原样
传播);记录 t0 行(记录时重读,直接馈通模型因此能反映已写入的初始
输入)。

### 3.3 每通信步(基本流)

`t → t+h`(末步截断到 `stop_time`),按调度序执行:

- `Single(p)`:写 `p` 的输入(取生产方本步已更新的输出快照——常量外推)
  → `p` 步进 → 重读 `p` 的 `record` 与被连接引用的类型化输出,更新快照;
- 因为按拓扑序执行,消费方看到的是**同一通信点**的生产方输出——无
  一拍滞后;
- `LoopBlock` 的执行见 §3.5;
- deadline 检查与单 FMU 主算法一致。

### 3.4 协同回滚(Discard 处理)

**切换条件:当且仅当所有参与者的 `supports_state_capture()` 都为 true**
时,运行进入协同回滚模式;只要有一个参与者不支持捕获,就保持原行为
(参与者按各自 backend 的 `step` 语义处理 Discard——FMI 2 报
`FmiCall`、FMI 3 静默吞掉——没有任何重试,`Discard` 即整体失败)。

协同模式(自动启用,无需配置项)下每个网格点:

1. 按调度序对所有参与者 `begin_rollback_point`(每个重试尝试各一次);
2. 整个网格点通过 `try_step` 执行(使 Discard 以 `Discarded` 错误浮出,
   而不是由单个 backend 自行反应);
3. 任一参与者 Discard → 按**调度逆序**对所有参与者 `rollback`,**整个
   网格步长减半**并重试——协同模式下不对单个参与者做局部减半;重试
   上限复用单 FMU 主算法的 `max_discard_retries`(5 次)与
   `min_retry_step` 下限;成功的减半点之后,后续网格点恢复完整步长
   (与单 FMU 主算法一致);
4. 全部成功 → 按调度序对所有参与者 `commit_rollback_point`;
5. 其他错误(非 Discard)→ 释放所有已武装的捕获点(忽略 commit 错误)
   后原样上抛,运行中止。

与单参与者重试逻辑的关系:单 FMU 主算法(`run_cs_simulation`)在捕获
可用时对**该参与者自己**减半重试;协同模式覆盖的是**整网**,切换条件
就是上面的全量捕获检查。两种模式互斥,不存在"部分协同"。

### 3.5 代数环定点求解(可选)

`CoupledConfig::new(max_loop_iterations~ : Int? = None,
loop_tolerance~ : Double = 1e-9)`。

`Some(n)` 且 Kahn 停滞时,环块按 Jacobi 定点迭代求解。每个通信点:

```
重复(至多 n 次):
  1. 写入所有块成员的输入(块外生产者的当前输出 + 块内成员上一轮输出);
  2. 块内成员按当前输入依次步进,重读各自被连接引用的输出;
  3. 残差 = 各 watched 输出分量两次迭代间的绝对差的最大值
     (Real 取 Real 快照,Int32/Bool 数值化后比较);
  残差 ≤ loop_tolerance → 收敛;
  已迭代 n 次仍未收敛 → Config 错误(带迭代数与最后残差)。
```

- **环成员提取方案(简单方案)**:把 Kahn 未放置的参与者**全部**视为
  一个块。限制:该集合是真环成员 ∪ 环的(传递)下游消费者,不是最小
  强连通分量——块偏大意味着每轮多做步进,但迭代语义不变(下游成员
  的输出不回流进环);连接图保证块内成员的连接目标都在块内(Kahn 已
  放置者不可能依赖未放置者),因此残差只需覆盖块成员被连接引用的输出;
- **残差范围**:仅"被连接引用"的输出分量参与残差;只被 `record` 记录、
  未进连接的时变输出不会造成虚假不收敛;
- **t0 不求解**(见 §3.2);
- **迭代语义限制**:每轮迭代对真实 FMU 重复调用 `doStep(t, h)` 而不在
  轮间回退 FMU 状态——对真实 CS FMU 这是未定义行为(mock 无状态所以
  测试可行)。约束收敛的直馈环通常 1~2 轮即停,但严谨做法(捕获可用
  时在轮间 rollback)记入 §5 遗留。
- `max_loop_iterations = None`(默认)时环/自环维持拒绝,`loop_tolerance`
  不生效。

### 3.6 类型化信号连接(Integer/Boolean)

`Coupling::new(..., signal~ : SignalType = Real)`,按连接选择读写面:

- `Real`(默认):写输入用 `write_real`,值取生产方 `record` 快照——
  **Real 连接的源 vr 必须在生产方 `record` 列表里**,否则 `Config`
  (不可观测);
- `Integer`/`Boolean`:写输入用 `write_integer`/`write_boolean`(Int32 /
  Bool),值取生产方的类型化输出快照(初始化与每步后经
  `read_integer`/`read_boolean` 读得);源 vr **不要求**在 `record` 里
  (`record` 是 Real 记录面,混用会在真实 FMU 上以读错类型失败);
- 连接两端类型必须一致是**调用方的约定**;消费者输入变量的实际类型
  无法静态检查,运行时类型不匹配由 FMU 自己报错(如 FMI 3 的
  capability 检查、FMI 2 的状态码)。

### 3.7 收尾

按声明顺序对每个参与者 `finish()`。

## 4. 验收

- mock(`src/sim/coupling_wbtest.mbt`):链式传播无滞后、菱形图拓扑序、
  环/自环/重名/未知端点/不可观测源拒绝、末步截断;协同回滚(双捕获
  mock 一个中途 Discard → 整网减半重试 + 双方 rollback 各一次;单捕获
  → 协同关闭、捕获面零调用);Integer/Boolean 连接 roundtrip(经类型化
  面,Real 泄漏可见);环定点求解收敛(双直馈 mock,收敛到不动点)、
  不收敛报错(带迭代数与残差)、`None` 时环仍拒绝、自连接在开启求解后
  可解;
- 端到端:导出的 `MoonfmiDahlquist`(生成器)+ 新导出的 `MoonfmiGain`
  (y = k·u,k=2 直馈)经 clang 编译、加载、耦合,记录值与解析解
  `y_n = 2·(1-h)^n` 逐点一致(`tests/integration/coupling_wbtest.mbt`;
  导出的 FMU 声明 `canGetAndSetFMUstate=false`,端到端走非协同路径,
  行为不变)。

## 5. 遗留问题

- 环成员提取是最小强连通分量(M SCC)而非"未放置全集合",可缩小块
  规模;
- 环迭代轮间不做 FMU 状态回退(见 §3.5 限制);捕获可用时轮间
  `rollback` 是更严谨的形态;
- t0 的环求解(需要无步进的输出一致性迭代或接受初始输出);
- 高阶外推;
- CLI/JSON 输出已覆盖(`moonfmi couple`,`moonfmi.couple/v1`);JSON 尚未
  记录 Integer/Boolean 连接的值(Real 记录面不变)。
