defmodule SymphonyElixirWeb.SetupController do
  @moduledoc """
  `GET /api/v1/setup`, the health model the app's Setup reads, and the actions it takes.

  The response holds one section per part of the setup. This one has `github_updates`
  (`SymphonyElixir.GitHub.WebhookSetup`); TP-902's Setup adds the others next to it.
  `POST /api/v1/setup/github_updates/:action` runs an action (`turn_on`, `run_step`, `test`,
  `restart_relay`, `recreate_secret`, `change_relay`, `turn_off`) and answers with the section as
  it leaves it.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.GitHub.WebhookSetup
  alias SymphonyElixirWeb.Endpoint

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, _params) do
    json(conn, %{github_updates: WebhookSetup.section(opts())})
  rescue
    error in ArgumentError -> config_unavailable(conn, error)
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

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
