# 参考资料

本目录集中管理外部链接与术语，避免正文散落失效链接。

---

## 1. 文档

| 文件 | 内容 |
| --- | --- |
| [`links.md`](links.md) | 官方标准、实现、工具链、测试语料链接 |
| [`glossary.md`](glossary.md) | FMI / WASM / ABI 术语表 |

---

## 2. 链接维护约定

1. 外部链接统一放在 [`links.md`](links.md)，正文只在必要时直接引用官方文档。
2. 每条链接记录：名称、URL、用途、版本/备注。
3. 优先链接**固定版本/tag/commit**，避免 `main` 漂移；无法固定时注明“滚动”。
4. 标准类链接以官方 `modelica/fmi-standard` 仓库和 `fmi-standard.org` 为准。
5. 每季度或每次标准升级时检查链接；CI 可做 HTTP 检查，但不要把网络失败当成代码失败。
6. 链接失效时，优先找官方新地址；找不到则在条目中标注“已失效”，不要静默删除。

---

## 3. 版本基线

| 项目 | 基线 |
| --- | --- |
| FMI 2 | 2.0.4 |
| FMI 3 | 3.0.2 |
| MoonBit | 以 `moon version` 为准，CI 固定 |
| LS-WASM | 草案，记录 commit |
| 文档日期 | 2026-10-29 |

---

## 4. 相关文档

- 标准资料：[`../standards/README.md`](../standards/README.md)
- 研究：[`../research/README.md`](../research/README.md)
- 设计：[`../design/README.md`](../design/README.md)
- 路线图：[`../roadmap/README.md`](../roadmap/README.md)
