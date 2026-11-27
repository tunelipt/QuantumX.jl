# Print the configuration of all connectors of a module (read only, nothing is changed).
#
#   julia +release~x86 --project=. examples/print_config.jl 192.168.169.10 [--xml]
#
# For each connector: mode, channel name, sensor (type, range, scaling, unit), signal
# (output rate, filter, decimals) and the current measured value. `--xml` also prints
# the complete parameter XML of the module (PARVIEW_CONNECTORPARAM).

using QuantumX

# FILTERCHARACT_BESSEL -> "bessel", TCTYPE_K -> "k"
short(x) = lowercase(replace(string(x), r"^[A-Z0-9]+_" => ""))

# first match of <tag>...</tag> in an XML string, "" if absent
xmltag(xml, tag) = (m = match(Regex("<$tag>([^<]*)</$tag>"), xml); m === nothing ? "" : m[1])

function unitstr(code, usr)
    u = cstring(usr)
    isempty(u) ? unit_name(code) : u
end

# Scaling as written in the sensor XML, e.g. `gain (m = 1.000000, b = 0.000000)`.
# Used when HBM_XUTIL_ParseSensor does not know the scaling (it reports Gain as unknown).
function xml_scaling(sxml)
    m = match(r"<Scalingtype choice=\"([^\"]+)\"><[^>]+>(.*?)</[^>]+></Scalingtype>", sxml)
    m === nothing && return "unknown"
    vals = join(("$(v[1]) = $(v[2])" for v in eachmatch(r"<(\w+)>([^<]*)</\1>", m[2])), ", ")
    return isempty(vals) ? lowercase(m[1]) : "$(lowercase(m[1])) ($vals)"
end

function describe_sensor(s::stSensor, sxml)
    t = s.Type
    d = if t == BRIDGESENSOR
        b = s.Bridge
        "bridge ($(short(b.BridgeType)), $(short(b.Wiring))-wire), excitation $(b.ExcitAmpl) V, " *
        "range ±$(s.MaxElecVal)"
    elseif t == INDBRIDGESENSOR
        b = s.IndBridge
        "inductive bridge ($(short(b.BridgeType))), excitation $(b.ExcitAmpl) V, range ±$(s.MaxElecVal)"
    elseif t == THERMOCOUPLE
        "thermocouple type $(uppercase(short(s.ThermoCouple.Type)))"
    elseif t == PTSENSOR
        "$(replace(string(s.Pt.Type), "PTTYPE_" => "Pt")), $(short(s.Pt.Wiring))-wire"
    elseif t == POTISENSOR
        "potentiometer $(s.Poti.Resistance) Ω, $(short(s.Poti.Wiring))-wire"
    elseif t in (VOLTAGESENSOR, CURRENTSENSOR, IEPESENSOR, LVDTSENSOR)
        "$(lowercase(replace(string(t), "SENSOR" => ""))), range ±$(s.MaxElecVal)"
    else
        lowercase(string(t))
    end
    s.Supply > 0 && (d *= ", supply $(s.Supply) V")
    sc = s.Scaling
    p = sc.TwoPoint
    d *= if sc.Type == SCALING_ZEROSPAN
        ", scaling zerospan ($(p.ElectVal1) → $(p.PhysVal1), $(p.ElectVal2) → $(p.PhysVal2))"
    elseif sc.Type == SCALING_UNKNOWN
        ", scaling " * xml_scaling(sxml)
    else
        ", scaling $(short(sc.Type))"
    end
    d *= ", unit $(unitstr(s.PhysUnit, s.PhysUnitUsr))"
    name = cstring(s.Identification.SensorName)
    isempty(name) || (d = "\"$name\" " * d)
    return d
end

function describe_signal(p::stSignalParams)
    f = p.FilterType == FILTERTYPE_OFF ? "filter off" :
        "$(short(p.FilterType)) $(short(p.FiltCharact)) $(p.FiltFreq) Hz"
    "$(p.OutputRate) Hz, $f, $(p.DecimalPlaces) decimals, unit $(unitstr(p.OutputUnit, p.OutputUnitUsr))"
end

function main(ip; showxml = false)
    view = PARVIEW_CONNECTORPARAM
    dev = connect(ip)
    try
        println(dev, "  (DLL ", dll_version(), ")")
        xml = read_xml(dev, view)
        showxml && println(xml, "\n")

        # connectors and their mode, e.g. <Connector1><Mode choice="AnalogInChannel">
        for m in eachmatch(r"<Connector(\d+)><Mode choice=\"([^\"]+)\">", xml)
            c, mode = parse(Int, m[1]), m[2]
            if mode != "AnalogInChannel"
                println("connector $c: mode $mode (details not decoded here, use --xml)")
                continue
            end
            chxml  = read_xml_section(dev, view, channel_path(c))
            sxml   = read_xml_section(dev, view, sensor_path(c))
            sensor = parse_xml(stSensor, sxml)
            signal = parse_xml(stSignalParams, read_xml_section(dev, view, signal_path(c)))
            name   = xmltag(chxml, "ChannelName")
            value  = measure(dev, c)
            println("connector $c", isempty(name) ? "" : " \"$name\"", ": analog input")
            println("  sensor: ", describe_sensor(sensor, sxml))
            println("  signal: ", describe_signal(signal))
            offset = xmltag(chxml, "Offset")
            isempty(offset) || parse(Float64, offset) == 0 || println("  zero offset: ", offset)
            println("  value:  ", isnan(value) ? "invalid (no sensor?)" : value)
        end
    finally
        disconnect(dev)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    isempty(ARGS) && error("usage: print_config.jl <ip> [--xml]")
    main(ARGS[1]; showxml = "--xml" in ARGS)
end
