module LibAaron
export @forward, flatten, @ccall
const Opt = Union{T,Nothing} where T

# forward methods on a struct to an attribute of that struct
# good for your composition.
# syntax: @forward CompositeType.attr Base.iterate Base.length :*
# Symbol literals automatically become Base.:symbol. Good for adding
# methods to built-in operators.
macro forward(attribute, functions...)
    stname = attribute.args[1]
    stattr = attribute.args[2].value
    block = quote end
    for f in functions
        if f isa QuoteNode
            f = :(Base.$(f.value)) 
            def1 = :($f(x::$stname, y) = $f(x.$stattr, y))
            def2 = :($f(x, y::$stname) = $f(x, y.$stattr))
            push!(block.args, def1, def2)
        else
            def = :($f(x::$stname, args...; kwargs...) = $f(x.$stattr, args...; kwargs...))
        end
        push!(block.args, def)
    end
    esc(block)
end

# flatten things. Probably not as fast as the one in the standard
# library, but more flexible.
struct Flatten
    iterable
    noflatten::Type
    dictfunc::Function

    Flatten(it, nf; dictfunc=nothing) = new(
        it, Union{Number,AbstractChar,nf}, dictfunc == nothing ? d->d : dictfunc
    )
end
flatten(it, nf::Type=AbstractString; kwargs...) = Flatten(it, nf; kwargs...)

function Base.iterate(f::Flatten, stack)
    while length(stack) > 0
        @inbounds node = stack[end]
        if isempty(node)
            pop!(stack)
            continue
        end
        next = popfirst!(node)
        if next isa f.noflatten
            return next, stack
        else
            try
                push!(stack, Iterators.Stateful(
                    next isa AbstractDict ? f.dictfunc(next) : next
                ))
            catch e
                e isa MethodError && return next, stack
                rethrow(e)
            end
        end
    end
    nothing
end

Base.iterate(f::Flatten) =
    iterate(f, Iterators.Stateful[Iterators.Stateful(f.iterable)])

# make calls to C have julia syntax. examples below.
macro ccall(expr)
    expr.head != :(::) &&
        error("@ccall needs a function signature with a return type")
    rettype = expr.args[2]

    call = expr.args[1]
    call.head != :call &&
        error("@ccall has to be a function call")

    if (f = call.args[1]) isa Expr
        lib = f.args[1]
        fname = f.args[2]
        func = :(($fname, $lib))
    else
        func = QuoteNode(f)
    end
    argtypes = :(())
    args = []
    for arg in call.args[2:end]
        arg.head != :(::) &&
            error("args in @ccall must be annotated")
        push!(args, arg.args[1])
        push!(argtypes.args, arg.args[2])
    end
    output = :(ccall($func, $rettype, $argtypes))
    append!(output.args, args)
    return esc(output)
end
        


const glib = "libglib-2.0"

# I wanted a uri escape function. The one in URIParser was weird, and
# the one in GLib is much faster anyway.
function uriescape(uri::AbstractString, noescape::Opt{AbstractString}=nothing)
    noesc = noescape == nothing ? C_NULL : noescape
    cstr = @ccall glib.g_uri_escape_string(
        uri::Cstring, noesc::Cstring, true::Cint
    )::Cstring
    out = unsafe_string(cstr)
    ccall(:free, Cvoid, (Cstring,), cstr)
    out
end

# how are hard links missing from the Julia standard library?
function hardlink(oldpath, newpath)
    err = @ccall link(oldpath::Cstring, newpath::Cstring)::Cint
    systemerror(
        "could not link $(repr(oldpath)) to $(repr(newpath))",
        err != 0
    )::Cint
    newpath
end

# and fifos?
function mkfifo(pathname, mode=0o644)
    err = @ccall mkfifo(pathname::Cstring, mode::Cuint)::Cint
    systemerror("couldn't make fifo, $(repr(pathname))", err != 0)
    pathname
end

end # module
