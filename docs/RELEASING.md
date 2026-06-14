# Releasing the Elixir server

The Elixir server ships as the `terminalwire` package on [Hex](https://hex.pm).
Releases are manual and cut from `main`. Version it independently of the Go client
and Ruby server — they share the *protocol*, not a version number (see the
workspace `RELEASING.md` in `terminalwire/protocol` for the cross-repo picture).

## Pre-flight

Run from the workspace (`terminalwire/protocol`) so you test against the corpus:

```sh
make elixir ELIXIR_REPO=~/path/to/elixir   # corpus + mix test --cover, 85% floor
```

Green there means the wire behavior is conformant, not just that units pass.

## Cut a release

1. Bump `@version` in `mix.exs`.
2. Move the `## [Unreleased]` notes in `CHANGELOG.md` under a new `## [x.y.z]`
   heading and update the compare links at the bottom.
3. Commit: `git commit -am "Release vX.Y.Z"`.
4. Tag and push: `git tag vX.Y.Z && git push origin main --tags`.
5. Publish to Hex (needs `mix hex.user auth` once on the machine):

   ```sh
   mix deps.get
   mix hex.publish        # review the file list (lib/ mix.exs README CHANGELOG LICENSE), confirm
   ```

`mix hex.publish` shows exactly which files ship (the `:files` list in `mix.exs`)
and the docs it will build — review before confirming.

## What ships

Set in `mix.exs` `package/0`: `lib/`, `mix.exs`, `README.md`, `CHANGELOG.md`,
`LICENSE` — Apache-2.0, maintainer Brad Gessler. Docs build from the README via
`ex_doc` and publish to hexdocs.pm with the package.
