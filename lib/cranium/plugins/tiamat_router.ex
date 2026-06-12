defmodule Cranium.Plugins.TiamatRouter do
  @moduledoc """
  Routes model selection through Tiamat's cost-aware Thompson Sampling
  endpoint, replacing local ensemble logic with learned routing decisions.

  Tiamat embeds recent conversation turns, retrieves quality observations
  from similar past episodes, and samples a model via Thompson Sampling
  with cost and latency penalties. Cranium maps the chosen arm back to a
  local profile for inference.

  ## Configuration

  In profiles.yaml:

      plugins:
        - module: Cranium.Plugins.TiamatRouter
          config:
            endpoint: http://tiamat.local:8900
            timeout: 3000
            recent_turns: 5
            interactive: true
            arm_profiles:
              opus-api: exo-api
              sonnet-api: exo-sonnet
              gpt-sub: exo-gpt
              qwen-local: exo-local

  ## Fallback

  If Tiamat is unreachable or returns an error, the plugin logs a warning
  and keeps the base profile — routing is a soft dependency.
  """

  @behaviour Cranium.Plugin

  require Logger

  @default_timeout 3_000
  @default_recent_turns 5

  @impl true
  def init(metadata) do
    config = metadata.plugin_config || %{}

    case config["endpoint"] do
      nil ->
        Logger.warning("TiamatRouter: no endpoint configured, ignoring")
        :ignore

      endpoint ->
        arm_profiles = config["arm_profiles"] || %{}

        if map_size(arm_profiles) == 0 do
          Logger.warning("TiamatRouter: no arm_profiles mapped, ignoring")
          :ignore
        else
          state = %{
            endpoint: String.trim_trailing(endpoint, "/"),
            timeout: config["timeout"] || @default_timeout,
            recent_turns: config["recent_turns"] || @default_recent_turns,
            interactive: config["interactive"] != false,
            arm_profiles: arm_profiles,
            last_decision: nil
          }

          {:ok, [:after_resolve_profile, :after_pass_complete], state}
        end
    end
  end

  @impl true
  def after_resolve_profile(context, state) do
    turns = fetch_recent_turns(context.conversation_id, state.recent_turns)

    payload = %{
      turns: turns,
      episode_id: context.epoch_id,
      interactive: state.interactive,
      expected_input_tokens: estimate_input_tokens(turns),
      expected_output_tokens: 2000
    }

    case call_route(state.endpoint, payload, state.timeout) do
      {:ok, %{"chosen_arm" => arm, "decision_id" => decision_id} = resp} ->
        model = resp["model"] || ""

        case Map.get(state.arm_profiles, arm) do
          nil ->
            Logger.warning("TiamatRouter: unknown arm #{arm}, keeping base profile")
            {:ok, context, state}

          target_profile ->
            final_context =
              if target_profile == context.profile_name do
                context
              else
                case swap_profile(context, target_profile) do
                  {:ok, new_context} ->
                    new_context

                  {:error, reason} ->
                    Logger.warning(
                      "TiamatRouter: profile swap failed",
                      target: target_profile,
                      reason: inspect(reason)
                    )

                    context
                end
              end

            state = %{
              state
              | last_decision: %{
                  decision_id: decision_id,
                  chosen_arm: arm,
                  tiamat_model: model,
                  profile: final_context.profile_name,
                  model: final_context.model,
                  backend: to_string(final_context.backend)
                }
            }

            {:ok, final_context, state}
        end

      {:error, reason} ->
        Logger.warning("TiamatRouter: route call failed, keeping base profile",
          reason: inspect(reason)
        )

        {:ok, context, state}
    end
  end

  @impl true
  def after_pass_complete(pass_context, state) do
    case state.last_decision do
      nil ->
        {:ok, state}

      decision ->
        Cranium.Store.save_ensemble_selection(%{
          epoch_id: pass_context.epoch_id,
          turn_count: pass_context.turn_count,
          profile: decision.profile,
          model: decision.model,
          backend: decision.backend,
          scores:
            encode_decision(decision)
        })

        {:ok, %{state | last_decision: nil}}
    end
  end

  # --- Private ---

  defp fetch_recent_turns(conversation_id, count) do
    case Cranium.Store.get_messages(conversation_id, limit: count) do
      {:ok, messages} ->
        messages
        |> Enum.reject(fn m -> m.role == :system end)
        |> Enum.map(fn m ->
          %{
            role: to_string(m.role),
            content: Cranium.Store.extract_text(m.content)
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp estimate_input_tokens(turns) do
    chars =
      Enum.reduce(turns, 0, fn t, acc ->
        acc + String.length(t.content || "")
      end)

    # Rough estimate: ~4 chars per token
    max(Float.round(chars / 4), 1000)
  end

  defp call_route(endpoint, payload, timeout) do
    url = endpoint <> "/route"

    case Req.post(url, json: payload, receive_timeout: timeout, connect_timeout: timeout) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp swap_profile(context, target_profile) do
    case Cranium.Config.resolve_profile(target_profile) do
      {:ok, resolved} ->
        {:ok,
         %{
           context
           | profile_name: resolved.name,
             backend: resolved.backend,
             backend_module: resolved.backend_module,
             model: resolved.model,
             identity: resolved.identity,
             thinking: resolved.thinking,
             backend_config: resolved.backend_config,
             context_window: resolved.context_window,
             saturation_warn: resolved.saturation_warn,
             saturation_critical: resolved.saturation_critical
         }}

      {:error, _} = err ->
        err
    end
  end

  defp encode_decision(decision) do
    [
      %{
        "source" => "tiamat",
        "decision_id" => decision.decision_id,
        "chosen_arm" => decision.chosen_arm,
        "tiamat_model" => decision.tiamat_model
      }
    ]
  end
end
