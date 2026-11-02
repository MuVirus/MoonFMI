# WebAssembly 组件探针

这里回答 P0 第四周的问题：MoonBit 能不能编译成 core wasm，再包成 WebAssembly component，跑通资源、字符串和字节数组。

三个探针分别对应设计里的 G1–G3：

| 探针 | WIT | 通过标准 |
| --- | --- | --- |
| `adder` | `docs:adder/add` | `add(10, 20)` 经 wasmtime 返回 `30` |
| `codec` | `moonfmi:codec/codec` | UTF-8 字符串、`list<u8>`、record 往返正确 |
| `counter` | `moonfmi:store/counter` | 宿主创建/使用/释放 resource，guest 析构函数被调用 |

产物和生成的绑定都在 `.cache/`，已被 Git 忽略。仓库里仍然只有一个 `moon.mod`，探针不会影响根模块的 `moon check` / `moon test`。

---

## 1. 前置工具

探针不是项目依赖，工具装在仓库外，运行时通过 `PATH` 查找：

| 工具 | 验证过的版本 | 用途 |
| --- | --- | --- |
| `wit-bindgen` | 0.63.0 | 生成 MoonBit guest 绑定 |
| `wasm-tools` | 1.263.0 | `component embed` / `component new` / 校验 |
| `wasmtime` | 50.0.1 | 直接调用 G1 组件 |
| `moon` | 0.1.20261023 | 编译 guest |
| Node.js | 24.18.0 | 宿主测试、`using` 语法、运行 jco |
| `@bytecodealliance/jco` | 1.40.0 | 把组件转译成 JS，供 Node 宿主使用 |

如果工具不在 `PATH`，用 `MOONFMI_WASM_BIN` 指向存放它们的目录：

```powershell
$env:MOONFMI_WASM_BIN = 'C:\Users\<you>\.moonfmi\bin'
```

`jco` 只用于测试，装在 `.cache/jco`，不会写进 `moon.mod`：

```powershell
node tests/spikes/wasm-component/run.mjs setup-jco
```

---

## 2. 命令

在仓库根目录执行：

```powershell
# 只构建三个组件，打印 core / component 大小
node tests/spikes/wasm-component/run.mjs build

# 构建 + 运行全部验收（默认命令）
node tests/spikes/wasm-component/run.mjs test

# 额外跑一轮吞吐测量（G7 的初步数据）
node tests/spikes/wasm-component/run.mjs bench

# 删除 .cache
node tests/spikes/wasm-component/run.mjs clean
```

`test` 期望输出：

```text
ok   adder: wasmtime --invoke add(10, 20) -> 30
ok   echo-string round-trip (len=0)
...
ok   1000 guest dtors ran after 1000 host drops
all WebAssembly spike checks passed
```

---

## 3. 构建流程

每个探针的步骤相同，只是 WIT 包名和生成路径不同：

```text
wit/<name>.wit
  -> wit-bindgen moonbit wit --out-dir <work> --derive-debug
  -> 把 guest/<name>/*.mbt 放进生成的 interface 包
  -> moon build --target wasm --release
  -> wasm-tools component embed wit gen.wasm --encoding utf16
  -> wasm-tools component new
  -> wasm-tools validate --features all
```

关键点是 `--encoding utf16`。MoonBit 的 `String` 是 UTF-16，而 component model 默认按 UTF-8 解释字符串；不加这个参数，中文和 emoji 会变成乱码。

生成的 `gen/moon.pkg` 已经把核心 wasm 的导出名改成 canonical ABI 名字，例如：

```text
wasmExportAdd:docs:adder/add@0.1.0#add
```

所以 `component embed` 不需要额外指定导出映射。

---

## 4. 各自验证了什么

### 4.1 adder（G1）

