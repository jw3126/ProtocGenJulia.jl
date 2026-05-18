"""
ProtoConnect — Connect RPC transport for ProtocGen-generated services.

Minimal v0 sketch covering unary calls only. Connect-protocol unary is
essentially a plain HTTP POST: request body is the encoded protobuf,
response body is the encoded reply, errors are HTTP non-200 with a
JSON envelope. No framing on either side — that's the big simplifier
versus gRPC-Web.

Streaming + Connect-JSON content type are intentionally deferred. The
streaming framing (`[flags:1][len:4][bytes]` with end-stream flag bit)
mirrors gRPC-Web closely; we'll land it once a real consumer needs it.

Spec reference: https://connectrpc.com/docs/protocol
"""
module ProtoConnect

import ProtocGen as PB
import HTTP
import JSON

const CONTENT_TYPE_PROTO = "application/proto"
const PROTOCOL_VERSION_HEADER = "Connect-Protocol-Version"
const PROTOCOL_VERSION = "1"

# ---------------------------------------------------------------------------
# Client.
# ---------------------------------------------------------------------------

"""
    Client(base_url; default_headers = Dict())

Connect-protocol client. Pass directly to a generated RPC stub:

    client = ProtoConnect.Client("http://localhost:8080")
    reply = SayHello(client, HelloRequest(name = "Alice"))

`base_url` is the origin only (no trailing slash); the path becomes
`/<service-fqn>/<method-name>` per Connect spec.
"""
struct Client <: PB.AbstractRpcTransport
    base_url::String
    default_headers::Dict{String,String}
end

function Client(base_url::AbstractString; default_headers::AbstractDict = Dict{String,String}())
    return Client(String(rstrip(base_url, '/')), Dict{String,String}(default_headers))
end

function PB.rpc_call(
    c::Client,
    service::AbstractString,
    method::AbstractString,
    body::AbstractVector{UInt8},
)
    url = string(c.base_url, "/", service, "/", method)
    headers = vcat(
        [
            "Content-Type" => CONTENT_TYPE_PROTO,
            PROTOCOL_VERSION_HEADER => PROTOCOL_VERSION,
        ],
        [k => v for (k, v) in c.default_headers],
    )
    resp = HTTP.post(url, headers, Vector{UInt8}(body); status_exception = false)
    if resp.status == 200
        return resp.body
    end
    throw(_decode_error_response(resp))
end

# Connect error wire form for unary: HTTP non-200 + JSON body
# `{"code":"invalid_argument","message":"…","details":[…]}`.
function _decode_error_response(resp::HTTP.Response)
    code = _status_from_http(resp.status)
    msg = "$(resp.status)"
    try
        body = String(copy(resp.body))
        if !isempty(body)
            payload = JSON.parse(body)
            if payload isa AbstractDict
                if haskey(payload, "code")
                    code = _status_from_connect_code(String(payload["code"]))
                end
                if haskey(payload, "message")
                    msg = String(payload["message"])
                end
            end
        end
    catch
        # Fall back to the HTTP-status mapping if the body isn't JSON.
    end
    return PB.RpcError(code, msg)
end

# ---------------------------------------------------------------------------
# Server.
# ---------------------------------------------------------------------------

"""
    Server() :: Server
    serve!(server, impl, methods::Tuple)
    listen(server; host, port)

In-process route table backing an HTTP listener. `serve!` walks the
tuple of RPC functions emitted by codegen (e.g. `Greeter = (SayHello,
SayHelloStream)`) and binds each to an impl object — the same impl
the user attached server-side methods to. `listen` opens an
`HTTP.serve` loop, sniffs the Content-Type, and dispatches.
"""
struct Server <: PB.AbstractRpcTransport
    routes::Dict{Tuple{String,String},Tuple{Function,Any}}
end
Server() = Server(Dict{Tuple{String,String},Tuple{Function,Any}}())

function serve!(s::Server, impl, methods::Tuple)
    for f in methods
        s.routes[(PB.service_fqn(f), PB.method_name(f))] = (f, impl)
    end
    return s
end

"""
    listen(server; host="0.0.0.0", port=8080) -> HTTP.Server

Start an HTTP listener routing requests through `server`'s route
table. Returns the HTTP.Server handle so callers can `close(srv)`
when done.
"""
function listen(s::Server; host = "0.0.0.0", port::Integer = 8080)
    return HTTP.serve!(_handler(s), host, port)
end

function _handler(s::Server)
    return function (req::HTTP.Request)
        target = req.target
        # Strip query string if any.
        qidx = findfirst('?', target)
        path = qidx === nothing ? target : target[1:qidx-1]
        parts = split(strip(path, '/'), '/')
        length(parts) == 2 || return HTTP.Response(404, "expected /<service>/<method>")
        route = get(s.routes, (String(parts[1]), String(parts[2])), nothing)
        route === nothing && return HTTP.Response(
            404,
            string("no route for ", parts[1], "/", parts[2]),
        )
        f, impl = route
        try
            mode = PB.rpc_mode(f)
            mode === :unary ||
                throw(PB.RpcError(PB.StatusCode.UNIMPLEMENTED, "$(mode) not supported"))
            req_val = PB.decode(req.body, PB.request_type(f))
            resp_val = f(impl, req_val)
            return HTTP.Response(
                200,
                ["Content-Type" => CONTENT_TYPE_PROTO],
                PB.encode(resp_val),
            )
        catch e
            if e isa PB.RpcError
                return _error_response(e)
            else
                # Wrap unexpected errors as INTERNAL so the client sees a
                # well-shaped Connect error envelope instead of a raw
                # 500 with a stringified exception.
                io = IOBuffer()
                showerror(io, e)
                return _error_response(PB.RpcError(PB.StatusCode.INTERNAL, String(take!(io))))
            end
        end
    end
