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

@testset "input_rate" begin
    @test input_rate("claude-opus-4-8") == 5.0
    @test input_rate("claude-haiku-4-5") == 1.0
    @test input_rate("unknown-model") == input_rate(DEFAULT_MODEL)   # fallback
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

@testset "parse_cli" begin
    # Bare prompt, defaults everywhere.
    o = parse_cli(["hello", "world"])
    @test o.prompt == "hello world"
    @test o.model == DEFAULT_MODEL
    @test o.compare == false
    @test o.json == false
    @test o.help == false

    # Model flag, both spellings.
    @test parse_cli(["-m", "claude-haiku-4-5", "hi"]).model == "claude-haiku-4-5"
    @test parse_cli(["--model", "claude-sonnet-5", "hi"]).model == "claude-sonnet-5"
    @test parse_cli(["--model=claude-sonnet-5", "hi"]).model == "claude-sonnet-5"

    # --compare with no list uses all known models.
    c = parse_cli(["--compare", "p"])
    @test c.compare == true
    @test Set(c.models) == Set(keys(PRICING))

    # --models implies --compare and restricts the set (both spellings).
    m = parse_cli(["--models", "a,b", "p"])
    @test m.compare == true
    @test m.models == ["a", "b"]
    @test parse_cli(["--models=a, b ,c", "p"]).models == ["a", "b", "c"]   # trimmed

    # Flags.
    @test parse_cli(["--json", "p"]).json == true
    @test parse_cli(["-h"]).help == true
    @test parse_cli(["--help"]).help == true

    # Errors.
    @test_throws ErrorException parse_cli(["--nope"])
    @test_throws ErrorException parse_cli(["--model"])       # missing value
    @test_throws ErrorException parse_cli(["--models"])      # missing value
end

# Opt-in live tests. Enable with:  RUN_LIVE_TESTS=1 ANTHROPIC_API_KEY=... julia --project=. test/runtests.jl
if get(ENV, "RUN_LIVE_TESTS", "") == "1"
    @testset "live API" begin
        key = resolve_api_key()

        @test count_tokens("hello world"; api_key = key) > 0

        r = evaluate_prompt(
            "Please kindly go ahead and summarize this for me, thank you so much!";
            api_key = key,
        )
        @test r["original_tokens"] > 0
        @test r["improved_tokens"] > 0
        @test !isempty(r["improved_prompt"])
        @test haskey(r, "redundant_phrases")

        rows = compare_models(
            "A prompt to price across a couple of models.";
            models = ["claude-opus-4-8", "claude-haiku-4-5"],
            api_key = key,
        )
        @test length(rows) == 2
        @test all(row -> row.tokens > 0, rows)
        @test issorted(rows; by = row -> row.cost_per_1k)   # cheapest first
    end
else
    @info "Skipping live API tests. Set RUN_LIVE_TESTS=1 and ANTHROPIC_API_KEY to run them."
end
