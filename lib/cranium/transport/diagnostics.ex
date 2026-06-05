defmodule Cranium.Transport.Diagnostics do
  @moduledoc """
  Diagnostics page and OAuth route handlers.

  Renders a sparse HTML diagnostics page at `/` showing service status,
  active profiles, and OpenAI OAuth status. Uses device code flow for
  authentication — no redirect URI needed.
  """

  alias Cranium.Backend.OAuth.Codex

  @doc """
  Render the diagnostics page.
  """
  def index(conn) do
    version = Application.spec(:cranium, :vsn) |> to_string()
    profiles = profile_summary()
    oauth_status = Codex.status()

    html = render_page(version, profiles, oauth_status)

    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, html)
  end

  @doc """
  Initiate the device code flow. Shows a page with the code to enter.
  """
  def auth_openai(conn) do
    case Codex.start_device_flow() do
      {:ok, %{user_code: code, verification_uri: uri}} ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, device_code_html(code, uri))

      {:error, reason} ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(500, error_html("Failed to start device flow: #{inspect(reason)}"))
    end
  end

  @doc """
  JSON status endpoint for polling from the device code page.
  """
  def auth_status(conn) do
    status = Codex.status()

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(status))
  end

  # --- HTML Rendering ---

  defp render_page(version, profiles, oauth_status) do
    oauth_badge =
      if oauth_status.authenticated do
        "<span style=\"color:#4a4\">authenticated</span> &middot; #{esc(to_string(oauth_status.account_id || "unknown"))}"
      else
        "<span style=\"color:#a44\">not authenticated</span>"
      end

    expires_info =
      if oauth_status.expires_at do
        " &middot; expires #{DateTime.to_iso8601(oauth_status.expires_at)}"
      else
        ""
      end

    profile_rows =
      profiles
      |> Enum.map(fn {name, backend, model} ->
        "<tr><td><code>#{esc(name)}</code></td><td>#{esc(backend)}</td><td>#{esc(model)}</td></tr>"
      end)
      |> Enum.join("\n")

    """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>cranium</title>
      <style>
        body { font-family: system-ui, sans-serif; max-width: 640px; margin: 40px auto; padding: 0 20px; color: #e0e0e0; background: #1a1a1a; }
        h1 { font-size: 1.4em; margin-bottom: 4px; }
        .version { color: #888; font-size: 0.85em; }
        h2 { font-size: 1.1em; margin-top: 28px; border-bottom: 1px solid #333; padding-bottom: 4px; }
        table { width: 100%; border-collapse: collapse; font-size: 0.9em; }
        td, th { text-align: left; padding: 4px 8px; border-bottom: 1px solid #2a2a2a; }
        th { color: #888; font-weight: normal; }
        code { background: #252525; padding: 1px 4px; border-radius: 3px; }
        .btn { display: inline-block; padding: 8px 16px; background: #2d5a27; color: #e0e0e0; text-decoration: none; border-radius: 4px; font-size: 0.9em; margin-top: 8px; }
        .btn:hover { background: #3a7a30; }
      </style>
    </head>
    <body>
      <h1>cranium</h1>
      <p class="version">v#{esc(version)}</p>

      <h2>Profiles</h2>
      <table>
        <tr><th>name</th><th>backend</th><th>model</th></tr>
        #{profile_rows}
      </table>

      <h2>OpenAI OAuth</h2>
      <p>#{oauth_badge}#{expires_info}</p>
      <a class="btn" href="/auth/openai">Sign in with OpenAI</a>
    </body>
    </html>
    """
  end

  defp device_code_html(user_code, verification_uri) do
    """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>cranium — sign in</title>
      <style>
        body { font-family: system-ui, sans-serif; max-width: 400px; margin: 60px auto; padding: 0 20px; text-align: center; color: #e0e0e0; background: #1a1a1a; }
        .code { font-size: 2em; font-family: monospace; letter-spacing: 0.15em; background: #252525; padding: 12px 24px; border-radius: 8px; display: inline-block; margin: 16px 0; color: #fff; user-select: all; }
        a { color: #6a6; }
        .status { color: #888; font-size: 0.9em; margin-top: 20px; }
        .done { color: #4a4; }
      </style>
    </head>
    <body>
      <h2>Sign in with OpenAI</h2>
      <p>Go to <a href="#{esc(verification_uri)}" target="_blank">#{esc(verification_uri)}</a> and enter this code:</p>
      <div class="code">#{esc(user_code)}</div>
      <p class="status" id="status">Waiting for authorization...</p>
      <p><a href="/">Back to diagnostics</a></p>
      <script>
        (function() {
          var poll = setInterval(function() {
            fetch('/auth/openai/status').then(function(r) { return r.json(); }).then(function(s) {
              if (s.authenticated) {
                clearInterval(poll);
                document.getElementById('status').className = 'done';
                document.getElementById('status').textContent = 'Authenticated! Redirecting...';
                setTimeout(function() { window.location.href = '/'; }, 1500);
              }
            }).catch(function() {});
          }, 3000);
        })();
      </script>
    </body>
    </html>
    """
  end

  defp error_html(message) do
    """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>cranium — error</title>
      <style>body { font-family: system-ui; max-width: 400px; margin: 80px auto; text-align: center; color: #e0e0e0; background: #1a1a1a; } .err { color: #c44; }</style>
    </head>
    <body>
      <h2>Error</h2>
      <p class="err">#{esc(message)}</p>
      <p><a href="/" style="color: #6a6;">Back to diagnostics</a></p>
    </body>
    </html>
    """
  end

  # --- Helpers ---

  defp profile_summary do
    Cranium.Config.list_profiles()
    |> Enum.map(fn name ->
      case Cranium.Config.resolve_profile(name) do
        {:ok, profile} ->
          {name, to_string(profile.backend), profile.model || "default"}

        _ ->
          {name, "unknown", "unknown"}
      end
    end)
  end

  defp esc(str) do
    str
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
