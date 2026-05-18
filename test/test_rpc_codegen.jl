module TestRpcCodegen

include("setup.jl")

# Build a FileDescriptorProto in-process so the test doesn't depend on protoc
# (the conformance corpus already shows the protoc roundtrip; this targets
# the service-emission path specifically).
function build_greeter_descriptor()
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
    fld(name, number; type = G.var"FieldDescriptorProto.Type".STRING) =
        G.FieldDescriptorProto(;
            name = name,
            number = Int32(number),
            label = G.var"FieldDescriptorProto.Label".OPTIONAL,
            type = type,
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
                    G.MethodDescriptorProto(;
                        name = "SayHelloStream",
                        input_type = ".greeter.HelloRequest",
                        output_type = ".greeter.HelloReply",
                        client_streaming = false,
                        server_streaming = true,
                    ),
                ],
            ),
        ],
    )
end

@testset "codegen: service emission" begin
    proto = build_greeter_descriptor()
    src = ProtocGen.Codegen.codegen(proto)

    # Surface checks — verify the four pieces of generated service glue are
    # present without anchoring on whitespace.
    @test occursin("function SayHello end", src)
    @test occursin("function SayHelloStream end", src)
    @test occursin("function PB.MethodDescriptorProto(::typeof(SayHello))", src)
    @test occursin("PB.service_fqn(::typeof(SayHello)) = \"greeter.Greeter\"", src)
    @test occursin(
        "function SayHello(t::PB.AbstractRpcTransport, req::HelloRequest)::HelloReply",
        src,
    )
    @test occursin("const Greeter = (SayHello, SayHelloStream,)", src)
    # Streaming RPCs don't get a client stub yet — descriptor still present.
    @test occursin(
        "function PB.MethodDescriptorProto(::typeof(SayHelloStream))",
        src,
    )
    @test !occursin("function SayHelloStream(t::PB.AbstractRpcTransport", src)

    # Eval the module and exercise the trait surface.
    mod = eval_generated(src, :GeneratedGreeter)
    SayHello = mod.SayHello
    SayHelloStream = mod.SayHelloStream

    @test Base.invokelatest(ProtocGen.service_fqn, SayHello) == "greeter.Greeter"
    @test Base.invokelatest(ProtocGen.method_name, SayHello) == "SayHello"
    @test Base.invokelatest(ProtocGen.rpc_mode, SayHello) === :unary
    @test Base.invokelatest(ProtocGen.rpc_mode, SayHelloStream) === :server_stream
    @test Base.invokelatest(ProtocGen.request_type, SayHello) === mod.HelloRequest
    @test Base.invokelatest(ProtocGen.response_type, SayHello) === mod.HelloReply
    @test mod.Greeter === (SayHello, SayHelloStream)
end

@testset "codegen: in-memory transport roundtrip" begin
    # Reuse the descriptor + eval'd module, then plug a Dict-backed transport
    # into the codegen-emitted SayHello stub. Exercises rpc_invoke + dispatch
    # end-to-end without any HTTP.
    proto = build_greeter_descriptor()
    src = ProtocGen.Codegen.codegen(proto)
    mod = eval_generated(src, :GreeterRpc)
    SayHello = mod.SayHello

    struct_def = quote
        struct InMemTransport <: ProtocGen.AbstractRpcTransport
            routes::Dict{Tuple{String,String},Function}
        end
    end
    Core.eval(@__MODULE__, struct_def)
    InMem = @__MODULE__().InMemTransport
    @eval function ProtocGen.rpc_call(
        t::$(InMem),
        svc::AbstractString,
        method::AbstractString,
        body::AbstractVector{UInt8},
    )
        f = t.routes[(String(svc), String(method))]
        return f(body)
    end

    impl = function (body)
        req = ProtocGen.decode(body, mod.HelloRequest)
        reply = mod.HelloReply(message = "Hi $(req.name)")
        return ProtocGen.encode(reply)
    end
    t = InMem(Dict(("greeter.Greeter", "SayHello") => impl))

    reply = Base.invokelatest(SayHello, t, mod.HelloRequest(name = "Bob"))
    @test reply.message == "Hi Bob"
end

end # module TestRpcCodegen
