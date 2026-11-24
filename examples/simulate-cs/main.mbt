///|
/// 加载一个 FMU，跑一次联合仿真（Co-Simulation），把录到的输出写成 CSV。
///
///   moon run examples/simulate-cs --target native -- \
///       tests/data/.cache/fmi2/BouncingBall.fmu ball.csv
///
/// FMI 2 与 FMI 3 走同一条流程：先从归档里的 `modelDescription.xml` 判断
/// 版本，再挑对应的加载器；加载之后两边的接口都是 `CsInstance`，主算法
/// 因此可以复用同一份代码。
///
/// 要改仿真区间，改下面的常量即可；换成自己的 FMU 只要换路径。

///|
/// 仿真的起始时间。
const START_TIME : Double = 0.0

///|
/// 仿真的结束时间。
const STOP_TIME : Double = 3.0

///|
/// 通信步长。
const STEP_SIZE : Double = 0.01

///|
/// 跑联合仿真主算法。`CsInstance` 是 `src/fmi` 里的 trait，FMI 2 与
/// FMI 3 的实例都实现了它。
fn run_cs(
  instance : &@fmi.CsInstance,
  references : Array[UInt32],
) -> @sim.SimulationResult raise @fmi.SimulationError {
  let config = @sim.CsConfig::new(
    start_time=START_TIME,
    stop_time=STOP_TIME,
    step_size=STEP_SIZE,
    record=references,
  )
  @sim.run_cs_simulation(instance, config~)
}

///|
fn main {
  let args = @common.arguments()
  if args.is_empty() {
    @common.fail(
      2, "usage: moon run examples/simulate-cs --target native -- <fmu> [out.csv]",
    )
  }
  let path = args[0]
  // 第二个参数可选：给了就写文件，不给就把 CSV 打到标准输出。
  let output = if args.length() > 1 { Some(args[1]) } else { None }
  // 整个归档读进内存；后面的加载器只需要这份字节。
  let data = @fs.read_file_to_bytes(path) catch {
    error =>
      match error {
        @fs.IOError(message) =>
          @common.fail(3, "cannot read '\{path}': \{message}")
      }
  }
  // 从归档里的模型描述判断 FMI 版本：两个版本的加载器和实例类型不同。
  let (model, _report) = @fmi.validate_fmu_bytes(data)
  let is_fmi3 = match model {
    Some(@schema.V3(_)) => true
    _ => false
  }
  // 平台串形如 "x86_64-windows"，决定去 binaries/ 下取哪个二进制。
  let host_name = @native.host_platform_name()
  let host = match @fmi.parse_host_platform(host_name) {
    Some(host) => host
    None => @common.fail(4, "unknown host platform '\{host_name}'")
  }
  // 加载器要求一个全新的空目录：整个 FMU 会被解压进去，动态库和资源才有
  // 真实路径。dispose() 会卸载动态库并删掉这个目录。
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let work_dir = ".moonfmi-tmp/run-\{@env.now()}"
  let (names, result) = if is_fmi3 {
    // 加载器一次做完四件事：开归档 → 校验模型描述 → 选平台二进制 →
    // 加载动态库 → 实例化 FMU。
    let loaded = @native.load_fmi3_fmu(data, host~, temp_directory=work_dir) catch {
      error => @common.fail(1, "cannot load '\{path}': \{error.message()}")
    }
    // 要录哪些输出：从模型描述里挑 Real 输出，拿它们的 value reference。
    let columns = @common.fmi3_columns(loaded.model())
    let references : Array[UInt32] = []
    let names : Array[String] = []
    for column in columns {
      references.push(column.0)
      names.push(column.1)
    }
    // 主算法只认 CsInstance 这个 trait，FMI 2 与 FMI 3 共用同一份代码。
    let result = run_cs(loaded.instance(), references) catch {
      error => {
        loaded.dispose()
        @common.fail(5, "simulation failed: \{error.message()}")
      }
    }
    // 释放实例、卸载动态库、删掉解压目录；成功和失败路径都要调。
    loaded.dispose()
    (names, result)
  } else {
    let loaded = @native.load_fmi2_fmu(data, host~, temp_directory=work_dir) catch {
      error => @common.fail(1, "cannot load '\{path}': \{error.message()}")
    }
    let columns = @common.fmi2_columns(loaded.model())
    let references : Array[UInt32] = []
    let names : Array[String] = []
    for column in columns {
      references.push(column.0)
      names.push(column.1)
    }
    let result = run_cs(loaded.instance(), references) catch {
      error => {
        loaded.dispose()
        @common.fail(5, "simulation failed: \{error.message()}")
      }
    }
    loaded.dispose()
    (names, result)
  }
  // 结果是一组时间点加每列一条序列，渲染成 `time,<列名>` 的 CSV。
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
        "simulated \{path}: \{result.steps()} steps, \{names.length()} output(s) -> \{file}",
      )
    }
    None => println(csv)
  }
}
