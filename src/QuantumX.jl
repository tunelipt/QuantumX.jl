"""
    QuantumX

Julia interface to the HBM QuantumX low-level API (`HBM_QX_Framework.dll`), built with
CxxWrap.jl. Requires a **32-bit (x86) Julia** because the HBM DLL is 32 bit.

Two layers:

* `QuantumX.LibQX` – raw 1:1 bindings, C names (`LibQX.HBM_XPAR_ReadXML`, ...),
  returning the C return code (plus outputs as a tuple). No exceptions on error codes.
* `QuantumX` – Julian functions (`connect`, `read_xml`, `subscribe`, `read_block`, ...)
  that check return codes and throw [`QXError`](@ref).
"""
module QuantumX

using CxxWrap
using Libdl
using Dates

const DEPS_FILE = joinpath(@__DIR__, "..", "deps", "deps.jl")
isfile(DEPS_FILE) || error("QuantumX is not built. Run `using Pkg; Pkg.build(\"QuantumX\")` with a 32-bit Julia.")
include(DEPS_FILE)   # defines libquantumx_wrap, QX_SDK_DIR

"Directory holding HBM_QX_Framework.dll (ENV `QUANTUMX_SDK_DIR` overrides the build-time value)."
sdk_dir() = get(ENV, "QUANTUMX_SDK_DIR", QX_SDK_DIR)

# The wrapper DLL imports HBM_QX_Framework.dll, which imports pthreadVC2.dll. Windows
# does not search the SDK folder by itself (and may find another HBM_QX_Framework.dll on
# PATH, e.g. from a "QuantumX API" installation with a different set of exports), so
# load them explicitly by full path before the wrapper. dlopen is reference counted,
# so calling this repeatedly is harmless.
function load_hbm_dll()
    Sys.WORD_SIZE == 32 || error("QuantumX needs a 32-bit Julia (HBM_QX_Framework.dll is 32 bit). " *
                                 "Install one with `juliaup add release~x86`.")
    dir = sdk_dir()
    for lib in ("pthreadVC2.dll", "HBM_QX_Framework.dll")
        path = joinpath(dir, lib)
        isfile(path) || error("$lib not found in $dir (set ENV[\"QUANTUMX_SDK_DIR\"])")
        h = Libdl.dlopen(path)
        loaded = Libdl.dlpath(h)
        if lowercase(normpath(loaded)) != lowercase(normpath(path))
            error("A different $lib is already loaded in this Julia process:\n  $loaded\n" *
                  "QuantumX was built against\n  $path\nStart a fresh Julia session and load QuantumX " *
                  "before anything else that uses the HBM API.")
        end
    end
    return nothing
end

"""
Raw CxxWrap bindings of the QuantumX API. Function names are the C names.
See `deps/src/quantumx_wrap.cpp` for the calling conventions.
"""
module LibQX
    using CxxWrap
    import ..QuantumX

    include("generated/enums.jl")
    include("types.jl")

    QuantumX.load_hbm_dll()
    @wrapmodule(() -> QuantumX.libquantumx_wrap)

    function __init__()
        QuantumX.load_hbm_dll()
        @initcxx
    end
end

using .LibQX
# re-export the enums, constants and mirrored struct types
for n in LibQX.GENERATED_ENUM_NAMES
    @eval const $n = LibQX.$n
    # export the prefixed C value names (PARVIEW_IOPARAM, BRIDGESENSOR, ...); generic
    # names such as NORMAL, SYNC or Active stay qualified (QuantumX.NORMAL)
    occursin('_', string(n)) && @eval export $n
end
for n in (:BRIDGESENSOR, :INDBRIDGESENSOR, :VOLTAGESENSOR, :CURRENTSENSOR, :THERMOCOUPLE, :PTSENSOR,
          :POTISENSOR, :LVDTSENSOR, :COUNTERSENSOR, :FREQUENCYSENSOR, :SSISENSOR, :PWMSENSOR, :IEPESENSOR,
          :PRESSURESENSOR, :INDCOUNTERSENSOR, :INDFREQUENCYSENSOR, :PULSEWIDTHSENSOR, :PERIODSENSOR)
    @eval export $n
end
for T in LibQX.MIRRORED_STRUCTS
    n = nameof(T)
    @eval const $n = LibQX.$n
end
const cstring = LibQX.cstring
const cchars = LibQX.cchars
const setfields = LibQX.setfields
const next_timestamp = LibQX.next_timestamp
const current_value = LibQX.current_value
const status_value = LibQX.status_value

include("generated/errors.jl")
include("constants.jl")
include("errors.jl")
include("api.jl")
include("daq.jl")

function __init__()
    check_layout()
end

"""
    check_layout()

Compare the memory layout of the Julia mirror structs with the C++ `sizeof`/`offsetof`
values. Throws if they differ (which would corrupt data passed to the DLL).
"""
function check_layout()
    names, offs = LibQX.layout_info()
    entries = filter(!isempty, split(names, ','))
    bad = String[]
    for (entry, cval) in zip(entries, offs)
        tname, field = split(entry, '.')
        T = getfield(LibQX, Symbol(tname == "DeviceInfo" ? "stDeviceInfo" : tname))
        jval = field == "sizeof" ? sizeof(T) : Int(fieldoffset(T, Base.fieldindex(T, Symbol(field))))
        jval == cval || push!(bad, "$entry: C++ $cval, Julia $jval")
    end
    isempty(bad) || error("QuantumX: struct layout mismatch between C++ and Julia:\n" * join(bad, "\n"))
    return length(entries)
end

export QXError, QXDevice, uuid
export init, unload, isinitialized, dll_version, own_uuid, set_workdir
export net_adapters, scan_network, scan_network_xml, scan_firewire, scan_firewire_xml
export connect, disconnect
export read_xml, write_xml, read_xml_section, write_xml_section, read_xsd, read_xslt,
       read_xsd_section, read_xslt_section, read_parameter, write_parameter,
       activate_default, activate_all_defaults, last_param_error, param_views
export connected_modules, topology, error_status, module_status
export execute, execute_xml, controls, read_control_xml, set_zero, set_led_mode, restart
export signal_list, measure, measure_all
export signal_path, channel_path, sensor_path, amplifier_path, alarm_path, peak_path, gate_path,
       parse_signal_path, compose_xml, parse_xml
export unit_name, unit_code, error_text, ntp2datetime, datetime2ntp
export Subscription, subscribe, unsubscribe, read_block, request_block, wait_block, SignalBlock,
       timestamps
export cstring, cchars, setfields, current_value, next_timestamp, status_value
export stSensor, stCanSigDesc, stSignalParams, stCanSignalParams, stAlarmIndexParams,
       stAlarmGlobalParams, stPeakIndexParams, stGateIndexParams, stTrigInfo, stDaqHeader,
       stErrStatItem, stModStatItem, stConModulInfo, stDeviceInfo, stScaling, stTwoPointScaling,
       stBridgeSensor, stIndBridgeSensor, stThermoCouple, stPt, stFrequency, stCounter, stSSI,
       stPotentiometer, stPressure, stSensorIdent
export ParView, ScaleType, SensorType, BridgeType, Wiring, ExcitationFreq, ScalingType, FilterType,
       FilterCharact, TcType, PtType, TrigType, DaqFormat

end # module
