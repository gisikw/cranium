defmodule Cranium.Muse.HTTP do
  @moduledoc """
  HTTP client for a remote `muse serve` daemon.

  The wire contract is the CLI invocation: the request carries exactly what
  `Cranium.Muse.exec/4` would put on argv — the `--exec` payload JSON (as
  the string the CLI would receive), the working directory it would `cd`
  to, the `--rw`/`--ro` grant lists, and env additions (MUSE_ROOM_DEPTH).
  The response body is exactly what `--exec` prints on stdout (the
  ExecResult wrapper) plus an `exit_code` field; `Cranium.Muse` feeds it
  through the same unwrap/error paths as local output.

  All protocol knowledge lives in this module so any delta in the serve
  implementation is a one-file fix.

  Failure posture mirrors a missing muse binary: unreachable endpoint,
  timeout, or auth failure logs a warning and returns `{:error, message}`,
  which the agent surfaces as a tool error — the session never crashes.
  """

  require Logger

  # Bash tool calls can legitimately run minutes; profile timeout_ms overrides.
  @default_timeout_ms 600_000
  @connect_timeout_ms 5_000

  @type exec_request :: %{
          payload: String.t(),
          working_dir: String.t() | nil,
          rw: [String.t()],
          ro: [String.t()],
          env: [{String.t(), String.t()}]
        }

  @spec exec(map(), exec_request()) ::
          {:ok, body :: String.t(), exit_code :: integer()} | {:error, String.t()}
  def exec(endpoint, request) do
    with {:ok, token} <- resolve_token(endpoint) do
      body = %{
        payload: request.payload,
        working_dir: request.working_dir,
        rw: request.rw,
        ro: request.ro,
        env: Map.new(request.env)
      }

      timeout_ms = endpoint[:timeout_ms] || @default_timeout_ms

      req_opts =
        [
          json: body,
          auth: {:bearer, token},
          receive_timeout: timeout_ms,
          connect_options: [timeout: @connect_timeout_ms],
          retry: false,
          decode_body: false
        ] ++ if(endpoint[:plug], do: [plug: endpoint[:plug]], else: [])

      case Req.post(exec_url(endpoint.url), req_opts) do
        {:ok, %{status: 200, body: raw}} when is_binary(raw) ->
          {:ok, raw, exit_code(raw)}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("muse exec endpoint: HTTP #{status}",
            url: endpoint.url,
            body: body |> to_string() |> String.slice(0..200)
          )

          {:error, "muse exec endpoint returned HTTP #{status}"}

        {:error, %Req.TransportError{reason: :timeout}} ->
          Logger.warning("muse exec endpoint: timed out",
            url: endpoint.url,
            timeout_ms: timeout_ms
          )

          {:error, "muse exec endpoint timed out after #{timeout_ms}ms"}

        {:error, reason} ->
          Logger.warning("muse exec endpoint: unreachable",
            url: endpoint.url,
            reason: inspect(reason)
          )

          {:error, "muse exec endpoint unreachable: #{inspect(reason)}"}
      end
    end
  end

  # The exit code the CLI would have returned rides inside the response
  # body. A body without one is treated as success output, matching the
  # CLI's verbatim passthrough of exit-0 stdout.
  defp exit_code(raw) do
    case Jason.decode(raw) do
      {:ok, %{"exit_code" => code}} when is_integer(code) -> code
      _ -> 0
    end
  end

  defp exec_url(base), do: String.trim_trailing(base, "/") <> "/exec"

  # Token comes via env or file indirection only — Cranium.Config rejects
  # literals. Resolved per call so rotation doesn't require a restart.
  defp resolve_token(%{token_env: env_var} = endpoint) when is_binary(env_var) do
    case System.get_env(env_var) do
      value when is_binary(value) and value != "" ->
        {:ok, String.trim(value)}

      _ ->
        token_error(endpoint, "env var #{env_var} is unset or empty")
    end
  end

  defp resolve_token(%{token_file: path} = endpoint) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        case String.trim(content) do
          "" -> token_error(endpoint, "token file #{path} is empty")
          token -> {:ok, token}
        end

      {:error, reason} ->
        token_error(endpoint, "token file #{path} unreadable: #{inspect(reason)}")
    end
  end

  defp resolve_token(endpoint) do
    token_error(endpoint, "no token_env or token_file configured")
  end

  defp token_error(endpoint, detail) do
    Logger.warning("muse exec endpoint: token unavailable",
      url: endpoint[:url],
      detail: detail
    )

    {:error, "muse exec endpoint token unavailable: #{detail}"}
  end
end
