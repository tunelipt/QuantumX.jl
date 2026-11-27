# High-level Julian API on top of LibQX.

const L = LibQX

# default buffer sizes for text results (bytes)
const XML_MAXSIZE = 4 * 1024 * 1024
const SMALL_MAXSIZE = 64 * 1024
const PATH_MAXLEN = 512

# ------------------------------------------------------------------ devices

"""
    QXDevice(uuid, ip = "", port = 0)

A QuantumX module, identified by its UUID. All device functions accept either a
`QXDevice` or the raw UUID (`UInt64`).
"""
struct QXDevice
    uuid::UInt64
    ip::String
    port::UInt16
end
QXDevice(uuid::Integer) = QXDevice(UInt64(uuid), "", 0)

uuid(d::QXDevice) = d.uuid
uuid(u::Integer) = UInt64(u)

Base.show(io::IO, d::QXDevice) =
    print(io, "QXDevice(uuid=", d.uuid, isempty(d.ip) ? "" : ", $(d.ip):$(d.port)", ")")

const DeviceLike = Union{QXDevice,Integer}

# ------------------------------------------------------------------ init

const _initialized = Ref(false)

"""
    init(; workdir = nothing)

Start the HBM framework (`HBM_Init`). Must be called before any communication.
`workdir` sets the working directory used for log configuration (`LOGCFG.INI`).
Called automatically by `connect` and the scan functions. `HBM_Unload` is
registered to run at exit.
"""
function init(; workdir::Union{Nothing,AbstractString} = nothing)
    _initialized[] && return nothing
    workdir === nothing || set_workdir(workdir)
    @qx L.HBM_Init()
    _initialized[] = true
    atexit(unload)
    return nothing
end

"Shut down the HBM framework (`HBM_Unload`)."
function unload()
    _initialized[] || return nothing
    L.HBM_Unload()
    _initialized[] = false
    return nothing
end

isinitialized() = _initialized[]
_ensure_init() = _initialized[] || init()

"Version string of HBM_QX_Framework.dll."
dll_version() = _jl(L.HBM_XUTIL_GetDllVersion())

"UUID of this PC application within the QuantumX network."
own_uuid() = L.HBM_XCOM_GetOwnUUID()

"Set the framework working directory (`HBM_XUTIL_SetWorkDir`)."
set_workdir(dir::AbstractString) = @qx L.HBM_XUTIL_SetWorkDir(String(dir))

# ------------------------------------------------------------------ discovery

"XML description of the network adapters of this PC (`HBM_XCOM_GetNetAdapter`)."
function net_adapters(; maxsize = SMALL_MAXSIZE)
    _ensure_init()
    @qx L.HBM_XCOM_GetNetAdapter(UInt32(maxsize))
end

const ALL_ADAPTERS = typemax(UInt32)

"""
    scan_network(adapter = ALL_ADAPTERS) -> Vector{NamedTuple}

Scan the Ethernet segment for QuantumX modules (`HBM_XCOM_ScanEthSegment`).
`adapter` is the 0-based adapter index from `net_adapters()`; the default scans all.
Returns `(uuid, ip, port, name, type)` named tuples.
"""
function scan_network(adapter::Integer = ALL_ADAPTERS)
    _ensure_init()
    list = @qx L.HBM_XCOM_ScanEthSegment(UInt32(adapter))
    return [_devinfo(d) for d in list]
end

"XML result of a network scan (`HBM_XCOM_DoNetScan`)."
function scan_network_xml(adapter::Integer = ALL_ADAPTERS; maxsize = SMALL_MAXSIZE)
    _ensure_init()
    @qx L.HBM_XCOM_DoNetScan(UInt32(adapter), UInt32(maxsize))
end

"Scan the FireWire bus (`HBM_XCOM_ScanFirewireSegment`)."
function scan_firewire()
    _ensure_init()
    list = @qx L.HBM_XCOM_ScanFirewireSegment()
    return [_devinfo(d) for d in list]
end

"XML result of a FireWire scan (`HBM_XCOM_DoFirewireScan`)."
function scan_firewire_xml(; maxsize = SMALL_MAXSIZE)
    _ensure_init()
    @qx L.HBM_XCOM_DoFirewireScan(UInt32(maxsize))
end

_devinfo(d::stDeviceInfo) =
    (uuid = d.Uuid, ip = cstring(d.IpAdr), port = Int(d.Port), name = cstring(d.Name), type = cstring(d.Type))

