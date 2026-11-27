# Tests that need no QuantumX hardware. Set ENV["QUANTUMX_TEST_IP"] = "192.168.x.y"
# to additionally run the hardware tests in hardware.jl against a real module.

using QuantumX
using QuantumX: LibQX
using Dates
using Test

const Q = QuantumX

# run in a scratch directory: HBM_Init may create log files in the working directory
const WORKDIR = mktempdir()
const ORIGDIR = pwd()
cd(WORKDIR)
atexit(() -> cd(ORIGDIR))

@testset "QuantumX" begin

@testset "library" begin
    @test Sys.WORD_SIZE == 32
    @test Q.check_layout() > 50
    @test occursin(r"^\d+\.\d+", dll_version())
    init()
    @test isinitialized()
    init()                       # idempotent
    @test own_uuid() isa UInt64
end

@testset "struct helpers" begin
    s = stSignalParams(Number = 2, FiltFreq = 10, OutputUnitUsr = "mV/V")
    @test s.Number == 2
    @test s.FiltFreq === 10.0
    @test cstring(s.OutputUnitUsr) == "mV/V"
    @test s.OutputRate == 0.0
    s2 = setfields(s; OutputRate = 300.0)
    @test s2.OutputRate == 300.0 && s2.Number == 2
    @test_throws ArgumentError stSignalParams(Bogus = 1)
    @test_throws ArgumentError cchars("x"^200, 128)
    @test cstring(cchars("abc", 8)) == "abc"
    @test sizeof(stDaqHeader) == 24
end

@testset "xpaths" begin
    p = signal_path(3, 1, 2)
    @test occursin("Connector3", p)
    r = parse_signal_path(p)
    @test (r.connector, r.channel, r.signal) == (3, 1, 2)
    @test !isempty(channel_path(2))
    @test !isempty(sensor_path(2))
    @test occursin("address=\"5\"", amplifier_path(5))
    @test !isempty(alarm_path())
    @test !isempty(peak_path())
    @test !isempty(gate_path())
    # text results are Julia Strings, not CxxWrap StdStrings (regexes need String)
    @test all(x -> x isa String, (p, channel_path(2), sensor_path(2), amplifier_path(5),
                                  alarm_path(), peak_path(), gate_path(), dll_version()))
end

@testset "compose/parse XML" begin
    sp = stSignalParams(Number = 1, FilterType = Q.FILTERTYPE_LOWPASS, FiltCharact = Q.FILTERCHARACT_BESSEL,
                        FiltFreq = 100, OutputRate = 600, DecimalPlaces = 5)
    xml = compose_xml(sp)
    @test occursin("<OutputRate>600", xml)
    @test xml isa String
    @test match(r"<OutputRate>([^<]*)<", xml) !== nothing
    sp2 = parse_xml(stSignalParams, xml)
    @test sp2.OutputRate == 600.0
    @test sp2.FiltFreq == 100.0
    @test sp2.FilterType == Q.FILTERTYPE_LOWPASS
    @test sp2.DecimalPlaces == 5

    sensor = stSensor(Type = Q.BRIDGESENSOR, MaxElecVal = 2.0, Supply = 5.0, PhysUnit = unit_code("N"),
                      Bridge = Q.stBridgeSensor(ExcitAmpl = 5.0, ExcitFreq = Q.EXCFREQ_DC,
                                                BridgeType = Q.BRIDGETYPE_FULL, Wiring = Q.WIRING_6, Impedance = 350.0),
                      Scaling = stScaling(Type = Q.SCALING_ZEROSPAN,
                                          TwoPoint = stTwoPointScaling(0.0, 0.0, 2.0, 1000.0)))
    sxml = compose_xml(sensor)
    @test occursin("<", sxml)
    s2 = parse_xml(stSensor, sxml)
    @test s2.Type == Q.BRIDGESENSOR
    @test s2.Bridge.BridgeType == Q.BRIDGETYPE_FULL
    @test s2.Scaling.TwoPoint.PhysVal2 ≈ 1000.0

    can = stCanSigDesc(SigName = "Speed", Identifier = 0x123, FrameFormat = Q.CAN_FRAME11,
                       BitSequence = Q.CAN_BYTEODER_INTEL, RawFormat = Q.CAN_UNSIGNEDINT32,
                       StartBit = 8, SignalLength = 16, ScalingFactor = 0.5, ScalingOffset = 1.0)
    cxml = compose_xml(can)
    c2 = parse_xml(stCanSigDesc, cxml)
    @test c2.Identifier == 0x123
    @test c2.SignalLength == 16
    @test c2.ScalingFactor == 0.5

    cs = stCanSignalParams(MaxRepetitionTime = 100.0, OutputFormat = Q.CAN_REAL32, DecimalPlaces = 3)
    cs2 = parse_xml(stCanSignalParams, compose_xml(cs))
    @test cs2.DecimalPlaces == 3

    g = stGateIndexParams(Active = Q.ACTIVE_NORMAL, SourceConnector = 1, SourceChannel = 1, SourceSignal = 1,
                          OnLevel = 2.0, OffLevel = 1.0)
    g2 = parse_xml(stGateIndexParams, compose_xml(g; index = 1); index = 1)
    @test g2.OnLevel == 2.0 && g2.OffLevel == 1.0
