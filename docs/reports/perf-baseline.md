# 性能基线(roadmap G-03)

> 机器:Windows 11 专业工作站版,x86_64,i7-12650H(clang 23.1.2 / MSVC;MoonBit
> native release 构建)。数据是 `moon test --target native --release
> -p MuVirus/MoonFMI/tests/integration -f bench`(整个包跑一次)打印的中位数,
> 2026-11-17 首次记录。

| benchmark | min ms | median ms | max ms | 备注 |
| --- | --- | --- | --- | --- |
| parse-validate-10k | 206 | 221 | 253 | 10k 变量 FMI 2 模型描述解析 + 语义校验;预算门 250 ms(`perf_budget_ms`) |
| zip-open-extract-dahlquist | 4 | 4 | 6 | 打开并全量解压真实 Dahlquist FMU |
| export-codegen-dahlquist | 0 | 0 | 0 | 示例 IR → 双版本 XML + 全部 C 代码(秒表分辨率 1 ms) |

回归判据(G-03):同一机器上 median 相对上表劣化超过 20% 即告警;parse-validate-10k
超过 250 ms 由 `perf_budget_ms` 硬门拦截。

复现命令:

```bash
moon test --target native --release -p MuVirus/MoonFMI/tests/integration -f bench
```
