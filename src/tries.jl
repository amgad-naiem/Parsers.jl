"""
    Trie(value::String, value_to_return::T) where {T}
    Trie(values::Vector{String}, value_to_return::T) where {T}
    Trie(values::Vector{Pair{String, T}}) where {T}

    A basic [trie](https://en.wikipedia.org/wiki/Trie) structure for use in parsing sentinel and other special values.
    The various constructors take either a single or set of strings to act as "sentinels" (i.e. special values to be parsed), plus an optional `value_to_return` argument, which will be the value returned if the sentinel is found while parsing.
    Note the last constructor `Trie(values::Vector{Pair{String, T}})` allows specifying different return values for different sentinel values. Bool parsing uses this like:
    ```
    const BOOLS = Trie(["true"=>true, "false"=>false])
    ```
    The only restriction is that each individual value must be of the same type (i.e. a single `Trie` can only ever return one type of value).
    
    See `?Parsers.match!` for more information on how a `Trie` can be used for special-value parsing.
"""
struct Trie{label, leaf, value, L}
    # label::UInt8
    # leaf::Bool
    # value::T
    leaves::L
end
function Trie(label::UInt8, leaf::Bool, value::T, leaves::Vector{Any}) where {T}
    l = Tuple(Trie(x...) for x in leaves)
    return Trie{label, leaf, value, typeof(l)}(l)
end

label(::Type{Trie{a, b, c, d}}) where {a, b, c, d} = a
leaf(::Type{Trie{a, b, c, d}}) where {a, b, c, d} = b
value(::Type{Trie{a, b, c, d}}) where {a, b, c, d} = c
leaves(::Type{Trie{a, b, c, d}}) where {a, b, c, d} = d

Trie(v::String, value::T=missing) where {T} = Trie([v], value)

function Trie(values::Vector{String}, value::T=missing) where {T}
    leaves = []
    for v in values
        if !isempty(v)
            append!(leaves, Tuple(codeunits(v)), value)
        end
    end
    return Trie(0x00, false, value, leaves)
end

function Trie(values::Vector{Pair{String, T}}) where {T}
    leaves = []
    for (k, v) in values
        if !isempty(k)
            append!(leaves, Tuple(codeunits(k)), v)
        end
    end
    return Trie(0x00, false, values[1].second, leaves)
end

function Base.append!(leaves, bytes, value)
    b = first(bytes)
    rest = Base.tail(bytes)
    for t in leaves
        if t[1] === b
            if isempty(rest)
                t[2] = true
                return
            else
                return append!(t[4], rest, value)
            end
        end
    end
    if isempty(rest)
        push!(leaves, [b, true, value, []])
        return
    else
        push!(leaves, [b, false, value, []])
        return append!(leaves[end][4], rest, value)
    end
end

function Base.show(io::IO, n::Trie{label, leaf, value, L}; indent::Int=0) where {label, leaf, value, L}
    print(io, "   "^indent)
    leafnode = leaf ? "leaf-node" : ""
    println(io, "Trie: '$(escape_string(string(Char(label))))' $leafnode")
    for l in n.leaves
        show(io, l; indent=indent+1)
    end
end

lower(c::UInt8) = UInt8('A') <= c <= UInt8('Z') ? c | 0x20 : c 

"""
    Parsers.match!(t::Parsers.Trie, io::IO, r::Parsers.Result, setvalue::Bool=true, ignorecase::Bool=false)

    Function that takes an `io::IO` argument, a prebuilt `r::Parsers.Result` argument, and a `t::Parsers.Trie` argument, and attempts to match/detect special values in `t` with the next bytes consumed from `io`.
    If special values are found, `r.result` will be set to the value that was associated with `t` when it was constructed.
    The return value of `Parsers.match!` is if a special value was indeed detected in `io` (`true` or `false`).
    Optionally, if the `setvalue` is `false`, `r.result` will be unaffected (i.e. not set) even if a special value is found.
    The optional argument `ignorecase` can be used if case-insensitive matching is desired.

    Note that `io` is reset to its original position if no special value is found.
"""
function match! end

@generated function match!(root::Trie{label, leaf, value, L}, io::IO, r::Result, setvalue::Bool=true, ignorecase::Bool=false) where {label, leaf, value, L}
    isempty(L.parameters) && return :(return true)
    q = quote
        eof(io) && return false
        pos = position(io)
        b = peekbyte(io)
        $(generatebranches(L.parameters, false, value, label))
        return false
        @label match
            if setvalue
                setfield!(r, 1, $value)
                r.code = OK
            end
            r.b = b
            return true
        @label nomatch
            fastseek!(io, pos)
            return false
    end
    # @show remove_line_number_nodes(q)
    return q
