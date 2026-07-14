# Nushell: native scope-introspection autodoc

> Transient research working paper for issue `polyglot-reference-autodoc-tooling`
> (task `research-candidate-options`, Nushell leg — no dedicated subtask). Drafted 2026-07-12.
> Sources: empirical session work of 2026-07-10..12 (scope metadata probes on nu 0.114.0, a
> working generator proof-of-concept, the four-package doc audit), nushell.github.io's
> `make_docs.nu` precedent, awesome-nu survey, numd/dotnu docs.
> Constraint of record: builtins and std library first; nupm modules and third-party Nushell
> scripts acceptable; Nushell plugins (Rust) permitted; no implementations without first-class
> Nushell support.

## System overview

**Recommended approach — highlighted: a builtins-only generator driven by `scope commands`
introspection, enriched with authored `@example` attributes whose examples are *executed*
during generation** (doctest semantics: the embedded output is real, and a failing example
fails the docs build). No framework adoption, no foreign runtime; the interpreter itself is
the extraction engine.

Why this is the recommendation and not merely an option:

- **Everything the docs need is already structured metadata.** On nu 0.114.0, `scope commands`
  returns per command: the doc-comment description, the long-form `extra_description`, every
  parameter with type, default, per-parameter doc comment and custom completion, input/output
  signatures, `search_terms`, and `@example` attributes as `{description, example, result}`
  records. This was verified empirically this session, and a ~40-line proof-of-concept rendered
  publishable markdown (description, long docs, parameter tables) for `tasks`, `tasks del`,
  and `tasks sub` from that metadata alone.
- **Authoritative precedent.** The official Nushell website generates its entire command
  reference the same way (`make_docs.nu` over scope data). This is the ecosystem's blessed path,
  not an invention.
- **The one real gap is examples, and `@example` closes it with compounding returns.** The
  2026-07-12 audit found descriptions complete across all four packages (session, watch, tasks,
  test) and **zero `@example` attributes anywhere**. Authoring them once feeds three consumers:
  `help` output in the shell, the generated reference, and — executed at generation time — a
  regression net over documented behavior.

## Extraction model

Fully semantic, via the parser/interpreter:

- **Collector seam**: a child interpreter per package —
  `nu -I <nupm-modules-dir> -c "use <mod>; scope commands | where name in $exports | to nuon"`.
  The `-I`/child-process seam is already proven twice in this repository's orbit (the test
  framework's sandboxed runner and the doc audit).
- **Export discovery**: `scope modules` lists a module's exported command names (unprefixed);
  map to prefixed display names (`<mod> <name>`) before filtering `scope commands` — a
  session-verified footgun.
- **Depth fallback**: the `ast` builtin (and `nu --ide-ast`) exposes token/AST data natively if
  non-exported internals ever need documenting; no plugin required even for that.
- **Known boundaries** (design around, not against): introspection sees only what imports
  cleanly — a parse-broken module yields no docs, which is a *feature* as a CI signal; private
  helpers are invisible by design; `result` on an example is only populated when authored with
  `--result` or captured by executing the example.

## Output pipeline and site integration

- **Markdown emitter**: pure string interpolation + `to md` over the scope records (the PoC's
  shape): per command — description, extra description, parameter table (name, type, default,
  doc comment), input/output signatures, examples with captured results.
- **Executed examples**: run each `@example` in a sandboxed child (the test framework's
  `with-sandbox` seam exists for exactly this shape of isolation), embed the real output,
  diff against `--result` where authored, and fail generation on drift.
- **Intermediate representation**: also emit the raw records as a committed `.nuon` snapshot.
  This is a diffable API surface (reviewable in PRs) and precomputed context for LLM/MCP
  consumers — which is verbatim one of the issue's `xvalue` bindings.
- **Site fit**: output is plain markdown → drops straight into the ProperDocs tree with
  URL-stable pages (the same pattern as the hosted schema files). No SSG coupling, no plugin
  runtime. Placement seam already staked: `~/.local/share/nushell/modules/docgen/mod.nu`
  (stub created 2026-07-12) — the generator ships as a personal module first, promotable to a
  fifth registry package once stable.

## Language coverage matrix