# ------------------------------------------------------------------ connection

"""
    connect(ip; port = 5001) -> QXDevice

Open a TCP/IP connection to a module (`HBM_XCOM_ConnectToTcpIpDev`).
"""
function connect(ip::AbstractString; port::Integer = QX_DEFAULT_PORT)
    _ensure_init()
    u = @qx L.HBM_XCOM_ConnectToTcpIpDev(String(ip), UInt16(port))
    return QXDevice(u, String(ip), UInt16(port))
end

"Close the TCP/IP connection (`HBM_XCOM_DisconnectFromTcpIpDev`)."
disconnect(d::QXDevice) = disconnect(d.ip; port = d.port)
disconnect(ip::AbstractString; port::Integer = QX_DEFAULT_PORT) =
    @qx L.HBM_XCOM_DisconnectFromTcpIpDev(String(ip), UInt16(port))

# ------------------------------------------------------------------ parameters (XPAR)

_view(v::ParView) = v
_view(v::Integer) = ParView(v)

"""
    read_xml(dev, view = PARVIEW_CONNECTORPARAM; current_choices_only = true, maxsize)

Read the XML parameter set of a view (`HBM_XPAR_ReadXML`).
"""
read_xml(dev::DeviceLike, view = PARVIEW_CONNECTORPARAM; current_choices_only::Bool = true, maxsize = XML_MAXSIZE) =
    @qx L.HBM_XPAR_ReadXML(uuid(dev), _view(view), UInt32(current_choices_only), UInt32(maxsize))

"""
    write_xml(dev, view, xml)

Write a complete XML parameter set (`HBM_XPAR_WriteXML`). On error, the module's
reply is available via `last_param_error()`.
"""
write_xml(dev::DeviceLike, view, xml::AbstractString) =
    @qx L.HBM_XPAR_WriteXML(uuid(dev), _view(view), String(xml), UInt32(sizeof(xml)))

"Read the XML section `xpath` of a view (`HBM_XPAR_ReadXMLSect`)."
read_xml_section(dev::DeviceLike, view, xpath::AbstractString; current_choices_only::Bool = true, maxsize = XML_MAXSIZE) =
    @qx L.HBM_XPAR_ReadXMLSect(uuid(dev), _view(view), UInt32(current_choices_only), String(xpath), UInt32(maxsize))

"Write an XML section at `xpath` (`HBM_XPAR_WriteXMLSect`)."
write_xml_section(dev::DeviceLike, view, xpath::AbstractString, xml::AbstractString) =
    @qx L.HBM_XPAR_WriteXMLSect(uuid(dev), _view(view), String(xpath), String(xml), UInt32(sizeof(xml)))

read_xsd(dev::DeviceLike, view; maxsize = XML_MAXSIZE) = @qx L.HBM_XPAR_ReadXSD(uuid(dev), _view(view), UInt32(maxsize))
read_xslt(dev::DeviceLike, view; maxsize = XML_MAXSIZE) = @qx L.HBM_XPAR_ReadXSLT(uuid(dev), _view(view), UInt32(maxsize))
read_xsd_section(dev::DeviceLike, view, xpath::AbstractString; maxsize = XML_MAXSIZE) =
    @qx L.HBM_XPAR_ReadXSDSect(uuid(dev), _view(view), String(xpath), UInt32(maxsize))
read_xslt_section(dev::DeviceLike, view, xpath::AbstractString; maxsize = XML_MAXSIZE) =
    @qx L.HBM_XPAR_ReadXSLTSect(uuid(dev), _view(view), String(xpath), UInt32(maxsize))

"Read a single numeric parameter (`HBM_XPAR_ReadDoublePar`)."
read_parameter(dev::DeviceLike, view, xpath::AbstractString, name::AbstractString) =
    @qx L.HBM_XPAR_ReadDoublePar(uuid(dev), _view(view), String(xpath), String(name))

"""
    write_parameter(dev, view, xpath, name, value)

Write a single parameter. Dispatches on the value type to
`HBM_XPAR_WriteIntPar` (Integer), `HBM_XPAR_WriteDoublePar` (Real) or
`HBM_XPAR_WriteStringPar` (String).
"""
write_parameter(dev::DeviceLike, view, xpath::AbstractString, name::AbstractString, v::Integer) =
    @qx L.HBM_XPAR_WriteIntPar(uuid(dev), _view(view), String(xpath), String(name), Int32(v))
