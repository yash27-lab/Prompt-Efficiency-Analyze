# Claude Token Efficiency Evaluator
#
# Analyzes a natural language prompt with the Claude API: counts its exact token
# usage, has Claude flag redundant phrasing and propose a tighter rewrite, then
# reports the token and cost savings. Also compares token cost across models.
#
# Usage:
#   export ANTHROPIC_API_KEY="sk-ant-..."      # or create secrets.jl (see secrets.jl.example)
#   julia main.jl [options] "Your prompt here"
#   echo "Your prompt here" | julia main.jl [options]
#   julia main.jl --help

using HTTP, JSON

const MESSAGES_URL     = "https://api.anthropic.com/v1/messages"
const COUNT_TOKENS_URL = "https://api.anthropic.com/v1/messages/count_tokens"
const API_VERSION      = "2023-06-01"
const DEFAULT_MODEL    = "claude-opus-4-8"

# Published prices in USD per 1,000,000 tokens. Used to estimate the cost of a
# single input, so only the input rate is applied here.
const PRICING = Dict(
    "claude-opus-4-8"  => (input = 5.0,  output = 25.0),
    "claude-sonnet-5"  => (input = 3.0,  output = 15.0),
    "claude-haiku-4-5" => (input = 1.0,  output = 5.0),
)

# JSON schema that constrains Claude's analysis to a machine-parseable shape.
const ANALYSIS_SCHEMA = Dict(
    "type" => "object",
    "properties" => Dict(
        "redundant_phrases" => Dict(
            "type" => "array",
            "items" => Dict("type" => "string"),
        ),
        "improved_prompt" => Dict("type" => "string"),
        "explanation"     => Dict("type" => "string"),
    ),
    "required" => ["redundant_phrases", "improved_prompt", "explanation"],
    "additionalProperties" => false,
)

const SYSTEM_PROMPT = """
You are a prompt-efficiency analyst. Given a user's prompt, identify redundant or \
filler phrasing that spends tokens without adding meaning, then rewrite the prompt \
to be as concise as possible while preserving its original intent and every specific \
constraint. Do not drop meaningful detail, and do not answer the prompt itself.
"""

# ---------------------------------------------------------------------------
# API access
# ---------------------------------------------------------------------------

"""
    resolve_api_key() -> String

Return the Anthropic API key from `ANTHROPIC_API_KEY`. If that variable is unset
and a `secrets.jl` file exists next to this script, include it first (it is
expected to set `ENV["ANTHROPIC_API_KEY"]`).
"""
function resolve_api_key()
    secrets = joinpath(@__DIR__, "secrets.jl")
    if !haskey(ENV, "ANTHROPIC_API_KEY") && isfile(secrets)
        include(secrets)
    end
    key = get(ENV, "ANTHROPIC_API_KEY", "")
    isempty(key) && error(
        "ANTHROPIC_API_KEY is not set. Export it, or create secrets.jl " *
        "(see secrets.jl.example).",
    )
    return key
end

auth_headers(api_key) = [
    "x-api-key"         => api_key,
    "anthropic-version" => API_VERSION,
    "content-type"      => "application/json",
]

# POST a JSON body and return the parsed response, surfacing API errors with the
# status code and message rather than a bare exception.
function post_json(url, api_key, body)
    resp = HTTP.post(url, auth_headers(api_key), JSON.json(body); status_exception = false)
    parsed = JSON.parse(String(resp.body))
    if resp.status != 200
        msg = get(get(parsed, "error", Dict()), "message", "unknown error")
        error("Claude API returned $(resp.status): $msg")
    end
    return parsed
end

"""
    count_tokens(text; model, api_key) -> Int

Exact input-token count for `text` on `model`, via the Anthropic token-counting
endpoint. This is model-specific — the same text tokenizes differently per model.
"""
function count_tokens(text::AbstractString; model = DEFAULT_MODEL, api_key)
    body = Dict(
        "model" => model,
        "messages" => [Dict("role" => "user", "content" => text)],
    )
    return post_json(COUNT_TOKENS_URL, api_key, body)["input_tokens"]
end

"""
    analyze_prompt_with_claude(prompt; model, api_key) -> Dict

Ask Claude to flag redundant phrasing and produce a tighter rewrite. Returns a
Dict with `redundant_phrases`, `improved_prompt`, and `explanation`.
"""
function analyze_prompt_with_claude(prompt::AbstractString; model = DEFAULT_MODEL, api_key)
    body = Dict(
        "model" => model,
        "max_tokens" => 2000,
        "system" => SYSTEM_PROMPT,
        "messages" => [Dict("role" => "user", "content" => "Analyze this prompt:\n\n" * prompt)],
        "output_config" => Dict(
            "format" => Dict("type" => "json_schema", "schema" => ANALYSIS_SCHEMA),
        ),
    )
    data = post_json(MESSAGES_URL, api_key, body)
    # With output_config.format the first text block is guaranteed valid JSON.
    text = first(b["text"] for b in data["content"] if b["type"] == "text")
    return JSON.parse(text)
