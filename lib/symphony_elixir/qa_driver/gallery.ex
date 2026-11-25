defmodule SymphonyElixir.QaDriver.Gallery do
  @moduledoc """
  The Component Gallery behind `SymphonyElixir.QaDriver`'s `qa_gallery` and
  `qa_gallery_open`, and the design check's comparison of pictures: the second program in
  Symphony.app's bundle (`Contents/Helpers/SymphonyGallery`, `macos/Gallery/GalleryApp.swift`),
  which draws the app's shared components and screens from made-up inputs.

  `qa_gallery` runs it on the QA host without a window: `--entries` lists what there is to look
  at, and `--shot` draws one entry into a fresh folder in the pass's run directory (`host_dir`),
  from which each picture is copied into `qa-evidence/` under the gallery's own file name.

  The design check judges only the pictures a change changed (TP-1667): `draw_all/4` draws every
  entry in one run (`--shot-all`) into a folder of its own, once with the change's gallery and once
  with its base's, and `compare/3` pairs the two folders by file name and compares each pair by its
  decoded pixels (`SymphonyElixir.QaDriver.Picture`): a pair whose bytes are the same is the same
  picture, and any other pair is the same only when its pixels are. A picture only the change has
  is new, one only the base has is removed. `save/3` copies the changed and new ones into
  `qa-evidence/`. `SymphonyElixir.QaDriver.gallery_changes/1` puts them together.

  `qa_gallery_open` launches the app as `qa_launch_app` does, on the gallery's
  fixture folder, where the app replaces itself with the gallery and hands it
  its own arguments (`--open <entry> …`), so the live window is driven with the
  other `qa_*` tools.
  """

  alias SymphonyElixir.QaDriver.{Checks, Picture}

  @fixtures "macos/Tests/Fixtures/gallery"
  @helper "Contents/Helpers/SymphonyGallery"
  @name ~r/\A[A-Za-z0-9._-]{1,120}\z/
  @width ~r/\A(laptop|desktop|[0-9]{3,5})\z/
  @picture ~r/\A[A-Za-z0-9._-]+\.png\z/
  # The pairs whose files are the same, byte for byte: those are the same picture, with nothing to decode.
  @same_bytes_script ~s(h=$1; b=$2; shift 2; for f do if cmp -s "$h/$f" "$b/$f"; then printf '%s\\n' "$f"; fi; done)
  @timeout_ms 60_000
  @shot_timeout_ms 300_000
  @draw_all_timeout_ms 1_200_000
  @output_limit 2_000_000

  @type tool_error :: {:error, {:qa_tool, String.t(), String.t()}}
  @typedoc "One gallery's pictures, drawn by `draw_all/4`: the folder on the QA host and the pictures' file names."
  @type drawn :: %{dir: Path.t(), pictures: [String.t()]}

  @typedoc """
  What `compare/3` found, each a list of file names: `changed` and `new` are the ones to judge.
  `pngs` holds the change's pictures it read, by name: the QA host removes a file once it is read.
  """
  @type comparison :: %{changed: [String.t()], new: [String.t()], removed: [String.t()], same: [String.t()], pngs: %{String.t() => binary()}}

  @type arguments :: %{
          entry: String.t() | nil,
          variation: String.t() | nil,
          width: String.t() | nil,
          appearance: String.t() | nil
        }

  @doc "The fixture folder, relative to the checkout, on which the app starts the gallery in its place."
  @spec fixtures() :: String.t()
  def fixtures, do: @fixtures

  @doc "The gallery's path in the bundle whose executable is `executable` (`<bundle>/Contents/MacOS/<name>`)."
  @spec path(Path.t()) :: Path.t()
  def path(executable), do: executable |> Path.dirname() |> Path.dirname() |> Path.dirname() |> Path.join(@helper)

  @doc """
  Checks `qa_gallery`'s arguments: `entry` and `variation` are names (letters, digits, `.`, `_`,
  `-`, at most 120 bytes), `width` is `laptop`, `desktop` or 3 to 5 digits, `appearance` is
  `light` or `dark`, and `variation` and `width` need an `entry`.
  """
  @spec arguments(map()) :: {:ok, arguments()} | tool_error()
  def arguments(args) do
    with {:ok, entry} <- name(args, "entry"),
         {:ok, variation} <- name(args, "variation"),
         {:ok, width} <- width(Map.get(args, "width")),
         {:ok, appearance} <- appearance(Map.get(args, "appearance")) do
      if is_nil(entry) and not (is_nil(variation) and is_nil(width)) do
        tool_error("invalid_arguments", "`variation` and `width` need an `entry`. Call qa_gallery without arguments to list the entries.")
      else
        {:ok, %{entry: entry, variation: variation, width: width, appearance: appearance}}
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
    with {:ok, %{entry: entry, variation: variation, width: width, appearance: appearance}} <- arguments(args),
         :ok <- required(entry) do
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

  @doc "The gallery's entries and widths."
  @spec listing(map(), Path.t()) :: {:ok, map()} | tool_error()
  def listing(config, gallery) do
    with {:ok, listed} <- entries(config, gallery), do: {:ok, Map.take(listed, ["entries", "widths"])}
  end

  @doc """
  Draws every entry in one run (`--shot-all`), in `appearance` and, for a screen, at `width`, into
  a fresh folder in the pass's run directory whose name starts with `label`. A gallery built before
  it drew every entry in one run is refused, before it runs: it would open its window instead.
  """
  @spec draw_all(map(), Path.t(), %{width: String.t(), appearance: String.t()}, String.t()) :: {:ok, drawn()} | tool_error()
  def draw_all(config, gallery, %{width: width, appearance: appearance}, label) do
    out = Path.join(config.host_dir, "gallery-#{label}-#{System.unique_integer([:positive])}")

    with :ok <- draws_all(config, gallery, label),
         {:ok, output} <- run(config, gallery, ["--shot-all", "--width", width, "--appearance", appearance, "--out", out], @draw_all_timeout_ms),
         {:ok, pictures} <- pictures(output, out) do
      {:ok, %{dir: out, pictures: Enum.map(pictures, &Path.basename/1)}}
    end
  end

  @doc """
  Pairs the pictures of `head` (the change's gallery) and `base` (its base's) by file name, and
  compares each pair: the same bytes, or else the same decoded pixels, is the same picture. A
  picture only `head` has is `new`, one only `base` has is `removed`. The QA host removes a file
  once it is read, so the change's pictures that differ come back in `pngs`, for `save/4`.
  """
  @spec compare(map(), drawn(), drawn()) :: {:ok, comparison()} | tool_error()
  def compare(config, %{dir: head_dir, pictures: head}, %{dir: base_dir, pictures: base}) do
    common = Enum.filter(head, &(&1 in base))

    with {:ok, same_bytes} <- same_bytes(config, head_dir, base_dir, common),
         {:ok, pngs} <- changed(config, head_dir, base_dir, common -- same_bytes) do
      changed = Enum.filter(common, &Map.has_key?(pngs, &1))
      {:ok, %{changed: changed, new: head -- base, removed: base -- head, same: common -- changed, pngs: pngs}}
    end
  end

  @doc """
  Copies the pictures `names` of `drawn` into `qa-evidence/` under their own file names, as
  `shoot/3` saves its own: a picture this pass already saved under that name is kept and returned
  with `existing: true`. A picture in `pngs` (by name, `compare/3`'s) was read already and is
  saved from there; any other is read from the QA host.
  """
  @spec save(map(), drawn(), [String.t()], %{String.t() => binary()}) :: {:ok, map()} | tool_error()
  def save(config, drawn, names, pngs \\ %{})
  def save(_config, _drawn, [], _pngs), do: {:ok, %{"files" => []}}

  def save(config, %{dir: dir}, names, pngs) do
    read = fn path -> with :error <- Map.fetch(pngs, Path.basename(path)), do: config.host.read.(path) end

    with {:ok, evidence} <- Checks.ensure_evidence_dir(config.worktree) do
      save_pictures(%{config | host: %{config.host | read: read}}, Enum.map(names, &Path.join(dir, &1)), evidence)
    end
  end

  @doc """
  Draws one entry (`--shot`) and saves each picture in `qa-evidence/` under the gallery's file
  name: in `appearance` alone when it names one, else light and dark, and a screen at `width`
  alone when it names one, else at laptop and desktop widths. A screen needs a `variation`. A
  picture this pass already saved under that name is kept and returned with `existing: true`.
  """
  @spec shoot(map(), Path.t(), arguments()) :: {:ok, map()} | tool_error()
  def shoot(config, gallery, %{entry: entry, variation: variation, width: width} = arguments) do
    out = Path.join(config.host_dir, "gallery-shots-#{System.unique_integer([:positive])}")
    appearance = Map.get(arguments, :appearance)
    args = ["--shot", entry] ++ flag("--variation", variation) ++ flag("--width", width) ++ flag("--appearance", appearance) ++ ["--out", out]

    with {:ok, %{"entries" => entries}} <- entries(config, gallery),
         :ok <- screen_variation(entries, entry, variation),
         {:ok, output} <- run(config, gallery, args, @shot_timeout_ms),
         {:ok, pictures} <- pictures(output, out),
         {:ok, evidence} <- Checks.ensure_evidence_dir(config.worktree) do
      save_pictures(config, pictures, evidence)
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

  # A gallery from before `--shot-all` does not know it and opens its window: its program names it, or it is not asked.
  defp draws_all(config, gallery, label) do
    case config.host.cmd.("/usr/bin/grep", ["-q", "-a", "-F", "--", "--shot-all", gallery], timeout_ms: @timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {_output, _status}} ->
        tool_error(
          "qa_gallery_too_old",
          "The #{label}'s Component Gallery was built before it drew every entry in one run (`--shot-all`), so its pictures cannot be drawn to compare. Merging the base branch into the PR gives it a base that has it."
        )

      {:error, reason} ->
        tool_error("qa_gallery_failed", "The QA host could not be asked about the #{label}'s Component Gallery: #{inspect(reason)}")
    end
  end

  defp same_bytes(_config, _head_dir, _base_dir, []), do: {:ok, []}

  defp same_bytes(config, head_dir, base_dir, names) do
    with {:ok, output} <- run(config, "/bin/sh", ["-c", @same_bytes_script, "sh", head_dir, base_dir | names], @timeout_ms) do
      listed = output |> String.split("\n", trim: true) |> MapSet.new()
      {:ok, Enum.filter(names, &MapSet.member?(listed, &1))}
    end
  end

  # The pairs whose bytes differ are decoded: a picture written again with the same pixels is the
  # same. The change's pictures that differ are kept, by name.
  defp changed(config, head_dir, base_dir, names) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, changed} ->
      with {:ok, head, png} <- decoded(config, Path.join(head_dir, name)),
           {:ok, base, _png} <- decoded(config, Path.join(base_dir, name)) do
        if Map.take(head, [:width, :height, :rgba]) == Map.take(base, [:width, :height, :rgba]),
          do: {:cont, {:ok, changed}},
          else: {:cont, {:ok, Map.put(changed, name, png)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp decoded(config, path) do
    with {:ok, png} <- read(config, path) do
      case Picture.decode(png) do
        {:ok, picture} -> {:ok, picture, png}
        {:error, why} -> tool_error("qa_gallery_failed", "The picture #{Path.basename(path)} could not be compared: #{why}.")
      end
    end
  end

  defp read(config, path) do
    case config.host.read.(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> tool_error("qa_gallery_failed", "The picture #{Path.basename(path)} could not be copied from the QA host: #{inspect(reason)}")
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

  defp save_pictures(config, pictures, evidence) do
    pictures
    |> Enum.reduce_while({:ok, []}, fn picture, {:ok, files} ->
      file = Path.basename(picture)

      path = Path.join(Checks.evidence_dir(), file)

      case save_picture(config, picture, evidence, file) do
        :ok -> {:cont, {:ok, [%{"path" => path} | files]}}
        :existing -> {:cont, {:ok, [%{"path" => path, "existing" => true} | files]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, files |> Enum.reverse() |> files_payload()}
      error -> error
    end
  end

  defp files_payload(files) do
    if Enum.any?(files, & &1["existing"]),
      do: %{"files" => files, "note" => "A file marked `existing` is the picture this pass drew before under that name; it was kept as it was. Judge it."},
      else: %{"files" => files}
  end

  # A picture this pass drew before keeps its file: the gallery draws the same entry the same way.
  defp save_picture(config, picture, evidence, file) do
    case config.host.read.(picture) do
      {:ok, png} ->
        case Checks.write_evidence(Path.join(evidence, file), png, file) do
          {:error, {:qa_tool, "qa_screenshot_exists", _message}} -> :existing
          result -> result
        end

      {:error, reason} ->
        tool_error("qa_gallery_failed", "The picture #{file} could not be copied from the QA host: #{inspect(reason)}")
    end
  end

  defp tool_error(code, message), do: {:error, {:qa_tool, code, message}}

  defp tail(output, limit) when byte_size(output) > limit, do: "…" <> binary_part(output, byte_size(output) - limit, limit)
  defp tail(output, _limit), do: output
end
