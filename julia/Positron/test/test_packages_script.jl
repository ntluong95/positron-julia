# Tests for scripts/packages/packages.jl helpers
using Test

include(joinpath(@__DIR__, "..", "..", "..", "scripts", "packages", "packages.jl"))

@testset "Packages Script Tests" begin
    @testset "metadata normalization helpers" begin
        @test _positron_normalize_package_description("  hello\n   world  ") == "hello world"
        @test _positron_normalize_package_description(nothing) == ""

        @test _positron_normalize_package_author("  Jane Doe <jane@example.com>  ") == "Jane Doe"
        @test _positron_normalize_package_author(nothing) == ""
    end

    @testset "project metadata extraction" begin
        pkg_source = mktempdir()
        write(
            joinpath(pkg_source, "Project.toml"),
            """
            name = "PkgMetadataFixture"
            uuid = "00000000-0000-0000-0000-000000000000"
            version = "0.1.0"
            description = "An\\n example  package"
            authors = ["  Jane Doe <jane@example.com>  "]
            """
        )

        metadata = _positron_package_metadata_from_source(pkg_source)
        @test metadata.description == "An example package"
        @test metadata.author == "Jane Doe"
        @test _positron_package_metadata_from_source(joinpath(pkg_source, "missing")) == (description = "", author = "")
    end
end
