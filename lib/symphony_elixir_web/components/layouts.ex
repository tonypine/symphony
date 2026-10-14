defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  alias SymphonyElixirWeb.StaticAssets

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:dashboard_css_path, StaticAssets.asset_path!("/dashboard.css"))
      |> assign(:phoenix_html_js_path, StaticAssets.asset_path!("/vendor/phoenix_html/phoenix_html.js"))
      |> assign(:phoenix_js_path, StaticAssets.asset_path!("/vendor/phoenix/phoenix.js"))
      |> assign(:phoenix_live_view_js_path, StaticAssets.asset_path!("/vendor/phoenix_live_view/phoenix_live_view.js"))

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer phx-track-static src={@phoenix_html_js_path}></script>
        <script defer phx-track-static src={@phoenix_js_path}></script>
        <script defer phx-track-static src={@phoenix_live_view_js_path}></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            function installRestartAwareReconnect(liveSocket) {
              var reconnectTimer = null;
              var reconnectActive = false;
              var reconnectAttempts = 0;

              function reconnectDelay() {
                return Math.min(30000, Math.round(1000 * Math.pow(1.5, reconnectAttempts)));
              }

              function shouldCancelReconnect(view) {
                return (
                  view &&
                  ((typeof view.isDestroyed === "function" && view.isDestroyed()) ||
                    (typeof view.isConnected === "function" && view.isConnected()))
                );
              }

              function scheduleReconnect(view) {
                clearTimeout(reconnectTimer);

                reconnectTimer = setTimeout(function () {
                  if (shouldCancelReconnect(view)) {
                    reconnectActive = false;
                    reconnectAttempts = 0;
                    return;
                  }

                  reconnectAttempts += 1;

                  if (!liveSocket.isConnected()) {
                    liveSocket.getSocket().connect();
                  }

                  scheduleReconnect(view);
                }, reconnectDelay());
              }

              liveSocket.reloadWithJitter = function (view, log) {
                if (typeof log === "function") log();

                if (!reconnectActive) {
                  reconnectActive = true;
                  reconnectAttempts = 0;
                }

                scheduleReconnect(view);
              };
            }

            var Hooks = {
              LocalTime: {
                render: function () {
                  var iso = this.el.getAttribute("datetime");
                  if (!iso) return;
                  var d = new Date(iso);
                  if (isNaN(d.getTime())) return;
                  this.el.textContent = d.toLocaleTimeString([], {
                    hour: "2-digit",
                    minute: "2-digit",
                    second: "2-digit",
                    hour12: false
                  });
                  this.el.setAttribute("title", d.toLocaleString());
                },
                mounted: function () { this.render(); },
                updated: function () { this.render(); }
              }
            };

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: Hooks
            });

            installRestartAwareReconnect(liveSocket);
            liveSocket.connect();

            window.liveSocket = liveSocket;
          });
        </script>
        <link phx-track-static rel="stylesheet" href={@dashboard_css_path} />
      </head>
      <body>
        <p class="mac-app-banner" role="note">
          Symphony for Mac is now where you direct the factory. This dashboard stays for Linux and remote use and gets no new features.
        </p>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
