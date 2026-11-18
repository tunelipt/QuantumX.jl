# CLAUDE.md

Julia interface (`QuantumX.jl`) to HBM's QuantumX low-level API, built with
[CxxWrap.jl](https://github.com/JuliaInterop/CxxWrap.jl). Windows only, 32-bit only.
Repository: https://github.com/tunelipt/QuantumX.jl

## Layout

All paths below are relative to this package folder.

```
deps/build.jl                compiles the wrapper → deps/usr/bin/libquantumx_wrap.dll, writes deps/deps.jl
deps/src/quantumx_wrap.cpp   CxxWrap bindings of all 125 API functions
gen/generate.jl              regenerates src/generated/{enums,errors}.jl from the SDK headers
src/QuantumX.jl              module, DLL loading, LibQX submodule, layout check, exports
src/types.jl                 Julia isbits mirrors of the C structs + helpers (cstring, cchars, setfields)
src/generated/               49 C enums as Julia @enum, 406 tError codes (generated, checked in)
src/constants.jl             selected #define constants
src/errors.jl                QXError, return-code checking (`@qx`, `_check`)
src/api.jl                   high-level API (connect, read_xml, measure, compose_xml, ...)
src/daq.jl                   Subscription, read_block / request_block / wait_block, block decoding
test/runtests.jl             offline tests (51); test/hardware.jl runs if QUANTUMX_TEST_IP is set
examples/acquire.jl          port of the help file's acquisition example
```

The HBM SDK is **not** part of this repository (HBM license). It is expected in the sibling folder
`../QuantumX Low-level API` (headers, `HBM_QX_Framework.{dll,lib}`, `pthreadVC2.dll`, `QuantumX_DLL.chm`;
DLL version 1.4.0.1, 2009), or wherever `QUANTUMX_SDK_DIR` points.

## Toolchain (required)

- **32-bit Julia**: `HBM_QX_Framework.dll` is 32 bit. Install with `juliaup add release~x86`
  and always run `julia +release~x86`. A 64-bit Julia cannot load the DLL.
- **Compiler**: MSYS2 `C:\msys64\mingw32\bin\g++.exe` (i686; `pacman -S mingw-w64-i686-gcc`).
  Override with `QUANTUMX_CXX`.
- **CxxWrap 0.17.x** (built and tested with 0.17.5). Rebuild the wrapper DLL when CxxWrap changes.
- SDK location: `QUANTUMX_SDK_DIR` (default `../QuantumX Low-level API`).

## Commands

```bash
julia +release~x86 --project=. -e "using Pkg; Pkg.instantiate(); Pkg.build()"   # build wrapper
julia +release~x86 --project=. test/runtests.jl                                  # tests
julia +release~x86 --startup-file=no gen/generate.jl                             # regenerate enums/errors
```

`Pkg.test()` failed in the 32-bit environment used for development ("expected package `Test` to be
registered"), so run `test/runtests.jl` directly (stdlib `Test` is on the default load path).

## Architecture

Two layers:

- **`QuantumX.LibQX`** – raw bindings, C names (`HBM_XPAR_ReadXML`, ...), never throw on error codes.
  Conventions: `const char*` → `String`; scalar output pointers are returned as a tuple after the
  return code (`rc, uuid = HBM_XCOM_ConnectToTcpIpDev(ip, port)`); text buffers take `MaxSize` and
  return a `String`; binary buffers are caller-owned Julia vectors (`ArrayRef`); C structs/enums are
  mapped with `mod.map_type` onto Julia isbits types / `@enum`s (C value names kept, `en` prefix
  dropped from type names, `enFormat` → `DaqFormat`).
- **`QuantumX`** – Julian functions that check return codes and throw `QXError(func, code)`
  (message includes the symbolic `ERR_*` name and `HBM_XUTIL_GetText` text). Positive return codes
  are only warned about when they are documented `WARN_*` codes (`HBM_Init` returns 1 on success).

## Pitfalls discovered (keep these in mind when changing things)

- **Exception models differ**: Julia 32-bit runtime uses SJLJ (`libgcc_s_sjlj-1.dll`), MSYS2 mingw32 uses
  DWARF-2. The wrapper links libstdc++/libgcc/winpthread **statically** and must not pass C++ objects
  (`std::string`, `std::vector`, `jlcxx::Array<std::string>` → `StdString`) to Julia. Return Julia
  Strings, isbits structs, tuples, or `jlcxx::Array` of isbits / `jl_value_t*` (GC-rooted with
  `JL_GC_PUSH`).
- **Two different DLLs may exist**: a *QuantumX API* installation (`C:\Program Files (x86)\HBM\QuantumX API\DLLs`,
  2012 version) may be on `PATH`; it lacks 13 functions of the SDK DLL and adds 9 others. `load_hbm_dll()`
  therefore dlopens `pthreadVC2.dll` and `HBM_QX_Framework.dll` by full path from the SDK folder before the
  wrapper (in `LibQX.__init__`, not cached across precompilation) and errors if another copy is already loaded.
  Supporting the 2012 DLL was offered and declined for now.
- **Import library quirk**: `HBM_XCTRL_ReadXML` and `HBM_XSYS_RequestDebugInfo` are exported undecorated,
  but `HBM_QX_Framework.lib` references C++-mangled names; the wrapper resolves them with `GetProcAddress`.
  All other functions link through the MSVC `.lib` (stdcall).
- **`HBM_Init` must run before XML compose/parse** (otherwise access violation). High-level functions call
  `_ensure_init()`; `init()` registers `HBM_Unload` at exit.
- **Lengths**: reported xpath/XML lengths exclude the NUL, so writes pass `sizeof(xml)`.
- **Struct layout**: 32-bit Julia aligns Float64/UInt64 to 8 like MSVC. `check_layout()` (run in `__init__`)
  compares 73 sizes/offsets with C++ `offsetof`/`sizeof` and errors on mismatch. `stSensor` contains
  `struct stPulseWidth;`/`struct stPeriodLength;` without member names — they take no space.
- **Async reads**: `HBM_XDAQ_Async_GetMeasValBlock` writes the received length later; the C++ side keeps that
  `UINT32` per handle, and Julia keeps pending subscriptions in `_PENDING` so the buffer is not GC'd.
- Generator: header comments must be stripped in one left-to-right pass (`//***` lines), files are CRLF/cp1252.

## Status

- Verified offline: loading, layouts, xpaths, XML compose/parse round trips, units, error texts, NTP time
  conversion, network scan call, and decoding of a synthetic big-endian measured-value block via
  `HBM_XUTIL_GetDaqHeader`/`GetDaqData` (confirms the wire format).
- **Not yet verified with hardware**: parameter read/write, subscriptions, async reads, and the assumed
  `[NTP timestamp][value]` layout of asynchronous data formats. Run with
  `QUANTUMX_TEST_IP=<module ip> julia +release~x86 --project=. test/runtests.jl`.
