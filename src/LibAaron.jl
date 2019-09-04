module LibAaron

import CcallMacros: @cdef, @ccall
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

# use a process as a filter
function procwrite!(proc, str::Union{AbstractVector{UInt8}, AbstractString})
    write(proc, str)
    close(proc.in)
end

function procwrite!(proc, lines)
    for line in lines
        write(proc, line, '\n')
    end
    close(proc.in)
end

function openfilter(fn::Function, cmd::Base.AbstractCmd, input)
    proc = open(cmd, read=true, write=true)
    writer = @async procwrite!(proc, input)
    reader = @async fn(proc)
    try
        wait(writer)
        return fetch(reader)
    finally
        close(proc)
    end
end

function openfilter(cmd::Base.AbstractCmd, input)
    proc = open(cmd, read=true, write=true)
    writer = @async procwrite!(proc, input)
    proc
end

# I wanted a uri escape function. The one in URIParser was weird, and
# the one in GLib is much faster anyway.
const glib = "libglib-2.0"

function uriescape(uri, allowed_chars=C_NULL; allow_utf8=false)
    cstr = @ccall glib.g_uri_escape_string(
        uri::Cstring, allow_chars::Cstring, allow_utf8::Cint
    )::Cstring
    out = unsafe_string(cstr)
    @ccall free(cstr::Cstring)::Cvoid
    out
end

# how are hard links missing from the Julia standard library?
function hardlink(oldpath, newpath)
    err = @ccall link(oldpath::Cstring, newpath::Cstring)::Cint
    systemerror("linking $(repr(oldpath)) to $(repr(newpath))", err != 0)
    newpath
end

# and fifos?
function mkfifo(pathname, mode=0o644)
    err = @ccall mkfifo(pathname::Cstring, mode::Cuint)::Cint
    systemerror("couldn't make fifo, $(repr(pathname))", err != 0)
    pathname
end

end # module