| Language (inventory) | This approach | Covered instead by |
| --- | --- | --- |
| Python | n/a — out of scope for this candidate | mkdocstrings (`mkdocstrings-handlers.md`) |
| TypeScript | n/a | mkdocstrings / TypeDoc route |
| JavaScript | n/a | TypeDoc-with-JSDoc route |
| Rust | n/a (a custom mkdocstrings handler or rustdoc-JSON glue) | mkdocstrings report, Rust sketch |
| **Nushell** | **fully covered, natively** | — |
| POSIX shell | n/a | shellman handler or fir dialect |

This candidate deliberately solves one leg *completely* rather than all legs shallowly; it can
also be repackaged as the collector inside a `mkdocstrings_handlers/nushell/` handler if the
ADR lands on the mkdocstrings scenario — the two candidates compose rather than compete.

## Per-language implementation requirements

### Python / TypeScript / JavaScript / Rust / POSIX shell

Not addressed by this approach; see the matrix above and the sibling reports. (Headings kept
for layout parity across the three working papers.)

### Nushell

Implementation sketch for the recommended generator, staged:

1. **`docgen collect`** (builtins only): for each target package (default: the four registry
   packages), spawn the child-interpreter collector, normalize records
   (exports mapping, signature flattening), return a table; `--nuon` flag persists the IR
   snapshot.
2. **`docgen render`**: records → one markdown page per module (or per command for large
   surfaces), written into the ProperDocs tree; deterministic ordering so diffs stay readable.
3. **`docgen check`**: execute every `@example` in a sandbox; compare captured output to
   authored `--result`; non-zero exit on drift or on a module that fails to import. This is
   the CI hook and the doctest layer.
4. **`@example` authoring pass** (the enrichment stage): add examples to the ~24 exported
   commands across session, watch, tasks, test — starting with tasks (richest surface,
   freshest in memory). Authoring order is an open question below.
5. **Promotion**: once stable under real use, move `docgen` from the personal module into the
   registry as a git-type package like its four siblings.

Effort: the PoC demonstrates stage 1–2 mechanics in ~40 lines; a robust generator with
stage 3 is a small number of days. Stage 4 is judgment work spread over time.

Alternatives considered and their standing:

- **A. Bare generator without example enrichment** — strictly dominated by the recommendation;
  same code, forfeits the doctest and help-quality returns. Fallback if example authoring stalls.
- **C. Third-party pure-nu composition** — numd (reproducible markdown; executes nu blocks in
  `.md`) suits *guides/tutorials*, not API reference; dotnu overlaps with scope introspection
  for module analysis. Both are nupm-installable complements to adopt later if a guide layer
  is wanted; neither replaces the generator. The awesome-nu survey confirms **no existing
  API-reference generator** — whatever we build is genuinely novel and publishable.
- **D. Rust plugin** — permitted by constraints but unjustified: every needed capability
  (scope metadata, `ast`, child processes) is a builtin. A plugin only earns its place for the
  *other* languages' parsing (e.g. tree-sitter), which is outside this candidate's scope.

## Assessment against ADR-0002 criteria

- **Explicit generation mechanism**: yes, and it is the strongest mechanism in the whole
  inventory — the language's own parser, with zero transcription and no drift class (what
  `help` shows and what the docs show are the same records by construction).
- **Fidelity**: semantic by construction; executed examples add behavioral verification no
  other candidate offers for any language (fir's embedded tests execute only as Lua;
  mkdocstrings verifies nothing at build time).
- **Effort/risk**: lowest of the three candidates for its leg — builtins only, blessed
  precedent, PoC already working; the main scheduled cost is example authoring, which pays
  into shell UX regardless of the docs outcome.
- **Strategic note for the ADR**: the Nushell leg should not drive the framework
  acceptance/refusal decision — it is covered natively either way, and the native collector
  slots into a mkdocstrings handler if that scenario wins. The decision weight sits on the
  other five languages.

## Open questions

- Page granularity: one page per module vs per command (URL stability for deep links)?
- Should the `.nuon` IR snapshot be committed as a first-class artifact from day one, or
  introduced when an MCP consumer materializes?
- `@example` authoring order and bar: which packages first, and is an example mandatory for
  every exported command or only for non-obvious surfaces?
- When (if ever) does `docgen` publish to the registry — after the first full generation run,
  or after the ADR resolves the framework question?
