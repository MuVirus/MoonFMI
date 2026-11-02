# P0 阶段报告

> 日期：2026-11-02。范围：P0 四周（基础设施 → 读 FMU → 调动态库 → C 中间层与 ABI → WebAssembly 探针）。
> 目标读者：没参与 P0、但要在 P1 接着做的人。

---

## 1. 结论

P0 计划里的导入侧目标全部达到：XML、ZIP、动态库加载、C 中间层、日志回调、ABI 基线和真实 FMI 2 CS 模型端到端都跑通了。WebAssembly 侧完成了最小目标（G1），并额外跑通了 resource（G2）和字符串/字节数组（G3），但没有做到 FMI 级别的组件（G4），也没有浏览器和回调验证。

一句话：**WebAssembly 值得进 P7，但只能以“实验性后端”进入；在 G4 通过前，不对外交付 LS-WASM 兼容性。**

| 工作项 | 结论 |
| --- | --- |
| Windows / Linux 构建、测试、格式化 | 通过（本地；GitHub CI 尚未实际跑过） |
| 测试 FMU 一条命令取齐 | 通过，8 个样品，SHA-256 校验 |
| XML / ZIP / 动态库安全读取 | 通过，含恶意输入测试 |
| C 中间层编入构建 | 通过，`native-stub` 双平台可用 |
| FMU 日志 | 通过，截断、UTF-8、生命周期、5 万条泄漏测试 |
| ABI 基线 + C 参考宿主 | 通过，BouncingBall 六点对照一致 |
| WASM G1 最小组件 | 通过 |
| WASM G2 resource | 通过 |
| WASM G3 字符串 / `list<u8>` | 通过 |
| WASM G4 Adder FMU | 未做 |
| WASM G5 浏览器 | 未做（只到 jco + Node） |
| WASM G6 回调 | 未做 |
| WASM G7 性能 | 只有初步数据，没有 native 对照 |

---

## 2. 环境

```text
Windows 11 专业工作站版 10.0.26300，x86_64，i7-12650H
WSL2 Ubuntu 22.04（Linux 侧验证）

moon 0.1.20261023 (3778465 2026-10-23)
moonc v0.10.17+d971670cd (2026-10-23)
MSVC cl.exe（native-stub）
clang 23.1.2（测试样品、C 参考宿主）
Node.js v24.18.0
npm 11.16.0

wit-bindgen 0.63.0
wasm-tools 1.263.0
wasmtime 50.0.1
@bytecodealliance/jco 1.40.0（仅测试，装在 tests/spikes/wasm-component/.cache）
```

工具是 GitHub release 的预编译包，放在仓库外的 `C:\Users\<user>\.moonfmi\bin`，不提交。`run.mjs` 通过 `PATH` 或 `MOONFMI_WASM_BIN` 查找。

---

## 3. WebAssembly 实验

探针在 [`tests/spikes/wasm-component/`](../../tests/spikes/wasm-component/README.md)，WIT、guest 实现和宿主测试都在仓库里；生成的绑定、core wasm、component 和 jco 输出在 `.cache/`，已忽略。

### 3.1 G1：最小组件

WIT：

```wit
package docs:adder@0.1.0;
interface add { add: func(x: u32, y: u32) -> u32; }
world adder { export add; }
```

命令：

```powershell
node tests/spikes/wasm-component/run.mjs test
```

实际展开的步骤：

```text
wit-bindgen moonbit wit --out-dir .cache/build/adder --derive-debug
moon build --target wasm --release
wasm-tools component embed wit gen.wasm --encoding utf16
wasm-tools component new
wasm-tools validate --features all
wasmtime run --invoke "add(10, 20)" adder.component.wasm
```

结果：

| 产物 | 大小 |
| --- | --- |
| core wasm | 2 669 B |
| component | 3 205 B |
| 调用结果 | `30` |

core wasm 没有 import，导出 `memory`、`cabi_realloc` 和 `docs:adder/add@0.1.0#add`。`component embed` 不需要额外映射，因为 `gen/moon.pkg` 在链接时已经把导出名改成 canonical ABI 名字。

### 3.2 G3：字符串、字节数组、record

WIT：

```wit
record sample { name: string, values: list<f64> }
echo-string: func(text: string) -> string;
echo-bytes: func(data: list<u8>) -> list<u8>;
summarize: func(input: sample) -> string;
```

覆盖的输入：

- 空字符串、ASCII、`中文🙂`、引号、换行、两个 emoji；
- 10 万字符长字符串（触发 `cabi_realloc`）；
- 空 `list<u8>`、4 字节、1 MiB；
- `sample { name: "中文🙂", values: [1.5, 2.5, -3.25] }`。

两条独立路径都通过：

1. `wasmtime run --invoke 'echo-string(\"中文🙂\")'` 返回 `"中文🙂"`；
2. jco 转译后用 Node 宿主逐项比较，字符串和字节数组都是值相等，不是只看长度。

产物：core 18 032 B，component 19 564 B；jco 生成的 JS 约 124 KiB，另带 17.6 KiB core wasm。

