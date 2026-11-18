# Julia isbits mirrors of the C structs of the QuantumX API.
#
# Field names and order follow the C headers exactly; CxxWrap's `map_type` maps the
# C++ struct onto these types, so memory layouts must match. This is verified at
# load time against offsetof/sizeof values reported by the C++ wrapper.
#
# Fixed size `char[N]` arrays are NTuple{N,UInt8}; use `cstring(x.Field)` to read them
# and the keyword constructors (`stSensor(; Supply = 5.0, ...)`) to create structs:
# unspecified fields are zero, Strings are accepted for char arrays.

const NAME_STRING_LENGTH = 256
const NAME_LEN = 128
const IPADR_LEN = 16
const TYPE_LEN = 16
const ERR_TEXT_LEN = 128

const CStr{N} = NTuple{N,UInt8}

struct stTwoPointScaling
    ElectVal1::Float64
    PhysVal1::Float64
    ElectVal2::Float64
    PhysVal2::Float64
end

struct stScaling
    Type::ScalingType
    TwoPoint::stTwoPointScaling
end

struct stBridgeSensor
    ExcitAmpl::Float64
    ExcitFreq::ExcitationFreq
    BridgeType::BridgeType
    Wiring::Wiring
    Impedance::Float64
end

struct stIndBridgeSensor
    ExcitAmpl::Float64
    BridgeType::BridgeType
    Wiring::Wiring
    Impedance::Float64
end

struct stThermoCouple
    Type::TcType
    Resistance::Float64
end

struct stPressure
    Type::PressureType
    MaxPressure::Float64
end

struct stPotentiometer
    Resistance::Float64
    Wiring::Wiring
end

struct stPt
    Type::PtType
    Wiring::Wiring
end

struct stFrequency
    S2enable::UInt32
    F4enable::UInt32
end

struct stCounter
    IndexEnable::UInt32
    IndexDivisor::UInt32
    S2enable::UInt32
    F4enable::UInt32
    PulsesPerRound::UInt32
end

struct stSSI
    ClockFreq::UInt32
    Resolution::UInt32
    Coding::SSICoding
end

struct stSensorIdent
    SensorName::CStr{NAME_STRING_LENGTH}
    Manufacturer::CStr{NAME_STRING_LENGTH}
    SerialNo::CStr{NAME_STRING_LENGTH}
    CalDate::CStr{NAME_STRING_LENGTH}
end

"Sensor description (C `struct stSensor`). See `HBM_XUTIL_ComposeSensor` / `HBM_XUTIL_ParseSensor`."
struct stSensor
    MaxElecVal::Float64
    Supply::Float64
    PhysUnit::UInt32
    PhysUnitUsr::CStr{NAME_LEN}
    Identification::stSensorIdent
    Type::SensorType
    Scaling::stScaling
    Bridge::stBridgeSensor
    IndBridge::stIndBridgeSensor
    ThermoCouple::stThermoCouple
    Pt::stPt
    Frequency::stFrequency
    Counter::stCounter
    # (the C header declares `struct stPulseWidth;` and `struct stPeriodLength;`
    #  here without member names, so they occupy no storage)
    SSI::stSSI
    Poti::stPotentiometer
    Pressure::stPressure
end

"CAN sensor description (C `struct stCanSigDesc`)."
struct stCanSigDesc
    SigName::CStr{NAME_LEN}
    Identifier::UInt32
    FrameFormat::CanFrameFormat
    BitSequence::CanBitSequence
    RawFormat::CanMessValFormat
    StartBit::UInt32
    SignalLength::UInt32
    ScalingFactor::Float64
    ScalingOffset::Float64
    PhysUnit::UInt32
    PhysUnitUsr::CStr{NAME_LEN}
    ModeBitSequence::CanBitSequence
    ModeValueFormat::CanMessValFormat
    ModeValue::UInt64
    ModeStartbit::UInt32
    ModeLength::UInt32
    SignalType::CanSignalTypeChoice
end

"Signal description (C `struct stSignalParams`): filter, output rate, decimal places."
struct stSignalParams
    Number::UInt32
    FilterType::FilterType
    FiltCharact::FilterCharact
    FiltFreq::Float64
    OutputRate::Float64
    DecimalPlaces::UInt32
    OutputUnit::UInt32
    OutputUnitUsr::CStr{NAME_LEN}
end

"CAN signal description (C `struct stCanSignalParams`)."
struct stCanSignalParams
    MaxRepetitionTime::Float64
    OutputFormat::CanMessValFormat
    DecimalPlaces::UInt32
end

struct stAlarmIndexParams
    Name::CStr{NAME_LEN}
    Active::Active
    SourceConnector::UInt32
    SourceChannel::UInt32
    SourceSignal::UInt32
    Level::Float64
    Hysteresis::Float64
    Direction::AlarmDirection
    Polarity::AlarmPolarity
    NotificationId::UInt32
end

struct stAlarmGlobalParams
    Active::Active
    IsoTransmitEnable::Enable
end

struct stPeakIndexParams
    Name::CStr{NAME_LEN}
    Active::Active
    SourceConnector::UInt32
    SourceChannel::UInt32
    SourceSignal::UInt32
    PeakType::PeakType
    PeakMode::PeakRunMode
    IsoTransmit::Enable
    InputGate::UInt32
end

struct stGateIndexParams
    Active::ActiveOutputLevel
    SourceConnector::UInt32
    SourceChannel::UInt32
    SourceSignal::UInt32
    OnLevel::Float64
    OffLevel::Float64
end

"Trigger definition (C `struct stTrigInfo`)."
struct stTrigInfo
    Type::TrigType
    Uuid::UInt64
    Connector::UInt32
    Channel::UInt32
    Signal::UInt32
    LevelMin::Float64
    LevelMax::Float64
    Name::CStr{NAME_LEN}
