# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  # Phoenix is a test-only dependency, so its formatter config cannot be
  # imported with :import_deps in every environment.
  locals_without_parens: [
    plug: 1,
    plug: 2,
    pipeline: 2,
    pipe_through: 1,
    scope: 2,
    scope: 3,
    get: 3
  ]
]
