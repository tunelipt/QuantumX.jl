# QuantumX.jl

Julia interface to the **HBM QuantumX low-level API** (`HBM_QX_Framework.dll`), built with
[CxxWrap.jl](https://github.com/JuliaInterop/CxxWrap.jl).

## Requirements

| What | Why | How |
|---|---|---|
| **32-bit Julia** | `HBM_QX_Framework.dll` is a 32-bit DLL and can only be loaded into a 32-bit process | `juliaup add release~x86`, then start with `julia +release~x86` |
| 32-bit MinGW-w64 `g++` | compiles the CxxWrap wrapper | MSYS2: `pacman -S mingw-w64-i686-gcc` (default path `C:\msys64\mingw32\bin\g++.exe`) |
| HBM SDK folder | headers, import library, DLLs | `QuantumX Low-level API` next to this package folder |

Environment variables (optional):

* `QUANTUMX_SDK_DIR` – SDK folder (build and run time). Default: `../QuantumX Low-level API`.
* `QUANTUMX_CXX` – path of the i686 `g++` (build time).

## Build

```bash
cd QuantumX.jl
julia +release~x86 --project=. -e "using Pkg; Pkg.instantiate(); Pkg.build()"
```

This compiles `deps/src/quantumx_wrap.cpp` into `deps/usr/bin/libquantumx_wrap.dll`.
Rebuild after updating CxxWrap (the wrapper is tied to the `libcxxwrap_julia` version).

Tests (no hardware needed; set `QUANTUMX_TEST_IP` to also run the hardware tests):

```bash
julia +release~x86 --project=. test/runtests.jl
```

## Usage

```julia
using QuantumX

dev = connect("192.168.169.10")                # QXDevice; HBM_Init is called automatically
scan_network()                                 # modules on the Ethernet segment

# parameters
xml = read_xml(dev, PARVIEW_CONNECTORPARAM)
sp  = stSignalParams(Number = 1, FilterType = FILTERTYPE_LOWPASS, FiltCharact = FILTERCHARACT_BESSEL,
                     FiltFreq = 100, OutputRate = 600, DecimalPlaces = 5)
write_xml_section(dev, PARVIEW_CONNECTORPARAM, channel_path(3), compose_xml(sp))

# single values
measure(dev, 3)                                # connector 3, signal 1, physical units (NaN if open)
measure_all(dev)

# continuous acquisition
sub = subscribe(dev, [signal_path(c) for c in 1:4])   # blocksize = 10000 bytes per signal
blocks = read_block(sub)                       # Vector{SignalBlock}, values in host order
blocks[1].values, timestamps(blocks[1])
request_block(sub); blocks = wait_block(sub)   # asynchronous variant
unsubscribe(sub)

disconnect(dev)
```

Errors: functions throw `QXError(func, code)`; its message includes the symbolic name
(`ERR_TCP_CONNECT_FAILED`, …) and the DLL's error text.

### Raw layer

Every exported C function is available in `QuantumX.LibQX` under its C name, returning
the C return code instead of throwing:

```julia
using QuantumX: LibQX
rc, uuid = LibQX.HBM_XCOM_ConnectToTcpIpDev("192.168.169.10", 0x1389)
rc, xml  = LibQX.HBM_XPAR_ReadXML(uuid, LibQX.PARVIEW_IOPARAM, 1, 4_000_000)
```

Conventions (see the header of `deps/src/quantumx_wrap.cpp`):

* output pointers are returned as a tuple after the return code;
* text buffers (`char*`, `UINT32* len`, `MaxSize`) take `MaxSize` and return a `String`;
* binary buffers are caller-owned Julia vectors (`Vector{UInt8}`, `Vector{Float64}`, `Vector{Int32}`);
* C structs map 1:1 to Julia isbits types (`stSensor`, `stTrigInfo`, …). Create them with
  keyword constructors (unset fields are zero), read `char[N]` fields with `cstring`,
  and modify copies with `setfields`.
* C enums are Julia `@enum`s (`ParView`, `SensorType`, …; C value names are kept).

## Design notes

* **C++ runtime isolation.** Julia's 32-bit runtime uses SJLJ exceptions while MSYS2's
  mingw32 GCC uses DWARF-2. The wrapper links libstdc++/libgcc/winpthread statically and
  passes no C++ objects (`std::string`, `std::vector`) to Julia; only Julia values,
  isbits structs and tuples cross the boundary.
* **DLL selection.** `HBM_QX_Framework.dll` and `pthreadVC2.dll` are loaded by full path
  from the SDK folder before the wrapper, so a different `HBM_QX_Framework.dll` on `PATH`
  (e.g. from a *QuantumX API* installation) is not picked up. If another copy is already
  loaded in the process, loading fails with an explanatory error.
* **Layout check.** On load, the sizes and field offsets of all mirrored structs are compared
  with C++ `sizeof`/`offsetof`; a mismatch is an error.
* **Import library quirk.** `HBM_XCTRL_ReadXML` and `HBM_XSYS_RequestDebugInfo` are exported
  undecorated by the DLL, but `HBM_QX_Framework.lib` references them by C++-mangled names, so
  the wrapper resolves these two with `GetProcAddress`.
* **Asynchronous reads.** The length variable written by `HBM_XDAQ_Async_GetMeasValBlock`
  is kept alive in C++ per request handle, and the Julia receive buffer stays referenced until
  `wait_block` completes.
* `gen/generate.jl` regenerates `src/generated/{enums,errors}.jl` from the SDK headers.

## Not verified without hardware

The offline test suite covers loading, struct layouts, xpaths, XML compose/parse round trips,
units, error texts, time conversion and decoding of a synthetic measured value block via
`HBM_XUTIL_GetDaqHeader`/`GetDaqData`. Communication with a module (parameters, measurement,
asynchronous reads, the timestamp layout of asynchronous signal formats) still needs
testing with a real device: `QUANTUMX_TEST_IP=… julia +release~x86 --project=. test/runtests.jl`.
