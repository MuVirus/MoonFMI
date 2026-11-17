# WASM CS FMU 组件(P7 · F-02/F-04/F-05/F-07)

这里回答 P7 的前三个问题:MoonBit 能不能把一个**最小 CS FMU**编译成 WebAssembly
component,宿主能不能驱动完整生命周期,日志能不能走回调。

| 任务 | 内容 | 结论 |
| --- | --- | --- |
| F-02 | WIT world(`moonfmi:adder`)+ get-version | ✅ `get-version()` 返回 `3.0` |
| F-04 | Adder CS resource(instantiate/set/step/get/terminate) | ✅ `y = u1 + u2 = 30` |
| F-05 | 宿主回调(guest → host `log`) | ✅ 实例化/步进/析构消息全部到达宿主 |
| F-07 | LS-WASM 布局打包 + manifest | ✅ `MoonfmiAdder.fmu`,modelDescription 通过 MoonFMI 校验 |
| F-06 | 浏览器宿主 | ✅ Chromium 内核自动化实测(见 `docs/reports/browser-poc.md`) |
| F-08 | WASM 导出器 | ✅ `src/export/export_wasm_fmu`(Float64 标量子集),e2e 构建通过 |

产物和生成的绑定都在 `.cache/`,已被 Git 忽略。

---

## 1. WIT 形状

```wit
interface host {
    log: func(level: u32, message: string);   // F-05 回调通道
}

interface cs {
    resource fmu {
        constructor();
        get-version: func() -> string;
        set-real: func(vr: u32, value: f64);
        get-real: func(vr: u32) -> f64;
        do-step: func(current: f64, step: f64) -> result<_, string>;
        terminate: func();
    }
    get-version: func() -> string;
}

world adder {
    import host;
    export cs;
}
```

值引用与导出的 modelDescription.xml 一致:u1 = 0,u2 = 1,y = 2。

## 2. 命令

```bash
export PATH="$PATH:$HOME/.moonfmi/bin"        # wit-bindgen / wasm-tools
node tests/fmu-wasm/run.mjs build             # 只构建组件
node tests/fmu-wasm/run.mjs test              # 构建 + jco/Node 宿主测试(默认)
node tests/fmu-wasm/run.mjs package           # 构建 + 打包 .cache/MoonfmiAdder.fmu
node tests/fmu-wasm/run.mjs browser           # 构建 + 转译 + 静态服务(http://127.0.0.1:8123/)
node tests/fmu-wasm/run.mjs build-export <dir>  # 构建 MoonFMI 导出的 WASM 工程
node tests/fmu-wasm/run.mjs setup-jco         # 装 jco(或复用 spike 的 .cache)
node tests/fmu-wasm/run.mjs clean
```

`test` 期望输出以 `all fmu-wasm checks passed` 结尾;`package` 会打印
FMU 的字节数与 sha256。MoonBit 侧的 `tests/integration/export_fmu_wbtest.mbt`
在 FMU 存在时校验其 ZIP 布局与 modelDescription 语义。

## 3. 验证了什么

- **resource 生命周期**:宿主 `new cs.Fmu()` 创建,`[Symbol.dispose]` 触发
  guest 的 `Fmu::dtor`(通过日志通道可见),与 P0 counter 探针的结论一致。
- **CS 语义**:`setReal(0,10)` + `setReal(1,20)` → `doStep(0,0.1)` →
  `getReal(2) === 30`;terminate 之后 do-step 报错(guest 消息原样传回)。
- **回调**:guest 全部日志经 `import host.log` 输出,组件内不打印。
  jco 的 `--map moonfmi:adder/host=./host_shim.mjs` 把导入接到本地 shim,
  测试断言捕获到的消息。
- **打包**:STORE 方式的确定性 ZIP(固定 1980-01-01 时间戳),布局为
  `modelDescription.xml` + `binaries/wasm32-wasip2/MoonfmiAdder.wasm` +
  `extra/org.modelica.fmi-ls-wasm/manifest.xml`。

## 4. 边界

- 宿主覆盖 Node(jco 转译)与 Chromium 内核浏览器(F-06);Firefox 提供手工步骤;
  LS-WASM 规范的完整 world(CS/ME/SE 全量接口)未实现——这里只是
  `get-version` + Adder 的最小面。
- `result<_, string>` 在 jco 的 JS 里映射为"成功返回 undefined、失败抛
  Error(message)",宿主测试按该约定断言。
- 打包脚本写的是 STORE 条目,没有压缩;MoonFMI 的 reader 两者都收。
- 工具不在 PATH 时用 `MOONFMI_WASM_BIN` 指向它们;缺工具时这套测试
  跳过,不影响主检查(`moon test` 不依赖 node/wit-bindgen)。

## 5. 相关文档

- P0 探针与工具链:[`../spikes/wasm-component/README.md`](../spikes/wasm-component/README.md)
- 设计:[`../../docs/design/wasm-strategy.md`](../../docs/design/wasm-strategy.md)
- 研究:[`../../docs/research/wasm-fmi.md`](../../docs/research/wasm-fmi.md)
