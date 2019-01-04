#!/usr/bin/env julia
using BenchmarkTools
import JSON
const Opt = Union{T,Nothing} where T

string = raw"""
"<datafield xmlns=\"http://viaf.org/viaf/terms#\" dtype=\"UNIMARC\" ind1=\" \" ind2=\" \" tag=\"215\">     <subfield code=\"7\">ba0yba0y</subfield> <subfield code=\"8\">fre   </subfield>     <subfield code=\"9\"> </subfield>     <subfield code=\"a\">Djelfa, Wilaya de (Alge\u0301rie)</subfield>   </datafield>"
"""[1:end-1]

tobyte(c::Char) = convert(UInt8, c)
macro mkbytes(args...)
    iargs = Iterators.Stateful(args)
    blk = quote end
    for (sym, char) in zip(iargs, iargs)
        push!(blk.args, :(const $sym = tobyte($char)))
    end
    blk
end


@mkbytes backslash '\\' slash '/' dq '"'
@mkbytes nl '\n' bs '\b' ret '\r' tab '\t'
@mkbytes n 'n' b 'b' r 'r' t 't' u 'u' 
const utf8_buf = zeros(UInt8, 6)

function string_unescape(str::String, buffer::Vector{UInt8})
    bytes = Base.CodeUnits(str)
    len = length(bytes)
    length(buffer) < len  && throw(BoundsError(buffer, length(bytes)))
    byteidx::Int = buffidx::Int = 0
    @inbounds while (i += 1) <= bytes
        j += 1
        byte = bytes[i]
        if byte == backslash
            i, j = unpack
        else
            buffer[j] = byte
        end
    end



@btime JSON.eval(string)
