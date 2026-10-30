# 风险清单

> 风险不是“可能出问题”的清单，而是需要**触发条件、缓解措施、应急方案**的登记表。每次阶段评审更新。

---

## 1. 评级

| 等级 | 可能性 | 影响 |
| --- | --- | --- |
| 高 | 很可能发生 | 阻塞里程碑/需要改架构 |
| 中 | 可能发生 | 延期/增加工作量 |
| 低 | 不太可能 | 局部影响 |

---

## 2. 技术风险

### R-01 · MoonBit 不能直接导出 native 动态库

| 项目 | 内容 |
| --- | --- |
| 可能性 | 高（当前已知限制） |
| 影响 | 高：阻塞 native 二进制 FMU 导出 |
| 触发 | 尝试把 MoonBit 包构建为 `.dll/.so` 失败 |
| 缓解 | 源码 FMU 优先；生成纯 C 代码，不依赖 MoonBit 运行时 |
| 应急 | native 二进制导出降级为“实验性”；只提供源码/WASM |
| 关联 | [`../design/exporter.md`](../design/exporter.md) |

### R-02 · C shim 无法与 MoonBit native 可执行文件链接

| 项目 | 内容 |
| --- | --- |
| 可能性 | 中 |
| 影响 | 高：结构体/回调/`size_t` 绑定受阻 |
| 触发 | MoonBit 构建系统不支持外部 C 静态库/目标文件 |
| 缓解 | P0 尽早做小实验；缩小中间层范围；编为独立动态库由 `dl` 加载 |
| 应急 | 只对可变参数/结构体使用独立 shim DLL；其余直接 FFI |
| 关联 | [`../design/ffi-and-abi.md`](../design/ffi-and-abi.md) |

### R-03 · ABI 假设错误（布尔/枚举/`size_t`/对齐）

| 项目 | 内容 |
| --- | --- |
| 可能性 | 中 |
| 影响 | 高：崩溃/静默错误，难调试 |
| 触发 | FMI 2/3 布尔混用；32 位 `size_t`；枚举宽度不同；结构体偏移错误 |
| 缓解 | 编译期 `sizeof`/`offsetof` 断言；每个平台 ABI 测试；官方头文件编译 shim |
| 应急 | 回退到 C shim 全量转换；限制支持平台 |
| 关联 | [`../design/ffi-and-abi.md`](../design/ffi-and-abi.md) |

### R-04 · 回调/可变参数/重入问题

| 项目 | 内容 |
| --- | --- |
| 可能性 | 中 |
| 影响 | 中–高：日志丢失、死锁、崩溃 |
| 触发 | FMI 2 logger 可变参数；FMU 内部线程回调；回调中调用 MoonBit 复杂逻辑 |
| 缓解 | C 侧 `vsnprintf` + 队列；不在回调中做重活；生命周期/锁测试 |
| 应急 | 回调只入队，主线程轮询；异步 CS 后置 |
| 关联 | [`../design/importer.md`](../design/importer.md) |

### R-05 · XML/ZIP 库不成熟或不可移植

| 项目 | 内容 |
| --- | --- |
| 可能性 | 中 |
| 影响 | 中：基础能力受阻 |
| 触发 | 第三方库 API 不稳定；wasm/native 行为不一致；无安全限制 |
| 缓解 | 优先用 `Milky2018/xml` / `fzip` 加薄封装；只有满足不了安全或位置要求时才自研 |
| 应急 | 引入经过审计的 C 库并通过 shim；限制输入 |
| 关联 | [`../design/xsd-and-validation.md`](../design/xsd-and-validation.md) |

### R-06 · XSD 覆盖不足/规范与 XSD 冲突

| 项目 | 内容 |
| --- | --- |
| 可能性 | 高 |
| 影响 | 中：误报/漏报 |
| 触发 | 语义规则无法用 XSD 表达；工具生成不合 XSD 的 FMU；规范正文与 XSD 不一致 |
| 缓解 | 手写语义校验；XSD 仅作 CI 外部对照，P0 不实现 XSD 引擎；规则编号/正反例；样品对比 |
| 应急 | 以规范正文为准，记录差异；提供 `--lenient`（不默认） |
| 关联 | [`../standards/model-description.md`](../standards/model-description.md) |

### R-07 · 测试语料不可用/许可证/体积

