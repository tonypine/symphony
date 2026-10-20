defmodule SymphonyElixirWeb.SetupController do
  @moduledoc """
  `GET /api/v1/setup`, the health model the app's Setup reads, and the actions it takes.

  The response holds the setup problems (`SymphonyElixir.Setup`: `problems`, `not_checked`,
  `checked_at`, `linear_checked_at`) and one section per part of the setup, `github_updates`
  (`SymphonyElixir.GitHub.WebhookSetup`). `POST /api/v1/setup/refresh` runs the checks again and
  answers with the problems. `POST /api/v1/setup/fixes` runs a `linear` fix the latest check
  proposed (`SymphonyElixir.Setup.Fixes`, the descriptor as the payload lists it, or under `fix`)
  and answers with the problems after it: 422 `fix_not_proposed` for one the check didn't propose,
  422 `fix_refused` with Linear's reason and the unchanged problems when Linear refused it.
  With `?repo=<key>`, `GET /api/v1/setup` and `POST /api/v1/setup/refresh` keep only the problems
  that name that repo and those that name none (`SymphonyElixir.Setup.for_repo/2`), and answer 404
  `repo_not_loaded` while the running config has no such repo, as between an Add Repo save and the
  reload or restart that reads it. `POST /api/v1/setup/github_updates/:action` runs an action (`turn_on`,
  `run_step`, `test`, `restart_relay`, `recreate_secret`, `change_relay`, `turn_off`) and answers with
  the section as it leaves it.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.WebhookSetup
  alias SymphonyElixir.Setup
  alias SymphonyElixir.Setup.Fixes
  alias SymphonyElixirWeb.Endpoint

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, params) do
    with_repo(conn, params, fn filter ->
      json(conn, Map.put(filter.(Setup.payload(setup())), :github_updates, WebhookSetup.section(opts())))
    end)
  rescue
    error in ArgumentError -> config_unavailable(conn, error)
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, params), do: with_repo(conn, params, &json(conn, &1.(Setup.refresh(setup()))))

  @spec fixes(Conn.t(), map()) :: Conn.t()
  def fixes(conn, params) do
    params = json_form(params)

    case Fixes.run(Map.get(params, "fix", params), server: setup()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :not_proposed} ->
        error_response(conn, 422, "fix_not_proposed", "The latest setup check didn't propose this fix. Check again, then use a fix it lists.")

      {:error, {:refused, message}} ->
        conn
        |> put_status(422)
        |> json(Map.put(Setup.payload(setup()), :error, %{code: "fix_refused", message: message}))
    end
  end

  @spec github_updates(Conn.t(), map()) :: Conn.t()
  def github_updates(conn, %{"action" => action} = params) do
    case WebhookSetup.action(action, params |> Map.drop(["action"]) |> json_form(), opts()) do
      {:ok, section} -> json(conn, %{github_updates: section})
      {:error, {:not_found, message}} -> error_response(conn, 404, "not_found", message)
      {:error, {:unprocessable, message}} -> error_response(conn, 422, "invalid_params", message)
      {:error, {:conflict, message}} -> error_response(conn, 409, "conflict", message)
      {:error, {:config, message}} -> error_response(conn, 422, "config_not_written", message)
    end
  rescue
    error in ArgumentError -> config_unavailable(conn, error)
  end

  # Calls `answer` with the payload filter `repo` asks for, or answers 404 while that repo isn't loaded.
  defp with_repo(conn, %{"repo" => key}, answer) when is_binary(key) and key != "" do
    if repo_loaded?(key) do
      answer.(&Setup.for_repo(&1, key))
    else
      error_response(conn, 404, "repo_not_loaded", "Symphony hasn't read the repo #{key} from symphony.yml yet.")
    end
  end

  defp with_repo(_conn, _params, answer), do: answer.(& &1)

  defp repo_loaded?(key) do
    case Config.system() do
      {:ok, system} -> Enum.any?(system.repos, &(&1.name == key))
      {:error, _reason} -> false
    end
  end

  # `curl -d '{"relay": …}'` sends JSON as a form, which parses as one key with no value.
  defp json_form(params) do
    Enum.reduce(params, %{}, fn
      {key, ""}, acc ->
        case Jason.decode(key) do
          {:ok, %{} = decoded} -> Map.merge(acc, decoded)
          _not_json -> Map.put(acc, key, "")
        end

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp config_unavailable(conn, error) do
    error_response(conn, 503, "config_unavailable", "Symphony couldn't read its configuration: #{Exception.message(error)}")
  end

  # Tests name the setup's collaborators (a fake `gh`, the hand-off, the clock) in the endpoint's config.
  defp opts, do: Endpoint.config(:github_updates) || []

  # Tests name a Setup server of their own.
  defp setup, do: Endpoint.config(:setup) || Setup

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
