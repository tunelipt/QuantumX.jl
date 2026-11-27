# Configure a single connector: sensor (type of signal), scaling, output rate and filter.
#
#   julia +release~x86 --project=. examples/configure.jl <ip> <connector> [options]
#
# Only the given options are changed; everything else keeps its current value.
#
# Sensor (written with `stSensor` -> `compose_xml` -> `write_xml_section`):
#   --sensor voltage         voltage | current | bridge | thermocouple | pt | potentiometer
#   --range 10               measuring range ±: V (voltage), mA (current), mV/V (bridge)
#   --excitation 5           bridge excitation in V
#   --bridge full            bridge type: full | half | quarter
#   --wiring 6               wiring (bridge 4/6, pt 3/4, potentiometer 5)
#   --tc K                   thermocouple type B, E, J, K, N, R, S, T
#   --pt 100                 Pt100 | Pt1000 (100 or 1000)
#   --scale 0:0,10:100       two-point (zero/span) scaling: electrical:physical,electrical:physical
#   --unit mm                physical unit (name as in `unit_code`, e.g. V, mA, mV/V, °C, mm, N, bar)
# Signal (`stSignalParams`):
#   --rate 1200              output rate in Hz (MX840: ... 50, 75, 100, 150, 200, 300, 600, 1200, 2400)
#   --filter lowpass         lowpass | off
#   --charact bessel         bessel | butterworth
#   --freq 100               lowpass cutoff frequency in Hz
#   --decimals 4             decimal places
# Other:
#   --name "pressure 1"      channel name
#   --save old.xml           save the connector's channel XML before changing anything
#   --restore old.xml        write a saved channel XML back (other options are ignored)
#   --dry-run                print the XML that would be written, change nothing
#
# Examples:
#   configure.jl 192.168.169.10 3 --rate 1200 --filter lowpass --freq 100
#   configure.jl 192.168.169.10 5 --sensor thermocouple --tc K --rate 10 --freq 1 --save conn5.xml
#   configure.jl 192.168.169.10 2 --sensor voltage --range 10 --scale 0:0,10:250 --unit bar
#   configure.jl 192.168.169.10 5 --restore conn5.xml
#
# The module may round or limit values (e.g. a low lowpass cutoff caps the output rate),
# so the settings are read back and differences are reported.

using QuantumX
include("print_config.jl")          # describe_sensor, describe_signal (its main does not run)

const SENSORS  = Dict("voltage" => VOLTAGESENSOR, "current" => CURRENTSENSOR, "bridge" => BRIDGESENSOR,
                      "thermocouple" => THERMOCOUPLE, "pt" => PTSENSOR, "potentiometer" => POTISENSOR)
const FILTERS  = Dict("lowpass" => FILTERTYPE_LOWPASS, "off" => FILTERTYPE_OFF)
const CHARACTS = Dict("bessel" => FILTERCHARACT_BESSEL, "butterworth" => FILTERCHARACT_BUTTERWORTH)
const BRIDGES  = Dict("full" => BRIDGETYPE_FULL, "half" => BRIDGETYPE_HALF, "quarter" => BRIDGETYPE_QUARTER)
const TCTYPES  = Dict(string(c) => t for (c, t) in zip("BEJKNRST", (TCTYPE_B, TCTYPE_E, TCTYPE_J, TCTYPE_K,
                                                                 TCTYPE_N, TCTYPE_R, TCTYPE_S, TCTYPE_T)))
const PTTYPES  = Dict("100" => PTTYPE_100, "1000" => PTTYPE_1000)
# default unit of each sensor type (used when the type changes and --unit is not given)
const DEFAULT_UNIT = Dict(VOLTAGESENSOR => "V", CURRENTSENSOR => "mA", BRIDGESENSOR => "mV/V",
                          THERMOCOUPLE => "°C", PTSENSOR => "°C", POTISENSOR => "%")

const SENSOR_OPTS = (:sensor, :range, :excitation, :bridge, :wiring, :tc, :pt, :scale, :unit)
const SIGNAL_OPTS = (:rate, :filter, :charact, :freq, :decimals)

wiring(n) = Wiring(n)