| 项目 | 内容 |
| --- | --- |
| 可能性 | 中 |
| 影响 | 中：集成测试缺失 |
| 触发 | 无法下载 Reference-FMUs；许可证限制；仓库过大 |
| 缓解 | 固定 commit/校验和；按需下载缓存；只提交小型自造 FMU |
| 应急 | 用生成器造最小 FMU；CI 分阶段拉取 |
| 关联 | [`../design/cli-and-testing.md`](../design/cli-and-testing.md) |

### R-08 · LS-WASM 草案变更/工具链不成熟

| 项目 | 内容 |
| --- | --- |
| 可能性 | 高 |
| 影响 | 中–高：WASM 返工 |
| 触发 | WIT world 改名；manifest 变更；`wit-bindgen` 无 MoonBit 后端；canonical ABI 不支持 resource |
| 缓解 | 隔离 `backend/wasm`；固定草案 commit；可行性门槛 G1–G7 |
| 应急 | WASM 保持实验性；先做自定义 core wasm 试验；不阻塞本机版本 |
| 关联 | [`../design/wasm-strategy.md`](../design/wasm-strategy.md) |

### R-09 · MoonBit wasm 运行时与 component 不兼容

| 项目 | 内容 |
| --- | --- |
| 可能性 | 中 |
| 影响 | 高：WASM 导出不可行 |
| 触发 | GC/内存初始化失败；WASI p2 adapter 不匹配；字符串/数组边界错误 |
| 缓解 | 最小可行性试验先行；记录产物；保留本机路径 |
| 应急 | 用 C/Rust 写 guest，MoonBit 只做宿主/工具 |
| 关联 | [`../research/wasm-fmi.md`](../research/wasm-fmi.md) |

### R-10 · 性能不达标

| 项目 | 内容 |
| --- | --- |
| 可能性 | 中 |
| 影响 | 中：大模型不可用 |
| 触发 | 每步多次跨 ABI；字符串/Map 查找；WASM 边界复制 |
| 缓解 | 批量 get/set；缓存 VR；预分配；基准测试 |
| 应急 | 限制模型规模；native 优化；C 热点下沉 |
| 关联 | [`../design/master-algorithm.md`](../design/master-algorithm.md) |

### R-11 · 加载不可信 native FMU 的代码执行风险

| 项目 | 内容 |
| --- | --- |
| 可能性 | 高（如果运行不可信 FMU） |
| 影响 | 高：任意代码执行 |
| 触发 | 用户加载来源不明 FMU |
| 缓解 | 默认只 validate；文档警告；`--sandbox` 子进程；WASM 长期方案 |
| 应急 | 禁用 native 加载/仅允许白名单；隔离环境运行 |
| 关联 | [`../design/importer.md`](../design/importer.md) |

### R-12 · Windows DLL 依赖/搜索路径问题

| 项目 | 内容 |
| --- | --- |
| 可能性 | 中 |
| 影响 | 中：FMU 加载失败 |
| 触发 | 同目录依赖 DLL；MSVC 运行库缺失；路径劫持 |
| 缓解 | 绝对路径；受限搜索目录；诊断缺失依赖；测试真实 FMU |
| 应急 | 提供依赖扫描/安装说明；用户显式配置搜索路径 |
| 关联 | [`../design/importer.md`](../design/importer.md) |

### R-13 · ME 求解器范围被高估

| 项目 | 内容 |
| --- | --- |
| 可能性 | 高 |
| 影响 | 中：用户期望落空 |
| 触发 | 刚性/DAE/大量事件模型 |
| 缓解 | 文档明确“非通用求解器”；先 Euler/RK4；外部求解器接口 |
| 应急 | 只支持教学/轻量模型；导出到成熟工具 |
| 关联 | [`../design/master-algorithm.md`](../design/master-algorithm.md) |

### R-14 · FMI 3 SE 时钟/抢占语义复杂

| 项目 | 内容 |
| --- | --- |
| 可能性 | 高 |
| 影响 | 中：SE 延期 |
| 触发 | 多速率/触发时钟；线程/抢占；调度顺序 |
| 缓解 | 首版只做研究/固定周期；SE 后置 |
| 应急 | 不承诺 SE；只支持单速率最小模型 |
| 关联 | [`../design/master-algorithm.md`](../design/master-algorithm.md) |

### R-15 · 事件震荡/零步长/死循环