end

"""
Header of one signal inside a measured value block (C `struct stDaqHeader`, packed).

`u` is the C union: `NextTimeStamp` for synchronous data (HdrFormat = 1), the current
value for asynchronous data (HdrFormat = 2). Use `next_timestamp(h)` / `current_value(h)`.
"""
struct stDaqHeader
    HdrFormat::UInt8
    DataFormat::UInt8
    UserSigId::UInt16
    MeasValCount::UInt32
    TimeStamp::UInt64
    u::UInt64
end

"One entry of the module error status (C `struct stErrStatItem`)."
struct stErrStatItem
    Level::UInt32
    Code::Int32
    Connector::UInt32
    Channel::UInt32
    Signal::UInt32
    ErrText::CStr{ERR_TEXT_LEN}
end

"""
One entry of the module status (C `struct stModStatItem`, packed).
`Value` holds the 8-byte C union (double / UInt64 NTP time / bytes); see `status_value`.
"""
struct stModStatItem
    Connector::UInt32
    Channel::UInt32
    Signal::UInt32
    Id::UInt32
    Value::UInt64
    Info::CStr{ERR_TEXT_LEN}
end

"Module connected to a device (C `struct stConModulInfo`)."
struct stConModulInfo
    UUID::UInt64
    DevType::UInt32
    InterfaceType::ComInterfaceType
    InterfaceHandle::Ptr{Cvoid}
end

"Device found by a segment scan (anonymous element struct of C `struct stDeviceList`)."
struct stDeviceInfo
    IpAdr::CStr{IPADR_LEN}
    Port::UInt32
    Uuid::UInt64
    Name::CStr{NAME_LEN}
    Type::CStr{TYPE_LEN}
end

const MIRRORED_STRUCTS = (stTwoPointScaling, stScaling, stBridgeSensor, stIndBridgeSensor, stThermoCouple,
    stPressure, stPotentiometer, stPt, stFrequency, stCounter, stSSI, stSensorIdent, stSensor,
    stCanSigDesc, stSignalParams, stCanSignalParams, stAlarmIndexParams, stAlarmGlobalParams,
    stPeakIndexParams, stGateIndexParams, stTrigInfo, stDaqHeader, stErrStatItem, stModStatItem,
    stConModulInfo, stDeviceInfo)

# ------------------------------------------------------------------ helpers

"""
    cstring(x::NTuple{N,UInt8}) -> String

Convert a fixed-size C `char[N]` field to a String (up to the first NUL).
"""
function cstring(x::NTuple{N,UInt8}) where {N}
    n = something(findfirst(==(0x00), x), N + 1) - 1
    return String(UInt8[x[i] for i in 1:n])
end

"""
    cchars(s::AbstractString, N) -> NTuple{N,UInt8}

Convert a String to a NUL-terminated C `char[N]` field. Errors if it does not fit.
"""
function cchars(s::AbstractString, ::Val{N}) where {N}
    b = codeunits(s)
    length(b) < N || throw(ArgumentError("string of $(length(b)) bytes does not fit into char[$N]"))
    return ntuple(i -> i <= length(b) ? b[i] : 0x00, Val(N))
end
cchars(s::AbstractString, N::Integer) = cchars(s, Val(N))

# zero value of any isbits type (enums included, even if 0 is not a member)
zero_of(::Type{T}) where {T} = reinterpret(T, zeros(UInt8, sizeof(T)))[1]

_convert_field(::Type{T}, v::T) where {T} = v
_convert_field(::Type{NTuple{N,UInt8}}, v::AbstractString) where {N} = cchars(v, Val(N))
_convert_field(::Type{T}, v) where {T} = convert(T, v)

# keyword constructors: stSensor(; Supply = 5.0, ...) – unspecified fields are zero
for T in MIRRORED_STRUCTS
    @eval (::Type{$T})(; kwargs...) = setfields(zero_of($T); kwargs...)
end

"""
    setfields(x; field = value, ...)

Return a copy of the immutable struct `x` with the given fields replaced
(Strings are accepted for `char[N]` fields).
"""
function setfields(x::T; kwargs...) where {T}
    for k in keys(kwargs)
        k in fieldnames(T) || throw(ArgumentError("type $T has no field $k"))
    end
    vals = ntuple(fieldcount(T)) do i
        f = fieldname(T, i)
        haskey(kwargs, f) ? _convert_field(fieldtype(T, i), kwargs[f]) : getfield(x, i)
    end
    return T(vals...)
end

"NTP time stamp of the next block (synchronous data, `HdrFormat == 1`)."
next_timestamp(h::stDaqHeader) = h.u

"Current value stored in the header union (asynchronous data, `HdrFormat == 2`)."
function current_value(h::stDaqHeader)
    f = h.DataFormat
    f == 0x5C && return reinterpret(Float32, UInt32(h.u & 0xffffffff))
    f == 0x50 && return reinterpret(Float64, h.u)
    f == 0x6C && return reinterpret(Int32, UInt32(h.u & 0xffffffff))
    f == 0x60 && return reinterpret(Int64, h.u)
    f == 0xEC && return UInt32(h.u & 0xffffffff)
    f == 0xE0 && return h.u
    return h.u
end

"Interpret the `Value` union of a module status entry as Float64, UInt64 or bytes."
status_value(item::stModStatItem, ::Type{Float64}) = reinterpret(Float64, item.Value)
status_value(item::stModStatItem, ::Type{UInt64}) = item.Value
status_value(item::stModStatItem, ::Type{Vector{UInt8}}) = collect(reinterpret(UInt8, [item.Value]))
