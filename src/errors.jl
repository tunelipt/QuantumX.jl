"""
    QXError(func, code)

Error returned by a QuantumX API function (negative return code). `code` is one of
the `tError` values (e.g. `QuantumX.ERR_EVFLG_PTHREADS`); `error_name(code)` gives
its symbolic name and `error_text(code)` the DLL's description.
"""
struct QXError <: Exception
    func::Symbol
    code::Int32
end

"Symbolic name of an error code (`:ERR_...`), or `nothing` if unknown."
error_name(code::Integer) = get(ERROR_NAMES, Int32(code), nothing)

"""
    error_text(code) -> String

Text description of an error/warning code as provided by `HBM_XUTIL_GetText`.
"""
function error_text(code::Integer)
    txt = try
        LibQX.HBM_XUTIL_GetText(Int32(code))
    catch
        ""
    end
    txt = strip(txt)
    return occursin("text missing", txt) ? "" : String(txt)
end

function Base.showerror(io::IO, e::QXError)
    print(io, "QXError: ", e.func, " returned ", e.code)
    name = error_name(e.code)
    name === nothing || print(io, " (", name, ")")
    txt = error_text(e.code)
    isempty(txt) || print(io, ": ", txt)
end

# Check the return code of a raw call. Tuples are (rc, outputs...):
#   rc only      -> nothing
#   (rc, x)      -> x
#   (rc, x, y..) -> (x, y, ...)
@inline function _check(func::Symbol, rc::Integer)
    rc < 0 && throw(QXError(func, rc))
    rc > 0 && _warn(func, rc)
    return nothing
end
@inline function _check(func::Symbol, t::Tuple)
    _check(func, t[1])
    rest = map(_jl, Base.tail(t))
    return length(rest) == 1 ? rest[1] : rest
end

# Text outputs come from the wrapper as CxxWrap `StdString`s; return Julia `String`s
# (regexes, for instance, only work on `String`).
_jl(x) = x
_jl(x::CxxWrap.StdString) = String(x)

# Positive return codes: only the documented warnings (WARN_*) are reported; other
# positive values are ordinary results (e.g. HBM_Init returns 1).
function _warn(func, rc)
    name = error_name(rc)
    name === nothing && return
    @warn "$func returned warning $rc ($name)" text = error_text(rc) maxlog = 10
end

"""
    @qx LibQX.HBM_Xxx(args...)

Call a raw binding and check its return code (throws `QXError` if negative).
Returns the outputs without the return code.
"""
macro qx(call)
    Meta.isexpr(call, :call) || error("@qx expects a function call")
    f = call.args[1]
    name = f isa Symbol ? f : (Meta.isexpr(f, :.) ? f.args[end].value : Symbol(f))
    return :(_check($(QuoteNode(name)), $(esc(call))))
end