end

# ---------------------------------------------------------------------------
# Analysis + reporting
# ---------------------------------------------------------------------------

"""
    input_rate(model) -> Float64

USD per 1,000,000 input tokens for `model`, falling back to the default model's
rate for unknown models.
"""
input_rate(model) = get(PRICING, model, PRICING[DEFAULT_MODEL]).input

"""
    estimate_savings(original_tokens, improved_tokens; model=DEFAULT_MODEL)

Return `(saved_tokens, percent_saved, saved_per_1k)` for a prompt trimmed from
`original_tokens` to `improved_tokens`. `saved_per_1k` is the input-cost saving,
in USD, over 1,000 identical calls at the model's input rate.
"""
function estimate_savings(original_tokens::Integer, improved_tokens::Integer; model = DEFAULT_MODEL)
    saved_tokens = original_tokens - improved_tokens
    saved_per_1k = saved_tokens / 1_000_000 * input_rate(model) * 1_000
    pct = original_tokens == 0 ? 0.0 : saved_tokens / original_tokens * 100
    return (saved_tokens, pct, saved_per_1k)
end

"""
    evaluate_prompt(prompt; model=DEFAULT_MODEL, api_key=resolve_api_key()) -> Dict

Run the full evaluation for `prompt` and return the analysis augmented with token
counts and estimated cost savings. Does not print — use `print_report` for that.
"""
function evaluate_prompt(prompt::AbstractString; model = DEFAULT_MODEL, api_key = resolve_api_key())
    original_tokens = count_tokens(prompt; model = model, api_key = api_key)
    analysis        = analyze_prompt_with_claude(prompt; model = model, api_key = api_key)
    improved        = analysis["improved_prompt"]
    improved_tokens = count_tokens(improved; model = model, api_key = api_key)

    saved, pct, per_1k = estimate_savings(original_tokens, improved_tokens; model = model)
    return merge(analysis, Dict(
        "model"                   => model,
        "original_tokens"         => original_tokens,
        "improved_tokens"         => improved_tokens,
        "tokens_saved"            => saved,
        "percent_saved"           => pct,
        "saving_per_1k_calls_usd" => per_1k,
        "input_rate_per_1m_usd"   => input_rate(model),
    ))
end

"Print the formatted report for a result Dict returned by `evaluate_prompt`."
function print_report(r::AbstractDict)
    println("\n=== Claude Token Efficiency Evaluator ===")
    println("Model: ", r["model"])
    println("\nOriginal prompt   : ", r["original_tokens"], " tokens")
    println("Improved prompt   : ", r["improved_tokens"], " tokens")
    println("Tokens saved      : ", r["tokens_saved"], " (", round(r["percent_saved"]; digits = 1), "%)")
    println("Est. saving / 1k calls: \$", round(r["saving_per_1k_calls_usd"]; digits = 4),
            " (input @ \$", r["input_rate_per_1m_usd"], "/1M tokens)")

    println("\nRedundant phrases:")
    if isempty(r["redundant_phrases"])
        println("  (none found)")
    else
        for phrase in r["redundant_phrases"]
            println("  - ", phrase)
        end
    end

    println("\nWhy: ", r["explanation"])
    println("\nImproved prompt:\n", r["improved_prompt"], "\n")
    return nothing
end

"""
    run_token_efficiency_tool(prompt; model=DEFAULT_MODEL) -> Dict

Convenience wrapper: resolve the key, evaluate `prompt`, print the report, and
return the result Dict.
"""
function run_token_efficiency_tool(prompt::AbstractString; model = DEFAULT_MODEL)
    r = evaluate_prompt(prompt; model = model, api_key = resolve_api_key())
    print_report(r)
    return r
end

# ---------------------------------------------------------------------------
# Cross-model comparison
# ---------------------------------------------------------------------------

