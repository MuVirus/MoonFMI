# 动态库测试样品

`tests/abi` 保存 ABI 基线和动态加载实验用的 C 样品。

## 1. 动态加载样品

| 文件 | 作用 |
| --- | --- |
| `fixture.c` | 正常库：整数加法、浮点乘法、填结构体、接回调 |
| `dependency.c` | 被 `broken.c` 依赖的小库，编译后会被删掉 |
| `broken.c` | 故意依赖一个不存在的库，用来验证“缺依赖”诊断 |
| `build-fixture.ps1` | Windows 构建脚本（PowerShell + clang） |
| `build-fixture.sh` | Linux 构建脚本（sh + clang） |

构建产物写入 `tests/abi/.cache/`，该目录已被忽略，不进 git。`scripts/check.ps1` 和 `scripts/check.sh` 会在跑测试前先构建一次。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/abi/build-fixture.ps1
```

```bash
sh tests/abi/build-fixture.sh
```

Windows 产物是 `libmoonfmi_fixture.dll` 和 `libmoonfmi_broken.dll`，Linux 产物是 `libmoonfmi_fixture.so` 和 `libmoonfmi_broken.so`。`broken` 依赖的库在构建完成后立即删除，因此它一定是“加载失败”的状态。

## 2. ABI 基线（后续补充）

`sizeof` / `offsetof` 基线要到 P0 第三周才生成：

- `fmi2/` — Windows 和 Linux 的 `fmi2*` 类型与回调结构体基线；
- `fmi3/` — Windows 和 Linux 的 `fmi3*` 类型与回调结构体基线。

当前目录只包含动态加载样品。