end

function _error_response(e::PB.RpcError)
    body = JSON.json(Dict("code" => _connect_code_string(e.code), "message" => e.message))
    return HTTP.Response(
        _http_status_for(e.code),
        ["Content-Type" => "application/json"],
        body,
    )
end

# ---------------------------------------------------------------------------
# Status-code ↔ Connect-code-string ↔ HTTP-status tables.
# Per https://connectrpc.com/docs/protocol#error-codes.
# ---------------------------------------------------------------------------

function _connect_code_string(c::PB.StatusCode.T)
    return _CONNECT_CODE_NAMES[c]
end

function _status_from_connect_code(s::AbstractString)
    return get(_CONNECT_CODE_LOOKUP, lowercase(strip(String(s))), PB.StatusCode.UNKNOWN)
end

const _CONNECT_CODE_NAMES = Dict{PB.StatusCode.T,String}(
    PB.StatusCode.OK => "ok",
    PB.StatusCode.CANCELLED => "canceled",
    PB.StatusCode.UNKNOWN => "unknown",
    PB.StatusCode.INVALID_ARGUMENT => "invalid_argument",
    PB.StatusCode.DEADLINE_EXCEEDED => "deadline_exceeded",
    PB.StatusCode.NOT_FOUND => "not_found",
    PB.StatusCode.ALREADY_EXISTS => "already_exists",
    PB.StatusCode.PERMISSION_DENIED => "permission_denied",
    PB.StatusCode.RESOURCE_EXHAUSTED => "resource_exhausted",
    PB.StatusCode.FAILED_PRECONDITION => "failed_precondition",
    PB.StatusCode.ABORTED => "aborted",
    PB.StatusCode.OUT_OF_RANGE => "out_of_range",
    PB.StatusCode.UNIMPLEMENTED => "unimplemented",
    PB.StatusCode.INTERNAL => "internal",
    PB.StatusCode.UNAVAILABLE => "unavailable",
    PB.StatusCode.DATA_LOSS => "data_loss",
    PB.StatusCode.UNAUTHENTICATED => "unauthenticated",
)

const _CONNECT_CODE_LOOKUP = Dict{String,PB.StatusCode.T}(
    name => code for (code, name) in _CONNECT_CODE_NAMES
)

function _http_status_for(c::PB.StatusCode.T)
    if c === PB.StatusCode.INVALID_ARGUMENT
        return 400
    elseif c === PB.StatusCode.OUT_OF_RANGE
        return 400
    elseif c === PB.StatusCode.FAILED_PRECONDITION
        return 412
    elseif c === PB.StatusCode.UNAUTHENTICATED
        return 401
    elseif c === PB.StatusCode.PERMISSION_DENIED
        return 403
    elseif c === PB.StatusCode.NOT_FOUND
        return 404
    elseif c === PB.StatusCode.ALREADY_EXISTS
        return 409
    elseif c === PB.StatusCode.ABORTED
        return 409
    elseif c === PB.StatusCode.RESOURCE_EXHAUSTED
        return 429
    elseif c === PB.StatusCode.CANCELLED
        return 408
    elseif c === PB.StatusCode.DEADLINE_EXCEEDED
        return 504
    elseif c === PB.StatusCode.UNIMPLEMENTED
        return 501
    elseif c === PB.StatusCode.UNAVAILABLE
        return 503
    elseif c === PB.StatusCode.INTERNAL || c === PB.StatusCode.DATA_LOSS ||
           c === PB.StatusCode.UNKNOWN
        return 500
    else
        return 500
    end
end

# Inverse — used when the body lacks a code field and we fall back to the HTTP status.
function _status_from_http(status::Integer)
    if status == 400
        return PB.StatusCode.INVALID_ARGUMENT
    elseif status == 401
        return PB.StatusCode.UNAUTHENTICATED
    elseif status == 403
        return PB.StatusCode.PERMISSION_DENIED
    elseif status == 404
        return PB.StatusCode.NOT_FOUND
    elseif status == 408
        return PB.StatusCode.CANCELLED
    elseif status == 409
        return PB.StatusCode.ALREADY_EXISTS
    elseif status == 412
        return PB.StatusCode.FAILED_PRECONDITION
    elseif status == 429
        return PB.StatusCode.RESOURCE_EXHAUSTED
    elseif status == 501
        return PB.StatusCode.UNIMPLEMENTED
    elseif status == 503
        return PB.StatusCode.UNAVAILABLE
    elseif status == 504
        return PB.StatusCode.DEADLINE_EXCEEDED
    elseif 500 <= status < 600
        return PB.StatusCode.INTERNAL
    else
        return PB.StatusCode.UNKNOWN
    end
end

end # module ProtoConnect