end

@testset "units, errors, time" begin
    c = unit_code("V")
    @test c >= 0
    @test unit_name(c) == "V"
    @test unit_name(c) isa String
    e = QXError(:HBM_XCOM_ConnectToTcpIpDev, Q.ERR_EVFLG_PTHREADS)
    msg = sprint(showerror, e)
    @test occursin("ERR_EVFLG_PTHREADS", msg)
    @test Q.error_name(0) == :ERR_SUCCESS
    t = DateTime(2024, 5, 17, 12, 30, 15, 250)
    @test ntp2datetime(datetime2ntp(t)) == t
    @test Q._check(:x, (0, 42)) == 42
    @test Q._check(:x, (0, 1, 2)) == (1, 2)
    @test_throws QXError Q._check(:x, -1)
end

@testset "measured value block decoding" begin
    # Synthetic block in the documented wire format (big endian):
    # [header sig 1][values sig 1][header sig 2][values sig 2]
    be(x) = reverse(reinterpret(UInt8, [x]))
    function sigblock(usersigid, vals::Vector{Float32}, t0, t1)
        hdr = vcat(UInt8[0x01, 0x14], be(UInt16(usersigid)), be(UInt32(length(vals))), be(UInt64(t0)), be(UInt64(t1)))
        return vcat(hdr, reduce(vcat, be.(vals)))
    end
    t0 = datetime2ntp(DateTime(2024, 1, 1))
    t1 = t0 + (UInt64(1) << 32)           # one second later
    v1 = Float32[1.5, -2.25, 3.0, 4.75]
    v2 = Float32[10, 20, 30]
    buf = vcat(sigblock(1, v1, t0, t1), sigblock(2, v2, t0, t1))
    rxlen = length(buf)
    append!(buf, zeros(UInt8, 64))
    b1 = Q.decode_signal(buf, rxlen, 1)
    b2 = Q.decode_signal(buf, rxlen, 2)
    @test b1 isa SignalBlock{Float32}
    @test b1.values == v1
    @test b2.values == v2
    @test b1.header.MeasValCount == 4
    @test b1.header.TimeStamp == t0
    ts = timestamps(b1)
    @test ts[1] == t0 && length(ts) == 4
    @test ntp2datetime(ts[3]) == DateTime(2024, 1, 1, 0, 0, 0, 500)

    # invalid marker (open input): Float32 0x5FFFFFFF in blocks -> NaN
    marker = reinterpret(Float32, 0x5FFFFFFF)
    v3 = Float32[1.0, marker, 2.0]
    buf3 = vcat(sigblock(3, v3, t0, t1), zeros(UInt8, 64))
    b3 = Q.decode_signal(buf3, length(buf3) - 64, 3)
    @test b3.values[1] == 1 && isnan(b3.values[2]) && b3.values[3] == 2
    @test Q.decode_signal(buf3, length(buf3) - 64, 3; invalid_nan = false).values[2] == marker
end

@testset "invalid marker" begin
    @test isinvalid(reinterpret(Float32, 0x5FFFFFFF))
    @test isinvalid(reinterpret(Float64, 0x440000000d7ab369))   # as returned by measure()
    @test !isinvalid(1.0) && !isinvalid(-7.8e-5) && !isinvalid(3.0e19) && !isinvalid(NaN)
    @test isnan(Q._nan_invalid(INVALID_MARKER)) && Q._nan_invalid(2.5) == 2.5
end

if haskey(ENV, "QUANTUMX_TEST_IP")
    include("hardware.jl")
end

end # testset

cd(ORIGDIR)
