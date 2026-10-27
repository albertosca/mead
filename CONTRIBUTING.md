# Contributing

Thanks for looking at `mead`. Open an issue before a large change so we can agree on the direction first.

## Setup

You need Elixir 1.20+ on Erlang/OTP 29.

```
mix deps.get
mix test
```

## Before you open a pull request

All three must pass, and CI runs them again:

```
mix test
mix format --check-formatted
mix compile --warnings-as-errors
```

* Every change comes with a test that fails without it.
* The coverage gate in `mix.exs` is a floor, not a target: cover real paths, and do not add tests for things that cannot happen.
* Code, comments, docs and commit messages are in English. Identifiers are full words: `index`, not `i`; `error`, not `err`.
* Paragraphs in markdown are one line each, with no hard wrapping.
* The architecture is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); update it when behavior changes.

## Security

Never open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).
