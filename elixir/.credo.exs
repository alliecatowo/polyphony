# Credo configuration for Polyphony.
#
# Only thresholds are tuned here. Every check that can catch an actual bug
# (unused variables, unsafe atoms, missing specs, etc.) stays at its default
# under `mix credo --strict`.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "config/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true,
      checks: %{
        extra: [
          # Match `line_length: 200` in .formatter.exs so credo and `mix format` agree.
          {Credo.Check.Readability.MaxLineLength, [max_length: 200]},
          # Opinion, not bugs: the GraphQL/REST normalisation code is branchy by nature
          # (one clause per payload shape). Thresholds are raised to the current worst
          # case so new, deeper code still gets flagged.
          {Credo.Check.Refactor.Nesting, [max_nesting: 4]},
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 16]}
        ]
      }
    }
  ]
}