"New sensor settings: the current ones with the requested changes."
function new_sensor(s::stSensor, o)
    t = get(o, :sensor, s.Type)
    changed_type = t != s.Type
    kw = Dict{Symbol,Any}(:Type => t)
    haskey(o, :range) && (kw[:MaxElecVal] = o[:range])
    if t == BRIDGESENSOR
        b = s.Bridge
        kw[:Bridge] = setfields(b; ExcitAmpl = get(o, :excitation, b.ExcitAmpl),
                                   BridgeType = get(o, :bridge, b.BridgeType),
                                   Wiring = haskey(o, :wiring) ? wiring(o[:wiring]) : b.Wiring)
    elseif t == THERMOCOUPLE
        kw[:ThermoCouple] = setfields(s.ThermoCouple; Type = get(o, :tc, s.ThermoCouple.Type))
    elseif t == PTSENSOR
        kw[:Pt] = setfields(s.Pt; Type = get(o, :pt, s.Pt.Type),
                                  Wiring = haskey(o, :wiring) ? wiring(o[:wiring]) : s.Pt.Wiring)
    elseif t == POTISENSOR
        haskey(o, :wiring) && (kw[:Poti] = setfields(s.Poti; Wiring = wiring(o[:wiring])))
    end

    # Scaling. Temperature sensors use the module's internal characteristic; others a
    # two-point scaling (identity unless --scale is given). The scaling must always be
    # set explicitly when the type changes or when ParseSensor did not recognise it
    # (e.g. Gain), because compose_xml writes an empty <Scalingtype> for unknown types.
    if haskey(o, :scale)
        (e1, p1), (e2, p2) = o[:scale]
        kw[:Scaling] = stScaling(SCALING_ZEROSPAN, stTwoPointScaling(e1, p1, e2, p2))
    elseif changed_type || s.Scaling.Type == SCALING_UNKNOWN
        kw[:Scaling] = t in (THERMOCOUPLE, PTSENSOR) ?
            stScaling(SCALING_INTERNAL, stTwoPointScaling(0, 0, 1, 1)) :
            stScaling(SCALING_ZEROSPAN, stTwoPointScaling(0, 0, 1, 1))
    end

    # Unit, given by its code (see the PhysUnitUsr note in `main`)
    unit = get(o, :unit, changed_type ? get(DEFAULT_UNIT, t, nothing) : nothing)
    if unit !== nothing
        code = unit_code(unit)
        code >= 0 || error("unknown unit \"$unit\"")
        kw[:PhysUnit] = code
        kw[:PhysUnitUsr] = ""
    end
    return setfields(s; kw...)
end

"New signal settings: the current ones with the requested changes."
function new_signal(p::stSignalParams, o, sensor::stSensor)
    kw = Dict{Symbol,Any}()
    haskey(o, :rate)     && (kw[:OutputRate] = o[:rate])
    haskey(o, :filter)   && (kw[:FilterType] = o[:filter])
    haskey(o, :charact)  && (kw[:FiltCharact] = o[:charact])
    haskey(o, :freq)     && (kw[:FiltFreq] = o[:freq])
    haskey(o, :decimals) && (kw[:DecimalPlaces] = o[:decimals])
    # the output unit follows the sensor unit
    kw[:OutputUnit] = sensor.PhysUnit
    kw[:OutputUnitUsr] = ""
    return setfields(p; kw...)
end

function show_connector(dev, c, title)
    view = PARVIEW_CONNECTORPARAM
    sxml = read_xml_section(dev, view, sensor_path(c))
    sig  = parse_xml(stSignalParams, read_xml_section(dev, view, signal_path(c)))
    name = xmltag(read_xml_section(dev, view, channel_path(c)), "ChannelName")
    println(title, isempty(name) ? "" : " \"$name\"")
    println("  sensor: ", describe_sensor(parse_xml(stSensor, sxml), sxml))
    println("  signal: ", describe_signal(sig))
    return sig
end

