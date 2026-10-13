defmodule SymphonyElixir.Playbook.FileSystem do
  @moduledoc """
  `Solid.FileSystem` implementation that serves Symphony's playbook partials from
  the compile-time-embedded `SymphonyElixir.Playbook` map.

  Used instead of `Solid.LocalFileSystem` because Symphony ships as an escript
  where `priv/` is dropped, so partials must come from memory, not
  disk.
  """

  @behaviour Solid.FileSystem

  alias SymphonyElixir.Playbook

  @impl Solid.FileSystem
  @spec read_template_file(binary(), any()) :: {:ok, String.t()} | {:error, Exception.t()}
  def read_template_file(name, _options) when is_binary(name) do
    case Playbook.fetch(name) do
      {:ok, body} ->
        {:ok, body}

      :error ->
        {:error, %Solid.FileSystem.Error{reason: "unknown playbook partial `#{name}`"}}
    end
  end
end