"""
    compare_models(prompt; models=sort(collect(keys(PRICING))), api_key=resolve_api_key())

Count `prompt`'s tokens on each model and return a vector of NamedTuples
`(model, tokens, cost_per_call, cost_per_1k, input_rate_per_1m)`, sorted cheapest
first. Useful for choosing the most cost-effective model for a given input.
"""
function compare_models(prompt::AbstractString;
                        models = sort(collect(keys(PRICING))),
                        api_key = resolve_api_key())
    rows = map(models) do m
        tokens = count_tokens(prompt; model = m, api_key = api_key)
        rate = input_rate(m)
        (model = m,
         tokens = tokens,
         cost_per_call = tokens / 1_000_000 * rate,
         cost_per_1k = tokens / 1_000_000 * rate * 1_000,
         input_rate_per_1m = rate)
    end
    return sort(collect(rows); by = r -> r.cost_per_1k)
end

"Print the comparison table for the rows returned by `compare_models`."
function print_comparison(rows)
    println("\n=== Token / input-cost comparison ===")
    println(rpad("Model", 20), lpad("Tokens", 8), lpad("\$/call", 14), lpad("\$/1k calls", 14))
    println("-"^56)
    for (i, r) in enumerate(rows)
        marker = i == 1 ? "   <- cheapest" : ""
        println(rpad(r.model, 20),
                lpad(string(r.tokens), 8),
                lpad(string(round(r.cost_per_call; digits = 6)), 14),
                lpad(string(round(r.cost_per_1k; digits = 4)), 14),
                marker)
    end
    println()
    return nothing
end

# ---------------------------------------------------------------------------
# Command-line interface
# ---------------------------------------------------------------------------

const HELP = """
Claude Token Efficiency Evaluator

Usage:
  julia main.jl [options] "Your prompt here"
  echo "Your prompt here" | julia main.jl [options]

Options:
  -m, --model MODEL     Model for the analysis (default: $DEFAULT_MODEL)
      --compare         Compare token count and input cost across models
      --models A,B,C    Restrict --compare to these models (implies --compare)
      --json            Print the raw JSON result instead of a formatted report
  -h, --help            Show this help and exit

If no prompt is given on the command line, it is read from standard input.

Examples:
  julia main.jl "Please kindly summarize this article for me, thanks!"
  julia main.jl -m claude-haiku-4-5 "Translate to French: hello"
  julia main.jl --compare "A moderately long prompt to price across models."
"""

print_help(io = stdout) = print(io, HELP)

"""
    parse_cli(args) -> NamedTuple

Parse command-line arguments into `(; model, compare, models, json, help, prompt)`.
Throws an `ErrorException` on an unknown option or a flag missing its value.
"""
function parse_cli(args)
    model = DEFAULT_MODEL
    compare = false
    models = String[]
    json = false
    help = false
    positional = String[]

    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("-h", "--help")
            help = true
        elseif a in ("-m", "--model")
            i += 1
            i <= length(args) || error("--model requires a value")
            model = args[i]
        elseif startswith(a, "--model=")
            model = split(a, "="; limit = 2)[2]
        elseif a == "--compare"
            compare = true
        elseif a == "--models"
            i += 1
            i <= length(args) || error("--models requires a comma-separated list")
            models = String.(strip.(split(args[i], ",")))
        elseif startswith(a, "--models=")
            models = String.(strip.(split(split(a, "="; limit = 2)[2], ",")))
        elseif a == "--json"
            json = true
        elseif a != "-" && startswith(a, "-")
            error("unknown option: $a")
        else
            push!(positional, a)
        end
        i += 1
    end

    isempty(models) || (compare = true)
    isempty(models) && (models = sort(collect(keys(PRICING))))
    return (; model, compare, models = String.(models), json, help, prompt = join(positional, " "))
end

# Entry point: only runs when this file is executed directly, not when included.
if abspath(PROGRAM_FILE) == @__FILE__
    local opts
    try
        opts = parse_cli(ARGS)
    catch err
        println(stderr, "Error: ", err isa ErrorException ? err.msg : sprint(showerror, err))
        println(stderr)
        print_help(stderr)
        exit(1)
    end

    if opts.help
        print_help()
        exit(0)
    end

    prompt = isempty(opts.prompt) ? strip(read(stdin, String)) : strip(opts.prompt)
    if isempty(prompt)
        print_help(stderr)
        exit(1)
    end

    try
        api_key = resolve_api_key()
        if opts.compare
            rows = compare_models(String(prompt); models = opts.models, api_key = api_key)
            opts.json ? println(JSON.json(rows)) : print_comparison(rows)
        else
            result = evaluate_prompt(String(prompt); model = opts.model, api_key = api_key)
            opts.json ? println(JSON.json(result)) : print_report(result)
        end
    catch err
        println(stderr, "Error: ", err isa ErrorException ? err.msg : sprint(showerror, err))
        exit(1)
    end
end