write_parameter(dev::DeviceLike, view, xpath::AbstractString, name::AbstractString, v::Real) =
    @qx L.HBM_XPAR_WriteDoublePar(uuid(dev), _view(view), String(xpath), String(name), Float64(v))
write_parameter(dev::DeviceLike, view, xpath::AbstractString, name::AbstractString, v::AbstractString) =
    @qx L.HBM_XPAR_WriteStringPar(uuid(dev), _view(view), String(xpath), String(name), String(v))

"Restore the default settings below `xpath` (`HBM_XPAR_ActivateDefaultSetting`)."
activate_default(dev::DeviceLike, view, xpath::AbstractString) =
    @qx L.HBM_XPAR_ActivateDefaultSetting(uuid(dev), _view(view), String(xpath))

"Restore all default settings (`HBM_XPAR_ActivateAllDefaultSettings`)."
activate_all_defaults(dev::DeviceLike) = @qx L.HBM_XPAR_ActivateAllDefaultSettings(uuid(dev))

"XML error reply of the last failed parameter write (`HBM_XPAR_GetLastErrMsg`)."
last_param_error() = @qx L.HBM_XPAR_GetLastErrMsg()

"""
    parse_errors(xml; connector, channel, mode = 0, maxerrors = 16) -> Vector{Int32}

Extract error codes for a connector/channel from an XML error reply
(`HBM_XUTIL_ParseErrors`), e.g. `parse_errors(last_param_error(); connector = 3, channel = 1)`.
"""
function parse_errors(xml::AbstractString; connector::Integer, channel::Integer, mode::Integer = 0, maxerrors::Integer = 16)
    _ensure_init()
    list = zeros(Int32, maxerrors)
    rc = L.HBM_XUTIL_ParseErrors(UInt32(connector), UInt32(channel), UInt32(mode), String(xml), UInt32(sizeof(xml)), list)
    _check(:HBM_XUTIL_ParseErrors, rc)
    return filter(!=(0), list)
end

"XML list of the parameter views of a module (`HBM_XPAR_GetParViewsString`)."
param_views(dev::DeviceLike; maxsize = SMALL_MAXSIZE) = @qx L.HBM_XPAR_GetParViewsString(uuid(dev), UInt32(maxsize))

# ------------------------------------------------------------------ status (XSTAT)

"Modules connected to a device (`HBM_XSTAT_GetConnectedModules`)."
connected_modules(dev::DeviceLike; maxcount::Integer = 256) =
    @qx L.HBM_XSTAT_GetConnectedModules(uuid(dev), UInt32(maxcount))

"XML topology of the QuantumX network (`HBM_XSTAT_GetTopologyString`)."
topology(; maxsize = XML_MAXSIZE) = (_ensure_init(); @qx L.HBM_XSTAT_GetTopologyString(UInt32(maxsize)))

"Current error status entries of a module (`HBM_XSTAT_GetErrorStatus`)."
error_status(dev::DeviceLike) = @qx L.HBM_XSTAT_GetErrorStatus(uuid(dev))

"Module status entries (`HBM_XSTAT_GetModuleStatus`)."
module_status(dev::DeviceLike) = @qx L.HBM_XSTAT_GetModuleStatus(uuid(dev))

# ------------------------------------------------------------------ controls (XCTRL)

"""
    execute(dev, control, args...; timestamp = 0)

Execute a control on the module (`HBM_XCTRL_Execute`) with up to 8 string arguments.
`timestamp` is an NTP time (0 = now).
"""
function execute(dev::DeviceLike, control::AbstractString, args...; timestamp::Integer = 0)
    length(args) <= 8 || throw(ArgumentError("at most 8 control arguments"))
    @qx L.HBM_XCTRL_Execute(uuid(dev), String(control), UInt64(timestamp), Any[string(a) for a in args])
end

"Execute a control with XML parameters and return the XML answer (`HBM_XCTRL_ExecuteXMLPars`)."
execute_xml(dev::DeviceLike, control::AbstractString, xmlpars::AbstractString; timestamp::Integer = 0, maxsize = SMALL_MAXSIZE) =
    @qx L.HBM_XCTRL_ExecuteXMLPars(uuid(dev), String(control), UInt64(timestamp), String(xmlpars), UInt32(maxsize))

