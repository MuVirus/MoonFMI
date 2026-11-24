// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "MuVirus/fmi"

version = "0.8.2"

readme = "README.md"

repository = "https://github.com/MuVirus/MoonFMI.git"

license = "Apache-2.0"

keywords = [ ]

preferred_target = "native"

description = "An experimental MoonBit interface to FMI-compliant FMUs."

import {
  "Milky2018/xml@0.6.1",
  "hustcer/fzip@0.8.8",
  "moonbitlang/async@0.22.9",
  "moonbitlang/x@0.5.7",
  "tonyfettes/c@0.8.0",
  "MuVirus/moonfig@0.2.4",
}