end

function generatebranches(leaves, isparentleaf, parentvalue, parentb)
    leaf = leaves[1]
    ifblock = Expr(:if, :(b === $(label(leaf)) || (ignorecase && lower(b) === $(lower(label(leaf))))), generatebranch(leaf))
    block = ifblock
    for i = 2:length(leaves)
        leaf = leaves[i]
        elseifblock = Expr(:elseif, :(b === $(label(leaf)) || (ignorecase && lower(b) === $(lower(label(leaf))))), generatebranch(leaf))
        push!(block.args, elseifblock)
        block = elseifblock
    end
    if isparentleaf
        push!(block.args, :(value = $value; b = $parentb; @goto match))
    end
    return quote
        $ifblock
        @goto nomatch
    end
end

function generatebranch(::Type{Trie{label, leaf, value, L}}) where {label, leaf, value, L}
    leaves = L.parameters
    if isempty(leaves)
        body = :(value = $value; @goto match)
    else
        eof = leaf ? :(eof(io) && (value = $value; @goto match)) : :(eof(io) && @goto nomatch)
        body = quote
            $eof
            b = peekbyte(io)
            $(generatebranches(leaves, leaf, value, label))
        end
    end
    return quote
        readbyte(io)
        $body
    end
end

match!(::Nothing, x, y) = false
@generated function match!(root::Trie{label, leaf, value, L}, ptr::Ptr{UInt8}, len::Int) where {label, leaf, value, L}
    isempty(L.parameters) && return :(return len == 0)
    q = quote
        len == 0 && return false
        i = 1
        b = unsafe_load(ptr, i)
        $(generatestrbranches(L.parameters))
    end
    # @show remove_line_number_nodes(q)
    return q
end

function generatestrbranches(leaves)
    leaf = leaves[1]
    ifblock = Expr(:if, :(b === $(label(leaf))), generatestrbranch(leaf))
    block = ifblock
    for i = 2:length(leaves)
        leaf = leaves[i]
        elseifblock = Expr(:elseif, :(b === $(label(leaf))), generatestrbranch(leaf))
        push!(block.args, elseifblock)
        block = elseifblock
    end
    return quote
        $ifblock
        return false
    end
end

function generatestrbranch(::Type{Trie{label, leaf, value, L}}) where {label, leaf, value, L}
    leaves = L.parameters
    if isempty(leaves)
        body = :(return i == len)
    else
        body = quote
            i == len && return $leaf
            i += 1
            b = unsafe_load(ptr, i)
            $(generatestrbranches(leaves))
        end
    end
    return quote
        $body
    end
end

function remove_line_number_nodes(ex)
    todelete = Int[]
    for (i, arg) in enumerate(ex.args)
        if typeof(arg) <: LineNumberNode
            push!(todelete, i)
        elseif typeof(arg) <: Expr && arg.head != :macrocall
            remove_line_number_nodes(arg)
        end
    end
    deleteat!(ex.args, todelete)
    return ex
end

# @noinline function match!(root::Trie, io::IO, r::Result, setvalue::Bool=true, ignorecase::Bool=false)
#     pos = position(io)
#     if isempty(root.leaves)
#         return true
#     else
#         for n in root.leaves
#             matchleaf!(n, io, r, setvalue, ignorecase) && return true
#         end
#     end
#     fastseek!(io, pos)
#     return false    
# end

# function matchleaf!(node::Trie, io::IO, r::Result, setvalue::Bool=true, ignorecase::Bool=false)
#     eof(io) && return false
#     b = peekbyte(io)
#     # @debug "matching $(escape_string(string(Char(b)))) against $(escape_string(string(Char(node.label))))"
#     if node.label === b || (ignorecase && lower(node.label) === lower(b))
#         readbyte(io)
#         if isempty(node.leaves)
#             setvalue && (r.result = node.value)
#             r.code = OK
#             r.b = b
#             return true
#         else
#             for n in node.leaves
#                 matchleaf!(n, io, r, setvalue, ignorecase) && return true
#             end
#         end
#         # didn't match, if this is a leaf node, then we matched, otherwise, no match
#         if node.leaf
#             setvalue && (r.result = node.value)
#             r.code = OK
#             r.b = b
#             return true
#         end
#     end
#     return false
# end
