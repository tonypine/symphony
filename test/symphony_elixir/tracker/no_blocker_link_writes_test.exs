defmodule SymphonyElixir.Tracker.NoBlockerLinkWritesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Memory

  # TP-1627: a ticket's dependencies are Symphony's stored `depends_on`, so nothing writes a Linear
  # blocker link any more. The tracker has no call that writes or removes one, and the one Linear
  # relation Symphony still creates is a `related` link.
  test "no code path writes a Linear blocker link" do
    callbacks = Tracker.behaviour_info(:callbacks)

    for name <- [:add_blocked_by, :remove_blocked_by] do
      refute Enum.any?(callbacks, fn {callback, _arity} -> callback == name end)

      for module <- [Tracker, Adapter, Memory], arity <- 0..4 do
        Code.ensure_loaded!(module)
        refute function_exported?(module, name, arity), "#{inspect(module)} still exports #{name}/#{arity}"
      end
    end

    sources = for path <- Path.wildcard("lib/**/*.ex"), do: {path, File.read!(path)}
    assert sources != []

    refute Enum.any?(sources, fn {_path, source} -> source =~ "issueRelationDelete" end)

    assert [{"lib/symphony_elixir/linear/adapter.ex", adapter}] =
             Enum.filter(sources, fn {_path, source} -> source =~ "issueRelationCreate" end)

    assert adapter =~ ~s("type" => "related")
    refute adapter =~ ~s("type" => "blocks")
  end
end
