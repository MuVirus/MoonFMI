# CLI JSON 输出契约

所有 `--json` 输出的第一个字段都是 `schema`,取值固定;字段只增不改,
破坏兼容前必须升版本号并记录变更。路径一律用 `/`,即使 Windows;
浮点用 JSON 数字,非有限值用字符串/null 并注明。测试基线见
`src/cli/cli_wbtest.mbt` 与 `tests/integration/package_wbtest.mbt`。

## `moonfmi.validate/v1` — `moonfmi validate --json`

```json
{
  "schema": "moonfmi.validate/v1",
  "file": "model.fmu",
  "fmiVersion": "2.0",
  "model": "BouncingBall",
  "valid": true,
  "errors": 0,
  "warnings": 1,
  "diagnostics": [
    {
      "code": "MD-050",
      "severity": "warning",
      "message": "unit \"K\" is not defined in UnitDefinitions",
      "path": "/fmiModelDescription/ModelVariables/ScalarVariable[7]/@unit",
      "line": 42,
      "column": 18,
      "hint": "declare the unit or drop the reference"
    }
  ]
}
```

- `fmiVersion`/`model`:无法解析时为 `null`;
- `line`/`column`/`hint`:无则为 `null`;
- `code`:`MD-xxx`(语义)、`STRUCTURE`(结构)、`XML`(词法)、`FMU-LAYOUT`(容器)。

## `moonfmi.info/v1` — `moonfmi info --json`

```json
{
  "schema": "moonfmi.info/v1",
  "modelName": "BouncingBall",
  "fmiVersion": "2.0",
  "variables": 5,
  "variableTypes": { "real": 4, "integer": 1 },
  "platforms": ["win64", "linux64"],
  "sha256": "…"
}
```

- `platforms`:`binaries/` 下的平台目录名(存档内出现的顺序);纯源码
  FMU 为 `[]`。

## `moonfmi.simulate/v1` — `moonfmi simulate --json`

```json
{
  "schema": "moonfmi.simulate/v1",
  "file": "BouncingBall.fmu",
  "startTime": 0,
  "stopTime": 3,
  "stepSize": 0.01,
  "steps": 300,
  "samples": 301,
  "outputs": ["h", "v"]
}
```

- 记录的数值数据在 `--output` 的 CSV 里;JSON 只是摘要。

## `moonfmi.package/v1` — `moonfmi package --json`

```json
{
  "schema": "moonfmi.package/v1",
  "directory": "build/MyModel",
  "output": "dist/MyModel.fmu",
  "entries": 12,
  "bytes": 23114,
  "sha256": "…",
  "deterministic": true,
  "roundtripValid": true,
  "warnings": []
}
```

## `moonfmi.doctor/v1` — `moonfmi doctor --json`

```json
{
  "schema": "moonfmi.doctor/v1",
  "checks": [
    { "name": "platform-mapping", "status": "ok", "detail": "windows", "required": true },
    { "name": "tool-xmllint", "status": "skip", "detail": "not on PATH", "required": false }
  ]
}
```

- `status` ∈ `ok | fail | skip`;必需项 `fail` → 退出码 7。

## 退出码(cli-and-testing.md §4)

| 码 | 含义 | 典型来源 |
| --- | --- | --- |
| 0 | 成功 | 全部命令 |
| 1 | 一般错误/无效 | 校验失败、加载失败、写文件失败 |
| 2 | 用法错误 | 未知命令/flag、缺参数 |
| 3 | 读文件失败 | `validate`/`info`/`simulate` |
| 4 | 不支持 | wasm 后端、FMI 3 传入 FMI 2 加载器、缺平台二进制 |
| 5 | 仿真失败 | FMI error/fatal、Discard 未恢复 |
| 6 | 超时 | `--timeout` 到期 |
| 7 | 环境缺失 | 主机平台未知、doctor 必需项失败 |
