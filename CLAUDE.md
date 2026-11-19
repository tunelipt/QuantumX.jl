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
test/runtests.jl             offline tests (57); test/hardware.jl runs if QUANTUMX_TEST_IP is set
examples/acquire.jl          port of the help file's acquisition example
examples/acquire_rate.jl     set output rate, record N s, CSV, restore rates
examples/acquire_filter.jl   same with configurable filter (CLI options), restores settings
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

`Pkg.test()` and running `test/runtests.jl` directly both work. If juliaup names the 32-bit channel
differently (e.g. `1.13~x86`), use that name instead of `release~x86`.

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
- Verified with hardware (QuantumX module, 2026-11-19, `test/hardware.jl` passed): connect,
  `read_xml`, `signal_list`, `measure`/`measure_all`, `module_status`/`error_status`, subscribe +
  synchronous `read_block`, asynchronous `request_block`/`wait_block` (block arrives), unsubscribe/disconnect.
- Verified with hardware (2026-11-19): parameter reads/writes (`read_parameter`/`write_parameter` of
  `OutputRate`), `read_xml_section` + `parse_xml(stSignalParams, …)`, and 4 signals × 1200 Hz for 10–30 s
  (`examples/acquire_rate.jl`; blocks arrive about every 0.09 s). `AddSignal`'s `BlockSize` is in bytes
  per signal.
- MX840 output rates (probed 2026-11-19, firmware 1.5.12.0): the XSD only says `double ≥ 0`; the module rounds
  a requested `OutputRate` up to the next supported value (with `WARN_PAR_PARSING`) and caps it at 2400 Hz.
  Seen: 0.001, 0.005, 0.01, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 25, 50, 75, 100, 150, 200, 300, 600, 1200, 2400.
  Always read the rate back. Connector 1 is kept at a rate ≥ the other connectors': raising it can raise
  others, and lowering it while others are higher has no effect — restore rates in reverse order (8 → 1).
- **Module crashes (reboots) were caused by how we started/read the subscription**, not by the module
  (2026-11-19). The old `subscribe` passed `StartTime = 0` to `FinishSubscription` and a 2 MB `MaxLen`
  (`MEASVALBLOCKSIZELIMIT`) to `GetMeasValBlock`; the MX840 (firmware 1.5.12) then rebooted after a few
  seconds, intermittently at first and every time later. HBM's .NET layer (`QXSimpleDAQ`, disassembled from
  the 2009 `HBM.QuantumX.dll`, same `HBM_QX_Framework.dll`) instead gets the start time from an immediate
  trigger (`ActivateTrigger` TRIGTP_IMMEDIATE + `WaitForTrigger(1000 ms)`) and passes `MaxLen = Σ(BlockSize+24)`.
  `subscribe` now does the same (`module_time`, default `blocksize = 10000`, computed `bufsize`); since then
  600 Hz (previously 6/6 crashes), 1200 Hz and 8 × 2400 Hz for 120 s run without a crash. Which of the two
  changes is the actual fix was not isolated.
- After a reboot the module answers status at ~55 s but rejects connects (`ERR_CON_ADRRESINI_FAILED`) until
  ~70 s; its clock counts from power-on (no time sync) and `write_parameter` changes are lost.
- Open inputs (no sensor; connectors 7–8 on 2026-11-19) deliver the constant `3.689349e19` =
  `reinterpret(Float32, 0x5FFFFFFF)`, the module's invalid-value marker — not a decoding error. `measure`
  returns it as a Float64 near 2^65 with noisy low bits, so `isinvalid` compares by value (rtol 1e-6 of
  `INVALID_MARKER = 2^65`). `measure`, `measure_all`, `read_block`, `wait_block` and `decode_signal` turn it
  into `NaN` by default (`invalid_nan = false` for raw values).
- **Not yet verified with hardware**: the values/layout of asynchronous data formats
  (assumed `[NTP timestamp][value]`; the test only checks that a block arrives). A CAN `AsyncSignal`
  subscribed on its own is accepted and reports `0x5C` (FLOAT_ASYNC → `SignalBlock{Float32}`), but delivered
  0 values (connector in analog mode, no CAN traffic), so the layout needs a CAN source to verify.
- Mixing a sync (analog) and an async (CAN) signal in one subscription fails in `FinishSubscription` with
  `ERR_DAQ_TRIGTIME` (start time 0); each works alone. Not yet investigated (separate subscriptions? explicit
  start time?). Run hardware tests with
  `QUANTUMX_TEST_IP=<module ip> julia +release~x86 --project=. test/runtests.jl`.
