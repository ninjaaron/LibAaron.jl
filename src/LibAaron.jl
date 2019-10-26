module LibAaron

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
macro isscript()
    esc(:( eval(:( abspath(PROGRAM_FILE) == @__FILE__ )) ))
end

"""
    update_env(source_file, command)

Many programming languages (including but not limited to Python) provide
scripts which modif the shell's environment for deveopment purposes.
Such modifications may include modifying `\$PATH` and many other tweaks.

Because these scripts are generally meant for execution in a shell, it
can be difficult to use them inside a program. `update_env` works
around this executing the appropriate commands in a `bash` shell, then
running `env` from that shell, and parsing the output into the
environment of the running Julia program.

- `source_file`: should be the file that contains the defintions to be
  made available to the shell. In the case of a Python virtualenv, it
  would be something like `venv/bin/activate`. Use an empty string,
  `""`, if no file is to be sourced. This is for cases like ocaml, where
  the command is something like `eval \$(opam env)`. In the case of
  `conda`, it may be a file which is normally sourced in .bashrc,
  .bash_profile or similar.
- `command`: the command to run once the file is sourced (probably a
  shell function defined therein). This may also be an empty string if
  no command is required.

Note that the `command` argument may be a `Cmd` instance or an instance
of `AbstractString`. If an `AbstractString` is given, the command will be
handed directly to the shell to exectute and could create an injection
vulnerability if input is not validated. Using a `Cmd` instance will
properly escape the command, but will make certain things impossible;
e.g. `eval \$(opam env)` will not work because it relies on shell
operators. Also note that operator shared between Julia strings and
the shell, like `\$` or `\$()` must be properly escaped in order to reach
the shell--with `raw""` or backslashes.
"""
function update_env(source_file::AbstractString, command::AbstractString)
    source_file = Base.shell_escape(source_file)
    script = if source_file == ""
        """
        $command
        env --null
        """
    else
        """
        source $source_file
        $command
        env --null
        """
    end
    proc = open(`sh`, write=true, read=true)
    reader = @async split(read(proc, String), '\0')
    close(proc)

    foreach(fetch(reader)) do line
        if '=' in line
            (key, value) = split(line, "="; limit=2)
            ENV[key] = value
        end
    end
end

# safe version
update_env(source_file::AbstractString, command::Cmd) =
    let command = join(Base.shell_escape.(command.exec), " ")
        update_env(source_file, command)
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
getlib(start) = filter(split.(readlines(`ldconfig -p`))) do fields
    startswith(fields[1], start)
end[1][1]

function geturiescape()
    glib::String = getlib("libglib-2.0")
    return function(uri, allowed_chars=C_NULL; allow_utf8=false)
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
end

# how are hard links missing from the Julia standard library?
function hardlink(oldpath::AbstractString, newpath::AbstractString)
    err = ccall(:link, Cint, (Cstring, Cstring), oldpath, newpath)
    systemerror("linking $oldpath -> $newpath", err != 0)
    newpath
end

# and fifos?
function mkfifo(pathname::AbstractString, mode=0o644)
    err = ccall(:mkfifo, Cint, (Cstring, Cuint), pathname, mode)
    systemerror("couldn't make fifo, $(repr(pathname))", err != 0)
    pathname
end

struct ExportName
    name::Symbol
    isconst::Bool
end
geteq(sym::Symbol) = ExportName(sym, false)
geteq(expr::Expr) =
    expr.head == :call ? ExportName(expr.args[1], true) : nothing

function getexports(expr, acc=[])
    if Meta.isexpr(expr, :block)
        foreach((e)->getexports(e, acc), expr.args)
    elseif Meta.isexpr(expr, :(=))
        push!(geteq(expr.args[1]))
    elseif Meta.isexpr(expr, :function)
        push!(ExportName(expr.args[1].args[1], true))
    elseif Meta.isexpr(expr, :module)
        push!(ExportName(expr.args[2], true))
    elseif Meta.isexpr(expr, :struct)
        push!(ExportName(expr.args[2], true))
    elseif Meta.isexpr(expr, :const)
        push!(ExportName(getexport(expr.args[1]).name, true))
    end
    return acc
end

mkassignment(mod, name, isconst) =
    isconst ? :(const $name = $mod.$name) : :($name = $mod.$name)


function use_this(mod, expr; noconst=false)
    dummyname = gensym(:DummyModule)
    exports = getexports(expr)
    exprs = Meta.isexpr(expr, :block) ? expr.args : [expr]
    assign = if noconst
        e->mkassignment(dummyname, e.name, false)
    else
        e->mkassignment(dummyname, e.name, e.isconst)
    end
    exported = map(assign, filter(!isnothing, exports))
    usemod = :(using $mod)
    outmod = quote
        module $dummyname
        $usemod
        $(exprs...)
        end
    end

    return quote
        @eval $(outmod.args[2])
        $(exported...)
    end
end

macro use(mod, expr)
    esc(use_this(mod, expr))
end

macro use_local(mod, expr)
    esc(use_this(mod, expr; noconst=true))
end

end # LibAaron module
