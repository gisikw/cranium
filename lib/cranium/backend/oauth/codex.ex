defmodule Cranium.Backend.OAuth.Codex do
  @moduledoc """
  OAuth 2.0 PKCE token manager for OpenAI Codex (ChatGPT subscription).

  Manages the full OAuth lifecycle: browser-based authorization, token
  exchange, persistence, and automatic refresh. Used by the OpenAI
  Responses backend when `auth: oauth` is configured.

  ## Flow

  1. User visits `/auth/openai` → `start_auth_flow/1` generates PKCE
     verifier and returns the authorization URL
  2. After OpenAI login, callback hits `/auth/openai/callback` →
     `exchange_code/2` swaps the code for tokens
  3. Tokens are persisted to disk and auto-refreshed before expiry
  4. Backend calls `get_headers/0` to get Authorization + Account-Id headers
  """

  use GenServer

  require Logger

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @auth_url "https://auth.openai.com/oauth/authorize"
  @token_url "https://auth.openai.com/oauth/token"
  @scope "openid profile email offline_access"
  @token_filename "openai_oauth.json"

  # Refresh 5 minutes before expiry
  @refresh_buffer_seconds 300

  defstruct [
    :access_token,
    :refresh_token,
    :account_id,
    :expires_at,
    :refresh_timer,
    :pending_verifier,
    :token_path
  ]

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get authorization headers for the Codex endpoint.
  Returns `{:ok, headers}` or `{:error, :not_authenticated}`.
  """
  def get_headers do
    GenServer.call(__MODULE__, :get_headers)
  end

  @doc """
  Start the OAuth PKCE flow. Returns `{:ok, authorize_url}`.
  The `redirect_uri` should be the full callback URL.
  """
  def start_auth_flow(redirect_uri) do
    GenServer.call(__MODULE__, {:start_auth_flow, redirect_uri})
  end

  @doc """
  Exchange an authorization code for tokens. Called from the callback handler.
  """
  def exchange_code(code, redirect_uri) do
    GenServer.call(__MODULE__, {:exchange_code, code, redirect_uri}, 30_000)
  end

  @doc """
  Check if authenticated.
  """
  def authenticated? do
    GenServer.call(__MODULE__, :authenticated?)
  end

  @doc """
  Get current status for the diagnostics page.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    token_path = token_path()
    state = %__MODULE__{token_path: token_path}

    state =
      case load_tokens(token_path) do
        {:ok, tokens} ->
          state = apply_tokens(state, tokens)
          Logger.info("OAuth.Codex: loaded persisted tokens for account #{state.account_id}")
          maybe_schedule_refresh(state)

        {:error, _} ->
          state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:get_headers, _from, state) do
    if state.access_token && !token_expired?(state) do
      headers = [
        {"authorization", "Bearer #{state.access_token}"},
        {"chatgpt-account-id", state.account_id}
      ]

      {:reply, {:ok, headers}, state}
    else
      {:reply, {:error, :not_authenticated}, state}
    end
  end

  def handle_call({:start_auth_flow, redirect_uri}, _from, state) do
    verifier = generate_code_verifier()
    challenge = generate_code_challenge(verifier)

    params =
      URI.encode_query(%{
        "client_id" => @client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => @scope,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "id_token_add_organizations" => "true",
        "codex_cli_simplified_flow" => "true"
      })

    url = "#{@auth_url}?#{params}"
    state = %{state | pending_verifier: verifier}
    {:reply, {:ok, url}, state}
  end

  def handle_call({:exchange_code, code, redirect_uri}, _from, state) do
    case state.pending_verifier do
      nil ->
        {:reply, {:error, :no_pending_flow}, state}

      verifier ->
        case do_exchange_code(code, redirect_uri, verifier) do
          {:ok, tokens} ->
            state = %{state | pending_verifier: nil}
            state = apply_tokens(state, tokens)
            persist_tokens(state)
            state = maybe_schedule_refresh(state)
            Logger.info("OAuth.Codex: authenticated for account #{state.account_id}")
            {:reply, {:ok, :authenticated}, state}

          {:error, reason} ->
            state = %{state | pending_verifier: nil}
            Logger.error("OAuth.Codex: code exchange failed: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:authenticated?, _from, state) do
    {:reply, state.access_token != nil && !token_expired?(state), state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      authenticated: state.access_token != nil && !token_expired?(state),
      account_id: state.account_id,
      expires_at: state.expires_at
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:refresh_token, state) do
    case do_refresh_token(state.refresh_token) do
      {:ok, tokens} ->
        state = apply_tokens(state, tokens)
        persist_tokens(state)
        state = maybe_schedule_refresh(state)
        Logger.info("OAuth.Codex: token refreshed for account #{state.account_id}")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("OAuth.Codex: token refresh failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # --- Token Exchange ---

  defp do_exchange_code(code, redirect_uri, verifier) do
    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "client_id" => @client_id,
        "code_verifier" => verifier
      })

    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    case Req.post(@token_url, body: body, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        parse_token_response(body)

      {:ok, %{status: status, body: body}} ->
        {:error, {:token_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_refresh_token(nil), do: {:error, :no_refresh_token}

  defp do_refresh_token(refresh_token) do
    body =
      URI.encode_query(%{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => @client_id
      })

    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    case Req.post(@token_url, body: body, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        parse_token_response(body)

      {:ok, %{status: status, body: body}} ->
        {:error, {:refresh_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_token_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> parse_token_response(parsed)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp parse_token_response(%{"access_token" => access_token} = body) do
    expires_in = body["expires_in"] || 3600
    expires_at = DateTime.add(DateTime.utc_now(), expires_in, :second)
    account_id = extract_account_id(access_token)

    {:ok,
     %{
       access_token: access_token,
       refresh_token: body["refresh_token"],
       account_id: account_id,
       expires_at: expires_at
     }}
  end

  defp parse_token_response(_), do: {:error, :missing_access_token}

  # --- JWT Account ID ---

  defp extract_account_id(jwt) do
    case String.split(jwt, ".") do
      [_header, payload, _sig | _] ->
        payload
        |> Base.url_decode64!(padding: false)
        |> Jason.decode!()
        |> get_in(["https://api.openai.com/auth", "account_id"])

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # --- PKCE ---

  defp generate_code_verifier do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp generate_code_challenge(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end

  # --- Token State ---

  defp apply_tokens(state, tokens) do
    %{
      state
      | access_token: tokens.access_token,
        refresh_token: tokens[:refresh_token] || state.refresh_token,
        account_id: tokens[:account_id] || state.account_id,
        expires_at: tokens[:expires_at] || state.expires_at
    }
  end

  defp token_expired?(%{expires_at: nil}), do: true

  defp token_expired?(%{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) != :lt
  end

  defp maybe_schedule_refresh(%{refresh_timer: old} = state) do
    if old, do: Process.cancel_timer(old)

    case state.expires_at do
      nil ->
        state

      expires_at ->
        seconds_until_expiry = DateTime.diff(expires_at, DateTime.utc_now(), :second)
        refresh_in = max(seconds_until_expiry - @refresh_buffer_seconds, 10)
        timer = Process.send_after(self(), :refresh_token, refresh_in * 1000)
        %{state | refresh_timer: timer}
    end
  end

  # --- Persistence ---

  defp token_path do
    config_dir = System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
    Path.join([config_dir, "cranium", @token_filename])
  end

  defp load_tokens(path) do
    case File.read(path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, %{"access_token" => _} = parsed} ->
            expires_at =
              case parsed["expires_at"] do
                nil -> nil
                str -> DateTime.from_iso8601(str) |> elem(1)
              end

            {:ok,
             %{
               access_token: parsed["access_token"],
               refresh_token: parsed["refresh_token"],
               account_id: parsed["account_id"],
               expires_at: expires_at
             }}

          _ ->
            {:error, :invalid_format}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_tokens(state) do
    data =
      Jason.encode!(%{
        "access_token" => state.access_token,
        "refresh_token" => state.refresh_token,
        "account_id" => state.account_id,
        "expires_at" => state.expires_at && DateTime.to_iso8601(state.expires_at)
      })

    dir = Path.dirname(state.token_path)
    File.mkdir_p!(dir)
    File.write!(state.token_path, data)
  end
end
