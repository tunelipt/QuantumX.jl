# Record several connectors with a given sample rate and filter for a fixed time.
#
#   julia +release~x86 --project=. examples/acquire_filter.jl 192.168.169.10 [options]
#
# Options (all optional):
#   --connectors 1,2,3,6     connectors to record (signal 1 of each)
#   --rate 1200              output rate in Hz; MX840 (fw 1.5.12): ... 50, 75, 100, 150, 200,
#                            300, 600, 1200, 2400 (other values are rounded up by the module)
#   --filter lowpass         lowpass | off
#   --charact bessel         bessel | butterworth (lowpass only)
#   --freq 100               lowpass cutoff frequency in Hz
#   --duration 10            recording time in s
#   --out data.csv           write a CSV file (t, conn1, conn2, ...)
#
# Rate and filter are written as one signal-parameter telegram (`stSignalParams` ->
# `compose_xml` -> `write_xml_section`, as in the HBM help example "Parametrisation of a
# signal"), read back, and the original settings are restored at the end.

using QuantumX
using Dates

const FILTERS  = Dict("lowpass" => FILTERTYPE_LOWPASS, "off" => FILTERTYPE_OFF)
const CHARACTS = Dict("bessel" => FILTERCHARACT_BESSEL, "butterworth" => FILTERCHARACT_BUTTERWORTH)

describe(s::stSignalParams) = s.FilterType == FILTERTYPE_OFF ?
    "$(s.OutputRate) Hz, filter off" :
    "$(s.OutputRate) Hz, $(s.FilterType) $(s.FiltCharact) $(s.FiltFreq) Hz"

function main(ip, outfile; connectors = [1, 2, 3, 6],
              rate = 1200.0,                        # Hz
              filtertype = FILTERTYPE_LOWPASS,      # FILTERTYPE_LOWPASS or FILTERTYPE_OFF
              charact = FILTERCHARACT_BESSEL,       # FILTERCHARACT_BESSEL or FILTERCHARACT_BUTTERWORTH
              freq = 100.0,                         # Hz, lowpass cutoff
              duration = 10.0)                      # s
    nsamples = round(Int, rate * duration)
    view     = PARVIEW_CONNECTORPARAM
    paths    = [signal_path(c) for c in connectors]

    dev = connect(ip)
    println("connected: ", dev)

    # Remember the complete signal parameters so they can be restored afterwards
    old = [parse_xml(stSignalParams, read_xml_section(dev, view, p)) for p in paths]

    values = [Float32[] for _ in connectors]
    t0 = nothing
    try
        for (p, o) in zip(paths, old)
            new = setfields(o; OutputRate = rate, FilterType = filtertype, FiltCharact = charact,
                            FiltFreq = filtertype == FILTERTYPE_OFF ? o.FiltFreq : freq)
            write_xml_section(dev, view, p, compose_xml(new))
        end
        actual = [parse_xml(stSignalParams, read_xml_section(dev, view, p)) for p in paths]
        for (c, a) in zip(connectors, actual)
            println("connector $c: ", describe(a))
        end
        any(a -> a.OutputRate != rate, actual) && @warn "module changed the requested rate" [a.OutputRate for a in actual]
        filtertype == FILTERTYPE_LOWPASS && any(a -> a.FiltFreq != freq || a.FilterType != filtertype, actual) &&
            @warn "module changed the requested filter" [(a.FilterType, a.FiltFreq) for a in actual]
        rate = actual[1].OutputRate                 # use what the module really does
        nsamples = round(Int, rate * duration)

        # block size per signal: room for 4 s of Float32 values, at least 10000 bytes
        sub = subscribe(dev, paths; blocksize = max(10000, ceil(Int, rate * 4 * 4)))
        try
            while any(v -> length(v) < nsamples, values)
                for b in read_block(sub)            # blocks until data is available
                    isempty(b.values) && continue
                    t0 === nothing && (t0 = b.header.TimeStamp)
                    append!(values[b.usersigid], b.values)
                end
            end
        finally
            try
                unsubscribe(sub)
            catch e
                @warn "unsubscribe failed" exception = e
            end
        end
    finally
        # Restore in reverse order: the MX840 (fw 1.5.12) keeps connector 1 at a rate
        # >= the other connectors', so lowering connector 1 first has no effect.
        try
            for (p, o) in Iterators.reverse(collect(zip(paths, old)))
                write_xml_section(dev, view, p, compose_xml(o))
            end
            now = [parse_xml(stSignalParams, read_xml_section(dev, view, p)) for p in paths]
            key(s) = (s.OutputRate, s.FilterType, s.FiltCharact, s.FiltFreq)
            key.(now) == key.(old) || @warn "settings not fully restored" old = describe.(old) now = describe.(now)
        catch e
            @warn "could not restore the signal settings" exception = e
        end
        try
            disconnect(dev)
        catch
        end
    end

    # Trim to exactly `nsamples` per connector (open inputs are NaN)
    values = [v[1:nsamples] for v in values]
    t = (0:nsamples-1) ./ rate                      # s, relative to the first sample
    println("start: ", ntp2datetime(t0), "  ", nsamples, " samples per connector")
    for (c, v) in zip(connectors, values)
        ok = filter(!isnan, v)
        if isempty(ok)
            println("connector $c: no valid values (open input?)")
        else
            println("connector $c: mean = $(sum(ok) / length(ok)), min = $(minimum(ok)), max = $(maximum(ok))")
        end
    end

    if outfile !== nothing
        open(outfile, "w") do io
            println(io, join(["t"; ["conn$c" for c in connectors]], ","))
            for i in 1:nsamples
                println(io, join([t[i]; [v[i] for v in values]], ","))
            end
        end
        println("written: ", outfile)
    end
    return t, values
end

# ------------------------------------------------------------------ command line

function parse_args(args)
    isempty(args) && error("usage: acquire_filter.jl <ip> [--connectors 1,2] [--rate Hz] " *
                           "[--filter lowpass|off] [--charact bessel|butterworth] [--freq Hz] " *
                           "[--duration s] [--out file.csv]")
    ip = args[1]
    kw = Dict{Symbol,Any}()
    outfile = nothing
    i = 2
    while i <= length(args)
        opt, val = args[i], get(args, i + 1, nothing)
        val === nothing && error("missing value for $opt")
        if opt == "--connectors"
            kw[:connectors] = parse.(Int, split(val, ","))
        elseif opt == "--rate"
            kw[:rate] = parse(Float64, val)
        elseif opt == "--filter"
            kw[:filtertype] = FILTERS[lowercase(val)]
        elseif opt == "--charact"
            kw[:charact] = CHARACTS[lowercase(val)]
        elseif opt == "--freq"
            kw[:freq] = parse(Float64, val)
        elseif opt == "--duration"
            kw[:duration] = parse(Float64, val)
        elseif opt == "--out"
            outfile = val
        else
            error("unknown option $opt")
        end
        i += 2
    end
    return ip, outfile, kw
end

if abspath(PROGRAM_FILE) == @__FILE__
    ip, outfile, kw = parse_args(ARGS)
    main(ip, outfile; kw...)
end
