///|
/// 校验一个 FMU 归档（或一份裸的 `modelDescription.xml`），并打印模型摘要
/// 与全部诊断。
///
/// 这是库用法的最小例子：只依赖 `src/fmi`，不加载任何动态库，所以在
/// native 与 wasm 上都能跑。
///
///   moon run examples/validate-model --target native -- \
///       tests/data/.cache/fmi2/BouncingBall.fmu
///
/// 退出码：`0` 没有错误，`1` 有错误，`2` 用法错误，`3` 文件读不了。

///|
/// 模型声明的接口，例如 `CoSimulation, ModelExchange`。
fn interfaces_of(model : @schema.ModelDescription) -> String {
  let names : Array[String] = []
  match model {
    @schema.V2(v2) =>
      for interface in v2.interfaces() {
        names.push(interface.kind.name())
      }
    @schema.V3(v3) =>
      for interface in v3.interfaces {
        names.push(interface.kind.name())
      }
  }
  names.join(", ")
}

///|
fn main {
  let args = @common.arguments()
  if args.is_empty() {
    @common.fail(
      2, "usage: moon run examples/validate-model --target native -- <fmu>",
    )
  }
  let path = args[0]
  // 可以是完整的 .fmu 归档，也可以是一份裸的 modelDescription.xml。
  let data = @fs.read_file_to_bytes(path) catch {
    error =>
      match error {
        @fs.IOError(message) =>
          @common.fail(3, "cannot read '\{path}': \{message}")
      }
  }
  // 一次调用走完整条校验流水线：容器检查、XML 解析、MD-001..MD-063 语义
  // 规则；归档里带 WASM 组件时还会顺带检查 LS-WASM manifest。
  let (model, report) = @fmi.validate_fmu_bytes(data)
  // 解析成功才有摘要；解析失败时原因在下面的诊断里。
  match model {
    Some(model) => {
      println("model:    \{model.model_name()}")
      println("fmi:      \{model.fmi_version_text()}")
      println("vars:     \{model.variable_count()}")
      println("ifaces:   \{interfaces_of(model)}")
    }
    None => println("model:    <the model description could not be parsed>")
  }
  println(
    "checks:   \{report.error_count()} error(s), \{report.warning_count()} warning(s), \{report.info_count()} info",
  )
  for diagnostic in report.diagnostics() {
    println(diagnostic.render())
  }
  // 有错误就以 1 退出，脚本可以据此判断；只有警告不算失败。
  if report.error_count() > 0 {
    @env.exit(1)
  }
}
