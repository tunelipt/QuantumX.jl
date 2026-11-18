# Continuous acquisition from a QuantumX module – Julia version of the
# "Starting an acquisition" example in the HBM help file.
#
#   julia +release~x86 --project=. examples/acquire.jl 192.168.169.10

using QuantumX
using Dates

ip = length(ARGS) >= 1 ? ARGS[1] : "192.168.169.10"

println("HBM_QX_Framework ", dll_version())
dev = connect(ip; port = 5001)
println("connected: ", dev)

# Signal 1 of channel 1 on connectors 1..8
signals = [signal_path(c, 1, 1) for c in 1:8]
sub = subscribe(dev, signals; blocksize = 4096)
try
    for i in 1:5
        sleep(1)
        blocks = read_block(sub)        # one SignalBlock per subscribed signal
        for b in blocks
            isempty(b.values) && continue
            t0 = ntp2datetime(b.header.TimeStamp)
            println("block $i  sig $(b.usersigid): $(length(b)) values from $t0, ",
                    "mean = $(sum(b.values) / length(b.values))")
        end
    end
finally
    unsubscribe(sub)
    disconnect(dev)
end
