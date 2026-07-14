# Extraction-layer coverage: target resolution, model shape, and failure
# behavior, all against hermetic fixture modules.
use ../mod.nu *

# The sample fixture's collected model.
def sample-model []: nothing -> record {
  collect ($FIXTURES | path join sample) | first
}

def "test collect-extracts-module-metadata" []: nothing -> nothing {
  let module = sample-model | get module
  assert equal $module.name sample
  assert equal $module.description "A tiny module exercising every metadata surface the collector extracts."
  assert equal $module.extra_description ""
  assert equal $module.file ($FIXTURES | path join sample mod.nu)
}

def "test collect-lists-exports-prefixed-and-sorted" []: nothing -> nothing {
  # exact equality also proves `main` surfaces as the module name and the
  # private `hidden` helper stays invisible
  assert equal (sample-model | get commands.name) [sample "sample greet" "sample total"]
}

def "test collect-normalizes-parameters" []: nothing -> nothing {
  let params = sample-model | get commands | where name == "sample greet" | first | get params
  assert equal $params [
    {
      name: name
      kind: positional
      type: string
      required: true
      short: null
      default: null
      description: "who to greet"
      completion: null
    }
    {
      name: polite
      kind: switch
      type: bool
      required: false
      short: p
      default: null
      description: "use a formal greeting"
      completion: null
    }
    {
      name: punctuation
      kind: named
      type: string
      required: false
      short: null
      default: !
      description: "trailing punctuation"
      completion: null
    }
  ]
}

def "test collect-extracts-io-signatures" []: nothing -> nothing {
  let commands = sample-model | get commands
  assert equal ($commands | where name == "sample greet" | first | get io) [
    {input: nothing, output: string}
  ]
  assert equal ($commands | where name == "sample total" | first | get io) [
    {input: list<int>, output: int}
  ]
}

def "test collect-captures-authored-examples" []: nothing -> nothing {
  let commands = sample-model | get commands
  assert equal ($commands | where name == "sample greet" | first | get examples) [
    {
      description: "greet politely"
      example: "greet world --polite"
      result: "Hello, world!"
    }
  ]
  assert equal ($commands | where name == "sample total" | first | get examples) []
}

def "test collect-carries-search-terms" []: nothing -> nothing {
  let greet = sample-model | get commands | where name == "sample greet" | first
  assert equal $greet.search_terms "hello, salutation"
  assert equal $greet.extra_description "The long form: greetings default to casual unless --polite is given."
}

def "test collect-accepts-file-and-name-targets" []: nothing -> nothing {
  let by_dir = collect ($FIXTURES | path join sample)
  assert equal (collect ($FIXTURES | path join sample mod.nu)) $by_dir
  $env.NU_LIB_DIRS = [$FIXTURES]
  assert equal (collect sample) $by_dir
}

def "test collect-accepts-single-file-module" []: nothing -> nothing {
  let model = collect ($FIXTURES | path join single.nu) | first
  assert equal $model.module.name single
  assert equal $model.module.file ($FIXTURES | path join single.nu)
  assert equal $model.commands.name ["single shout"]
}

def "test collect-handles-multiple-targets" []: nothing -> nothing {
  let dir = $FIXTURES | path join sample
  assert equal (collect $dir $dir | length) 2
}

def "test collect-model-is-nuon-serializable" []: nothing -> nothing {
  # the model doubles as a committed IR snapshot, so it must survive a
  # nuon roundtrip losslessly
  let model = collect ($FIXTURES | path join sample)
  assert equal ($model | to nuon | from nuon) $model
}

def "test collect-raises-on-broken-module" []: nothing -> nothing {
  assert error { collect ($FIXTURES | path join broken) }
}

def "test collect-raises-on-missing-target" []: nothing -> nothing {
  assert error { collect ($FIXTURES | path join nonexistent) }
}

def "test collect-requires-a-target" []: nothing -> nothing {
  assert error { collect }
}
