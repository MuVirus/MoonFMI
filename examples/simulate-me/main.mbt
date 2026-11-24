///|
/// 加载一个 FMU，跑一次模型交换（Model Exchange）仿真，把录到的输出写成
/// CSV。
///
///   moon run examples/simulate-me --target native -- \
///       tests/data/.cache/fmi2/VanDerPol.fmu vdp.csv
///
/// ME 与 CS 的差别在宿主这一侧：模型交换的模型不提供 `fmi2DoStep`，宿主
/// 自己积分连续状态（Euler 或经典 RK4），再用 `fmi2SetContinuousStates`
/// 把状态写回模型。因此 ME 的配置里要额外给出连续状态数与事件指示器数，
/// 它们来自模型描述。

///|
/// 仿真的起始时间。
const START_TIME : Double = 0.0

///|
/// 仿真的结束时间。
const STOP_TIME : Double = 5.0

///|
/// 积分步长。
const STEP_SIZE : Double = 0.01

///|
/// 跑模型交换主算法。`MeInstance` 是 `src/fmi` 里的 trait，FMI 2 与 FMI 3
/// 的实例都实现了它。
fn run_me(
  instance : &@fmi.MeInstance,
  references : Array[UInt32],
  state_count : Int32,
  event_indicator_count : Int32,
) -> @sim.SimulationResult raise @fmi.SimulationError {
  let config = @sim.MeConfig::new(
    start_time=START_TIME,
    stop_time=STOP_TIME,
    step_size=STEP_SIZE,
    record=references,
    // 换成 @sim.Euler 就是一阶显式欧拉；RK4 精度更高，代价是每步四次求值。
    solver=@sim.Rk4,
    // 连续状态数与事件指示器数：ME 的模型只给导数、不给「一步」，宿主按
    // 这两个数字开缓冲区，然后自己积分再把状态写回去。
    state_count~,
    event_indicator_count~,
  )
  @sim.run_me_simulation(instance, config~)
}

///|
fn main {
  let args = @common.arguments()
  if args.is_empty() {
    @common.fail(
      2, "usage: moon run examples/simulate-me --target native -- <fmu> [out.csv]",
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
  // 加载器要求一个全新的空目录：整个 FMU 会被解压进去。
  @fs.create_dir(".moonfmi-tmp") catch {
    _ => ()
  }
  let work_dir = ".moonfmi-tmp/run-\{@env.now()}"
  let (names, result) = if is_fmi3 {
    // ME 的加载器：除了 CS 那几件事，还要读出连续状态数与事件指示器数。
    let loaded = @native.load_fmi3_me_fmu(data, host~, temp_directory=work_dir) catch {
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
    // 主算法只认 MeInstance 这个 trait，FMI 2 与 FMI 3 共用同一份代码。
    let result = run_me(
      loaded.instance(),
      references,
      loaded.state_count,
      loaded.event_indicator_count,
    ) catch {
      error => {
        loaded.dispose()
        @common.fail(5, "simulation failed: \{error.message()}")
      }
    }
    // 释放实例、卸载动态库、删掉解压目录。
    loaded.dispose()
    (names, result)
  } else {
    let loaded = @native.load_fmi2_me_fmu(data, host~, temp_directory=work_dir) catch {
      error => @common.fail(1, "cannot load '\{path}': \{error.message()}")
    }
    let columns = @common.fmi2_columns(loaded.model())
    let references : Array[UInt32] = []
    let names : Array[String] = []
    for column in columns {
      references.push(column.0)
      names.push(column.1)
    }
    let result = run_me(
      loaded.instance(),
      references,
      loaded.state_count,
      loaded.event_indicator_count,
    ) catch {
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
        "simulated \{path}: \{result.steps()} steps, \{result.events()} event(s), \{names.length()} output(s) -> \{file}",
      )
    }
    None => println(csv)
  }
}