| 项目 | 内容 |
| --- | --- |
| 可能性 | 中 |
| 影响 | 中：仿真卡死 |
| 触发 | 事件迭代不收敛；Discard 重试；输入突变 |
| 缓解 | 事件迭代上限；最大步数；超时；诊断 |
| 应急 | 终止并输出部分结果/事件日志 |
| 关联 | [`../design/master-algorithm.md`](../design/master-algorithm.md) |

### R-16 · 打包不可复现

| 项目 | 内容 |
| --- | --- |
| 可能性 | 中 |
| 影响 | 低–中：供应链/CI 差异 |
| 触发 | ZIP 时间戳/顺序/权限；绝对路径；工具版本 |
| 缓解 | 确定性 ZIP；固定时间戳/排序；哈希测试 |
| 应急 | 提供“可复现模式”文档；CI 固定环境 |
| 关联 | [`../design/packaging.md`](../design/packaging.md) |

### R-17 · 工具链版本漂移

| 项目 | 内容 |
| --- | --- |
| 可能性 | 高 |
| 影响 | 中：构建/ABI 变化 |
| 触发 | MoonBit/wasm-tools/wit-bindgen/jco 升级 |
| 缓解 | 固定版本；CI 记录版本；升级单独 PR |
| 应急 | 回退版本；隔离实验分支 |
| 关联 | [`../research/moonbit-ecosystem.md`](../research/moonbit-ecosystem.md) |

### R-18 · 文档与实现漂移

| 项目 | 内容 |
| --- | --- |
| 可能性 | 高 |
| 影响 | 中：误导贡献者 |
| 触发 | 设计变更未更新文档；示例失效 |
| 缓解 | DoD 包含文档；链接检查；示例 CI |
| 应急 | 标记过时章节；版本化文档 |
| 关联 | [`../AGENTS.md`](../AGENTS.md) |

### R-19 · 测试不稳定（flaky）

| 项目 | 内容 |
| --- | --- |
| 可能性 | 中 |
| 影响 | 中：CI 不可信 |
| 触发 | 时间/浮点/并发/外部下载 |
| 缓解 | 固定种子/容差；离线缓存；重试仅用于已知外部因素 |
| 应急 | 隔离 flaky 测试；记录 issue |
| 关联 | [`../design/cli-and-testing.md`](../design/cli-and-testing.md) |

### R-20 · 规范歧义/工具实现差异

| 项目 | 内容 |
| --- | --- |
| 可能性 | 高 |
| 影响 | 中：兼容性争议 |
| 触发 | 默认值/事件/字符串/平台细节不一致 |
| 缓解 | 以官方头文件/规范正文为准；交叉检查；记录差异 |
| 应急 | 提供兼容开关；不静默“修好” |
| 关联 | [`../research/fmpy.md`](../research/fmpy.md) |

---

## 3. 项目风险

### R-21 · 范围蔓延

- 触发：同时做 FMI 1/2/3、SE、浏览器、导出、GUI；
- 缓解：MVP 定义（P2）；非目标清单；阶段退出标准；
- 应急：砍掉 P6/P7，保 P1–P2。

### R-22 · 单人/小团队 bus factor

- 触发：关键开发者离开；
- 缓解：文档、测试、代码评审、避免“只有一个人懂”的模块；
- 应急：优先保留核心解析/导入路径。

### R-23 · 依赖许可证不兼容

- 触发：引入 GPL/商业库；
- 缓解：依赖审计；优先 MIT/Apache/BSD；记录许可证；
- 应急：替换/自研；隔离动态依赖。

---

## 4. 风险矩阵

| 影响 \ 可能性 | 低 | 中 | 高 |
| --- | --- | --- | --- |
| 高 | R-03 | R-02, R-09 | R-01, R-11 |
| 中 | R-16 | R-04, R-05, R-07, R-10, R-12, R-15, R-19, R-20 | R-06, R-08, R-13, R-14, R-17, R-18 |
| 低 | — | R-23 | R-21, R-22 |

---

## 5. 评审节奏

- 每个阶段开始时：确认高风险项是否有缓解计划；
- 每个阶段结束时：更新可能性/影响，关闭已消除风险；
- P0/P7 前：专门评审工具链/ABI/WASM 风险；
- 发布前：安全、许可证、可复现性专项检查。

---

## 6. 相关文档

- 路线图：[`roadmap.md`](roadmap.md)
- Backlog：[`backlog.md`](backlog.md)
- 架构：[`../design/architecture.md`](../design/architecture.md)
- 工具链：[`../research/moonbit-ecosystem.md`](../research/moonbit-ecosystem.md)
