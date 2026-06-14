# Changelog

All notable changes to the Terminalwire Elixir server are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/); this project
adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] — Unreleased

First public release: a complete Elixir server implementation of the Terminalwire
v2 protocol, validated against the same language-neutral conformance corpus as the
Go client and the Ruby server.

### Added
- **Sans-IO protocol core** — `Terminalwire.Protocol`, `Codec`, `Negotiator`,
  `Frames`, `Window` (MessagePack wire, capability negotiation, flow control).
- **Server runtime** — `Terminalwire.Server.Connection` (sans-IO state machine),
  `Server.Session` (the process that drives it), `Server.Context` (the CLI-facing
  API), `Server.IO` (a group-leader IO device so `IO.puts`/`Owl`/`IO.ANSI` stream
  to the client with no wiring), and the `Terminalwire.WebSock` adapter.
- **Full v2 feature set** — streaming stdio with flow control, live window resize,
  `Ctrl-C` → server-side interrupt (exit 130), stdin piping (`Context.read`/
  `read_chunk`), raw input / single-key for REPL/TUI, terminal query, and
  files / dirs / env / browser behind the client-enforced entitlement policy.
- **Build-your-CLI docs** — Context API reference plus three parsing styles
  (raw/`OptionParser`, Optimus, Owl) and the two output rules.
- **Runnable examples** — `examples/self_describing.exs` and `examples/owl_cli.exs`.
- **Coverage floor** — `mix test --cover` gates the build at 85%.

[Unreleased]: https://github.com/terminalwire/elixir/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/terminalwire/elixir/releases/tag/v0.1.0
