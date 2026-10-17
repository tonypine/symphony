defmodule SymphonyElixir.GitHub.WebhookSecret do
  @moduledoc """
  The shared secret GitHub signs webhook deliveries with, as instant GitHub updates set it up
  (`SymphonyElixir.GitHub.WebhookSetup`).

  Symphony makes the secret (32 random bytes, hex) and hands it off: it writes it to
  `<state-root>/github_webhook_secret`, readable only by the user, which the service reads while
  `$SYMPHONY_GITHUB_WEBHOOK_SECRET` is unset (`SymphonyElixir.GitHub.Webhook.secret/1`). The macOS
  app moves it into its secret item `symphony-github-webhook` and its launcher passes it as
  `SYMPHONY_GITHUB_WEBHOOK_SECRET`. `symphony.yml` only ever names the variable
  (`secret: $SYMPHONY_GITHUB_WEBHOOK_SECRET`), never the value.
  """

  alias SymphonyElixir.GitHub.Webhook
  alias SymphonyElixir.{Paths, Secret}

  @env "SYMPHONY_GITHUB_WEBHOOK_SECRET"
  @item "symphony-github-webhook"

  @doc "The environment variable the app's launcher passes the secret in."
  @spec env() :: String.t()
  def env, do: @env

  @doc "What `symphony.yml` holds under `github.webhooks.secret`: the variable, never the value."
  @spec setting() :: String.t()
  def setting, do: "$" <> @env

  @doc "The name of the app's secret item that keeps it."
  @spec item() :: String.t()
  def item, do: @item

  @doc "A new secret."
  @spec generate() :: Secret.t()
  def generate, do: 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower) |> Secret.wrap()

  @doc """
  Hands `secret` off to the app: the state root's secret file, mode 0600, replaced whole. The
  service's own `SYMPHONY_GITHUB_WEBHOOK_SECRET` takes the new value too, so a re-created secret
  verifies deliveries at once rather than after the next start (agents never inherit it:
  `SymphonyElixir.AgentEnv` passes an allowlist).
  """
  @spec hand_off(Secret.t()) :: :ok | {:error, File.posix()}
  def hand_off(%Secret{} = secret) do
    file = Paths.github_webhook_secret_file()
    temporary = "#{file}.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(temporary, ""),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.write(temporary, Secret.unwrap(secret)),
         :ok <- File.rename(temporary, file) do
      System.put_env(@env, Secret.unwrap(secret))
    else
      error ->
        _ = File.rm(temporary)
        error
    end
  end

  @doc "The secret deliveries are checked against now: the variable, else the handed-off file."
  @spec current() :: Secret.t() | nil
  def current, do: Webhook.secret(Webhook.settings())
end
