module LibAaron

const Opt = Union{T,Nothing} where T

"""
forward methods on a struct to an attribute of that struct
good for your composition.
syntax: `@forward CompositeType.attr Base.iterate Base.length :*`
Symbol literals automatically become Base.:symbol. Good for adding
methods to built-in operators.
"""
macro forward(structfield, functions...)
    structname = structfield.args[1]
    field = structfield.args[2].value
    block = quote end
    for f in functions
        # case for operator symbols
        if f isa QuoteNode
            f = :(Base.$(f.value)) 
            def1 = :($f(x::$structname, y) = $f(x.$field, y))
            def2 = :($f(x, y::$structname) = $f(x, y.$field))
            push!(block.args, def1, def2)
        # normal case
        else
            def = :(
                $f(x::$structname, args...; kwargs...) = $f(x.$field, args...; kwargs...)
            )
            push!(block.args, def)
        end
    end
    esc(block)
end

"""
Check if you're running as a script. Normally used with `@__FILE__` as the
argument. Usage:

    isscript(@__FILE__)

Normally, it won't run if the file is loaded interactively. Override with:

    isscript(@__FILE__, run_interactive=true)
"""
isscript(file; run_interactive=false) =
    file == abspath(PROGRAM_FILE) && (run_interactive || !isinteractive())


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
getlib(start) = filter(split.(readlines(`ldconfig -p`))) do fields
    startswith(fields[1], start)
end[1][1]

function uriescape(uri, allowed_chars=C_NULL; allow_utf8=false)
    cstr = ccall(
        (:g_uri_escape_string, glib),
        Cstring,
        (Cstring, Cstring, Cint),
        uri, allowed_chars, allow_utf8
    )
    out = unsafe_string(cstr)
    ccall(:free, Cvoid, (Cstring,), cstr)
    out
end

# how are hard links missing from the Julia standard library?
function hardlink(oldpath::S, newpath::S) where S <: AbstractString
    err = ccall(:link, Cint, (Cstring, Cstring), oldpath, newpath)
    systemerror("linking $oldpath -> $newpath", err != 0)
    newpath
end

# and fifos?
function mkfifo(pathname, mode=0o644)
    err = ccall(:mkfifo, Cint, (Cstring, Cuint), pathname, mode)
    systemerror("couldn't make fifo, $(repr(pathname))", err != 0)
    pathname
end

end # LibAaron module
