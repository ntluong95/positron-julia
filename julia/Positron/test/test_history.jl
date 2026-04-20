using Test
using Positron

@testset "History parsing and selection" begin
    @testset "read_repl_history_entries parses Julia history entries" begin
        mktemp() do path, io
            write(
                io,
                """
                # time: 2026-04-20 00:00:00 UTC
                # mode: julia
                \tx = 1

                # time: 2026-04-20 00:01:00 UTC
                # mode: shell
                \tls

                # time: 2026-04-20 00:02:00 UTC
                # mode: julia
                \tprintln("hello")
                \tprintln("world")
                """,
            )
            close(io)

            @test Positron.read_repl_history_entries(path) == [
                "x = 1",
                "println(\"hello\")\nprintln(\"world\")",
            ]
        end
    end

    @testset "select_command_history supports tail and range" begin
        indexed_entries = [(1, "a = 1"), (2, "b = 2"), (3, "c = 3")]

        tail_selection = Positron.select_command_history(
            indexed_entries,
            Dict("hist_access_type" => "tail", "n" => 2),
        )
        @test tail_selection == [(2, "b = 2"), (3, "c = 3")]

        range_selection = Positron.select_command_history(
            indexed_entries,
            Dict("hist_access_type" => "range", "start" => 2, "stop" => 3),
        )
        @test range_selection == [(2, "b = 2")]
    end
end