关键参数是 `component embed --encoding utf16`。MoonBit `String` 是 UTF-16；漏掉它，非 ASCII 内容会乱码。

### 3.3 G2：resource 生命周期

WIT：

```wit
resource counter {
    constructor(start: u32);
    bump: func(by: u32) -> u32;
    value: func() -> u32;
}
dropped: func() -> u32;
```

guest 用一张全局数组保存数值，`Counter::dtor` 把对应槽位标记为删除并给 `dropped` 加一。宿主用 jco 生成的 JS 类：

```js
const a = new counter.Counter(10);
a.bump(5);                  // 15
a[Symbol.dispose]();        // 触发 guest dtor
counter.dropped();          // 1
```

测试还创建 1000 个句柄，确认：

- 全部存活时 `dropped()` 不变；
- 逐个 `Symbol.dispose()` 后 `dropped()` 正好增加 1000；
- `using` 离开作用域会自动释放。

产物：core 8 567 B，component 10 745 B。

这个探针证明的是生命周期，不是状态管理：真实 FMU resource 应保存实例指针，而不是演示用的数组下标。

### 3.4 G7：初步性能

单机、单次运行，jco/Node 宿主，数字只用于判断量级：

| 操作 | 次数 | 总时间 | 每次 |
| --- | --- | --- | --- |
| `echo-string` 5 字符 | 200 000 | 1 349 ms | 6.75 µs |
| `echo-string` 4 096 字符 | 20 000 | 1 197 ms | 59.87 µs |
| `echo-bytes` 4 KiB | 20 000 | 231 ms | 11.55 µs |
| `summarize` 3 个 f64 | 100 000 | 828 ms | 8.28 µs |
| resource 新建 + `bump` + 释放 | 100 000 | 1 408 ms | 14.08 µs |

这些是“JS ↔ component ↔ MoonBit”的端到端开销，不能直接和 native FMU 的 C 调用比。G7 要求与 native 同模型对照，尚未做。

### 3.5 G4–G6：为什么没做

- **G4（Adder FMU）**：需要先确定 LS-WASM 的 WIT 世界、实例状态机和 `modelDescription.xml` 的映射。这是 P7 的第一件事，不是 P0 能顺手带过的。
- **G5（浏览器）**：jco 转译产物已经在 Node 里跑通；浏览器还差静态服务器、ES module 加载和无头浏览器脚本。Node 结果只能算部分证据。
- **G6（回调）**：需要 WIT `import` 一个日志函数，再由宿主实现。方向可行，但没有做；FMI 日志回调是 P7 的必答题。

### 3.6 复现

```powershell
# 工具在 PATH 上，或：
$env:MOONFMI_WASM_BIN = 'C:\Users\<you>\.moonfmi\bin'

node tests/spikes/wasm-component/run.mjs setup-jco
node tests/spikes/wasm-component/run.mjs test
node tests/spikes/wasm-component/run.mjs bench
```

### 3.7 P0 总体回归

最后跑了一遍完整的本地检查：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check.ps1
```

| 阶段 | 结果 |
| --- | --- |
| `moon fmt --check` | 通过 |
| `moon check --target native --deny-warn` | 通过 |
| `moon check --target wasm --deny-warn` | 通过 |
| `moon test --target native` | 45/45 |
| `moon test --target native --release -p .../tests/integration` | 15/15 |
| `moon test --target wasm` | 30/30 |
| ABI 基线（Windows） | `x86_64-windows.json` 逐字段一致 |
| C 参考宿主 | 6 个采样点与基准一致 |
| XSD 对照（可选） | 5/5 按预期 |

Linux 侧沿用第三周的分步检查：`build-fixture.sh`、`check-abi.mjs`、`run-fmi2-host.sh`、`check-host.mjs` 都通过。

---

## 4. 踩过的坑

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 非 ASCII 字符串乱码 | component 默认 UTF-8，MoonBit `String` 是 UTF-16 | `component embed --encoding utf16` |
| `wasmtime --invoke 'echo-string("hi")'` 报 `invalid value type` | PowerShell 吞掉内层双引号 | 写成 `\"hi\"`，或改用 Node 宿主 |
| `Named export 'codec' not found` | jco 输出的 `.js` 被 Node 当成 CommonJS | 输出目录放 `{"type":"module"}` 的 `package.json` |
| 根模块扫描到探针 | 生成的项目自带 `moon.mod` | 只在隐藏的 `.cache/` 里生成 |
| WIT 包名 `moonfmi:resource` 解析失败 | `resource` 是关键字 | 包名改 `moonfmi:store` |
| `0.to_byte()` 解析失败 | 整数字面量调用方法要加括号 | `(0).to_byte()` |
| `moon build` 看起来报错但退出码为 0 | PowerShell 把原生 stderr 当错误显示 | 看 `Artifacts:` 和真实退出码 |
| `npm` 找到的是无扩展名脚本 | `where npm` 第一条不是 `.cmd` | 优先选 `.exe/.cmd/.bat` |

---

## 5. 五个决定

### 5.1 XML 读取器：用 `Milky2018/xml`，外面包安全限制

