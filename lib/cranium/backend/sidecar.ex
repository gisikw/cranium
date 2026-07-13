defmodule Cranium.Backend.Sidecar do
  @moduledoc """
  Synchronous single-turn inference for sidecar evaluations.

  Resolves a Cranium profile, dispatches through the profile's backend module
  (typically Tiamat), and collects the text response. Used by macro condition
  evaluation, macro revision, and plugin sidecar calls.

  This replaces direct Ollama HTTP calls — all inference now routes through
  Cranium profiles and their configured backends.
  """

  require Logger

  @default_profile "sidecar"
  @default_timeout 60_000

  @doc """
  Send a single-turn prompt and return the text response.

  Options:
    - `profile` — Cranium profile name (default: "sidecar")
    - `timeout` — receive timeout in ms (default: 60_000)

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec chat(String.t(), keyword()) :: {:ok, String.t()} | {:error, any()}
  def chat(prompt, opts \\ []) do
    profile_name = Keyword.get(opts, :profile, @default_profile)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case Cranium.Config.resolve_profile(profile_name) do
      {:ok, resolved} ->
        messages = [%{role: "user", content: prompt}]

        backend_opts = [
          system: nil,
          model: resolved.model,
          tools: [],
          thinking: nil,
          backend_config: resolved.backend_config,
          ephemeral: true,
          router_profile: resolved.router_profile,
          conversation_id: "sidecar-#{System.unique_integer([:positive])}",
          epoch_id: Ecto.UUID.generate(),
          no_cache: true
        ]

        case resolved.backend_module.stream_chat(messages, backend_opts) do
          {:ok, pid} ->
            ref = Process.monitor(pid)
            collect_response(pid, ref, [], timeout)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :not_found} ->
        Logger.warning("Sidecar: profile '#{profile_name}' not found")
        {:error, {:profile_not_found, profile_name}}
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  defp collect_response(pid, ref, acc, timeout) do
    receive do
      {:llm_text, text} ->
        collect_response(pid, ref, [text | acc], timeout)

      {:llm_stop, "end_turn"} ->
        Process.demonitor(ref, [:flush])
        {:ok, acc |> Enum.reverse() |> Enum.join()}

      {:llm_stop, "tool_use"} ->
        # Sidecar shouldn't be making tool calls, but collect what we have
        Process.demonitor(ref, [:flush])
        {:ok, acc |> Enum.reverse() |> Enum.join()}

      {:llm_stop, {:error, reason}} ->
        Process.demonitor(ref, [:flush])
        {:error, reason}

      # Ignore other messages from the backend
      {:llm_tool_use, _} ->
        collect_response(pid, ref, acc, timeout)

      {:llm_usage, _} ->
        collect_response(pid, ref, acc, timeout)

      {:llm_assistant_content, _} ->
        collect_response(pid, ref, acc, timeout)

      {:DOWN, ^ref, :process, ^pid, :normal} ->
        {:ok, acc |> Enum.reverse() |> Enum.join()}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:process_crashed, reason}}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :shutdown)
        {:error, :timeout}
    end
  end
end
