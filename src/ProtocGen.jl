module ProtocGen

import EnumX
import BufferedStreams
import OrderedCollections: OrderedDict
import StructHelpers
using TOML

const PACKAGE_VERSION = let
    project = TOML.parsefile(joinpath(@__DIR__, "..", "Project.toml"))
    VersionNumber(project["version"])
end

struct OneOf{T}
    name::Symbol
    value::T
end

"""
    DecodeError(msg)

Thrown by generated `decode` methods when a wire-format invariant is violated
that the decoder can describe — e.g., a proto2 `required` field is missing
from the input. Distinct from `EOFError` and the codec's lower-level errors.
"""
struct DecodeError <: Exception
    msg::String
end

function Base.showerror(io::IO, e::DecodeError)
    print(io, "DecodeError: ", e.msg)
end

function Base.getindex(t::OneOf)
    return t.value
end
function Base.Pair(t::OneOf)
    return t.name => t.value
end

include("codec/Codecs.jl")

# OneOf-vs-OneOf merge: per the protobuf spec, when multiple members
# of the same oneof appear on the wire, only the last seen member is
# set. So when two top-level messages are merged, `s2`'s active member
# replaces `s1`'s. Defined here (not inside Codecs) because `OneOf` is
# declared in this module.
@inline Codecs._merge_structs(::OneOf, s2::OneOf) = s2

import .Codecs
import .Codecs:
    _decode,
    _decode!,
    _encode,
    AbstractProtoDecoder,
    AbstractProtoEncoder,
    ProtoDecoder,
    ProtoEncoder,
    BufferedVector,
    message_done,
    decode_tag,
    _encoded_size,
    _skip_and_capture!

abstract type AbstractProtoBufMessage end

function reserved_fields(::Type{T}) where {T}
    return (names = String[], numbers = Union{Int,UnitRange{Int}}[])
end

function extendable_field_numbers(::Type{T}) where {T}
    return Union{Int,UnitRange{Int}}[]
end

function oneof_field_types(::Type{T}) where {T}
    return (;)
end

function field_numbers(::Type{T}) where {T}
    return (;)
end

# Maps each Julia field name → the JSON key it serializes to. Codegen
# emits a method per generated message reading the (already populated)
# `json_name` from the FieldDescriptor; the default-empty NamedTuple
# returned here means "use the Julia field name verbatim" — useful for
# in-process / hand-written types that haven't been through codegen.
function json_field_names(::Type{T}) where {T}
    return (;)
end

# Public binary codec surface. The underscore-prefixed `_encode` /
# `_decode` are the wire-level workhorses used by generated code; users
# should not have to touch `ProtoEncoder` / `ProtoDecoder` at all.
function encode(io::IO, msg::AbstractProtoBufMessage)
    _encode(ProtoEncoder(io), msg)
    return io
end

function encode(msg::AbstractProtoBufMessage)
    buf = IOBuffer()
    _encode(ProtoEncoder(buf), msg)
    return take!(buf)
end

function decode(io::IO, ::Type{T}) where {T<:AbstractProtoBufMessage}
    return _decode(ProtoDecoder(io), T)
end

function decode(bytes::AbstractVector{UInt8}, ::Type{T}) where {T<:AbstractProtoBufMessage}
    return _decode(ProtoDecoder(IOBuffer(bytes)), T)
end

# `json.jl` defines `_decode_json_message`, which the generated bootstrap
# files extend (forwarding methods so abstract cycle supertypes route to
# the concrete struct). It has to load *before* `gen/google/google.jl`
# pulls those files in.
include("json.jl")

include("../gen/google/google.jl")

include("codegen.jl")
include("plugin.jl")
include("plugin_app.jl")
include("wkt.jl")
include("json_wkt.jl")
include("rpc.jl")
include("testing.jl")

export encode, decode, encode_json, decode_json
export OneOf, AbstractProtoBufMessage, DecodeError, OrderedDict
export reserved_fields,
    extendable_field_numbers, oneof_field_types, field_numbers, json_field_names
export AbstractRpcTransport, RpcError, StatusCode

end # module
