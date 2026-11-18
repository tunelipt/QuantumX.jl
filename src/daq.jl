# Continuous data acquisition: subscriptions and decoding of measured value blocks.

"""
    SignalBlock

Measured values of one signal taken from a measured value block.

* `usersigid` – user signal id given at `subscribe`
* `header`    – the `stDaqHeader` (format, count, NTP time stamps)
* `values`    – values in host byte order (`Float32` for most analog signals)
* `times`     – NTP time stamps per value for asynchronous signals, empty otherwise
                (use `timestamps(block)` for synchronous signals)
"""
struct SignalBlock{T}
    usersigid::Int
    header::stDaqHeader
    values::Vector{T}
    times::Vector{UInt64}
end

Base.length(b::SignalBlock) = length(b.values)
Base.show(io::IO, b::SignalBlock{T}) where {T} =
    print(io, "SignalBlock{", T, "}(sig ", b.usersigid, ", ", length(b.values), " values)")

const SYNC_ELTYPES = Dict{UInt8,DataType}(
    DAQ_MVALFMT_FLOAT => Float32, DAQ_MVALFMT_DOUBLE => Float64,
    DAQ_MVALFMT_INT8 => Int8, DAQ_MVALFMT_INT16 => Int16,
    DAQ_MVALFMT_INT32 => Int32, DAQ_MVALFMT_INT64 => Int64)

const ASYNC_ELTYPES = Dict{UInt8,DataType}(
    DAQ_MVALFMT_FLOAT_ASYNC => Float32, DAQ_MVALFMT_DOUBLE_ASYNC => Float64,
    DAQ_MVALFMT_INT32_ASYNC => Int32, DAQ_MVALFMT_INT64_ASYNC => Int64,
    DAQ_MVALFMT_UINT32_ASYNC => UInt32, DAQ_MVALFMT_UINT64_ASYNC => UInt64)

"Size in bytes of one measured value of a data format (low nibble, 0 means 16)."
function value_size(fmt::UInt8)
    n = fmt & DAQ_MVALFMT_MASK
    return n == 0 ? 16 : Int(n)
end

"""
    decode_signal(buf, rxlen, usersigid) -> SignalBlock

Extract one signal from a raw measured value block using `HBM_XUTIL_GetDaqHeader`
(mode 0 = user signal id) and `HBM_XUTIL_GetDaqData` (big endian -> host order).
"""
function decode_signal(buf::Vector{UInt8}, rxlen::Integer, usersigid::Integer)
    hdr, offset = @qx L.HBM_XUTIL_GetDaqHeader(UInt32(0), UInt32(usersigid), buf, UInt32(rxlen))
    n = Int(hdr.MeasValCount)
    elsize = value_size(hdr.DataFormat)
    raw = Vector{UInt8}(undef, n * elsize)
    if n > 0
        rc = GC.@preserve raw L.HBM_XUTIL_GetDaqData(buf, offset, hdr, Ptr{Cvoid}(pointer(raw)), UInt32(length(raw)))
        _check(:HBM_XUTIL_GetDaqData, rc)
    end
    T = get(SYNC_ELTYPES, hdr.DataFormat, nothing)
    if T !== nothing
        return SignalBlock{T}(Int(usersigid), hdr, collect(reinterpret(T, raw)), UInt64[])
    end
    T = get(ASYNC_ELTYPES, hdr.DataFormat, nothing)
    if T !== nothing && elsize == 8 + sizeof(T)
        # asynchronous data: an NTP time stamp precedes each value
        times = Vector{UInt64}(undef, n)
        vals = Vector{T}(undef, n)
        for i in 1:n
            o = (i - 1) * elsize
            times[i] = reinterpret(UInt64, raw[o+1:o+8])[1]
            vals[i] = reinterpret(T, raw[o+9:o+elsize])[1]
        end
        return SignalBlock{T}(Int(usersigid), hdr, vals, times)
    end
    # CAN raw values or unknown format: return the bytes
    return SignalBlock{UInt8}(Int(usersigid), hdr, raw, UInt64[])
end

"""
    timestamps(block::SignalBlock) -> Vector{UInt64}

NTP time stamps of the values. For synchronous signals they are interpolated
between `header.TimeStamp` and the next block's time stamp.
"""
function timestamps(b::SignalBlock)
    isempty(b.times) || return b.times
    n = length(b.values)
    n == 0 && return UInt64[]
    t0 = b.header.TimeStamp
    t1 = next_timestamp(b.header)
    t1 > t0 || return fill(t0, n)
    dt = (t1 - t0) / n
    return [t0 + round(UInt64, (i - 1) * dt) for i in 1:n]
end

# ------------------------------------------------------------------ subscriptions

"""
    Subscription

An active measurement on one module, created by [`subscribe`](@ref). Holds the receive
buffer; read data with [`read_block`](@ref) (synchronous) or
[`request_block`](@ref)/[`wait_block`](@ref) (asynchronous). Close with
[`unsubscribe`](@ref).
"""
mutable struct Subscription
    dev::QXDevice
    signals::Vector{String}
    usersigids::Vector{UInt16}
    buffer::Vector{UInt8}
    pending::Union{Nothing,UInt32}   # handle of an outstanding async request
    active::Bool
