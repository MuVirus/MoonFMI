# 安全审查与风险清单(G-04)

> 状态:2026-11-17 首次成文,覆盖 P0–P8 已实现面。审阅对象:XML、ZIP、动态库
> 加载、导出代码生成、WASM。后续每次硬化改动应回到本表更新"残余风险"。

---

## 1. 威胁模型

MoonFMI 处理三类不可信输入:

1. **不可信的 FMU 文件**(ZIP 容器 + XML 说明 + 本地二进制);
2. **不可信的动态库**(FMU 内 `binaries/<platform>/*.dll|so` 在宿主进程内执行);
3. **不可信的生成输入**(导出器把用户提供的 IR 变成 C 代码与 XML)。

信任边界:验证器(validate/info)在解析层运行,不执行 FMU;simulate/export
才会进入加载与代码生成。WASM 后端是唯一不落地执行宿主任意代码的路径,但仍在
P7 实验阶段。

## 2. 已防护面(带测试)

| 面 | 防护 | 测试 |
| --- | --- | --- |
| XML 实体展开(XXE/billion laughs) | 禁 DTD、实体计数/大小上限 | `tests/data/model-description/malicious/` |
| XML 深度嵌套 | 深度上限(默认值见 `default_xml_limits`) | deep-nesting.xml |
| XML 大小 | 总量/属性长度上限 | 同上 |
| ZIP 路径穿越 | 条目名归一化,拒绝 `..`、绝对路径、反斜杠 | zip_wbtest 4 例 |
| ZIP 压缩炸弹 | 条目/总膨胀预算 + 压缩比上限 | zip_wbtest 3 例 |
| ZIP 结构 | 截断、校验和不匹配按条目名报错;重复条目大小写不敏感拒绝 | zip_wbtest |
| ZIP fuzz | 固定种子 400 次变异不 panic | zip_wbtest(G-01) |
| XML fuzz | 固定种子两代语料 300+200 次变异不 panic | schema_wbtest(G-01) |
| 动态库加载 | 绝对路径、平台目录映射、符号缺失逐个定位、失败实例隔离(retired 链) | native_wbtest / fmi2_wbtest |
| FMU 日志回调 | 4 KiB 截断 + UTF-8 边界对齐 + 5 万条无泄漏 | fmi2_log_wbtest |
| 平台目录穿越 | `modelIdentifier` 语法校验(`is_safe_model_identifier`) | schema 测试 |
| 内部路径 | `is_safe_internal_path` 校验资源/源文件引用 | schema 测试 |
| 导出代码生成 | IR 自检(EX-001..EX-017):未知引用、非法组合、数组/类型按版本拒绝;C 名字统一前缀+清洗 | export_wbtest |
| 能力误报 | 生成 FMU 不导出未声明能力的符号;宿主按能力显式报错(Fmi2/Fmi3CapabilityMissing) | C-09 测试 |
| WASM | 组件在沙箱内运行;日志经宿主回调,组件不可直接 IO | fmu-wasm 宿主测试 |

## 3. 残余风险(按优先级)

| # | 风险 | 影响 | 缓解/计划 |
| --- | --- | --- | --- |
| R1 | 加载 FMU = 执行宿主任意代码(native 后端本质) | simulate 信任 FMU 二进制 | 文档已声明(README);长期方向:最小化进程隔离或 wasm 后端 |
| R2 | `dlopen` 前未校验二进制哈希/签名 | 恶意 FMU 可投毒 | 用户侧校验;release checklist 要求分发时提供 sha256 清单 |
| R3 | XML/ZIP 上限是配置常量,未做表压差分 | 极端输入下内存峰值 | R-05/R-10 跟踪(第三方库限制);G-03 基线监控 |
| R4 | WASM 后端未覆盖 LS-WASM 全量 world | 与规范 FMU 互通性有限 | P7 实验边界已声明(见 tests/fmu-wasm/README §4) |
| R5 | 导出 C 代码未经独立 fuzz | 生成代码对病态 IR 的鲁棒性靠 IR 自检 | IR check 是前置门;可在 P8+ 补"导出→重解析"差分测试 |
| R6 | `serialize_fmu_state` 尺寸探测依赖 FMU 行为 | 非 Reference-FMUs 的策略差异 | 尺寸查询 + 增长回退已实现;跨更多 FMU 验证属 G-02 扩展 |
| R7 | 临时目录按 `@env.now()` 命名 | 本机可预测名(共享主机的符号链接攻击面) | Windows/Linux 单用户场景可接受;可选随机后缀(P8+) |

## 4. 依赖安全

依赖清单与来源见 [`../roadmap/release-checklist.md`](../roadmap/release-checklist.md)
(SBOM 一节)。所有解析上限在自有代码内实现,不依赖第三方库的安全开关。

## 5. 相关文档

- 风险登记:`../roadmap/risks.md`
- 架构与依赖方向:`architecture.md`
- 测试设计:`cli-and-testing.md`
