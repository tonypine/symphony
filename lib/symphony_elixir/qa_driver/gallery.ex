defmodule SymphonyElixir.QaDriver.Gallery do
  @moduledoc """
  The Component Gallery behind `SymphonyElixir.QaDriver`'s `qa_gallery` and
  `qa_gallery_open`: the second program in Symphony.app's bundle
  (`Contents/Helpers/SymphonyGallery`, `macos/Gallery/GalleryApp.swift`), which
  draws the app's shared components and screens from made-up inputs.

  `qa_gallery` runs it on the QA host without a window: `--entries` and
  `--affected` list what there is to look at and what the PR's changed files
  are a reason to look at, and `--shot` draws one entry into a fresh folder in
  the pass's run directory (`host_dir`), from which each picture is copied
  into `qa-evidence/` under the gallery's own file name.

  `qa_gallery_open` launches the app as `qa_launch_app` does, on the gallery's
  fixture folder, where the app replaces itself with the gallery and hands it
  its own arguments (`--open <entry> …`), so the live window is driven with the
  other `qa_*` tools.
  """

  alias SymphonyElixir.QaDriver.Checks

  @fixtures "macos/Tests/Fixtures/gallery"
  @helper "Contents/Helpers/SymphonyGallery"
  @name ~r/\A[A-Za-z0-9._-]{1,120}\z/
  @width ~r/\A(laptop|desktop|[0-9]{3,5})\z/
  @picture ~r/\A[A-Za-z0-9._-]+\.png\z/
  # `host.cmd` has no standard input: the shell pipes the changed paths, its own arguments, into the gallery.
  @affected_script ~s(g=$1; shift; printf '%s\\n' "$@" | "$g" --affected)
  @timeout_ms 60_000
  @shot_timeout_ms 300_000
  @output_limit 2_000_000

  @type tool_error :: {:error, {:qa_tool, String.t(), String.t()}}
  @type arguments :: %{entry: String.t() | nil, variation: String.t() | nil, width: String.t() | nil}

  @doc "The fixture folder, relative to the checkout, on which the app starts the gallery in its place."
  @spec fixtures() :: String.t()
  def fixtures, do: @fixtures

  @doc "The gallery's path in the bundle whose executable is `executable` (`<bundle>/Contents/MacOS/<name>`)."
  @spec path(Path.t()) :: Path.t()
  def path(executable), do: executable |> Path.dirname() |> Path.dirname() |> Path.dirname() |> Path.join(@helper)

  @doc """
  Checks `qa_gallery`'s arguments: `entry` and `variation` are names (letters, digits, `.`, `_`,
  `-`, at most 120 bytes), `width` is `laptop`, `desktop` or 3 to 5 digits, and `variation` and
  `width` need an `entry`.
  """
  @spec arguments(map()) :: {:ok, arguments()} | tool_error()
  def arguments(args) do
    with {:ok, entry} <- name(args, "entry"),
         {:ok, variation} <- name(args, "variation"),
         {:ok, width} <- width(Map.get(args, "width")) do
      if is_nil(entry) and not (is_nil(variation) and is_nil(width)) do
        tool_error("invalid_arguments", "`variation` and `width` need an `entry`. Call qa_gallery without arguments to list the entries.")
      else
        {:ok, %{entry: entry, variation: variation, width: width}}
      end
    end
  end

  @doc """
  Checks `qa_gallery_open`'s arguments and returns what the launch takes: `qa_launch_app`'s
  arguments (the gallery's fixtures, the `fixture` environment, the appearance) and the app's own
  arguments, which it hands to the gallery.
  """
  @spec open(map()) :: {:ok, map(), [String.t()]} | tool_error()
  def open(args) do
    with {:ok, %{entry: entry, variation: variation, width: width}} <- arguments(args),
         :ok <- required(entry),
         {:ok, appearance} <- appearance(Map.get(args, "appearance")) do
      launch = %{"api_fixtures" => @fixtures, "environment" => "fixture", "appearance" => appearance}
      dark = if appearance == "dark", do: ["--dark"], else: []
      {:ok, launch, ["--open", entry] ++ flag("--variation", variation) ++ flag("--width", width) ++ dark}
    end
  end

  @doc "Whether the bundle carries the gallery at `gallery` on the QA host."
  @spec ensure_present(map(), Path.t()) :: :ok | tool_error()
  def ensure_present(config, gallery) do
    case config.host.cmd.("/bin/test", ["-x", gallery], timeout_ms: @timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {_output, _status}} ->
        tool_error(
          "qa_gallery_missing",
          "The built app carries no Component Gallery at #{@helper}. Only Symphony.app's QA build has one; without it there is nothing for qa_gallery and qa_gallery_open to show."
        )

      {:error, reason} ->
        tool_error("qa_gallery_failed", "The QA host could not be asked for the Component Gallery: #{inspect(reason)}")
    end
  end

  @doc """
  The gallery's entries and widths, with the entries `changed` is a reason to look at as
  `affected`. `changed` is the PR's changed files or why they could not be listed: then `affected`
  is nil and `note` says why.
  """
  @spec listing(map(), Path.t(), {:ok, [String.t()]} | {:error, term()}) :: {:ok, map()} | tool_error()
  def listing(config, gallery, changed) do
    with {:ok, listed} <- entries(config, gallery),
         {:ok, affected, note} <- affected(config, gallery, changed) do
      payload = listed |> Map.take(["entries", "widths"]) |> Map.put("affected", affected)
      {:ok, if(note, do: Map.put(payload, "note", note), else: payload)}
    end
  end

  @doc """
  Draws one entry (`--shot`) and saves each picture in `qa-evidence/` under the gallery's file
  name. A screen needs a `variation`.
  """
  @spec shoot(map(), Path.t(), arguments()) :: {:ok, map()} | tool_error()
  def shoot(config, gallery, %{entry: entry, variation: variation, width: width}) do
    out = Path.join(config.host_dir, "gallery-shots-#{System.unique_integer([:positive])}")
    args = ["--shot", entry] ++ flag("--variation", variation) ++ flag("--width", width) ++ ["--out", out]

    with {:ok, %{"entries" => entries}} <- entries(config, gallery),
         :ok <- screen_variation(entries, entry, variation),
         {:ok, output} <- run(config, gallery, args, @shot_timeout_ms),
         {:ok, pictures} <- pictures(output, out),
         {:ok, evidence} <- Checks.ensure_evidence_dir(config.worktree) do
      save(config, pictures, evidence)
    end
  end

  # -- arguments ----------------------------------------------------------------

  defp name(args, key) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> if Regex.match?(@name, value), do: {:ok, value}, else: invalid_name(key)
      _other -> invalid_name(key)
    end
  end

  defp invalid_name(key), do: tool_error("invalid_arguments", "`#{key}` must be 1-120 characters of letters, digits, `.`, `_` or `-`.")

  defp width(nil), do: {:ok, nil}

  defp width(width) do
    if is_binary(width) and Regex.match?(@width, width) do
      {:ok, width}
    else
      tool_error("invalid_arguments", "`width` must be `laptop`, `desktop` or a number of points of 3 to 5 digits.")
    end
  end

  defp appearance(appearance) when appearance in [nil, "light", "dark"], do: {:ok, appearance}
  defp appearance(_other), do: tool_error("invalid_arguments", "`appearance` must be `light` or `dark`.")

  defp required(nil), do: tool_error("invalid_arguments", "`entry` is required: an entry's `id` from qa_gallery.")
  defp required(_entry), do: :ok

  defp flag(_flag, nil), do: []
  defp flag(flag, value), do: [flag, value]

  # -- the gallery's answers ------------------------------------------------------

  defp entries(config, gallery) do
    with {:ok, output} <- run(config, gallery, ["--entries"], @timeout_ms) do
      case Jason.decode(output) do
        {:ok, %{"entries" => entries} = listed} when is_list(entries) -> {:ok, listed}
        _other -> unreadable("--entries", output)
      end
    end
  end

  defp affected(_config, _gallery, {:error, reason}) do
    {:ok, nil, "The PR's changed files could not be listed (#{inspect(reason)}), so `affected` is unknown: pick the entries from the PR's diff yourself."}
  end

  # Nothing changed is nothing to look at; the shell would hand the gallery one empty path.
  defp affected(_config, _gallery, {:ok, []}), do: {:ok, %{"all" => false, "entries" => []}, nil}

  defp affected(config, gallery, {:ok, paths}) do
    with {:ok, output} <- run(config, "/bin/sh", ["-c", @affected_script, "sh", gallery | paths], @timeout_ms) do
      case Jason.decode(output) do
        {:ok, %{"all" => all, "entries" => entries}} when is_boolean(all) and is_list(entries) ->
          {:ok, %{"all" => all, "entries" => entries}, nil}

        _other ->
          unreadable("--affected", output)
      end
    end
  end

  defp unreadable(command, output) do
    tool_error("qa_gallery_failed", "The Component Gallery's answer to #{command} could not be read: #{tail(String.trim(output), 500)}")
  end

  defp run(config, executable, args, timeout_ms) do
    case config.host.cmd.(executable, args, timeout_ms: timeout_ms, output_limit: @output_limit) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> tool_error("qa_gallery_failed", "The Component Gallery failed (exit #{status}): #{tail(String.trim(output), 2_000)}")
      {:error, reason} -> tool_error("qa_gallery_failed", "The Component Gallery could not run on the QA host: #{inspect(reason)}")
    end
  end

  # -- pictures -------------------------------------------------------------------

  # A screen's variations are drawn one at a time, so the agent names the one a step is about.
  defp screen_variation(entries, entry, nil) do
    case Enum.find(entries, &(is_map(&1) and &1["id"] == entry)) do
      %{"kind" => "screen", "variations" => variations} when is_list(variations) ->
        tool_error("invalid_arguments", "#{entry} is a screen: pass `variation`, one of #{Enum.join(variations, ", ")}.")

      _other ->
        :ok
    end
  end

  defp screen_variation(_entries, _entry, _variation), do: :ok

  # The gallery prints each picture's path on a line of its own; anything else in its output is not one.
  defp pictures(output, out) do
    pictures =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(Path.dirname(&1) == out and Regex.match?(@picture, Path.basename(&1))))
      |> Enum.uniq()

    case pictures do
      [] -> tool_error("qa_gallery_failed", "The Component Gallery drew no picture: #{tail(String.trim(output), 500)}")
      pictures -> {:ok, pictures}
    end
  end

  defp save(config, pictures, evidence) do
    pictures
    |> Enum.reduce_while({:ok, []}, fn picture, {:ok, files} ->
      file = Path.basename(picture)

      case save_picture(config, picture, evidence, file) do
        :ok -> {:cont, {:ok, [%{"path" => Path.join(Checks.evidence_dir(), file)} | files]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, %{"files" => Enum.reverse(files)}}
      error -> error
    end
  end

  defp save_picture(config, picture, evidence, file) do
    case config.host.read.(picture) do
      {:ok, png} ->
        with {:error, {:qa_tool, "qa_screenshot_exists", _message}} <- Checks.write_evidence(Path.join(evidence, file), png, file) do
          tool_error(
            "qa_screenshot_exists",
            "#{Checks.evidence_dir()}/#{file} already exists: this pass drew that picture before. Use that file, or move it aside and call qa_gallery again."
          )
        end

      {:error, reason} ->
        tool_error("qa_gallery_failed", "The picture #{file} could not be copied from the QA host: #{inspect(reason)}")
    end
  end

  defp tool_error(code, message), do: {:error, {:qa_tool, code, message}}

  defp tail(output, limit) when byte_size(output) > limit, do: "…" <> binary_part(output, byte_size(output) - limit, limit)
  defp tail(output, _limit), do: output
end