**决定**：保留 `Milky2018/xml@0.6.1`，在 `src/xml` 外包一层 `XmlLimits`：32 MB、深度 256、单元素 1024 个属性、单属性 64 KiB，拒绝 `DOCTYPE`，错误带行列号。

**理由**：它在 native 和 wasm 两个目标上都能编译、能跑测试，`SourceSpan` 能给出位置；真实 BouncingBall 的 `modelDescription.xml` 已读出。自写解析器要重新处理实体、CDATA、命名空间和编码，收益不足以抵消风险。

**改主意的条件**（计划里写的三条）：wasm 跑不了、位置信息不够、维护停摆。目前都没发生。

### 5.2 ZIP 读取器：目录自己解析，inflate 用 `fzip`

**决定**：用 `hustcer/fzip@0.8.8` 做解压和 CRC32；中央目录、条目名、声明大小、压缩方法、压缩比、重名和路径穿越检查由 `src/zip` 自己做。

**理由**：计划里的触发条件确实出现了——`fzip` 的 `unzip_list` 不提供我们需要的全部条目字段，所以按预案“自己解析目录，deflate 仍用库”。这样安全策略（256 MB 总量、4096 条目、单条 64 MB、压缩比 200）完全在我们自己的代码里，不依赖上游默认值。

**替代**：连 inflate 一起自写。拒绝，因为 deflate 的边界情况多，测试成本高于收益。

### 5.3 C 中间层：`native-stub` 直接编进包

**决定**：`src/backend/native/moon.pkg` 用 `native-stub` 列出 `dl.c` 和 `fmi2_shim.c`，由 MoonBit 构建直接编译。

**理由**：Windows 的 MSVC 和 Linux 的 `cc` 都一次通过；不需要额外 `-I`、`cc-link-flags` 或静态库，也不存在两套 CRT。计划里的两条退路（静态库、独立动态库）没有启用。

**影响**：C 文件必须和包一起走；好处是编译器、运行库、异常模型天然一致。

### 5.4 WebAssembly：进 P7，但保持实验性

**决定**：P7 可以做 `backend/wasm`，但先以实验性后端推进；G4（Adder FMU）通过前，不宣称 LS-WASM 兼容，也不把 WASM 作为默认路径。

**理由**：G1–G3 都过了，工具链可以脚本化复现，说明“MoonBit → component → 宿主”不是死路。但 G4–G7 没做，尤其没有浏览器和回调证据，不能据此承诺完整 FMI。

**改主意的条件**：G4 发现 LS-WASM 的 WIT 映射无法用当前 `wit-bindgen` 表达，或宿主 import 回调在浏览器里不可用；那时退回“只做实验/演示”，不阻塞 native。

### 5.5 测试 FMU：保留 8 个

**决定**：继续用 Reference-FMUs v0.0.42 的 8 个样品：FMI 2 和 FMI 3 各 4 个（BouncingBall、Feedthrough、Resource、Dahlquist/StateSpace）。

**理由**：上游同时提供 FMI 2 和 FMI 3 构建，计划里“缩到 4 个”的触发条件没有出现；8 个覆盖输出、输入、资源、状态和数组，成本只有约 2.4 MB 缓存和几秒解压。

**改主意的条件**：CI 时间或仓库体积成为问题时，先保留 BouncingBall、Feedthrough、Resource 和 StateSpace 四个核心模型。

---

## 6. 对 P1 的影响

- **导入器可以立即开工**：XML、ZIP、动态库、日志、ABI 都有可用的基础，FMI 2 CS 已端到端。
- **WASM 不阻塞 P1**：它属于 P7；P1 只依赖 native 路径。
- **P7 的第一件事是 G4**：把 Adder 的 `instantiate/step/get/set/terminate` 映射到 WIT，再补 G5/G6/G7；不要先写正式后端。
- **XML 性能仍是风险**：1 MB 文档实测约 144 ms，未达到 100 ms 目标，已登记在 `risks.md`。P1 若处理大模型描述，需要先做性能定位。
- **CI 还没在 GitHub 上实际跑过**：本地 Windows 全量检查和 WSL 分步检查都通过，但“CI 能拦住错误”尚未由远端证明。
- **第三方交叉验证还没做**：FMPy 跑同一模型、`7z x` 逐文件解压对比仍待补；它们不影响 P1 开工，但会让“与参考实现一致”的证据更完整。
- **FMI 3 运行时还没接**：P0 只做了 FMI 2 CS 的 C shim；FMI 3 的尺寸基线已就位，运行时和 ME 路径属于 P3/P4。

---

## 7. 相关文档

- 计划：[`p0-plan.md`](p0-plan.md)
- 路线图：[`roadmap.md`](roadmap.md)
- 风险：[`risks.md`](risks.md)
- 实施记录：[`../records/2026-11-02.md`](../records/2026-11-02.md)
- WASM 设计：[`../design/wasm-strategy.md`](../design/wasm-strategy.md)
- ABI 结论：[`../design/ffi-and-abi.md`](../design/ffi-and-abi.md)
- 探针说明：[`../../tests/spikes/wasm-component/README.md`](../../tests/spikes/wasm-component/README.md)
