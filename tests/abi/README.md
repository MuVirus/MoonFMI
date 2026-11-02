# 动态库与 ABI 测试样品

`tests/abi` 保存 ABI 基线、C 参考宿主，以及动态加载和日志测试用的 C 样品。

所有构建产物都写进 `tests/abi/.cache/`，该目录已被忽略，不进 git。`scripts/check.ps1` 和 `scripts/check.sh` 会在跑测试前先构建一次。

## 1. 动态加载样品

| 文件 | 作用 |
| --- | --- |
| `fixture.c` | 正常库：整数加法、浮点乘法、填结构体、接回调 |
| `dependency.c` | 被 `broken.c` 依赖的小库，编译后会被删掉 |
| `broken.c` | 故意依赖一个不存在的库，用来验证“缺依赖”诊断 |
| `build-fixture.ps1` | Windows 构建脚本（PowerShell + clang） |
| `build-fixture.sh` | Linux 构建脚本（sh + clang） |

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/abi/build-fixture.ps1
```

```bash
sh tests/abi/build-fixture.sh
```

Windows 产物是 `libmoonfmi_fixture.dll` 和 `libmoonfmi_broken.dll`，Linux 产物是 `libmoonfmi_fixture.so` 和 `libmoonfmi_broken.so`。`broken` 依赖的库在构建完成后立即删除，因此它一定是“加载失败”的状态。

## 2. ABI 基线

`probe.c` 用官方头文件打印 FMI 2 和 FMI 3 的 `sizeof`、`offsetof` 与枚举值，输出是 JSON。它不复制任何结构体定义——头文件改了，输出就跟着改。

```powershell
tests/abi/.cache/probe.exe --header   # 例如 x86_64-windows.json
tests/abi/.cache/probe.exe > tests/abi/baselines/x86_64-windows.json
```

```bash
tests/abi/.cache/probe --header       # 例如 x86_64-linux.json
tests/abi/.cache/probe > tests/abi/baselines/x86_64-linux.json
```

已提交的基线：

| 文件 | 平台 |
| --- | --- |
| `baselines/x86_64-windows.json` | Windows x86_64，MSVC 头文件/编译器 |
| `baselines/x86_64-linux.json` | Linux x86_64，clang |

比较：

```bash
node tests/abi/check-abi.mjs
```

脚本先用 `--header` 问出本机对应的基准文件名，再逐字段比较。缺失字段、多出字段、值不一致都会打印成 `fmi2.sizeof.fmi2Boolean: expected 4, got 8` 这样的行。新增平台时先提交一份基线，再让检查脚本去比。

两份基线目前内容相同。它们分开保存，是因为记录的是“这个平台实际是什么”，而不是“我们认为它们应该相同”。

## 3. 日志测试用的假 FMU

`logging_fmu.c` 是一个最小的 FMI 2 CS 库，不是真实模型。每次 `fmi2DoStep` 按配置打印 `count` 条 `kind` 类型的日志：

| kind | 内容 |
| --- | --- |
| 0 | 普通短消息 `step N` |
| 1 | 8192 字节 ASCII，应被截断到 4096 |
| 2 | 中文和 emoji |
| 3 | 4094 字节后接一个 3 字节字符，截断点落在字符中间 |
| 4 | 4093 字节后接一个 4 字节 emoji |
| 5 | 正好 4096 字节，不应被截断 |
| 6 | 从 FMU 自己创建的线程打印一条 |

值引用 0 控制条数，值引用 1 控制类型。`fmi2FreeInstance` 里也会打一条日志，用来验证释放开始后不再回调用户代码。

对应的 MoonBit 测试在 `tests/integration/fmi2_log_wbtest.mbt`。

## 4. C 参考宿主

`fmi2_host.c` 是一个只依赖官方头文件和平台加载器的独立 C 程序。它加载 `BouncingBall.fmu` 里的动态库，以 10 ms 步长跑到 3 秒，每 0.5 秒采样一次 `(time, h, v)`，输出 JSON。这份输出是 MoonBit 后端的对照答案。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/abi/run-fmi2-host.ps1
node tests/abi/check-host.mjs
```

```bash
sh tests/abi/run-fmi2-host.sh
node tests/abi/check-host.mjs
```

基准在 `baselines/fmi2-bouncingball.json`，共 6 个采样点。比较用相对误差 1e-9，因为两个宿主累积 300 步浮点加法的方式相同，差异只应来自打印精度。

两个细节：

- `fmuResourceLocation` 必须是 `file:` URI，传普通路径会让 `fmi2Instantiate` 失败；
- 头文件用相对路径 `../../docs/standards/headers/fmi2/fmi2Functions.h`，不额外加 `-I`。

## 5. 复现顺序

```bash
node tests/data/fetch-fmus.mjs                     # 取测试语料
powershell -File tests/abi/build-fixture.ps1       # 或 sh tests/abi/build-fixture.sh
node tests/abi/check-abi.mjs                       # ABI 基线
powershell -File tests/abi/run-fmi2-host.ps1       # C 参考宿主
node tests/abi/check-host.mjs                      # 对照基准
```
