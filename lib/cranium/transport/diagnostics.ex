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
  Import tokens posted from the diagnostics page textarea.
  """
  def auth_import(conn) do
    case Codex.import_tokens(conn.body_params) do
      :ok ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{ok: true}))

      {:error, reason} ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{error: to_string(reason)}))
    end
  end

  @doc """
  JSON status endpoint for polling OAuth state.
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

    import_section =
      """
      <p style="margin-top:12px;color:#888;font-size:0.9em">Run on a device with <a href="https://github.com/openai/codex" style="color:#6a6">Codex CLI</a>:</p>
      <pre style="background:#252525;padding:8px 12px;border-radius:4px;overflow-x:auto;user-select:all;font-size:0.85em">cat ~/.codex/auth.json</pre>
      <textarea id="tokens" rows="4" style="width:100%;box-sizing:border-box;background:#252525;color:#e0e0e0;border:1px solid #333;border-radius:4px;padding:8px;font-family:monospace;font-size:0.8em;resize:vertical;margin-top:8px" placeholder="Paste token JSON here..."></textarea>
      <div style="margin-top:8px">
        <button onclick="importTokens()" class="btn">Import</button>
        <span id="import-status" style="margin-left:12px;font-size:0.9em"></span>
      </div>
      <script>
      function importTokens(){var r=document.getElementById('tokens').value.trim();if(!r)return;var s=document.getElementById('import-status');s.textContent='Importing...';s.style.color='#888';try{var d=JSON.parse(r)}catch(e){s.textContent='Invalid JSON';s.style.color='#c44';return}fetch('/auth/openai/token',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(d)}).then(function(r){return r.json()}).then(function(d){if(d.ok){s.textContent='Done!';s.style.color='#4a4';setTimeout(function(){location.reload()},1200)}else{s.textContent='Error: '+(d.error||'unknown');s.style.color='#c44'}}).catch(function(){s.textContent='Request failed';s.style.color='#c44'})}
      </script>
      """

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
        .btn { display: inline-block; padding: 8px 16px; background: #2d5a27; color: #e0e0e0; text-decoration: none; border-radius: 4px; font-size: 0.9em; border: none; cursor: pointer; }
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
      #{import_section}
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
