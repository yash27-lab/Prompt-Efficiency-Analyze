using Test

# Including main.jl defines the functions/constants without running the CLI block
# (that block only executes when main.jl is the program entry point).
include(joinpath(@__DIR__, "..", "main.jl"))

@testset "estimate_savings" begin
    # 100 -> 60 tokens on Opus 4.8 ($5 / 1M input tokens).
    saved, pct, per_1k = estimate_savings(100, 60; model = "claude-opus-4-8")
    @test saved == 40
    @test pct ≈ 40.0
    @test per_1k ≈ 40 / 1_000_000 * 5.0 * 1_000   # == 0.2

    # A different model uses a different input rate.
    _, _, per_1k_haiku = estimate_savings(100, 60; model = "claude-haiku-4-5")
    @test per_1k_haiku ≈ 40 / 1_000_000 * 1.0 * 1_000

    # An unknown model falls back to the default rate.
    _, _, per_1k_unknown = estimate_savings(100, 60; model = "does-not-exist")
    @test per_1k_unknown ≈ per_1k

    # No improvement means no saving; guard against divide-by-zero.
    @test estimate_savings(50, 50)[1] == 0
    @test estimate_savings(0, 0)[2] == 0.0
end

@testset "analysis schema" begin
    @test ANALYSIS_SCHEMA["additionalProperties"] == false
    @test Set(ANALYSIS_SCHEMA["required"]) ==
          Set(["redundant_phrases", "improved_prompt", "explanation"])
end

@testset "pricing table" begin
    @test PRICING[DEFAULT_MODEL].input == 5.0
    @test haskey(PRICING, "claude-sonnet-5")
end
