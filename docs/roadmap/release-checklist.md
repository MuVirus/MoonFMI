# 发布检查清单与 SBOM(G-06)

> 每次 tag(`0.x`)前逐项过一遍。勾选后把本文件随 release 附上。

## 1. 质量门

- [ ] `moon run scripts/check.mbtx --target native` 全绿(fmt / info / 依赖方向 / ABI / 语料)
- [ ] `moon test --target native --release` 全绿(含 perf 预算与 bench)
- [ ] `moon test --target native` 全绿(debug)
- [ ] Windows + Linux 双平台构建(本地 + GitHub Actions)
- [ ] `node tools/field-coverage.mjs` 报告无异常回退(B-19)
- [ ] `moon run scripts/crosscheck.mbtx --target native --release` 表格与上次对比无新 FAIL(G-02)
- [ ] 性能:对照 [`../reports/perf-baseline.md`](../reports/perf-baseline.md),median 劣化 >20% 需说明(G-03)
- [ ] fuzz:`moon test -p src/zip -p src/schema`(固定种子回归)通过(G-01)

## 2. 文档

- [ ] README 快速上手四步在本机重跑一遍
- [ ] 已知限制一节与实现一致(README「Known limits」)
- [ ] `docs/cli-json.md` 契约与输出一致
- [ ] `docs/reports/` 下 bench / crosscheck / field-coverage 已刷新
- [ ] CHANGELOG/发布说明覆盖用户可见变化

## 3. 发布产物

- [ ] `moon build --target native --release cmd/main` 产出 CLI
- [ ] 附 sha256:`main.exe` / `main` 二进制。可复现性:两次 `moon clean` + release 构建仅 PE 链接时间戳字节不同(COFF TimeDateStamp 与调试目录时间戳,识别规则:双侧均解码为合理 Unix 时间戳),其余逐位一致——已由 `moon run scripts/repro-build.mbtx --target native` 自动核对(0.7.0;2026-11-19 实测 1,399,808 字节中仅 2 字节时间戳差异)。逐字节可复现需链接器支持 SOURCE_DATE_EPOCH(上游未提供),发布时以附 sha256 为准。
- [ ] 若发布源码导出样例 FMU:构建产物 + 生成 FMU 的 sha256
- [ ] 版本号:遵守 roadmap 发布节奏表(`0.x` 对应阶段)

## 4. SBOM(依赖清单)

直接依赖(`moon.mod`,均为 MoonBit 社区注册表包;核对日期 2026-11-19):

| 依赖 | 版本 | 许可证 | 用途 | 备注 |
| --- | --- | --- | --- | --- |
| `Milky2018/xml` | 0.6.1 | 见包 | XML 事件流解析(封装在 `src/xml`) | 上限与安全在自有代码 |
| `hustcer/fzip` | 0.8.8 | 见包 | ZIP 读写(封装在 `src/zip`) | 确定性写入自实现 |
| `moonbitlang/async` | 0.22.9 | Apache-2.0 | `--sandbox` 子进程(`src/cli`) | 0.7.0 准入,见 `research/moonbit-ecosystem.md` §13.1;仅 native |
| `moonbitlang/x` | 0.5.7 | Apache-2.0 | `fs`、`crypto`(sha256) | 官方扩展库 |
| `tonyfettes/c` | 0.8.0 | 见包 | C FFI 绑定(`src/backend/native`) | native 目标 |

脚本专用(不进运行时):`moonbitlang/async@0.22.9`(scripts/*.mbtx,
tests/abi/*.mbtx)、`moonbitlang/core`(工具链自带)。测试专用:
`tonyfettes/c`(native-stub)。

工具链(MoonBit `moon`/`moonc`,clang/MSVC,node,wit-bindgen,wasm-tools,
jco)见 `docs/roadmap/p0-report.md` §2 与 `tests/fmu-wasm/README.md` §1;
它们是构建/测试依赖,不随产物分发。

许可证审计:本仓库 Apache-2.0;Reference-FMUs 语料 BSD-2-Clause(仅测试,
不入发布物);FMI 标准头文件(Modelica Association)随仓库内嵌
`docs/standards/headers/`,许可允许再分发,发布说明需注明来源与版本(2.0.4 / 3.0.2)。

## 5. 已知限制披露

- [ ] 发布说明包含「非通用求解器」「单 FMU」「SE 未实现」「wasm 实验性」四条
- [ ] `docs/roadmap/risks.md` 无未披露的高危项;`security-review.md` 残余风险已同步
