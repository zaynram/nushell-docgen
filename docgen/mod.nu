# Extract structured documentation models from Nushell source.
#
# This module is the extraction layer of the docgen pipeline — and, until
# ADR-0002 freezes the integration question, deliberately the whole module.
# Each target is imported by a clean child interpreter and introspected
# through `scope modules` / `scope commands`, so the model is semantic by
# construction: what `help` shows and what the model records are the same
# data. Rendering and example execution are decision-dependent layers and
# do not live here.
#
# Boundaries, by design: a module that fails to import raises (a parse-broken
# module is a CI signal, not a gap to skip over); private helpers are
# invisible; nested submodules are not traversed.

# nu-lint-ignore-file: add_doc_comment_exported_fn

# The introspection program run inside the child interpreter. %USE% and
# %WHERE% are substituted by `introspect`; nuon on stdout is the only output.
const CHILD_SCRIPT = r#'
use %USE%
let found = scope modules | where %WHERE%
if ($found | is-empty) {
  error make --unspanned 'docgen: module imported but not found in scope'
}
let module = $found | first
# an exported `main` is listed under the module's own name and imports bare;
# every other export imports prefixed
let names = $module.commands.name | each {|it|
  if $it == $module.name { $it } else { $"($module.name) ($it)" }
}
{
  module: ($module | select name description extra_description file)
  commands: (
    scope commands
    | where name in $names
    | select name category description extra_description search_terms signatures examples is_const
    | sort-by name
  )
}
| to nuon
'#

# Resolve one collect target into the child's `use` argument and the
# `scope modules` predicate pinning down the imported module. Bare names
# resolve through the child's lib dirs; paths are expanded here so the
# predicate can match on the module's file identity, with a bare `mod.nu`
# target resolved to its parent directory (importing the file directly
# would name the module `mod`).
def resolve [target: string]: nothing -> record<use: string, where: string> {
  if not (($target =~ '[/\\]') or ($target ends-with .nu)) {
    return {use: $target, where: $"name == ($target | to nuon)"}
  }
  let full: path = try { $target | path expand --strict } catch {
    error make --unspanned $"docgen: target does not exist: ($target)"
  }
  let file: path = match ($full | path type) {
    dir => ($full | path join mod.nu)
    _ => $full
  }
  let entry: path = if ($file | path basename) == mod.nu {
    $file | path dirname
  } else {
    $file
  }
  {use: $entry, where: $"file == ($file | to nuon)"}
}

# Library directories the child resolves bare module names against: the
# caller's NU_LIB_DIRS plus the nupm modules directory.
def include-dirs []: nothing -> list<string> {
  $env.NU_LIB_DIRS?
  | default []
  | append ($nu.data-dir | path basename --replace nupm | path join modules)
  | uniq
}

# Import a target in a clean child interpreter and return the raw scope
# metadata. The child seam keeps the caller's session state out of the
# model and turns an import failure into a loud, attributable error.
def introspect [target: string]: nothing -> record {
  let t = resolve $target
  let script = $CHILD_SCRIPT
    | str replace %USE% ($t.use | to nuon)
    | str replace %WHERE% $t.where
  let out = ^$nu.current-exe --no-config-file --include-path (include-dirs | str join (char esep)) --commands $script
    | complete
  if $out.exit_code != 0 {
    error make --unspanned $"docgen: failed to collect ($target):\n($out.stderr | str trim)"
  }
  $out.stdout | from nuon
}

# Reshape one signature overload's rows into the model's parameter table,
# keeping only rows a caller can actually pass (input/output rows are
# surfaced separately as `io`).
def params-of []: any -> table {
  where parameter_type in [positional rest named switch]
  | each {|p|
    {
      name: $p.parameter_name
      kind: $p.parameter_type
      type: (if $p.parameter_type == switch { 'bool' } else { $p.syntax_shape | default any })
      required: (match $p.parameter_type {
        positional => (not ($p.is_optional | default false))
        _ => false
      })
      short: $p.short_flag
      default: $p.parameter_default
      description: $p.description
      completion: $p.completion
    }
  }
}

# One input/output type pair per signature overload.
def io-of []: record -> table {
  values
  | each {|rows|
    {
      input: ($rows | where parameter_type == input | get --optional 0.syntax_shape | default any)
      output: ($rows | where parameter_type == output | get --optional 0.syntax_shape | default any)
    }
  }
}

# Reshape one raw `scope commands` row into the documentation model. The
# parameter list is identical across overloads, so it comes from the first;
# io keeps every overload's pair.
def normalize []: record -> record {
  let raw = $in
  {
    name: $raw.name
    description: $raw.description
    extra_description: $raw.extra_description
    search_terms: $raw.search_terms
    category: $raw.category
    params: ($raw.signatures | values | get --optional 0 | default [] | params-of)
    io: ($raw.signatures | io-of)
    examples: $raw.examples
    is_const: $raw.is_const
  }
}

# Extract the documentation model for one or more Nushell modules.
#
# Each target is either a module name (resolved against the caller's
# NU_LIB_DIRS and the nupm modules directory) or a filesystem path to a
# module directory, its mod.nu, or a single-file module. The result is one
# row per target: the module's own metadata plus a normalized table of
# its exported commands (prefixed display names, `main` shown as the module
# name), sorted for diff-stable output. Persist the diffable IR snapshot by
# piping through `to nuon`.
@example "collect an installed module and list its command names" {
  collect tasks | first | get commands.name
}
@example "persist a module directory's model as a nuon snapshot" {
  collect ./docgen | to nuon --indent 2 | save docs/api.nuon
}
export def collect [
  ...targets: string # module names or paths (directory, mod.nu, or file.nu)
]: nothing -> table {
  if ($targets | is-empty) {
    error make --unspanned 'docgen collect: at least one module target is required'
  }
  $targets | each {|target|
    let raw = introspect $target
    {
      module: $raw.module
      commands: ($raw.commands | each { normalize })
    }
  }
}

# Entry point: `docgen <targets...>` delegates to `docgen collect`.
export def main [
  ...targets: string # module names or paths (directory, mod.nu, or file.nu)
]: nothing -> table {
  collect ...$targets
}