function main(ip, c::Integer, o::Dict{Symbol,Any})
    view = PARVIEW_CONNECTORPARAM
    dry  = get(o, :dryrun, false)
    dev  = connect(ip)
    try
        mode = match(Regex("<Connector$c><Mode choice=\"([^\"]+)\""), read_xml(dev, view))
        mode === nothing && error("module has no connector $c")
        mode[1] == "AnalogInChannel" || error("connector $c is in mode $(mode[1]); only analog inputs are supported")

        if haskey(o, :restore)
            xml = read(o[:restore], String)
            dry ? println(xml) : write_xml_section(dev, view, channel_path(c), xml)
            show_connector(dev, c, dry ? "connector $c (unchanged, dry run)" : "connector $c restored from $(o[:restore])")
            return
        end

        show_connector(dev, c, "connector $c before")
        if haskey(o, :save)
            write(o[:save], read_xml_section(dev, view, channel_path(c)))
            println("saved: ", o[:save])
        end

        sensor = parse_xml(stSensor, read_xml_section(dev, view, sensor_path(c)))
        if any(k -> haskey(o, k), SENSOR_OPTS)
            sensor = new_sensor(sensor, o)
            # HBM_XUTIL_ComposeSensor (DLL 1.4.0.1) always writes <PhysUnitUsr>V</PhysUnitUsr>,
            # whatever the struct holds. The unit is given by its code (PhysUnit), and the
            # module itself reports an empty PhysUnitUsr then, so clear it.
            xml = replace(compose_xml(sensor), r"<PhysUnitUsr>[^<]*</PhysUnitUsr>" => "<PhysUnitUsr></PhysUnitUsr>")
            dry ? println("sensor XML:\n", xml) : write_xml_section(dev, view, sensor_path(c), xml)
        end
        # write the signal after the sensor: a new sensor can change the signal's unit
        signal = nothing
        if any(k -> haskey(o, k), SIGNAL_OPTS) || any(k -> haskey(o, k), SENSOR_OPTS)
            old = parse_xml(stSignalParams, read_xml_section(dev, view, signal_path(c)))
            signal = new_signal(old, o, sensor)
            xml = compose_xml(signal)
            dry ? println("signal XML:\n", xml) : write_xml_section(dev, view, signal_path(c), xml)
        end
        if haskey(o, :name)
            dry ? println("channel name: ", o[:name]) :
                  write_parameter(dev, view, channel_path(c), "ChannelName", o[:name])
        end
        dry && return

        now = show_connector(dev, c, "connector $c after")
        if signal !== nothing
            haskey(o, :rate) && now.OutputRate != o[:rate] &&
                @warn "module set $(now.OutputRate) Hz instead of $(o[:rate]) Hz" *
                      (now.FilterType == FILTERTYPE_LOWPASS ? " (a low lowpass cutoff limits the rate)" : "")
            haskey(o, :freq) && now.FiltFreq != o[:freq] &&
                @warn "module set the cutoff to $(now.FiltFreq) Hz instead of $(o[:freq]) Hz"
        end
        println("value: ", measure(dev, c))
    finally
        disconnect(dev)
    end
end

# ------------------------------------------------------------------ command line

function parse_scale(s)
    pts = [parse.(Float64, split(p, ":")) for p in split(s, ",")]
    length(pts) == 2 && all(p -> length(p) == 2, pts) || error("--scale expects e1:p1,e2:p2")
    return Tuple(Tuple(p) for p in pts)
end

lookup(d, val, opt) = get(d, lowercase(val)) do
    error("invalid value \"$val\" for $opt (use one of: $(join(sort(collect(keys(d))), ", ")))")
end

function parse_args(args)
    length(args) >= 2 || error("usage: configure.jl <ip> <connector> [options]; see the header of the file")
    ip, c = args[1], parse(Int, args[2])
    o = Dict{Symbol,Any}()
    i = 3
    while i <= length(args)
        opt = args[i]
        if opt == "--dry-run"
            o[:dryrun] = true; i += 1; continue
        end
        val = get(args, i + 1, nothing)
        val === nothing && error("missing value for $opt")
        if     opt == "--sensor";     o[:sensor] = lookup(SENSORS, val, opt)
        elseif opt == "--range";      o[:range] = parse(Float64, val)
        elseif opt == "--excitation"; o[:excitation] = parse(Float64, val)
        elseif opt == "--bridge";     o[:bridge] = lookup(BRIDGES, val, opt)
        elseif opt == "--wiring";     o[:wiring] = parse(Int, val)
        elseif opt == "--tc";         o[:tc] = TCTYPES[uppercase(val)]
        elseif opt == "--pt";         o[:pt] = lookup(PTTYPES, replace(lowercase(val), "pt" => ""), opt)
        elseif opt == "--scale";      o[:scale] = parse_scale(val)
        elseif opt == "--unit";       o[:unit] = val
        elseif opt == "--rate";       o[:rate] = parse(Float64, val)
        elseif opt == "--filter";     o[:filter] = lookup(FILTERS, val, opt)
        elseif opt == "--charact";    o[:charact] = lookup(CHARACTS, val, opt)
        elseif opt == "--freq";       o[:freq] = parse(Float64, val)
        elseif opt == "--decimals";   o[:decimals] = parse(Int, val)
        elseif opt == "--name";       o[:name] = val
        elseif opt == "--save";       o[:save] = val
        elseif opt == "--restore";    o[:restore] = val
        else error("unknown option $opt")
        end
        i += 2
    end
    return ip, c, o
end

if abspath(PROGRAM_FILE) == @__FILE__
    ip, c, o = parse_args(ARGS)
    main(ip, c, o)
end
