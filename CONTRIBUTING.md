# Contributing

Thanks for looking at `mead`. Open an issue before a large change so we can agree on the direction first.

## Setup

You need Elixir 1.20+ on Erlang/OTP 29.

```
git clone https://github.com/albertosca/mead.git
cd mead
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

## Releasing

Releases are cut by tags, and the `Release` workflow does the rest.

1. Raise `version` in `mix.exs`. If the minor version changes, update the `{:mead, "~> 0.x"}` snippet in the READMEs and quickstart guides; a test fails until they agree.
2. Merge to `main` with CI green.
3. Tag that commit and push the tag:

   ```
   git tag v0.2.0
   git push origin v0.2.0
   ```

The workflow refuses a tag that does not equal the `mix.exs` version or is not on `main`, runs the tests, publishes the package and its docs to Hex, and creates the GitHub release with generated notes. A tag with a suffix such as `v0.2.0-rc.1` is published as a pre-release. It needs the `HEX_API_KEY` repository secret, a Hex API key with write permission.

## Security

Never open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).
