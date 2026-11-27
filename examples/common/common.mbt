///|
/// 示例共用的小工具：命令行参数、失败退出、输出列收集、CSV 渲染。
///
/// 每个示例都是一个独立的可执行包，这一份 helpers 只是把重复的部分收在一
/// 处——抄进自己的工程时把它一起带上即可。

///|
/// 打印一行消息并以给定退出码结束。`@env.exit` 不会返回，所以这个函数的
/// 返回类型可以是任意类型——错误分支因此能直接嵌在表达式里。
pub fn[T] fail(code : Int32, message : String) -> T {
  println(message)
  @env.exit(code)
}

///|
/// 命令行参数。`moon run` 会把可执行文件路径放在 `argv[0]`，第一个看起来
/// 像路径的参数要丢掉。
pub fn arguments() -> Array[String] {
  let args = @env.args()
  if args.is_empty() {
    return args
  }
  let first = args[0]
  if first.contains("/") || first.contains("\\") {
    let rest : Array[String] = []
    for index = 1; index < args.length(); index = index + 1 {
      rest.push(args[index])
    }
    return rest
  }
  args
}

///|
/// FMI 2 模型里所有 Real 输出的 value reference 与名字，按文档顺序。
pub fn fmi2_columns(
  model : @schema.Fmi2ModelDescription,
) -> Array[(UInt32, String)] {
  let columns : Array[(UInt32, String)] = []
  for variable in model.variables {
    if variable.effective_causality() == @schema.Causality::Output {
      match variable.payload {
        @schema.Fmi2Payload::Real(_) =>
          columns.push((variable.value_reference, variable.name))
        _ => ()
      }
    }
  }
  columns
}

///|
/// FMI 3 模型里所有 Float64 标量输出。Float32 与数组输出没有录进来：
/// 录制器是 Double 的，数组要另外用 `RecordedArray` 展开成 `name[i]` 列。
pub fn fmi3_columns(
  model : @schema.Fmi3ModelDescription,
) -> Array[(UInt32, String)] {
  let columns : Array[(UInt32, String)] = []
  for variable in model.variables {
    if variable.effective_causality() == @schema.Causality::Output &&
      variable.type_kind is @schema.Fmi3TypeKind::Float64 &&
      variable.dimensions.is_empty() {
      columns.push((variable.value_reference, variable.name))
    }
  }
  columns
}

///|
/// 把仿真结果渲染成 CSV：第一行是 `time,<列名>`，之后每个采样点一行。
pub fn to_csv(names : Array[String], result : @sim.SimulationResult) -> String {
  let builder = StringBuilder()
  builder.write_string("time")
  for name in names {
    builder.write_string(",")
    builder.write_string(name)
  }
  builder.write_string("\n")
  for row, time in result.times() {
    builder.write_string(time.to_string())
    for index = 0; index < names.length(); index = index + 1 {
      builder.write_string(",")
      builder.write_string(result.series()[index][row].to_string())
    }
    builder.write_string("\n")
  }
  builder.to_string()
}