end

Base.show(io::IO, s::Subscription) =
    print(io, "Subscription(", s.dev, ", ", length(s.signals), " signals, ", s.active ? "active" : "closed", ")")

_sigid(s::AbstractString) = String(s)
_sigid(t::Tuple) = signal_path(t...)
_sigid(c::Integer) = signal_path(c)

"""
    subscribe(dev, signals; blocksize = 4096, starttime = 0, bufsize = 2_000_000) -> Subscription

Configure and start a measurement (`HBM_XDAQ_OpenSubscription`, `AddSignal`,
`FinishSubscription`). `signals` is a vector of signal ids (xpaths from
`signal_path`/`signal_list`), `(connector, channel, signal)` tuples or connector numbers.
User signal ids are assigned 1, 2, ... in order. `starttime` is an NTP time stamp
(0 = start now).
"""
function subscribe(dev::DeviceLike, signals::AbstractVector; blocksize::Integer = 4096,
                   starttime::Integer = 0, bufsize::Integer = MEASVALBLOCKSIZELIMIT)
    d = dev isa QXDevice ? dev : QXDevice(dev)
    ids = String[_sigid(s) for s in signals]
    u = uuid(d)
    @qx L.HBM_XDAQ_OpenSubscription(u)
    usersigids = UInt16.(1:length(ids))
    try
        for (id, us) in zip(ids, usersigids)
            @qx L.HBM_XDAQ_AddSignal(u, id, us, UInt32(blocksize))
        end
        @qx L.HBM_XDAQ_FinishSubscription(u, UInt64(starttime))
    catch
        L.HBM_XDAQ_ClearSubscription(u)
        rethrow()
    end
    return Subscription(d, ids, usersigids, Vector{UInt8}(undef, bufsize), nothing, true)
end

# Subscriptions with an outstanding asynchronous request. Keeps their buffers rooted so
# the GC never frees memory the DLL is still going to write into.
const _PENDING = Set{Subscription}()
const _PENDING_LOCK = ReentrantLock()
_set_pending!(sub, h) = lock(_PENDING_LOCK) do
    sub.pending = h
    h === nothing ? delete!(_PENDING, sub) : push!(_PENDING, sub)
end
subscribe(dev::DeviceLike, signal::Union{AbstractString,Tuple,Integer}; kw...) = subscribe(dev, [signal]; kw...)

"""
    unsubscribe(sub)

Stop the measurement (`HBM_XDAQ_ClearSubscription`).
"""
function unsubscribe(sub::Subscription)
    sub.active || return nothing
    if sub.pending !== nothing
        # let an outstanding asynchronous request finish before the buffer can go away
        L.HBM_XCOM_Async_ReadData(sub.pending)
        _set_pending!(sub, nothing)
    end
    @qx L.HBM_XDAQ_ClearSubscription(uuid(sub.dev))
    sub.active = false
    return nothing
end

function _decode_all(sub::Subscription, rxlen)
    return [decode_signal(sub.buffer, rxlen, us) for us in sub.usersigids]
end

"""
    read_block(sub) -> Vector{SignalBlock}

Read the next block of measured values of all subscribed signals
(`HBM_XDAQ_GetMeasValBlock`); blocks until data is available.
"""
function read_block(sub::Subscription)
    sub.active || error("subscription is closed")
    sub.pending === nothing || error("an asynchronous request is pending; call wait_block first")
    rxlen = @qx L.HBM_XDAQ_GetMeasValBlock(uuid(sub.dev), sub.buffer)
    return _decode_all(sub, rxlen)
end

"""
    request_block(sub)

Start an asynchronous block request (`HBM_XDAQ_Async_GetMeasValBlock`) and return
immediately. Collect the data with [`wait_block`](@ref). Useful to request data from
several modules in parallel.
"""
function request_block(sub::Subscription)
    sub.active || error("subscription is closed")
    sub.pending === nothing || error("an asynchronous request is already pending")
    h = @qx L.HBM_XDAQ_Async_GetMeasValBlock(uuid(sub.dev), sub.buffer)
    _set_pending!(sub, h)
    return nothing
end

"""
    wait_block(sub; timeout_ms = nothing) -> Union{Vector{SignalBlock},Nothing}

Wait for the request started by [`request_block`](@ref) (`HBM_XCOM_Async_ReadData` or
`HBM_XCOM_Async_ReadData_Timeout`). With a timeout, returns `nothing` if the data has not
arrived yet; call again to keep waiting.
"""
function wait_block(sub::Subscription; timeout_ms::Union{Nothing,Integer} = nothing)
    h = sub.pending
    h === nothing && error("no asynchronous request pending")
    rc, rxlen = timeout_ms === nothing ? L.HBM_XCOM_Async_ReadData(h) :
                                         L.HBM_XCOM_Async_ReadData_Timeout(h, UInt32(timeout_ms))
    if rc == ERR_EVFLG_PTHREADS && timeout_ms !== nothing
        return nothing
    end
    _set_pending!(sub, nothing)
    _check(:HBM_XCOM_Async_ReadData, rc)
    return _decode_all(sub, rxlen)
end
