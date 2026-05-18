# RPC support — transport-agnostic surface that codegen-emitted service
# stubs build on. Concrete wire protocols (Connect, gRPC, gRPC-Web, ...)
# live in separate packages that subtype `AbstractRpcTransport` and
# implement `rpc_call` (unary) plus the streaming variants when they
# support them.
#
# Design notes live in https://github.com/jw3126/ProtocGen.jl/issues/9.

import EnumX

"""
    AbstractRpcTransport

Supertype every concrete transport (`ProtoConnect.Client`,
`ProtoConnect.Server`, in-process test transports, ...) subtypes.

Codegen-emitted client stubs dispatch on this supertype, so the user
calls `SayHello(transport, req)` directly with whatever transport they
hold — no per-service `*Client` wrapper.
"""
# Re-export the proto descriptor type at the top level so codegen can
# emit `PB.MethodDescriptorProto(...)` without reaching into the nested
# `google.protobuf` module. Users get a shorter spelling too.
const MethodDescriptorProto = google.protobuf.MethodDescriptorProto

abstract type AbstractRpcTransport end

"""
    StatusCode

Canonical RPC status code set, mirrored from gRPC / Connect. The
specific HTTP-status mapping is a transport concern; ProtocGen only
owns the symbolic vocabulary.
"""
EnumX.@enumx StatusCode begin
    OK = 0
    CANCELLED = 1
    UNKNOWN = 2
    INVALID_ARGUMENT = 3
    DEADLINE_EXCEEDED = 4
    NOT_FOUND = 5
    ALREADY_EXISTS = 6
    PERMISSION_DENIED = 7
    RESOURCE_EXHAUSTED = 8
    FAILED_PRECONDITION = 9
    ABORTED = 10
    OUT_OF_RANGE = 11
    UNIMPLEMENTED = 12
    INTERNAL = 13
    UNAVAILABLE = 14
    DATA_LOSS = 15
    UNAUTHENTICATED = 16
end

"""
    RpcError(code, message[, metadata])

Thrown by transports and handlers to signal an RPC-level failure.
The transport translates it to its wire-specific error form (HTTP
status + JSON envelope for Connect, trailers for gRPC, …).
"""
struct RpcError <: Exception
    code::StatusCode.T
    message::String
    metadata::Dict{String,String}
end

function RpcError(code::StatusCode.T, message::AbstractString)
    return RpcError(code, String(message), Dict{String,String}())
end

function Base.showerror(io::IO, e::RpcError)
    print(io, "RpcError(", e.code, "): ", e.message)
end

# -----------------------------------------------------------------------------
# Codegen-emitted methods. Generated `*_pb.jl` files attach one method per RPC
# function `f` to each of these:
#
#   PB.MethodDescriptorProto(::typeof(f))  — proto descriptor (name, I/O FQNs,
#                                            streaming bits).
#   PB.service_fqn(::typeof(f))            — owning service's FQN string. Not
#                                            on MethodDescriptorProto itself,
#                                            so it lives as its own trait.
#
# Everything else (`method_name`, `request_type`, `response_type`, `rpc_mode`)
# is derived from those two, so codegen doesn't have to repeat itself.
# -----------------------------------------------------------------------------

"""
    service_fqn(f) -> String

Fully-qualified service name (e.g. `"greeter.Greeter"`) of the RPC
function `f`. Codegen emits one method per RPC.
"""
function service_fqn end

function method_name(f::Function)
    desc = MethodDescriptorProto(f)
    name = desc.name
    name === nothing &&
        error("MethodDescriptorProto for $(f) is missing the `name` field")
    return name
end

function rpc_mode(f::Function)
    desc = MethodDescriptorProto(f)
    cs = something(desc.client_streaming, false)
    ss = something(desc.server_streaming, false)
    if cs && ss
        return :bidi
    elseif ss
        return :server_stream
    elseif cs
        return :client_stream
    else
        return :unary
    end
end

function request_type(f::Function)
    fqn = MethodDescriptorProto(f).input_type
    fqn === nothing &&
        error("MethodDescriptorProto for $(f) is missing the `input_type` field")
    return _resolve_message_type(f, fqn, "input_type")
end

function response_type(f::Function)
    fqn = MethodDescriptorProto(f).output_type
    fqn === nothing &&
        error("MethodDescriptorProto for $(f) is missing the `output_type` field")
    return _resolve_message_type(f, fqn, "output_type")
end

function _resolve_message_type(f::Function, fqn::AbstractString, field::String)
    # Proto FQN refs are leading-dot in descriptors (`.greeter.HelloRequest`);
    # the message-type registry keys are dotless (`greeter.HelloRequest`).
    key = startswith(fqn, ".") ? fqn[2:end] : String(fqn)
    T = lookup_message_type(key)
    T === nothing && error(
        "RPC $(f): cannot resolve $(field) $(repr(fqn)) — no message type registered. " *
        "Did you forget to load the proto module that defines it?",
    )
    return T
end

# -----------------------------------------------------------------------------
# Transport surface. Transports implement `rpc_call` (unary, mandatory);
# streaming variants are optional and throw `RpcError(UNIMPLEMENTED, …)`
# by default so a unary-only transport gives a clean diagnostic.
# -----------------------------------------------------------------------------

"""
    rpc_call(t::AbstractRpcTransport, service_fqn, method, req_bytes) -> Vector{UInt8}

Send a unary RPC. Transports must implement this. `req_bytes` carries
the encoded protobuf body; the return value is the encoded response.
"""
function rpc_call(
    t::AbstractRpcTransport,
    service::AbstractString,
    method::AbstractString,
    req_bytes::AbstractVector{UInt8},
)
    throw(
        RpcError(
            StatusCode.UNIMPLEMENTED,
            "$(typeof(t)) does not implement rpc_call",
        ),
    )
end

# Streaming entry points — placeholders so transports that support them
# get a clean override target. Not wired into codegen yet.
function rpc_server_stream(
    t::AbstractRpcTransport,
    service::AbstractString,
    method::AbstractString,
    req_bytes::AbstractVector{UInt8},
)
    throw(
        RpcError(
            StatusCode.UNIMPLEMENTED,
            "$(typeof(t)) does not implement rpc_server_stream",
        ),
    )
end

function rpc_client_stream end
function rpc_bidi_stream end

"""
    rpc_invoke(t::AbstractRpcTransport, f::Function, req) -> response

Generic client-side glue codegen calls into. Encodes `req`, dispatches
to `rpc_call` (or the relevant streaming variant), and decodes the
response per `response_type(f)`. Streaming variants will land alongside
the matching codegen.
"""
function rpc_invoke(
    t::AbstractRpcTransport,
    f::Function,
    req::AbstractProtoBufMessage,
)
    mode = rpc_mode(f)
    if mode === :unary
        req_bytes = encode(req)
        resp_bytes = rpc_call(t, service_fqn(f), method_name(f), req_bytes)
        return decode(resp_bytes, response_type(f))
    else
        throw(
            RpcError(
                StatusCode.UNIMPLEMENTED,
                "rpc_invoke: $(mode) not yet wired (see #9)",
            ),
        )
    end
end
