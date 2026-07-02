defmodule Cranium.Backend.OAuth.Codex do
  @moduledoc """
  OAuth 2.0 token manager for OpenAI Codex (ChatGPT subscription).

  Uses the device code flow — no redirect URI needed. The user visits a
  URL and enters a code from any device, while cranium polls in the
  background until authorization completes.

  ## Flow

  1. User clicks "Sign in with OpenAI" on the diagnostics page
  2. `start_device_flow/0` POSTs to OpenAI's device endpoint, gets a
     user_code + verification_uri
  3. Diagnostics page shows "Go to [url], enter [code]"
  4. GenServer polls token endpoint in background until user completes auth
  5. Tokens are persisted to disk and auto-refreshed before expiry
  6. Backend calls `get_headers/0` to get Authorization + Account-Id headers
  """

  use GenServer

  require Logger

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @device_url "https://auth.openai.com/codex/device"
  @token_url "https://auth.openai.com/oauth/token"
  @scope "openid profile email offline_access"
  @token_filename "openai_oauth.json"
  @device_grant_type "urn:ietf:params:oauth:grant-type:device_code"

  # Refresh 5 minutes before expiry
  @refresh_buffer_seconds 300

  defstruct [
    :access_token,
    :refresh_token,
    :account_id,
    :expires_at,
    :refresh_timer,
    :token_path,
    # Device flow state (transient, while waiting for user to authorize)
    :device_code,
    :user_code,
    :verification_uri,
    :device_poll_timer,
    :device_poll_interval
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
  Start the device code flow. Returns `{:ok, %{user_code, verification_uri}}`
  or `{:error, reason}`. The GenServer will poll in the background.
  """
  def start_device_flow do
    GenServer.call(__MODULE__, :start_device_flow, 15_000)
  end

  @doc """
  Import tokens from an external source (e.g. Codex CLI auth.json).
  Accepts a map with at least `"access_token"`. Optionally includes
  `"refresh_token"`, `"account_id"`, `"expires_at"`, `"expires_in"`.
  """
  def import_tokens(token_data) when is_map(token_data) do
    GenServer.call(__MODULE__, {:import_tokens, token_data})
  end

  @doc """
  Check if authenticated.
  """
  def authenticated? do
    GenServer.call(__MODULE__, :authenticated?)
  end

  @doc """
  Get current status for the diagnostics page. Includes device flow state
  if one is in progress.
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

  def handle_call(:start_device_flow, _from, state) do
    # Cancel any existing device poll
    if state.device_poll_timer, do: Process.cancel_timer(state.device_poll_timer)

    case request_device_code() do
      {:ok,
       %{
         device_code: device_code,
         user_code: user_code,
         verification_uri: uri,
         interval: interval
       }} ->
        timer = Process.send_after(self(), :device_poll, interval * 1000)

        state = %{
          state
          | device_code: device_code,
            user_code: user_code,
            verification_uri: uri,
            device_poll_timer: timer,
            device_poll_interval: interval
        }

        Logger.info("OAuth.Codex: device flow started — code #{user_code}")
        {:reply, {:ok, %{user_code: user_code, verification_uri: uri}}, state}

      {:error, reason} ->
        Logger.error("OAuth.Codex: device flow failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:import_tokens, data}, _from, state) do
    case parse_imported_tokens(data) do
      {:ok, tokens} ->
        state = apply_tokens(state, tokens)
        persist_tokens(state)
        state = maybe_schedule_refresh(state)
        Logger.info("OAuth.Codex: tokens imported for account #{state.account_id}")
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:authenticated?, _from, state) do
    {:reply, state.access_token != nil && !token_expired?(state), state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      authenticated: state.access_token != nil && !token_expired?(state),
      account_id: state.account_id,
      expires_at: state.expires_at,
      device_pending: state.device_code != nil,
      user_code: state.user_code,
      verification_uri: state.verification_uri
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:device_poll, state) do
    case poll_device_token(state.device_code) do
      {:ok, tokens} ->
        state = apply_tokens(state, tokens)
        state = clear_device_state(state)
        persist_tokens(state)
        state = maybe_schedule_refresh(state)
        Logger.info("OAuth.Codex: device flow completed for account #{state.account_id}")
        {:noreply, state}

      {:pending} ->
        timer = Process.send_after(self(), :device_poll, state.device_poll_interval * 1000)
        {:noreply, %{state | device_poll_timer: timer}}

      {:slow_down} ->
        new_interval = state.device_poll_interval * 2
        timer = Process.send_after(self(), :device_poll, new_interval * 1000)
        {:noreply, %{state | device_poll_timer: timer, device_poll_interval: new_interval}}

      {:error, reason} ->
        Logger.error("OAuth.Codex: device poll failed: #{inspect(reason)}")
        {:noreply, clear_device_state(state)}
    end
  end

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

  # --- Device Code Flow ---

  defp request_device_code do
    body =
      URI.encode_query(%{
        "client_id" => @client_id,
        "scope" => @scope
      })

    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    # The /codex/device endpoint redirects POST→GET. Use GET with query params
    # and let Req follow the full redirect chain.
    url = @device_url <> "?" <> body

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        parse_device_response(body)

      {:ok, %{status: status, body: body}} ->
        {:error, {:device_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_device_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> parse_device_response(parsed)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp parse_device_response(%{"device_code" => dc, "user_code" => uc} = body) do
    {:ok,
     %{
       device_code: dc,
       user_code: uc,
       verification_uri:
         body["verification_uri"] || body["verification_url"] ||
           "https://chatgpt.com/codex/device",
       interval: body["interval"] || 5
     }}
  end

  defp parse_device_response(_), do: {:error, :missing_device_code}

  defp poll_device_token(device_code) do
    body =
      URI.encode_query(%{
        "grant_type" => @device_grant_type,
        "device_code" => device_code,
        "client_id" => @client_id
      })

    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    case Req.post(@token_url, body: body, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        parse_token_response(body)

      {:ok, %{status: _status, body: body}} ->
        parsed = if is_binary(body), do: Jason.decode(body) |> elem(1), else: body
        error = if is_map(parsed), do: parsed["error"], else: nil

        case error do
          "authorization_pending" -> {:pending}
          "slow_down" -> {:slow_down}
          _ -> {:error, {:token_error, parsed}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Token Refresh ---

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

  # --- Import (external tokens) ---

  # Unwrap Codex CLI's nested format: {"tokens": {"access_token": ...}}
  defp parse_imported_tokens(%{"tokens" => %{"access_token" => _} = inner}) do
    parse_imported_tokens(inner)
  end

  defp parse_imported_tokens(%{"access_token" => access_token} = data) do
    expires_at =
      cond do
        is_integer(data["expires_at"]) ->
          DateTime.from_unix!(data["expires_at"])

        is_binary(data["expires_at"]) ->
          case DateTime.from_iso8601(data["expires_at"]) do
            {:ok, dt, _} -> dt
            _ -> DateTime.add(DateTime.utc_now(), 3600, :second)
          end

        is_integer(data["expires_in"]) ->
          DateTime.add(DateTime.utc_now(), data["expires_in"], :second)

        true ->
          DateTime.add(DateTime.utc_now(), 3600, :second)
      end

    account_id = data["account_id"] || extract_account_id(access_token)

    {:ok,
     %{
       access_token: access_token,
       refresh_token: data["refresh_token"],
       account_id: account_id,
       expires_at: expires_at
     }}
  end

  defp parse_imported_tokens(_), do: {:error, :missing_access_token}

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

  # --- State Helpers ---

  defp apply_tokens(state, tokens) do
    %{
      state
      | access_token: tokens.access_token,
        refresh_token: tokens[:refresh_token] || state.refresh_token,
        account_id: tokens[:account_id] || state.account_id,
        expires_at: tokens[:expires_at] || state.expires_at
    }
  end

  defp clear_device_state(state) do
    if state.device_poll_timer, do: Process.cancel_timer(state.device_poll_timer)

    %{
      state
      | device_code: nil,
        user_code: nil,
        verification_uri: nil,
        device_poll_timer: nil,
        device_poll_interval: nil
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