"XML list of available controls (`HBM_XCTRL_GetControlsString`)."
controls(dev::DeviceLike; maxsize = XML_MAXSIZE) = @qx L.HBM_XCTRL_GetControlsString(uuid(dev), UInt32(maxsize))

"XML parameter description of a control (`HBM_XCTRL_ReadXML`)."
read_control_xml(dev::DeviceLike, control::AbstractString; maxsize = XML_MAXSIZE) =
    @qx L.HBM_XCTRL_ReadXML(uuid(dev), String(control), UInt32(maxsize))

"""
    set_zero(dev, connector, channel = 1; target = nothing)

Zero (tare) a channel (`HBM_XCTRL_SetZero`), or set it to `target`
(`HBM_XCTRL_SetZeroWithTarget`).
"""
set_zero(dev::DeviceLike, connector::Integer, channel::Integer = 1; target::Union{Nothing,Real} = nothing) =
    target === nothing ? (@qx L.HBM_XCTRL_SetZero(uuid(dev), UInt32(connector), UInt32(channel))) :
                         (@qx L.HBM_XCTRL_SetZeroWithTarget(uuid(dev), UInt32(connector), UInt32(channel), Float64(target)))

"Set the mode of an LED (`HBM_XCTRL_SetLedMode`)."
set_led_mode(dev::DeviceLike, led::Integer, mode::Integer) = @qx L.HBM_XCTRL_SetLedMode(uuid(dev), UInt32(led), UInt32(mode))

"Restart a module (`HBM_XSYS_DoRestartSystem`)."
restart(dev::DeviceLike; cold::Bool = false, use_udp::Bool = false) = @qx L.HBM_XSYS_DoRestartSystem(uuid(dev), cold, use_udp)

# ------------------------------------------------------------------ single values (XDAQ)

"Signal ids (xpaths) available for acquisition (`HBM_XDAQ_GetSignalList`)."
signal_list(dev::DeviceLike) = String.(@qx L.HBM_XDAQ_GetSignalList(uuid(dev)))

"""
    measure(dev, connector, signal = 1; scale = SCALETP_PHYS, invalid_nan = true) -> Float64
    measure(dev, signal_id::String; invalid_nan = true) -> Float64

Read a single current measured value (`HBM_XDAQ_GetAnalogMeasVal` / `HBM_XDAQ_GetMeasVal`).
The module's invalid marker (open input, see [`INVALID_MARKER`](@ref)) is returned as
`NaN` unless `invalid_nan = false`.
"""
function measure(dev::DeviceLike, connector::Integer, signal::Integer = 1;
                 scale::ScaleType = SCALETP_PHYS, invalid_nan::Bool = true)
    v = @qx L.HBM_XDAQ_GetAnalogMeasVal(uuid(dev), UInt32(connector), UInt32(signal), scale)
    return invalid_nan ? _nan_invalid(v) : v
end
function measure(dev::DeviceLike, sigid::AbstractString; invalid_nan::Bool = true)
    v = @qx L.HBM_XDAQ_GetMeasVal(uuid(dev), String(sigid))
    return invalid_nan ? _nan_invalid(v) : v
end

"""
    measure_all(dev; enabled_only = true, maxvals = 256, invalid_nan = true) -> Vector{Float64}

One current value of every signal of the module (`HBM_XDAQ_GetAllMeasVals`). Invalid
values (open inputs) are `NaN` unless `invalid_nan = false`.
"""
function measure_all(dev::DeviceLike; enabled_only::Bool = true, maxvals::Integer = 256,
                     invalid_nan::Bool = true)
    vals = zeros(Float64, maxvals)
    n = @qx L.HBM_XDAQ_GetAllMeasVals(uuid(dev), UInt32(enabled_only), vals)
    out = vals[1:min(Int(n), maxvals)]
    return invalid_nan ? _nan_invalid!(out) : out
end

# ------------------------------------------------------------------ xpaths (XUTIL)

"""
    signal_path(connector, channel = 1, signal = 1; conntype = 1) -> String

Xpath / signal id of a signal (`HBM_XUTIL_ComposeSignalPath`), e.g. for `subscribe`.
"""
signal_path(connector::Integer, channel::Integer = 1, signal::Integer = 1; conntype::Integer = 1) =
    String(L.HBM_XUTIL_ComposeSignalPath(UInt32(connector), UInt32(channel), UInt32(signal), UInt32(conntype), UInt32(PATH_MAXLEN)))
