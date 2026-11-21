# Credo's defaults, plus `mix.lock`: the step runner passes the changed Elixir files to
# `mix credo --strict`, and a lock-only change would otherwise be linted as source.
%{
  configs: [
    %{
      name: "default",
      files: %{
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/", "mix.lock"]
      }
    }
  ]
}
