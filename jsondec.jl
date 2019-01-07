#!/usr/bin/env julia
using BenchmarkTools
import JSON

const astring = raw"""
"<datafield xmlns=\\"http://viaf.org/viaf/terms#\\" \n dtype=\\"UNIMARC\\" ind1=\\" \\" ind2=\\" \\" tag=\\"215\\">     <subfield code=\\"7\\">ba0yba0y</subfield> <subfield code=\\"8\\">fre   </subfield>     <subfield code=\\"9\\"> </subfield>     <subfield code=\\"a\\">Djelfa, Wilaya de (Alge\u0301rie)</subfield>   </datafield>"
"""[1:end-1]

# look up ascii characters by byte
const ascii = [Char(i) for i in 1:127]

# lookup the meanings of control characters by byte
const controlchars = "bfnrt"
const escchars = fill(0x00, 127)
for c in controlchars
    escchars[codepoint(c)] = codepoint(Meta.parse("'\\$c'"))
end
for c in "\"\\/"
    escchars[codepoint(c)] = convert(UInt8, ascii[codepoint(c)])
end

struct JSONStringError <: Exception
    var::String
end
Base.show(io, err::JSONStringError) = print(io, "JSONStringerror: $(err.var)")


codelen(i::UInt32) = 4 - (trailing_zeros(0xff000000 | i) >> 3)

# same as: parse(UInt64, str; base=10), but more than 2x faster.
const errptr = Ref(Ptr{UInt8}(0))
function str2uint64(str::Ptr{UInt8}, base::Integer)
    num = ccall(
        :strtoull, Culonglong,
        (Ptr{UInt8}, Ptr{Ptr{UInt8}}, Cint),
        str, errptr, base
    )
    unsafe_load(errptr[]) != 0x00 &&
        error("could not convert $(repr(str)) to base $base")
    num
end
str2uint64(str::String, base::Integer) = str2uint64(pointer(str), base)
str2uint64(str) = str2uint64(str, 10)

# I'm sorry for using pointers like this, but it actually makes a huge
# difference vs. allocating a new string every time.
const str_buff = convert(Ptr{UInt8}, Libc.calloc(5, 1))
# why use @inbounds when you have pointer arithmetic?
@inline function addcodepoint!(bytesp::Ptr{UInt8}, bufferp::Ptr{UInt8})
    unsafe_copyto!(str_buff, bytesp, 4)
    cpoint = convert(UInt32, str2uint64(str_buff, 16))
    # the follwing is modified from string() in substring.jl in base.
    chared = reinterpret(UInt32, Char(cpoint))
    len = codelen(chared)
    x = bswap(chared)
    for i in 1:len
        unsafe_store!(bufferp += 1, x % UInt8)
        x >>= 8
    end
    return len
end
    
function string_unescape!(str::String, buffer::Vector{UInt8})
    bytes = Base.CodeUnits(str)
    len = length(bytes)
    length(buffer) < len  && throw(BoundsError(buffer, length(bytes)))
    i::Int = j::Int = 0
    @inbounds while (i += 1) <= len
        byte = bytes[i]
        if ascii[byte] == '\\'
            byte = bytes[i += 1]
            byte > 127 && throw(JSONStringError("Invalid escape sequence at byte #$i of input. This looks like unicode higher than ASCII"))
            if ascii[byte] == 'u'
                bytes_written = addcodepoint!(pointer(bytes, i+=1), pointer(buffer, j))
                j += bytes_written
                i += 3
            else
                if (escchar = escchars[byte]) == 0x00
                    badchar = "'\\$(ascii[byte])'"
                    throw(JSONStringError("Invalid escape sequence: $badchar at byte #$i"))
                end
                buffer[j += 1] = escchar
            end
        else
            buffer[j += 1] = byte
        end
    end
    return String(@view buffer[1:j])
end


function main()
    # @btime JSON.parse(astring)
    buffer = zeros(UInt8, 1000)
    @btime string_unescape!("\\u0061", $buffer)
    @btime string_unescape!("\\u00eb", $buffer)
    @btime string_unescape!("\\u00eb\\u0061", $buffer)
    @btime string_unescape!("\\u00eb\\u0061\\u00ef", $buffer)
    @btime string_unescape!(astring, $buffer)
    @btime JSON.parse(astring)
    println(string_unescape!("\\u00eb", buffer))
end
main()
