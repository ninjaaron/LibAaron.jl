module LibAaron
export @forward, flatten

# forwartd
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

end # module