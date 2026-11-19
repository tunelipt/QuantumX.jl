# Record several connectors at a given sample rate for a fixed time.
#
#   julia +release~x86 --project=. examples/acquire_rate.jl 192.168.169.10 [out.csv]
#
# Sets the output rate of signal 1 of each connector, records `duration` seconds,
# optionally writes a CSV file, and restores the original output rates at the end.

using QuantumX
using Dates

function main(ip, outfile; connectors = [1, 2, 3, 6],
              rate = 1200.0,        # Hz; MX840 (fw 1.5.12): ... 50, 75, 100, 150, 200, 300, 600, 1200, 2400
                                    # other values are rounded up, so the rate is read back below
              duration = 10.0)      # s
    nsamples = round(Int, rate * duration)
    view     = PARVIEW_CONNECTORPARAM
    paths    = [signal_path(c) for c in connectors]

    dev = connect(ip)
    println("connected: ", dev)

    # Remember the current output rates so they can be restored afterwards
    old_rates = [read_parameter(dev, view, p, "OutputRate") for p in paths]

    values = [Float32[] for _ in connectors]
    t0 = nothing
    try
        for p in paths
            write_parameter(dev, view, p, "OutputRate", rate)
        end
        actual = [read_parameter(dev, view, p, "OutputRate") for p in paths]
        all(==(rate), actual) || @warn "module did not accept the requested rate" actual
        for (c, r, sp) in zip(connectors, actual, paths)
            filt = parse_xml(stSignalParams, read_xml_section(dev, view, sp))
            println("connector $c: $(r) Hz, filter $(filt.FilterType) $(filt.FiltFreq) Hz")
        end

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
        # Restore the original rates. If the connection was lost (e.g. the module
        # rebooted), warn instead of throwing so the original error stays visible;
        # after a reboot the module is back at its stored settings anyway.
        # Restore in reverse order: the MX840 (fw 1.5.12) keeps connector 1 at a rate
        # >= the other connectors', so lowering connector 1 first has no effect.
        try
            for (p, r) in Iterators.reverse(collect(zip(paths, old_rates)))
                write_parameter(dev, view, p, "OutputRate", r)
            end
            now = [read_parameter(dev, view, p, "OutputRate") for p in paths]
            now == old_rates || @warn "output rates not fully restored" old_rates now
        catch e
            @warn "could not restore the output rates" old_rates exception = e
        end
        try
            disconnect(dev)
        catch
        end
    end

    # Trim to exactly `nsamples` per connector
    values = [v[1:nsamples] for v in values]
    t = (0:nsamples-1) ./ rate                      # s, relative to the first sample
    println("start: ", ntp2datetime(t0), "  ", nsamples, " samples per connector")
    for (c, v) in zip(connectors, values)
        println("connector $c: mean = $(sum(v) / length(v)), min = $(minimum(v)), max = $(maximum(v))")
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

ip      = length(ARGS) >= 1 ? ARGS[1] : "192.168.169.10"
outfile = length(ARGS) >= 2 ? ARGS[2] : nothing
main(ip, outfile)
