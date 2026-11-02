# P0 实验

`tests/spikes` 放一次性验证用的探针，用来回答 P0 的五个问题。

前三项没有做成一次性脚本，而是直接落进了正式包和集成测试：

| 问题 | 位置 |
| --- | --- |
| 能不能读说明书 | `src/xml` 与 `src/xml/xml_wbtest.mbt`，真实文件由 `tests/integration` 覆盖 |
| 能不能安全打开 FMU | `src/zip` 与 `src/zip/zip_wbtest.mbt`，真实文件由 `tests/integration` 覆盖 |
| 能不能加载动态库 | `src/backend/native`（含 `dl.c`）与 `tests/integration`，C 样品在 `tests/abi` |

原因很简单：这三项本来就要长期保留，做成脚本再重写一遍没有意义。一次性探针只留给第四项。

WebAssembly 的探针放在 [`wasm-component/`](wasm-component/README.md)，用 WIT + `wit-bindgen` + `wasm-tools` 验证 G1–G3。