channel_path(connector::Integer, channel::Integer = 1; conntype::Integer = 1) =
    String(L.HBM_XUTIL_ComposeChannelPath(UInt32(connector), UInt32(channel), UInt32(conntype), UInt32(PATH_MAXLEN)))
sensor_path(connector::Integer, channel::Integer = 1; conntype::Integer = 1) =
    String(L.HBM_XUTIL_ComposeSensorPath(UInt32(connector), UInt32(channel), UInt32(conntype), UInt32(PATH_MAXLEN)))
amplifier_path(connector::Integer) = String(L.HBM_XUTIL_ComposeAmplifierPath(UInt32(connector), UInt32(PATH_MAXLEN)))
alarm_path() = String(L.HBM_XUTIL_ComposeAlarmPath(UInt32(PATH_MAXLEN)))
peak_path() = String(L.HBM_XUTIL_ComposePeakPath(UInt32(PATH_MAXLEN)))
gate_path() = String(L.HBM_XUTIL_ComposeGatePath(UInt32(PATH_MAXLEN)))

"""
    parse_signal_path(xpath) -> (connector, channel, signal, conntype)
"""
function parse_signal_path(xpath::AbstractString)
    c, ch, s, t = @qx L.HBM_XUTIL_ParseSignalPath(String(xpath), UInt32(sizeof(xpath)))
    return (connector = Int(c), channel = Int(ch), signal = Int(s), conntype = Int(t))
end

# ------------------------------------------------------------------ XML composing / parsing

"""
    compose_xml(params; index = nothing, maxlen = 64k) -> String

Create the XML telegram for a parameter struct (`HBM_XUTIL_Compose*`):
`stSensor`, `stCanSigDesc`, `stCanSignalParams`, `stSignalParams`, `stAlarmGlobalParams`,
and (with `index`) `stAlarmIndexParams`, `stGateIndexParams`, `stPeakIndexParams`.
"""
compose_xml(s::stSensor; maxlen = SMALL_MAXSIZE) = (_ensure_init(); @qx L.HBM_XUTIL_ComposeSensor(s, UInt32(maxlen)))
compose_xml(s::stCanSigDesc; maxlen = SMALL_MAXSIZE) = (_ensure_init(); @qx L.HBM_XUTIL_ComposeCanSensor(s, UInt32(maxlen)))
compose_xml(s::stCanSignalParams; maxlen = SMALL_MAXSIZE) = (_ensure_init(); @qx L.HBM_XUTIL_ComposeCanSignal(s, UInt32(maxlen)))
compose_xml(s::stSignalParams; maxlen = SMALL_MAXSIZE) = (_ensure_init(); @qx L.HBM_XUTIL_ComposeSignal(s, UInt32(maxlen)))
compose_xml(s::stAlarmGlobalParams; maxlen = SMALL_MAXSIZE) = (_ensure_init(); @qx L.HBM_XUTIL_ComposeAlarmGlobal(s, UInt32(maxlen)))
compose_xml(s::stAlarmIndexParams; index::Integer, maxlen = SMALL_MAXSIZE) = (_ensure_init(); @qx L.HBM_XUTIL_ComposeAlarmIndex(UInt32(index), s, UInt32(maxlen)))
compose_xml(s::stGateIndexParams; index::Integer, maxlen = SMALL_MAXSIZE) = (_ensure_init(); @qx L.HBM_XUTIL_ComposeGateIndex(UInt32(index), s, UInt32(maxlen)))
compose_xml(s::stPeakIndexParams; index::Integer, maxlen = SMALL_MAXSIZE) = (_ensure_init(); @qx L.HBM_XUTIL_ComposePeakIndex(UInt32(index), s, UInt32(maxlen)))

