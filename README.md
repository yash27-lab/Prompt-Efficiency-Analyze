# Claude Token Efficiency Evaluator

A Julia command-line tool that uses Anthropic's Claude API to analyze a natural
language prompt for token efficiency. It counts the prompt's exact token usage,
has the model flag redundant phrasing and propose a more concise rewrite, and
reports the resulting token and cost savings. It can also compare a prompt's
token cost across models.

## Overview

Given a prompt, the tool:

- Counts the prompt's exact tokens via the Anthropic `count_tokens` endpoint.
- Asks the model to identify redundant or filler phrasing and rewrite the prompt
  more concisely while preserving its intent and constraints. The response is
  returned as structured JSON.
- Counts the tokens of the improved prompt.
- Estimates the token and input-cost savings and prints a formatted report.

In comparison mode (`--compare`), it counts the prompt across several models and
prints a cost table, making it easy to identify the most economical model for a
given input.

## Requirements

- [Julia](https://julialang.org/) 1.6 or later
- An Anthropic API key

## Setup

1. Clone the repository:

   ```bash
   git clone https://github.com/yash27-lab/Prompt-Efficiency-Analyze.git
   cd Prompt-Efficiency-Analyze
   ```

2. Install the dependencies:

   ```bash
   julia --project=. -e 'using Pkg; Pkg.instantiate()'
   ```

3. Provide your Anthropic API key. Either export it as an environment variable:

   ```bash
   export ANTHROPIC_API_KEY="sk-ant-..."
   ```

   or copy `secrets.jl.example` to `secrets.jl` (which is git-ignored) and set the
   key there:

   ```bash
   cp secrets.jl.example secrets.jl
   # then edit secrets.jl
   ```

## Usage

```
julia main.jl [options] "Your prompt here"
echo "Your prompt here" | julia main.jl [options]
```

| Option | Description |
| --- | --- |
| `-m`, `--model MODEL` | Model for the analysis (default: `claude-opus-4-8`) |
| `--compare` | Compare token count and input cost across models |
| `--models A,B,C` | Restrict `--compare` to these models (implies `--compare`) |
| `--json` | Print the raw JSON result instead of a formatted report |
| `-h`, `--help` | Show help and exit |

If no prompt is given on the command line, it is read from standard input.

### Analyze a prompt

```bash
julia --project=. main.jl "I was just wondering if you could maybe help me out by writing a short summary of the following article for me, please?"
```

```
=== Claude Token Efficiency Evaluator ===
Model: claude-opus-4-8

Original prompt   : 29 tokens
Improved prompt   : 11 tokens
Tokens saved      : 18 (62.1%)
Est. saving / 1k calls: $0.09 (input @ $5.0/1M tokens)

Redundant phrases:
  - I was just wondering if you could maybe
  - help me out by
  - for me, please

Why: The politeness padding and hedging ("just wondering", "maybe", "for me,
please") add tokens without changing the instruction.

Improved prompt:
Summarize the following article.
```

### Select a model

```bash
julia --project=. main.jl -m claude-haiku-4-5 "Translate to French: hello"
```

### Compare cost across models

```bash
julia --project=. main.jl --compare "A moderately long prompt to price across models."
```

```
=== Token / input-cost comparison ===
Model                 Tokens        $/call    $/1k calls
--------------------------------------------------------
claude-haiku-4-5          11      1.1e-5         0.011   <- cheapest
claude-sonnet-5           11      3.3e-5         0.033
claude-opus-4-8           11      5.5e-5         0.055
```

### Machine-readable output

Add `--json` to any command to print the raw result as JSON, suitable for piping
into other tools:

```bash
julia --project=. main.jl --json "Summarize this." | jq .improved_prompt
```

## Library API

The functions in `main.jl` can be called directly:

```julia
include("main.jl")

# Full evaluation (prints a report, returns a Dict):
run_token_efficiency_tool("Your prompt here")
run_token_efficiency_tool("Your prompt"; model = "claude-sonnet-5")

# Data only, no printing (resolves the key from the environment):
result = evaluate_prompt("Your prompt here")
print_report(result)

# Compare token cost across models:
rows = compare_models("Your prompt here")
print_comparison(rows)
```

## Tests

Offline unit tests (no API calls) cover the cost math, the command-line parser,
and the schema:

```bash
julia --project=. test/runtests.jl
```

Opt-in live tests call the API directly. Enable them with an environment variable
and a valid key:

```bash
RUN_LIVE_TESTS=1 ANTHROPIC_API_KEY="sk-ant-..." julia --project=. test/runtests.jl
```

## Notes

- The API key is never committed. `secrets.jl` is listed in `.gitignore`.
- Token counts are model-specific; the same text tokenizes differently on
  different models.
- Cost estimates use published per-million input-token prices and cover the input
  side only. The analysis request itself also incurs a small, one-time cost.
