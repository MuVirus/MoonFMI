///|
/// 把两个 FMU 组成一次耦合仿真：第一个 FMU 的输出接到第二个 FMU 的输入，
/// 宿主按拓扑序推进参与者。
///
///   moon run examples/couple-fmus --target native -- \
///       tests/data/.cache/fmi2/Dahlquist.fmu \
///       tests/data/.cache/fmi2/Feedthrough.fmu \
///       coupled.csv
///
/// 示例用 Dahlquist（线性衰减状态 `x`）驱动 Feedthrough 的
/// `Float64_continuous_input`，再录下 Feedthrough 的输出。
///
/// 关键点：连线用的是 value reference，而 value reference 只在单个模型
/// 描述内有效，所以这里按"变量名"反查，而不是写死数字。
///
/// 示例按 FMI 2 写（两个语料 FMU 都是 FMI 2）。FMI 3 的参与者把加载器换成
/// `load_fmi3_fmu`、把列的收集换成 `fmi3_columns` 即可，其余不变。

///|
/// 仿真的起始时间，单位秒。
const START_TIME : Double = 0.0

///|
/// 仿真的结束时间，单位秒。
const STOP_TIME : Double = 1.0

///|
/// 通信步长，单位秒。取 0.1：Dahlquist 自带的步进就是这个量级，每一步都能
/// 看到源模型的变化。
const STEP_SIZE : Double = 0.1

///|
/// 源模型的输出变量名。
const SOURCE_OUTPUT : String = "x"

///|
/// 目标模型的输入变量名。
const TARGET_INPUT : String = "Float64_continuous_input"

///|
/// 目标模型的输出变量名。
const TARGET_OUTPUT : String = "Float64_continuous_output"

///|
/// 按名字查 value reference；找不到就返回 `None`。
fn find_vr(model : @schema.Fmi2ModelDescription, name : String) -> UInt32? {
  for variable in model.variables {
    if variable.name == name {
      return Some(variable.value_reference)
    }
  }
  None
}

///|
fn main {
  let args = @common.arguments()
  if args.length() < 2 {
    @common.fail(
      2, "usage: moon run examples/couple-fmus --target native -- <source.fmu> <target.fmu> [out.csv]",
    )
  }
  let source_path = args[0]
  let target_path = args[1]
  let output = if args.length() > 2 { Some(args[2]) } else { None }
  let source_data = @fs.read_file_to_bytes(source_path) catch {
    error =>
      match error {
        @fs.IOError(message) =>
          @common.fail(3, "cannot read '\{source_path}': \{message}")
      }
  }
  let target_data = @fs.read_file_to_bytes(target_path) catch {
    error =>
      match error {
        @fs.IOError(message) =>
          @common.fail(3, "cannot read '\{target_path}': \{message}")
      }
  }
  let host_name = @native.host_platform_name()
  let host = match @fmi.parse_host_platform(host_name) {
    Some(host) => host
    None => @common.fail(4, "unknown host platform '\{host_name}'")
  }
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let stamp = @env.now()
  // 每个 FMU 解压到自己的空目录，互不干扰。
  let source = @native.load_fmi2_fmu(
    source_data,
    host~,
    temp_directory=".moonfmi-tmp/couple-\{stamp}-source",
  ) catch {
    error => @common.fail(1, "cannot load '\{source_path}': \{error.message()}")
  }
  let target = @native.load_fmi2_fmu(
    target_data,
    host~,
    temp_directory=".moonfmi-tmp/couple-\{stamp}-target",
  ) catch {
    error => {
      source.dispose()
      @common.fail(1, "cannot load '\{target_path}': \{error.message()}")
    }
  }
  let source_vr = match find_vr(source.model(), SOURCE_OUTPUT) {
    Some(reference) => reference
    None => {
      source.dispose()
      target.dispose()
      @common.fail(
        1,
        "'\{source_path}' has no variable named '\{SOURCE_OUTPUT}'",
      )
    }
  }
  let target_in_vr = match find_vr(target.model(), TARGET_INPUT) {
    Some(reference) => reference
    None => {
      source.dispose()
      target.dispose()
      @common.fail(
        1,
        "'\{target_path}' has no variable named '\{TARGET_INPUT}'",
      )
    }
  }
  let target_out_vr = match find_vr(target.model(), TARGET_OUTPUT) {
    Some(reference) => reference
    None => {
      source.dispose()
      target.dispose()
      @common.fail(
        1,
        "'\{target_path}' has no variable named '\{TARGET_OUTPUT}'",
      )
    }
  }
  // 参与者按声明顺序给出；连线指明谁驱动谁，宿主据此排拓扑序。
  // 每个参与者只录自己关心的变量：源录驱动量，目标录响应量。
  let config = @sim.CoupledConfig::new(
    start_time=START_TIME,
    stop_time=STOP_TIME,
    step_size=STEP_SIZE,
    participants=[
      @sim.CoupledParticipant::new(name="source", instance=source.instance(), record=[
        source_vr,
      ]),
      @sim.CoupledParticipant::new(name="target", instance=target.instance(), record=[
        target_out_vr,
      ]),
    ],
    connections=[
      @sim.Coupling::new(
        from="source",
        out_vr=source_vr,
        to="target",
        in_vr=target_in_vr,
      ),
    ],
  )
  let result = @sim.run_coupled_simulation(config~) catch {
    error => {
      source.dispose()
      target.dispose()
      @common.fail(5, "coupled simulation failed: \{error.message()}")
    }
  }
  source.dispose()
  target.dispose()
  // 结果里的序列按参与者声明顺序拼接：先是 source 的，再是 target 的，
  // 所以列名也是这个顺序。
  let names = ["source.\{SOURCE_OUTPUT}", "target.\{TARGET_OUTPUT}"]
  let csv = @common.to_csv(names, result)
  match output {
    Some(file) => {
      @fs.write_string_to_file(file, csv) catch {
        error =>
          match error {
            @fs.IOError(message) =>
              @common.fail(1, "cannot write '\{file}': \{message}")
          }
      }
      println(
        "coupled \{source_path} -> \{target_path}: \{result.steps()} steps, \{names.length()} output(s) -> \{file}",
      )
    }
    None => println(csv)
  }
}