"""
    parse_xml(T, xml; index = nothing) -> T

Parse an XML telegram into a parameter struct (`HBM_XUTIL_Parse*`). The inverse of
`compose_xml`.
"""
parse_xml(::Type{stSensor}, xml::AbstractString) = (_ensure_init(); @qx L.HBM_XUTIL_ParseSensor(String(xml), UInt32(sizeof(xml))))
parse_xml(::Type{stCanSigDesc}, xml::AbstractString) = (_ensure_init(); @qx L.HBM_XUTIL_ParseCanSensor(String(xml), UInt32(sizeof(xml))))
parse_xml(::Type{stCanSignalParams}, xml::AbstractString) = (_ensure_init(); @qx L.HBM_XUTIL_ParseCanSignal(String(xml), UInt32(sizeof(xml))))
parse_xml(::Type{stSignalParams}, xml::AbstractString) = (_ensure_init(); @qx L.HBM_XUTIL_ParseSignal(String(xml), UInt32(sizeof(xml))))
parse_xml(::Type{stAlarmGlobalParams}, xml::AbstractString) = (_ensure_init(); @qx L.HBM_XUTIL_ParseAlarmGlobal(String(xml)))
parse_xml(::Type{stAlarmIndexParams}, xml::AbstractString; index::Integer) = (_ensure_init(); @qx L.HBM_XUTIL_ParseAlarmIndex(UInt32(index), String(xml)))
parse_xml(::Type{stGateIndexParams}, xml::AbstractString; index::Integer) = (_ensure_init(); @qx L.HBM_XUTIL_ParseGateIndex(UInt32(index), String(xml)))
parse_xml(::Type{stPeakIndexParams}, xml::AbstractString; index::Integer) = (_ensure_init(); @qx L.HBM_XUTIL_ParsePeakIndex(UInt32(index), String(xml)))

"Description of the last XML parsing error (`HBM_XUTIL_GetLastXmlError`)."
last_xml_error() = _jl(L.HBM_XUTIL_GetLastXmlError())

# ------------------------------------------------------------------ units, time

"Name of a physical unit code (`HBM_XUTIL_GetUnitNameFromCode`)."
unit_name(code::Integer) = _jl(L.HBM_XUTIL_GetUnitNameFromCode(UInt32(code)))

"Physical unit code of a unit name (`HBM_XUTIL_GetUnitCodeFromName`); negative if unknown."
unit_code(name::AbstractString) = Int(L.HBM_XUTIL_GetUnitCodeFromName(String(name)))

const NTP_EPOCH = DateTime(1900, 1, 1)

"""
    ntp2datetime(ts::UInt64) -> DateTime

Convert an NTP time stamp (upper 32 bit: seconds since 1900-01-01 UTC, lower 32 bit:
fraction) to a `DateTime` (UTC, millisecond resolution).
"""
function ntp2datetime(ts::Integer)
    ts = UInt64(ts)
    secs = ts >> 32
    frac = ts & 0xffffffff
    ms = round(Int64, frac * 1000 / 2.0^32)
    return NTP_EPOCH + Second(secs) + Millisecond(ms)
end

"Convert a UTC `DateTime` to an NTP time stamp."
function datetime2ntp(t::DateTime)
    ms = Dates.value(t - NTP_EPOCH)
    secs, rem = fldmod(ms, 1000)
    return (UInt64(secs) << 32) | UInt64(round(Int64, rem * 2.0^32 / 1000))
end

"Seconds represented by an NTP time stamp (Float64)."
ntp_seconds(ts::Integer) = Float64(UInt64(ts) >> 32) + Float64(UInt64(ts) & 0xffffffff) / 2.0^32

# ------------------------------------------------------------------ logging

"""
    configure_log(type, filename; format = LOGDATAFORMAT_ASCII, wrap = LOGWRAPMODE_APPEND,
                  size = 5_000_000, source = 0xffff)

Configure framework logging on the PC (`HBM_XUTIL_ParamLogfile`). `type` is
`LOGID_COMMUNICATION`, `LOGID_ERROR` or `LOGID_DEBUG`; `source` is a mask of
`COMSRC_*`, `ERRLVL_*` or `DBGSRC_*` values.
"""
configure_log(type::Integer, filename::AbstractString; format::LogDataFormat = LOGDATAFORMAT_ASCII,
              wrap::LogWrapMode = LOGWRAPMODE_APPEND, size::Integer = 5_000_000, source::Integer = 0xffff) =
    @qx L.HBM_XUTIL_ParamLogfile(UInt32(type), String(filename), format, wrap, UInt32(size), UInt32(source))

"Add a line to a framework log file (`HBM_XUTIL_LogAdd`)."
log_add(type::Integer, text::AbstractString) = @qx L.HBM_XUTIL_LogAdd(UInt32(type), String(text))
