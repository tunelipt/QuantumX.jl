# Hardware tests – run only when ENV["QUANTUMX_TEST_IP"] is set (included by runtests.jl).
#   QUANTUMX_TEST_IP        IP address of a QuantumX module
#   QUANTUMX_TEST_PORT      TCP port (default 5001)
#   QUANTUMX_TEST_CONNECTOR connector with an analog input to read (default 1)

@testset "hardware" begin
    ip = ENV["QUANTUMX_TEST_IP"]
    port = parse(Int, get(ENV, "QUANTUMX_TEST_PORT", "5001"))
    conn = parse(Int, get(ENV, "QUANTUMX_TEST_CONNECTOR", "1"))

    dev = connect(ip; port)
    @test dev.uuid != 0
    try
        xml = read_xml(dev, Q.PARVIEW_CONNECTORPARAM)
        @test startswith(xml, "<?xml")
        @test !isempty(signal_list(dev))
        @test measure(dev, conn) isa Float64
        @test measure_all(dev) isa Vector{Float64}
        @test module_status(dev) isa Vector{stModStatItem}
        @test error_status(dev) isa Vector{stErrStatItem}

        sub = subscribe(dev, [signal_path(conn)]; blocksize = 1024)
        try
            sleep(1)
            blocks = read_block(sub)
            @test length(blocks) == 1
            @test blocks[1].usersigid == 1
            @test length(blocks[1]) > 0

            request_block(sub)
            ablocks = nothing
            for _ in 1:50
                ablocks = wait_block(sub; timeout_ms = 200)
                ablocks === nothing || break
            end
            @test ablocks !== nothing
        finally
            unsubscribe(sub)
        end
    finally
        disconnect(dev)
    end
end
