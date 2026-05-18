using Test
using ProtocGen
using ProtoConnect
using HTTP
using Sockets

# Build greeter.proto's descriptor in-process — keeps the test hermetic
# (no dependency on `examples/out/greeter_pb.jl`, which is git-ignored).
function _greeter_file_descriptor()
    G = ProtocGen.google.protobuf
    msg(name, fields...) = G.DescriptorProto(;
        name = name,
        field = collect(fields),
        nested_type = G.DescriptorProto[],
        enum_type = G.EnumDescriptorProto[],
        extension_range = G.var"DescriptorProto.ExtensionRange"[],
        oneof_decl = G.OneofDescriptorProto[],
        reserved_range = G.var"DescriptorProto.ReservedRange"[],
        reserved_name = String[],
        extension = G.FieldDescriptorProto[],
    )
    fld(name, number) = G.FieldDescriptorProto(;
        name = name,
        number = Int32(number),
        label = G.var"FieldDescriptorProto.Label".OPTIONAL,
        type = G.var"FieldDescriptorProto.Type".STRING,
    )
    return G.FileDescriptorProto(;
        name = "greeter.proto",
        package = "greeter",
        syntax = "proto3",
        dependency = String[],
        public_dependency = Int32[],
        weak_dependency = Int32[],
        enum_type = G.EnumDescriptorProto[],
        extension = G.FieldDescriptorProto[],
        message_type = [
            msg("HelloRequest", fld("name", 1)),
            msg("HelloReply", fld("message", 1)),
        ],
        service = [
            G.ServiceDescriptorProto(;
                name = "Greeter",
                method = [
                    G.MethodDescriptorProto(;
                        name = "SayHello",
                        input_type = ".greeter.HelloRequest",
                        output_type = ".greeter.HelloReply",
                        client_streaming = false,
                        server_streaming = false,
                    ),
                ],
            ),
        ],
    )
end

# Generate + eval into a fresh anon module.
const proto = _greeter_file_descriptor()
const src = ProtocGen.Codegen.codegen(proto)
ProtocGen.unregister_message_type("greeter.HelloRequest")
ProtocGen.unregister_message_type("greeter.HelloReply")
const Greeter = Module()
Core.eval(Greeter, Meta.parseall(src))

const SayHello = Greeter.SayHello
const HelloRequest = Greeter.HelloRequest
const HelloReply = Greeter.HelloReply
const GreeterMethods = Greeter.Greeter

# User-side server impl.
struct EchoGreeter
    suffix::String
end
function (Greeter.SayHello)(impl::EchoGreeter, req::HelloRequest)
    if isempty(req.name)
        throw(ProtocGen.RpcError(ProtocGen.StatusCode.INVALID_ARGUMENT, "name is required"))
    end
    return HelloReply(message = "Hello, $(req.name)$(impl.suffix)")
end

# Listen on an ephemeral port and tear down at the end.
function with_running_server(f; impl = EchoGreeter("!"))
    srv = ProtoConnect.Server()
    ProtoConnect.serve!(srv, impl, GreeterMethods)
    http = ProtoConnect.listen(srv; host = "127.0.0.1", port = 0)
    try
        # `port = 0` asks the kernel for a free port; the actual port lives on
        # the underlying TCP server. `HTTP.Server` does not expose it directly.
        _, port = getsockname(http.listener.server)
        f("http://127.0.0.1:$(port)")
    finally
        close(http)
    end
end

@testset "ProtoConnect — unary roundtrip" begin
    with_running_server() do url
        client = ProtoConnect.Client(url)
        reply = Base.invokelatest(SayHello, client, HelloRequest(name = "Alice"))
        @test reply isa HelloReply
        @test reply.message == "Hello, Alice!"
    end
end

@testset "ProtoConnect — RpcError round-trip" begin
    with_running_server() do url
        client = ProtoConnect.Client(url)
        err = try
            Base.invokelatest(SayHello, client, HelloRequest(name = ""))
            nothing
        catch e
            e
        end
        @test err isa ProtocGen.RpcError
        @test err.code === ProtocGen.StatusCode.INVALID_ARGUMENT
        @test occursin("name is required", err.message)
    end
end

@testset "ProtoConnect — 404 on unknown method" begin
    with_running_server() do url
        client = ProtoConnect.Client(url)
        err = try
            ProtocGen.rpc_call(client, "greeter.Greeter", "DoesNotExist", UInt8[])
            nothing
        catch e
            e
        end
        @test err isa ProtocGen.RpcError
        @test err.code === ProtocGen.StatusCode.NOT_FOUND
    end
end
