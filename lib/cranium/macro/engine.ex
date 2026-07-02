defmodule Cranium.Macro.Engine do
  @moduledoc """
  Macro engine coordination layer.

  Evaluates triggers, executes firing macros, manages session state,
  and returns injections for the turn pipeline. Also handles tool
  registration and routing for explicit-trigger macros.

  Lifecycle hooks:
  - `evaluate_turn/1` — called from TurnAssembler (before_context_build).
    Consumes sidecar results, checks auto-close, evaluates triggers,
    activates condition macros, returns injections.
  - `after_pass/1` — called from PassReactor (after_pass_complete).
    Dispatches sidecar evaluations for eligible active macros.
  - `on_epoch_end/1` — called from Cranium.clear_epoch.
    Dispatches revision for eligible macros.
  """

  require Logger

  alias Cranium.Macro.{Registry, Trigger, Executor, State, Sidecar, Revision, Definition}

  @type turn_context :: %{
          optional(:room_name) => String.t(),
          optional(:message_text) => String.t(),
          optional(atom()) => term(),
          conversation_id: String.t(),
          epoch_id: String.t(),
          turn_count: integer()
        }

  @type injection :: %{priority: integer(), content: String.t()}

  @doc """
  Evaluate macro triggers and execute firing macros for a turn.

  Called from TurnAssembler during context build. This is the main
  entry point for the macro engine on each turn.

  Flow:
  1. Consume pending sidecar results → update condition states
  2. Check auto-close for condition macros with all conditions resolved
  3. Collect injections from active condition macros
  4. Evaluate triggers for non-active macros
  5. Activate newly-firing condition macros
  6. Execute firing macros
  7. Return {injections, announcements}
  """
  @spec evaluate_turn(turn_context()) :: {[injection()], [injection()]}
  def evaluate_turn(context) do
    room_name = context[:room_name] || context.conversation_id
    macros = Registry.list()

    if macros == [] do
      {[], []}
    else
      # 1-2. Consume sidecar results and check auto-close
      completion_injections = consume_and_close(macros, room_name, context)

      # 3. Collect injections from active condition macros
      active_injections = collect_active_injections(macros, room_name, context)

      # 4. Evaluate triggers for non-active macros
      session_state = State.get_session(room_name)
      active_names = active_macro_names(macros, room_name)

      triggerable =
        Enum.filter(macros, fn m ->
          m.name not in active_names
        end)

      trigger_result = Trigger.evaluate(triggerable, context.message_text, session_state)

      # Update session state
      new_session = %{
        seen: trigger_result.seen,
        discovered: trigger_result.discovered_set,
        versions: build_versions(trigger_result.firing, session_state)
      }

      State.put_session(room_name, new_session)

      # 5. Activate newly-firing condition macros
      {condition_firing, regular_firing} =
        Enum.split_with(trigger_result.firing, &(&1.lifecycle == :condition))

      Enum.each(condition_firing, fn macro ->
        activate_macro(macro, room_name, context.turn_count)
      end)

      # 6. Execute firing macros (both regular and newly-activated condition macros)
      regular_injections = execute_firing_macros(regular_firing, room_name, context)

      # Newly activated condition macros also inject their body
      new_active_injections = execute_firing_macros(condition_firing, room_name, context)

      # 7. Build discovery announcements
      announcements = build_discovery_announcements(trigger_result.discovered)

      all_injections =
        completion_injections ++ active_injections ++ regular_injections ++ new_active_injections

      {all_injections, announcements}
    end
  end

  @doc """
  Called after inference pass completes. Dispatches sidecar evaluations
  for active macros with learning=sidecar that meet interval requirements.
  """
  @spec after_pass(turn_context()) :: :ok
  def after_pass(context) do
    room_name = context[:room_name] || context.conversation_id
    macros = Registry.list()

    macros
    |> Enum.filter(&(&1.learning == :sidecar and &1.conditions != []))
    |> Enum.each(fn macro ->
      macro_state = get_macro_state(macro, room_name)

      if macro_state["active"] do
        case Sidecar.dispatch(macro, room_name, context) do
          :dispatched ->
            Logger.debug("Macro.Engine: sidecar dispatched for #{macro.name}")

          {:skipped, reason} ->
            Logger.debug("Macro.Engine: sidecar skipped for #{macro.name}: #{reason}")
        end
      end
    end)

    :ok
  end

  @doc """
  Called at epoch end. Dispatches revision for macros with revision=session_end
  that were active or fired during this epoch.
  """
  @spec on_epoch_end(map()) :: :ok
  def on_epoch_end(context) do
    conversation_id = context.conversation_id
    room_name = context[:room_name] || conversation_id
    macros = Registry.list()
    session_state = State.get_session(room_name)
    seen = Map.get(session_state, :seen, MapSet.new())

    macros
    |> Enum.filter(&(&1.revision == :session_end))
    |> Enum.each(fn macro ->
      macro_state = get_macro_state(macro, room_name)

      # Revise if the macro was active (condition lifecycle) or fired (match lifecycle)
      should_revise =
        macro_state["active"] ||
          macro_state["activated_at_turn"] ||
          (macro.trigger == :match and MapSet.member?(seen, macro.name))

      if should_revise do
        Revision.dispatch(macro, context)
      end
    end)

    :ok
  end

  @doc """
  Execute an explicit-trigger macro invoked as a tool call.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec execute_tool(String.t(), map(), turn_context()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute_tool(macro_name, tool_input, context) do
    macro_name = unprefix_tool_name(macro_name)
    room_name = context[:room_name] || context[:conversation_id] || "unknown"

    case Registry.get(macro_name) do
      {:ok, macro} ->
        state = get_macro_state(macro, room_name)
        exec_context = Map.merge(context, tool_input_to_context(tool_input))

        case Executor.execute(macro, state, exec_context) do
          {:ok, output, new_state} ->
            persist_state_if_needed(macro, room_name, state, new_state)

            # If this is a condition-lifecycle macro being activated via tool
            if macro.lifecycle == :condition and not Map.get(state, "active", false) do
              activate_macro(macro, room_name, context[:turn_count] || 0)
            end

            {:ok, format_tool_output(output)}

          {:error, reason} ->
            {:error, reason}
        end

      :error ->
        {:error, "macro '#{macro_name}' not found"}
    end
  end

  @doc """
  Return Anthropic-format tool definitions for all explicit-trigger macros
  with listed or discoverable advertising.
  """
  @spec tool_definitions() :: [map()]
  def tool_definitions do
    Registry.list_by_trigger(:explicit)
    |> Enum.filter(&(&1.advertising in [:listed, :discoverable]))
    |> Enum.flat_map(&macro_tool_definitions/1)
  end

  @doc """
  Return Anthropic-format tool definitions for macros that have been
  discovered in a specific room's session.
  """
  @spec tool_definitions_for_room(String.t()) :: [map()]
  def tool_definitions_for_room(room_name) do
    session = State.get_session(room_name)
    discovered = Map.get(session, :discovered, MapSet.new())

    # Listed macros always show, discoverable only after discovery
    Registry.list_by_trigger(:explicit)
    |> Enum.filter(fn macro ->
      macro.advertising == :listed ||
        (macro.advertising == :discoverable && MapSet.member?(discovered, macro.name))
    end)
    |> Enum.flat_map(&macro_tool_definitions/1)
  end

  @doc """
  Check if a tool name corresponds to a macro tool.
  """
  @spec macro_tool?(String.t()) :: boolean()
  def macro_tool?(tool_name) do
    # Macro tools are prefixed with "macro_" to avoid name collisions
    String.starts_with?(tool_name, "macro_") and
      case Registry.get(unprefix_tool_name(tool_name)) do
        {:ok, %{trigger: :explicit}} -> true
        _ -> false
      end
  end

  # --- Activation / Deactivation ---

  defp activate_macro(macro, room_name, turn_count) do
    state = get_macro_state(macro, room_name)

    # Don't re-activate already-active macros
    unless state["active"] do
      condition_states =
        macro.conditions
        |> Enum.with_index()
        |> Enum.map(fn {_cond, idx} ->
          %{"index" => idx, "status" => "pending"}
        end)

      new_state =
        Map.merge(state, %{
          "active" => true,
          "activated_at_turn" => turn_count,
          "condition_states" => condition_states,
          "last_eval_turn" => nil,
          "last_eval_message_count" => nil
        })

      State.put_state(macro.name, room_name, new_state)

      Logger.info(
        "Macro.Engine: activated #{macro.name} in #{room_name} " <>
          "with #{length(macro.conditions)} conditions"
      )
    end
  end

  defp deactivate_macro(macro, room_name) do
    state = get_macro_state(macro, room_name)

    new_state = Map.put(state, "active", false)
    State.put_state(macro.name, room_name, new_state)

    # Reset sidecar tracking
    Sidecar.reset(macro.name, room_name)

    # Deactivate children
    Enum.each(macro.children, fn child ->
      deactivate_macro(child, room_name)
    end)

    Logger.info("Macro.Engine: deactivated #{macro.name} in #{room_name}")
  end

  # --- Sidecar Result Consumption & Auto-Close ---

  defp consume_and_close(macros, room_name, context) do
    macros
    |> Enum.filter(&(&1.learning == :sidecar and &1.lifecycle == :condition))
    |> Enum.flat_map(fn macro ->
      macro_state = get_macro_state(macro, room_name)

      if macro_state["active"] do
        case Sidecar.consume(macro.name, room_name) do
          {:ok, completed_indices} ->
            # Apply completions to condition states
            condition_states = apply_completions(macro_state, completed_indices)

            # Update eval tracking
            total_messages = count_messages(context)

            new_state =
              Map.merge(macro_state, %{
                "condition_states" => condition_states,
                "last_eval_turn" => context.turn_count,
                "last_eval_message_count" => total_messages
              })

            State.put_state(macro.name, room_name, new_state)

            # Check auto-close
            maybe_auto_close(macro, room_name, condition_states)

          :none ->
            # No sidecar results, but still check auto-close
            # (conditions may have been updated by tool calls)
            condition_states = macro_state["condition_states"] || []
            maybe_auto_close(macro, room_name, condition_states)
        end
      else
        []
      end
    end)
  end

  defp apply_completions(macro_state, completed_indices) do
    condition_states = macro_state["condition_states"] || []

    Enum.map(condition_states, fn cs ->
      if cs["index"] in completed_indices and cs["status"] in ["pending", "skipped"] do
        %{cs | "status" => "complete"}
      else
        cs
      end
    end)
  end

  defp maybe_auto_close(macro, room_name, condition_states) do
    pending = Enum.filter(condition_states, &(&1["status"] == "pending"))

    if pending == [] and condition_states != [] do
      deactivate_macro(macro, room_name)

      completed = Enum.count(condition_states, &(&1["status"] == "complete"))
      skipped = Enum.count(condition_states, &(&1["status"] == "skipped"))

      [
        %{
          priority: 40,
          content:
            "<system-reminder>Macro **#{macro.name}** has completed " <>
              "(#{completed} completed, #{skipped} skipped). It has been deactivated.</system-reminder>"
        }
      ]
    else
      []
    end
  end

  # --- Active Macro Helpers ---

  defp active_macro_names(macros, room_name) do
    macros
    |> Enum.filter(&(&1.lifecycle == :condition))
    |> Enum.filter(fn macro ->
      state = get_macro_state(macro, room_name)
      state["active"] == true
    end)
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  defp collect_active_injections(macros, room_name, context) do
    macros
    |> Enum.filter(&(&1.lifecycle == :condition))
    |> Enum.filter(fn macro ->
      state = get_macro_state(macro, room_name)
      state["active"] == true
    end)
    |> Enum.flat_map(fn macro ->
      state = get_macro_state(macro, room_name)

      exec_context = %{
        conversation_id: context.conversation_id,
        epoch_id: context.epoch_id,
        room_name: room_name,
        turn_count: context.turn_count,
        message_text: context.message_text
      }

      case Executor.execute(macro, state, exec_context) do
        {:ok, %{priority: _, content: _} = injection, new_state} ->
          persist_state_if_needed(macro, room_name, state, new_state)
          [injection]

        {:ok, _other, new_state} ->
          persist_state_if_needed(macro, room_name, state, new_state)
          []

        {:error, reason} ->
          Logger.warning("Macro.Engine: active injection failed for #{macro.name}: #{reason}")
          []
      end
    end)
  end

  # --- Existing Private Functions ---

  defp execute_firing_macros(firing, room_name, context) do
    firing
    |> Enum.flat_map(fn macro ->
      state = get_macro_state(macro, room_name)

      exec_context = %{
        conversation_id: context.conversation_id,
        epoch_id: context.epoch_id,
        room_name: room_name,
        turn_count: context.turn_count,
        message_text: context.message_text
      }

      case Executor.execute(macro, state, exec_context) do
        {:ok, %{priority: _, content: _} = injection, new_state} ->
          persist_state_if_needed(macro, room_name, state, new_state)
          [injection]

        {:ok, _other_output, new_state} ->
          persist_state_if_needed(macro, room_name, state, new_state)
          []

        {:error, reason} ->
          Logger.warning("Macro.Engine: execution failed for #{macro.name}: #{reason}")
          []
      end
    end)
  end

  defp build_discovery_announcements(discovered) do
    Enum.map(discovered, fn macro ->
      description =
        case macro.trigger do
          :explicit ->
            "A new capability is available: **#{macro.name}** — #{macro.description}. You can use it as a tool."

          _ ->
            "Context available: **#{macro.name}** — #{macro.description}."
        end

      %{priority: 45, content: "<system-reminder>#{description}</system-reminder>"}
    end)
  end

  defp build_versions(firing, session_state) do
    existing_versions = Map.get(session_state, :versions, %{})

    Enum.reduce(firing, existing_versions, fn macro, acc ->
      if macro.version do
        Map.put(acc, macro.name, macro.version)
      else
        acc
      end
    end)
  end

  defp get_macro_state(macro, room_name) do
    case State.get_state(macro.name, room_name) do
      {:ok, state} -> state
      :error -> defaults_from_schema(macro.state_schema)
    end
  end

  defp defaults_from_schema(nil), do: %{}

  defp defaults_from_schema(schema) when is_map(schema) do
    schema
    |> Enum.map(fn
      {key, %{"default" => default}} -> {key, default}
      {key, _} -> {key, nil}
    end)
    |> Map.new()
  end

  defp persist_state_if_needed(_macro, _room_name, state, state), do: :ok

  defp persist_state_if_needed(macro, room_name, _old_state, new_state) do
    State.put_state(macro.name, room_name, new_state)
  end

  defp count_messages(context) do
    case Cranium.Store.get_messages(context.conversation_id, epoch_id: context.epoch_id) do
      {:ok, messages} -> length(messages)
      {:error, _} -> 0
    end
  end

  defp macro_tool_definitions(%Definition{} = macro) do
    # The macro itself as a tool (if it has a prompt/script body that makes sense as a tool)
    main_def = %{
      name: prefix_tool_name(macro.name),
      description: macro.description,
      input_schema: build_input_schema(macro)
    }

    # Plus any explicitly declared tools on the macro
    child_tool_defs =
      Enum.map(macro.tools, fn tool ->
        %{
          name: prefix_tool_name("#{macro.name}_#{tool.name}"),
          description: tool.description,
          input_schema: tool.input_schema
        }
      end)

    [main_def | child_tool_defs]
  end

  defp build_input_schema(%{body_type: :prompt, prompt_body: %{text: text}}) do
    # Extract template variables as optional input properties
    vars =
      Regex.scan(~r/%\{(\w+)\}/, text)
      |> Enum.map(fn [_, var] -> var end)
      |> Enum.uniq()

    if vars == [] do
      %{type: "object", properties: %{}}
    else
      properties =
        Enum.map(vars, fn var ->
          {var, %{type: "string", description: "Value for #{var}"}}
        end)
        |> Map.new()

      %{type: "object", properties: properties}
    end
  end

  defp build_input_schema(%{input_schema: schema}) when is_map(schema), do: schema

  defp build_input_schema(_macro) do
    %{
      type: "object",
      properties: %{
        input: %{type: "string", description: "Input to the macro"}
      }
    }
  end

  defp prefix_tool_name(name) do
    "macro_" <> String.replace(name, ~r/[^a-zA-Z0-9_]/, "_")
  end

  defp unprefix_tool_name("macro_" <> rest) do
    # Try exact match first, then with hyphens restored
    case Registry.get(rest) do
      {:ok, _} -> rest
      :error -> String.replace(rest, "_", "-")
    end
  end

  defp unprefix_tool_name(name), do: name

  defp tool_input_to_context(input) when is_map(input) do
    input
    |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
    |> Map.new()
  end

  defp format_tool_output(%{content: content}), do: content
  defp format_tool_output(output) when is_binary(output), do: output
  defp format_tool_output(nil), do: "OK"

  defp format_tool_output(outputs) when is_list(outputs),
    do: Enum.map_join(outputs, "\n", &format_tool_output/1)
end
