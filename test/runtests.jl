module ProfileEndpointsTests

using ProfileEndpoints
using Serialization
using Test

import InteractiveUtils
import HTTP
import Profile
import PProf

const port = 13423
const server = ProfileEndpoints.serve_profiling_server(;port=port)
const url = "http://127.0.0.1:$port"

@testset "ProfileEndpoints.jl" begin

    @testset "CPU profiling" begin
        done = Threads.Atomic{Bool}(false)
        # Schedule some work that's known to be expensive, to profile it
        workload() = @async begin
            for _ in 1:1000
                if done[] return end
                InteractiveUtils.peakflops()
                yield()  # yield to allow the tests to run
            end
        end

        @testset "profile endpoint" begin
            done[] = false
            t = workload()
            req = HTTP.get("$url/profile?duration=3&pprof=false")
            @test req.status == 200
            @test length(req.body) > 0

            data, lidict = deserialize(IOBuffer(req.body))
            # Test that the profile seems like valid profile data
            @test data isa Vector{UInt64}
            @test lidict isa Dict{UInt64, Vector{Base.StackTraces.StackFrame}}

            @info "Finished `profile` tests, waiting for peakflops workload to finish."
            done[] = true
            wait(t)  # handle errors
        end

        @testset "profile_start/stop endpoints" begin
            done[] = false
            t = workload()
            req = HTTP.get("$url/profile_start")
            @test req.status == 200
            @test String(req.body) == "CPU profiling started."

            sleep(3)  # Allow workload to run a while before we stop profiling.

            req = HTTP.get("$url/profile_stop?pprof=false")
            @test req.status == 200
            data, lidict = deserialize(IOBuffer(req.body))
            # Test that the profile seems like valid profile data
            @test data isa Vector{UInt64}
            @test lidict isa Dict{UInt64, Vector{Base.StackTraces.StackFrame}}

            @info "Finished `profile_start/stop` tests, waiting for peakflops workload to finish."
            done[] = true
            wait(t)  # handle errors

            # We retrive data via PProf directly if `pprof=true`; make sure that path's tested.
            # This second call to `profile_stop` should still return the profile, even though
            # the profiler is already stopped, as it's `profile_start` that calls `clear()`.
            req = HTTP.get("$url/profile_stop?pprof=true")
            @test req.status == 200
            # Test that there's something here
            # TODO: actually parse the profile
            data = read(IOBuffer(req.body), String)
            @test length(data) > 100
        end
    end

    @testset "Heap snapshot $query" for query in ("", "?all_one=true")
        req = HTTP.get("$url/heap_snapshot$query", retry=false, status_exception=false)
        if !isdefined(Profile, :take_heap_snapshot)
            # Assert the version is before https://github.com/JuliaLang/julia/pull/46862
            # Although we actually also need https://github.com/JuliaLang/julia/pull/47300
            @assert VERSION < v"1.9.0-DEV.1643"
            @test req.status == 501  # not implemented
        else
            @test req.status == 200
            data = read(IOBuffer(req.body), String)
            # Test that there's something here
            # TODO: actually parse the profile
            @test length(data) > 100
        end
    end

    @testset "Allocation profiling" begin
        done = Threads.Atomic{Bool}(false)
        # Schedule some work that's known to be expensive, to profile it
        workload() = @async begin
            for _ in 1:200
                if done[] return end
                global a = [[] for i in 1:1000]
                yield()  # yield to allow the tests to run
            end
        end

        @testset "allocs_profile endpoint" begin
            done[] = false
            t = workload()
            req = HTTP.get("$url/allocs_profile?duration=3", retry=false, status_exception=false)
            if !(isdefined(Profile, :Allocs) && isdefined(PProf, :Allocs))
                @assert VERSION < v"1.8.0-DEV.1346"
                @test req.status == 501  # not implemented
            else
                @test req.status == 200
                @test length(req.body) > 0

                data = read(IOBuffer(req.body), String)
                # Test that there's something here
                # TODO: actually parse the profile
                @test length(data) > 100
            end
            @info "Finished `allocs_profile` tests, waiting for workload to finish."
            done[] = true
            wait(t)  # handle errors
        end

        @testset "allocs_profile_start/stop endpoints" begin
            done[] = false
            t = workload()
            req = HTTP.get("$url/allocs_profile_start", retry=false, status_exception=false)
            if !(isdefined(Profile, :Allocs) && isdefined(PProf, :Allocs))
                @assert VERSION < v"1.8.0-DEV.1346"
                @test req.status == 501  # not implemented
            else
                @test req.status == 200
                @test String(req.body) == "Allocation profiling started."
            end

            sleep(3)  # Allow workload to run a while before we stop profiling.

            req = HTTP.get("$url/allocs_profile_stop", retry=false, status_exception=false)
            if !(isdefined(Profile, :Allocs) && isdefined(PProf, :Allocs))
                @assert VERSION < v"1.8.0-DEV.1346"
                @test req.status == 501  # not implemented
            else
                @test req.status == 200
                data = read(IOBuffer(req.body), String)
                # Test that there's something here
                # TODO: actually parse the profile
                @test length(data) > 100
            end
            @info "Finished `allocs_profile_stop` tests, waiting for workload to finish."
            done[] = true
            wait(t)  # handle errors
        end
    end

    @testset "Type inference profiling" begin
        if !isdefined(Core.Compiler.Timings, :clear_and_fetch_timings)
            @test HTTP.get("$url/typeinf_profile_start", retry=false, status_exception=false).status == 501
            @test HTTP.get("$url/typeinf_profile_stop", retry=false, status_exception=false).status == 501
        else
            @testset "typeinf start/stop endpoints" begin
                resp = HTTP.get("$url/typeinf_profile_start", retry=false, status_exception=false)
                @test resp.status == 200
                @test String(resp.body) == "Type inference profiling started."

                # workload
                @eval foo() = 2
                @eval foo()

                resp = HTTP.get("$url/typeinf_profile_stop", retry=false, status_exception=false)
                @test resp.status == 200
                data = read(IOBuffer(resp.body), String)
                # Test that there's something here
                # TODO: actually parse the profile
                @test length(data) > 100
            end
        end
    end

    @testset "error handling" begin
        let res = HTTP.get("$url/profile", status_exception=false)
            @test 400 <= res.status < 500
            @test res.status != 404
            # Make sure we describe how to use the endpoint
            body = String(res.body)
            @test occursin("duration", body)
            @test occursin("delay", body)
        end

        if (isdefined(Profile, :Allocs) && isdefined(PProf, :Allocs))
            let res = HTTP.get("$url/allocs_profile", status_exception=false)
                @test 400 <= res.status < 500
                @test res.status != 404
                # Make sure we describe how to use the endpoint
                body = String(res.body)
                @test occursin("duration", body)
                @test occursin("sample_rate", body)
            end
        end
    end
end

close(server)

end # module ProfileEndpointsTests
