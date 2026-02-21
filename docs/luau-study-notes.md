# Luau study notes (initial pass)

## What Luau is
- Luau is a fast, small, safe, gradually typed embeddable scripting language derived from Lua
  5.1, with extra features such as type annotations and type inference. The runtime keeps most
  of the Lua 5.1 API but has some deviations (such as compiling separately and no `__gc`
  support).【F:luau-master/luau-master/README.md†L1-L59】

## Tooling
- `luau` is a REPL and file runner (sandboxed, with `require` access).
- `luau-analyze` is a type checker/linter; `.luaurc` or `--!` comments configure it.
- There is a community LSP built on `luau-analyze`.【F:luau-master/luau-master/README.md†L17-L34】

## Build and test overview
- CMake builds provide `Luau.Repl.CLI` and `Luau.Analyze.CLI` targets.
- Makefile builds can build binaries and run tests with `make test`.
- Tests include `Luau.UnitTest` (compiler/type checker) and `Luau.Conformance` (VM tests).【F:luau-master/luau-master/README.md†L55-L96】

## Dependencies and license
- Runtime requires C++11; compiler/analysis require C++17; no external deps besides STL/CRT.
- Test suite uses doctest; REPL uses isocline.
- Licensed under MIT, with attribution requested for integrations.【F:luau-master/luau-master/README.md†L98-L114】

## Contribution workflow highlights
- Questions go to GitHub Discussions; documentation lives in the separate `luau-lang/site`
  repository and is English-only today.
- Bugs should be filed as GitHub issues with repro details; feature work should start with an
  issue and, for language/semantic changes, an RFC in `luau-lang/rfcs`.
- Code style is guided by `.clang-format` and naming conventions (`lowerCamelCase`,
  `UpperCamelCase`, `kCamelCase`, `SCARY_CASE`), with VM-specific rules preferring `lua_`/`luaX_`
  prefixes and lowercase macros.
- Tests can be run with `make test` or the `Luau.UnitTest`/`Luau.Conformance` CMake targets.
- Performance and feature-flag guidance: run benchmarks for VM changes and use
  `LUAU_FASTFLAG` when gating large changes.【F:luau-master/luau-master/CONTRIBUTING.md†L1-L67】

## Security notes
- Luau provides a sandboxed VM and libraries; memory safety issues are treated as
  vulnerabilities, and unsigned bytecode is unsupported.
- No termination guarantees are provided; untrusted code may exhaust CPU/RAM.
- Security issues should be reported via Roblox's HackerOne program.【F:luau-master/luau-master/SECURITY.md†L1-L14】

## Next steps
- Read `CONTRIBUTING.md` and `SECURITY.md` for contribution workflow and policies.
- Inspect `tests/conformance` to understand runtime behavior expectations.
- Review `Compiler/`, `VM/`, and `Analysis/` to map the major subsystems.【F:luau-master/luau-master/README.md†L83-L104】