`add(x: u32, y: u32) -> u32`。core wasm 约 2.7 KB，没有 import，导出 `memory`、`cabi_realloc` 和 `docs:adder/add@0.1.0#add`。用 wasmtime 调用得到 `30`，说明“MoonBit 函数 → 合法 component → 宿主调用”这条链路成立。

### 4.2 codec（G3）

覆盖五种值形态：

- 空字符串、ASCII、中文 + emoji、引号、换行；
- 10 万字符的长字符串，触发 `cabi_realloc`；
- 空字节数组、4 字节、1 MiB；
- record（`string` + `list<f64>`）。

宿主侧同时用 `wasmtime run --invoke` 和 jco/Node 检查。wasmtime 的 `--invoke` 能直接传字符串、数组和 record，但 PowerShell 会吞掉参数里的双引号，需要写成 `'echo-string(\"hello\")'`。

### 4.3 counter（G2）

guest 实现并导出一个 resource：

```wit
resource counter {
    constructor(start: u32);
    bump: func(by: u32) -> u32;
    value: func() -> u32;
}
```

宿主用 `new counter.Counter(10)` 创建，`bump` / `value` 正常；调用 `handle[Symbol.dispose]()` 或 `using` 离开作用域时，guest 的 `Counter::dtor` 执行，`dropped()` 计数增加。测试创建了 1000 个句柄，确认释放前计数不变、逐个释放后正好加 1000。

这里的 rep 是一张全局数组的下标，用来记录数值；真实 FMU resource 会放实例指针。这个探针只证明生命周期，不证明状态管理策略。

---

## 5. 踩过的坑

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 字符串乱码 | component 默认 UTF-8，MoonBit `String` 是 UTF-16 | `component embed --encoding utf16` |
| `wasmtime --invoke 'echo-string("hi")'` 报 `invalid value type` | PowerShell 把内层双引号去掉了 | 写成 `\"hi\"`，或改用 Node 宿主 |
| `Named export 'codec' not found` | jco 输出的 `.js` 被 Node 当成 CommonJS | 在输出目录放 `{"type":"module"}` 的 `package.json` |
| `moon` 把探针当成根模块的一部分 | 生成的项目自带 `moon.mod` | 只在 `.cache/`（隐藏目录）里生成，根模块扫描不到 |
| `wit-bindgen` 报 `found keyword resource` | WIT 包名不能叫 `resource` | 包名用 `moonfmi:store`，resource 名仍叫 `counter` |
| `0.to_byte()` 解析失败 | 对整数字面量调用方法要加括号 | `(0).to_byte()` |
| `using` 语法报错 | Node < 24 不支持显式资源管理 | 使用 Node 24，或改成手动 `[Symbol.dispose]()` |

---

## 6. 边界

- 这里的组件是**函数级探针**，不是 FMI FMU：没有 `modelDescription.xml`、没有实例状态机、没有步进循环。G4 还没做。
- 宿主是 Node，不是浏览器。G5 只到“jco 转译 + Node 运行”，Chrome/Firefox 未测。
- 没有做 host import 回调（G6）。FMI 日志需要在 WIT 里声明 import，再由宿主实现，方案可行但未验证。
- `bench` 只记录当前机器的调用开销，没有和 native FMI 后端做同模型对比，因此不构成 G7 的完整结论。
- 探针没有接入 `scripts/check.ps1` / `check.sh`：它们依赖仓库外的工具，缺工具时应当跳过而不是让主检查失败。CI 是否加一个可选 job，等 P1 再定。

---

## 7. 相关文档

- 设计：[`../../../docs/design/wasm-strategy.md`](../../../docs/design/wasm-strategy.md)
- 研究：[`../../../docs/research/wasm-fmi.md`](../../../docs/research/wasm-fmi.md)
- 阶段报告：[`../../../docs/roadmap/p0-report.md`](../../../docs/roadmap/p0-report.md)
- 实施记录：[`../../../docs/records/2026-11-02.md`](../../../docs/records/2026-11-02.md)
