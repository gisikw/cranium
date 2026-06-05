defmodule Cranium.Transport.Diagnostics do
  @moduledoc """
  Diagnostics page and OAuth route handlers.

  Renders a sparse HTML diagnostics page at `/` showing service status,
  active profiles, and OpenAI OAuth status. Handles the OAuth PKCE
  redirect and callback routes for Codex authentication.
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
  Initiate the OpenAI OAuth PKCE flow. Redirects to OpenAI.
  """
  def auth_openai(conn) do
    callback_url = build_callback_url(conn)

    case Codex.start_auth_flow(callback_url) do
      {:ok, authorize_url} ->
        conn
        |> Plug.Conn.put_resp_header("location", authorize_url)
        |> Plug.Conn.send_resp(302, "")

      {:error, reason} ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(500, error_html("Failed to start OAuth flow: #{inspect(reason)}"))
    end
  end

  @doc """
  Handle the OAuth callback from OpenAI.
  """
  def auth_callback(conn) do
    params = URI.decode_query(conn.query_string)
    code = params["code"]
    callback_url = build_callback_url(conn)

    cond do
      params["error"] ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(400, error_html("OAuth error: #{params["error_description"] || params["error"]}"))

      code == nil ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(400, error_html("Missing authorization code"))

      true ->
        case Codex.exchange_code(code, callback_url) do
          {:ok, :authenticated} ->
            conn
            |> Plug.Conn.put_resp_content_type("text/html")
            |> Plug.Conn.send_resp(200, success_html())

          {:error, reason} ->
            conn
            |> Plug.Conn.put_resp_content_type("text/html")
            |> Plug.Conn.send_resp(500, error_html("Token exchange failed: #{inspect(reason)}"))
        end
    end
  end

  # --- HTML Rendering ---

  defp render_page(version, profiles, oauth_status) do
    oauth_badge =
      if oauth_status.authenticated do
        "<span style=\"color:#4a4\">authenticated</span> &middot; #{oauth_status.account_id || "unknown"}"
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

  defp success_html do
    """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>cranium — authenticated</title>
      <style>body { font-family: system-ui; max-width: 400px; margin: 80px auto; text-align: center; color: #e0e0e0; background: #1a1a1a; }</style>
    </head>
    <body>
      <h2>Authenticated</h2>
      <p>OpenAI OAuth tokens saved. You can close this tab.</p>
      <p><a href="/" style="color: #6a6;">Back to diagnostics</a></p>
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

  defp build_callback_url(conn) do
    scheme = get_scheme(conn)
    host = get_host(conn)
    "#{scheme}://#{host}/auth/openai/callback"
  end

  defp get_scheme(conn) do
    # Respect X-Forwarded-Proto from reverse proxy
    case Plug.Conn.get_req_header(conn, "x-forwarded-proto") do
      [proto | _] -> proto
      [] -> to_string(conn.scheme)
    end
  end

  defp get_host(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-host") do
      [host | _] -> host
      [] ->
        case Plug.Conn.get_req_header(conn, "host") do
          [host | _] -> host
          [] -> "#{conn.host}:#{conn.port}"
        end
    end
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
