#!/usr/bin/env julia
using BenchmarkTools
# import JSON

const astring = raw"""
"<datafield xmlns=\\"http://viaf.org/viaf/terms#\\" \n dtype=\\"UNIMARC\\" ind1=\\" \\" ind2=\\" \\" tag=\\"215\\">     <subfield code=\\"7\\">ba0yba0y</subfield> <subfield code=\\"8\\">fre   </subfield>     <subfield code=\\"9\\"> </subfield>     <subfield code=\\"a\\">Djelfa, Wilaya de (Alge\u0301rie)</subfield>   </datafield>"
"""[1:end-1]

const ascii = [Char(i) for i in 1:127]
const controlchars = "bfnrt"
const escchars = fill(0x00, 127)
for c in controlchars
    escchars[codepoint(c)] = codepoint(Meta.parse("'\\$c'"))
end
for c in "\"\\/"
    escchars[codepoint(c)] = convert(UInt8, ascii[codepoint(c)])
end


codelen(i::UInt32) = 4 - (trailing_zeros(0xff000000 | i) >> 3)

# same as: parse(UInt64, str; base=10), but way faster.
str2uint64(str::String, base::Integer=10) =
    ccall(:strtoul, Culong, (Cstring, Ptr{Cstring}, Cint), str, C_NULL, base)

# str_buff is not a "constant". This is really a buffer that is
# manipulated with unsafe_copy! arithmetic in addcodepoint!. I'm sorry
# for doing this, but it actually makes a huge difference against
# allocating a new string every time.
const str_buff = "0000"
# why use @inbounds when you have pointer arithmetic?
function addcodepoint!(bytesp::Ptr{UInt8}, bufferp::Ptr{UInt8})
    unsafe_copyto!(pointer(str_buff), bytesp, 4)
    cpoint = convert(UInt32, str2uint64(str_buff, 16))
    chared = reinterpret(UInt32, Char(cpoint))
    # the follwing ins modified from string
    lenc = codelen(chared)
    offs = 1
    x = bswap(chared)
    for i in 1:lenc
        unsafe_store!(bufferp + offs, x % UInt8)
        offs += 1
        x >>= 8
    end
    return lenc
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
            if ascii[byte] == 'u'
                bytes_written = addcodepoint!(pointer(bytes, i+=1), pointer(buffer, j))
                j += bytes_written
                i += 3
            else
                buffer[j += 1] = escchars[byte]
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
    @btime string_unescape!(astring, $buffer)
end
main()
