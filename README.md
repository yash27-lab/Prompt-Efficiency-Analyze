# Claude Token Efficiency Evaluator 🚀

A small Julia tool that uses Anthropic's Claude API to analyze a natural language
prompt for **token efficiency**: it counts the prompt's exact token usage, has
Claude flag redundant phrasing and propose a tighter rewrite, and reports the
token and cost savings.

---

## 🎯 How It Works

Given a prompt, the tool:

- Counts the prompt's exact tokens via the Anthropic `count_tokens` endpoint.
- Asks Claude to identify redundant / filler phrasing and rewrite the prompt more
  concisely while preserving intent and constraints (returned as structured JSON).
- Counts the tokens of the improved prompt.
- Estimates the token and input-cost savings and prints a formatted report.

---

## ⚙️ Setup

Requires [Julia](https://julialang.org/) 1.6+.

1. Clone the repository:

   ```bash
   git clone https://github.com/yash27-lab/Prompt-Efficiency-Analyze.git
   cd Prompt-Efficiency-Analyze
   ```

2. Install the dependencies:

   ```bash
   julia --project=. -e 'using Pkg; Pkg.instantiate()'
   ```

3. Provide your Anthropic API key. Either export it:

   ```bash
   export ANTHROPIC_API_KEY="sk-ant-..."
   ```

   or copy `secrets.jl.example` to `secrets.jl` (git-ignored) and fill in your key:

   ```bash
   cp secrets.jl.example secrets.jl
   # then edit secrets.jl
   ```

---

## ▶️ Usage

Pass the prompt as an argument:

```bash
julia --project=. main.jl "I was just wondering if you could maybe help me out by writing a short summary of the following article for me, please?"
```

or pipe it in on stdin:

```bash
echo "Please kindly go ahead and translate this text into French for me." | julia --project=. main.jl
```

### Example output

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

---

## 🧩 Using it as a library

The functions in `main.jl` can be called directly:

```julia
include("main.jl")

result = run_token_efficiency_tool("Your prompt here")          # prints a report, returns a Dict
result = run_token_efficiency_tool("Your prompt"; model = "claude-sonnet-5")
```

---

## 🧪 Tests

Offline unit tests (no API calls) cover the cost math and schema:

```bash
julia --project=. test/runtests.jl
```

---

## 🔐 Notes

- Your API key is never committed — `secrets.jl` is listed in `.gitignore`.
- Token counts are model-specific; the same text tokenizes differently per model.
- Cost estimates use published per-million input-token prices and cover the input
  side only (the analysis call itself also incurs a small one-time cost).
