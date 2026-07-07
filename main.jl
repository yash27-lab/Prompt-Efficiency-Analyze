# Claude Token Efficiency Evaluator
#
# Analyzes a natural language prompt with the Claude API: counts its exact token
# usage, has Claude flag redundant phrasing and propose a tighter rewrite, then
# reports the token and cost savings.
#
# Usage:
#   export ANTHROPIC_API_KEY="sk-ant-..."      # or create secrets.jl (see secrets.jl.example)
#   julia main.jl "Your prompt here"
#   echo "Your prompt here" | julia main.jl

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

"""
    estimate_savings(original_tokens, improved_tokens; model=DEFAULT_MODEL)

Return `(saved_tokens, percent_saved, saved_per_1k)` for a prompt trimmed from
`original_tokens` to `improved_tokens`. `saved_per_1k` is the input-cost saving,
in USD, over 1,000 identical calls at the model's input rate.
"""
function estimate_savings(original_tokens::Integer, improved_tokens::Integer; model = DEFAULT_MODEL)
    saved_tokens = original_tokens - improved_tokens
    rate = get(PRICING, model, PRICING[DEFAULT_MODEL]).input   # USD per 1M input tokens
    saved_per_1k = saved_tokens / 1_000_000 * rate * 1_000
    pct = original_tokens == 0 ? 0.0 : saved_tokens / original_tokens * 100
    return (saved_tokens, pct, saved_per_1k)
end

"""
    run_token_efficiency_tool(prompt; model=DEFAULT_MODEL) -> Dict

Run the full evaluation for `prompt` and print a formatted report. Returns the
analysis augmented with token counts and estimated cost savings.
"""
function run_token_efficiency_tool(prompt::AbstractString; model = DEFAULT_MODEL)
    api_key = resolve_api_key()

    original_tokens = count_tokens(prompt; model = model, api_key = api_key)
    analysis        = analyze_prompt_with_claude(prompt; model = model, api_key = api_key)
    improved        = analysis["improved_prompt"]
    improved_tokens = count_tokens(improved; model = model, api_key = api_key)

    saved_tokens, pct, saved_per_1k = estimate_savings(original_tokens, improved_tokens; model = model)
    rate = get(PRICING, model, PRICING[DEFAULT_MODEL]).input

    println("\n=== Claude Token Efficiency Evaluator ===")
    println("Model: $model")
    println("\nOriginal prompt   : $original_tokens tokens")
    println("Improved prompt   : $improved_tokens tokens")
    println("Tokens saved      : $saved_tokens ($(round(pct; digits = 1))%)")
    println("Est. saving / 1k calls: \$$(round(saved_per_1k; digits = 4)) " *
            "(input @ \$$(rate)/1M tokens)")

    println("\nRedundant phrases:")
    if isempty(analysis["redundant_phrases"])
        println("  (none found)")
    else
        for phrase in analysis["redundant_phrases"]
            println("  - $phrase")
        end
    end

    println("\nWhy: ", analysis["explanation"])
    println("\nImproved prompt:\n$improved\n")

    return merge(analysis, Dict(
        "original_tokens"  => original_tokens,
        "improved_tokens"  => improved_tokens,
        "tokens_saved"     => saved_tokens,
        "percent_saved"    => pct,
    ))
end

# CLI entry point: prompt comes from the arguments, or from stdin if none given.
if abspath(PROGRAM_FILE) == @__FILE__
    prompt = isempty(ARGS) ? read(stdin, String) : join(ARGS, " ")
    prompt = strip(prompt)
    if isempty(prompt)
        println(stderr, "Usage: julia main.jl \"Your prompt here\"")
        exit(1)
    end
    try
        run_token_efficiency_tool(String(prompt))
    catch err
        println(stderr, "Error: ", err isa ErrorException ? err.msg : sprint(showerror, err))
        exit(1)
    end
end
