///|
/// 从模型 IR 生成一个源码 FMU，并确定性打包成 `.fmu`。
///
///   moon run examples/export-source-fmu --target native -- \
///       .moonfmi-tmp/export-example
///
/// 导出器覆盖的是受限的显式模型：连续状态、直通输出、参数与输入。方程只
/// 支持 IR 里那几种构造，它不是 Modelica 编译器。
///
/// 生成的 `.fmu` 是源码 FMU：里面有 `modelDescription.xml`、C 源码和
/// `CMakeLists.txt`，但没有编译好的动态库。要在 MoonFMI 里真正跑它，先用
/// CMake 编出 `binaries/<平台>/` 下的库，再把目录重新打包。

///|
/// 一个最小模型：`x' = -k*x`，输出 `y = x`。
/// value reference 按声明顺序分配：k = 0，x = 1，y = 2。
fn build_ir() -> @export.ModelIr {
  let ir = @export.ModelIr::new(
    model_name="MoonfmiExample",
    generation_tool="MoonFMI example",
    description="x' = -k*x with one continuous state",
  )
  ir.add_interface(
    kind=@schema.InterfaceKind::CoSimulation,
    model_identifier="MoonfmiExample",
  )
  ir.add_interface(
    kind=@schema.InterfaceKind::ModelExchange,
    model_identifier="MoonfmiExample",
  )
  ignore(
    ir.add_real_parameter(name="k", start=1.0, description="decay constant"),
  )
  ignore(ir.add_real_state(name="x", start=1.0, description="state"))
  ignore(ir.add_real_output(name="y", description="output"))
  // 方程用 IR 表达式描述：变量引用、常数与四则运算。
  ir.add_derivative(
    state="x",
    expr=@export.IrExpr::mul(
      @export.IrExpr::neg(@export.IrExpr::v("k")),
      @export.IrExpr::v("x"),
    ),
  )
  ir.add_output_equation(output="y", expr=@export.IrExpr::v("x"))
  ir
}

///|
fn main {
  let args = @common.arguments()
  // 参数可选：给了就是输出目录，不给就用默认的 .moonfmi-tmp/export-example。
  let output_dir = if args.is_empty() {
    ".moonfmi-tmp/export-example"
  } else {
    args[0]
  }
  let options = @export.ExportOptions::new(
    // 换成 @schema.FmiVersion::V3 就是 FMI 3 的源码 FMU（会多一份
    // buildDescription.xml）。
    fmi_version=@schema.FmiVersion::V2,
    output_dir=Some(output_dir),
    // 顺手把生成的源码目录打成确定性 .fmu（同样的 IR 两次导出字节相同）。
    write_fmu=true,
  )
  // 导出器先自检 IR（方程指向不存在的变量之类会直接报错），再生成文件。
  let result = @export.export_source_fmu(build_ir(), options) catch {
    error => @common.fail(1, "export failed: \{error.message()}")
  }
  println("output:  \{result.output_dir}")
  for (name, _bytes) in result.files {
    println("  \{name}")
  }
  match result.fmu_path {
    Some(path) => println("fmu:     \{path}")
    None => ()
  }
  match result.sha256 {
    Some(hash) => println("sha256:  \{hash}")
    None => ()
  }
  for diagnostic in result.diagnostics {
    println("warning: \{diagnostic.render()}")
  }
  // 生成的模型描述要能通过自己的校验器——导出与导入是闭环的。
  let (_model, report) = @schema.parse_and_validate(result.files[0].1)
  if !report.is_valid() {
    @common.fail(
      1,
      "the generated modelDescription.xml failed validation: \{report.diagnostics()[0].render()}",
    )
  }
  println("the generated modelDescription.xml passes validation")
}
