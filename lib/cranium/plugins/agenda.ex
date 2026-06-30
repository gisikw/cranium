defmodule Cranium.Plugins.Agenda do
  @moduledoc """
  Structured meeting agenda plugin with sidecar evaluation.

  Loads agenda definitions (JSON) from a configured directory. The agent
  activates an agenda via tool call, receives the meeting body, and
  converses naturally. A cheap sidecar model periodically evaluates recent
  turns against the agenda's completion criteria. The plugin injects
  progress reminders so the agent stays oriented without doing its own
  bookkeeping.

  ## Configuration

  In profiles.yaml:

      plugins:
        - module: Cranium.Plugins.Agenda
          config:
            agendas_path: /path/to/agendas
            state_path: /path/to/agenda-state
            sidecar_profile: haiku-eval
            eval_interval: 5
            injection_priority: 25

  ## Agenda definition format

  Static agenda (body/criteria inline):

      {
        "name": "weekly-sync",
        "description": "Weekly team sync agenda",
        "body": "Review action items from last week...",
        "criteria": [
          {
            "topic": "Action Items",
            "prose": "Review prior commitments.",
            "conditions": ["User confirmed action items reviewed"]
          }
        ]
      }

  Dynamic agenda (init script generates body/criteria):

      {
        "name": "project-debrief",
        "description": "Debrief a project. Invoke with {\"project\": \"<name>\"}",
        "init": "scripts/project-debrief-init.sh"
      }
  """

  @behaviour Cranium.Plugin

  require Logger

  @default_eval_interval 5
  @default_injection_priority 25
  @default_init_timeout 30

  @default_eval_prompt """
  You are evaluating whether meeting agenda criteria have been satisfied by recent conversation.

  Remaining criteria (with indices):
  %{criteria}

  Recent conversation:
  %{lookback}

  For each criterion, determine if the conversation has satisfied it.
  A criterion is satisfied when the participants have meaningfully addressed
  the topic — not just mentioned it, but reached a conclusion, decision,
  or acknowledgment.

  Respond with ONLY a JSON array of indices for criteria that were satisfied.
  If none were satisfied, respond with an empty array: []

  Example: [0, 3]
  """

  # --- Plugin Callbacks ---

  @impl true
  def init(metadata) do
    config = metadata.plugin_config || %{}
    agendas_path = config["agendas_path"]
    state_path = config["state_path"]

    cond do
      is_nil(agendas_path) or not File.dir?(agendas_path) ->
        Logger.debug("Agenda: no valid agendas_path, ignoring",
          conversation_id: metadata.conversation_id
        )

        :ignore

      is_nil(state_path) ->
        Logger.debug("Agenda: no state_path configured, ignoring",
          conversation_id: metadata.conversation_id
        )

        :ignore

      true ->
        definitions = load_definitions(agendas_path)

        if definitions == [] do
          Logger.debug("Agenda: no valid definitions found in #{agendas_path}, ignoring",
            conversation_id: metadata.conversation_id
          )

          :ignore
        else
          File.mkdir_p!(state_path)

          {:ok, eval_agent} = Agent.start_link(fn -> %{in_flight: false, result: nil} end)

          state = %{
            definitions: definitions,
            agendas_path: agendas_path,
            state_path: state_path,
            room_name: metadata.room_name,
            conversation_id: metadata.conversation_id,
            epoch_id: metadata.epoch_id,
            sidecar_profile: config["sidecar_profile"],
            eval_interval: config["eval_interval"] || @default_eval_interval,
            eval_prompt: config["eval_prompt"],
            injection_priority: config["injection_priority"] || @default_injection_priority,
            init_timeout: config["init_timeout_seconds"] || @default_init_timeout,
            agenda: %{active: false},
            eval_agent: eval_agent,
            rehydrated: false,
            just_auto_closed: false,
            auto_closed_name: nil
          }

          tools = build_tool_definitions(definitions)

          Logger.info("Agenda: loaded #{length(definitions)} definitions from #{agendas_path}",
            conversation_id: metadata.conversation_id
          )

          {:ok,
           [:on_epoch_start, :before_context_build, :after_pass_complete, :on_epoch_end], tools,
           state}
        end
    end
  end

  @impl true
  def on_epoch_start(context, state) do
    state = %{state | epoch_id: context.epoch_id}
    persisted = read_persisted_state(state)

    case persisted do
      %{"active" => true} = p ->
        agenda = rehydrate_agenda(p)

        Logger.info("Agenda: rehydrated active agenda '#{agenda.definition_name}'",
          conversation_id: context.conversation_id
        )

        {:ok, %{state | agenda: agenda, rehydrated: true}}

      _ ->
        {:ok, %{state | agenda: %{active: false}, rehydrated: false}}
    end
  end

  @impl true
  def before_context_build(turn_context, state) do
    # Check auto-close injection first — agenda is already inactive at this point
    if state.just_auto_closed do
      injection = format_completion_injection(state)
      {:ok, [injection], %{state | just_auto_closed: false}}
    else
      if not state.agenda.active do
        {:ok, :skip, state}
      else
        # Consume pending sidecar results
        {state, completions} = consume_eval_results(state)

        # Check auto-close
        state = maybe_auto_close(state)

        cond do
          # Just auto-closed — inject completion notice
          state.just_auto_closed ->
            injection = format_completion_injection(state)
            {:ok, [injection], %{state | just_auto_closed: false}}

          # First turn after activation or rehydration
          state.rehydrated ->
            injection = format_reminder_injection(state, :rehydration)
            {:ok, [injection], %{state | rehydrated: false}}

          is_first_turn_after_activation?(state, turn_context) ->
            injection = format_reminder_injection(state, :activation)
            {:ok, [injection], state}

          # Sidecar results just consumed
          completions != [] ->
            injection = format_reminder_injection(state, :eval_update)
            {:ok, [injection], state}

          true ->
            {:ok, :skip, state}
        end
      end
    end
  end

  @impl true
  def after_pass_complete(context, state) do
    if not state.agenda.active do
      {:ok, state}
    else
      maybe_fire_sidecar(context, state)
    end
  end

  @impl true
  def on_epoch_end(_context, state) do
    persist_state(state)
    :ok
  end

  @impl true
  def handle_tool_call(%{tool_name: "activate_agenda"} = ctx, state) do
    handle_activate(ctx, state)
  end

  def handle_tool_call(%{tool_name: "end_agenda"} = _ctx, state) do
    handle_end(state)
  end

  def handle_tool_call(%{tool_name: "agenda_status"} = _ctx, state) do
    handle_status(state)
  end

  def handle_tool_call(%{tool_name: "agenda_skip"} = ctx, state) do
    handle_skip(ctx, state)
  end

  # --- Tool Handlers ---

  defp handle_activate(%{input: input, turn_count: turn_count}, state) do
    if state.agenda.active do
      {:error, "Agenda already active: '#{state.agenda.definition_name}'", state}
    else
      name = input["name"]
      params = input["params"] || %{}

      case find_definition(state.definitions, name) do
        nil ->
          {:error, "Unknown agenda: '#{name}'", state}

        definition ->
          case instantiate_agenda(definition, params, turn_count, state) do
            {:ok, agenda} ->
              state = %{state | agenda: agenda}
              persist_state(state)
              content = format_activation_result(agenda)
              {:ok, content, state}

            {:error, reason} ->
              {:error, "Init script failed: #{reason}", state}
          end
      end
    end
  end

  defp handle_end(state) do
    if not state.agenda.active do
      {:error, "No active agenda", state}
    else
      summary = format_completion_summary(state.agenda.conditions)
      name = state.agenda.definition_name
      state = %{state | agenda: %{active: false}}
      persist_state(state)
      {:ok, "Agenda '#{name}' ended. #{summary}", state}
    end
  end

  defp handle_status(state) do
    if not state.agenda.active do
      {:error, "No active agenda", state}
    else
      {:ok, format_full_status(state.agenda), state}
    end
  end

  defp handle_skip(%{input: input}, state) do
    if not state.agenda.active do
      {:error, "No active agenda", state}
    else
      condition =
        cond do
          is_integer(input["condition_index"]) ->
            Enum.find(state.agenda.conditions, &(&1.index == input["condition_index"]))

          is_binary(input["condition_text"]) ->
            text = String.downcase(input["condition_text"])

            Enum.find(state.agenda.conditions, fn c ->
              String.downcase(c.criterion) == text
            end)

          true ->
            nil
        end

      cond do
        is_nil(condition) ->
          {:error, "Condition not found", state}

        condition.status != :pending ->
          {:error, "Condition is already #{condition.status}, cannot skip", state}

        true ->
          conditions =
            Enum.map(state.agenda.conditions, fn c ->
              if c.index == condition.index, do: %{c | status: :skipped}, else: c
            end)

          agenda = %{state.agenda | conditions: conditions}
          state = %{state | agenda: agenda}
          state = maybe_auto_close(state)
          persist_state(state)
          {:ok, "Skipped: #{condition.criterion}", state}
      end
    end
  end

  # --- Sidecar Evaluation ---

  defp maybe_fire_sidecar(context, state) do
    eval_state = Agent.get(state.eval_agent, & &1)
    turns_since = context.turn_count - (state.agenda.last_eval_turn || state.agenda.activated_at_turn)
    remaining = Enum.filter(state.agenda.conditions, &(&1.status in [:pending, :skipped]))

    if not eval_state.in_flight and
         turns_since >= state.eval_interval and
         remaining != [] do
      # Capture lookback messages now, before spawning the task
      lookback = fetch_lookback_messages(state)

      Agent.update(state.eval_agent, fn s -> %{s | in_flight: true} end)

      eval_agent = state.eval_agent
      sidecar_profile = state.sidecar_profile
      eval_prompt_template = state.eval_prompt
      room_name = state.room_name

      Task.start(fn ->
        result = run_sidecar_eval(remaining, lookback, sidecar_profile, eval_prompt_template)

        case result do
          {:ok, indices} ->
            Logger.info("Agenda: sidecar completed, #{length(indices)} conditions satisfied",
              room: room_name
            )

            Agent.update(eval_agent, fn _ ->
              %{in_flight: false, result: indices}
            end)

          {:error, reason} ->
            Logger.warning("Agenda: sidecar evaluation failed",
              error: inspect(reason),
              room: room_name
            )

            Agent.update(eval_agent, fn _ ->
              %{in_flight: false, result: nil}
            end)
        end
      end)

      {:ok, state}
    else
      {:ok, state}
    end
  end

  defp fetch_lookback_messages(state) do
    case Cranium.Store.get_messages(state.conversation_id, epoch_id: state.epoch_id) do
      {:ok, messages} ->
        # Drop messages before activation; then drop those before last eval
        msg_offset = state.agenda.last_eval_message_count || 0
        Enum.drop(messages, msg_offset)

      {:error, _} ->
        []
    end
  end

  defp run_sidecar_eval(remaining, lookback_messages, sidecar_profile, eval_prompt_template) do
    criteria_text =
      remaining
      |> Enum.map_join("\n", fn c ->
        status_tag = if c.status == :skipped, do: " [skipped]", else: ""
        "  [#{c.index}] #{c.criterion} (#{c.section_topic})#{status_tag}"
      end)

    lookback_text =
      lookback_messages
      |> Enum.map_join("\n", fn msg ->
        role = msg[:role] || msg["role"] || "unknown"
        content = Cranium.Store.extract_text(msg[:content] || msg["content"])
        "#{role}: #{content}"
      end)

    if lookback_text == "" do
      {:ok, []}
    else
      template = eval_prompt_template || @default_eval_prompt

      prompt =
        template
        |> String.replace("%{criteria}", criteria_text)
        |> String.replace("%{lookback}", lookback_text)

      profile = sidecar_profile || "sidecar"

      case Cranium.Backend.Sidecar.chat(prompt, profile: profile, timeout: 60_000) do
        {:ok, text} ->
          parse_sidecar_response(text)

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  defp parse_sidecar_response(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, indices} when is_list(indices) ->
        {:ok, Enum.filter(indices, &is_integer/1)}

      {:ok, _} ->
        {:error, :unexpected_format}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  defp parse_sidecar_response(_), do: {:error, :unexpected_response}

  # --- Eval Result Consumption ---

  defp consume_eval_results(state) do
    eval_state = Agent.get(state.eval_agent, & &1)

    case eval_state.result do
      nil ->
        {state, []}

      indices when is_list(indices) ->
        Agent.update(state.eval_agent, fn s -> %{s | result: nil} end)

        # Apply completions
        conditions =
          Enum.map(state.agenda.conditions, fn c ->
            if c.index in indices and c.status in [:pending, :skipped] do
              %{c | status: :complete}
            else
              c
            end
          end)

        # Update eval tracking
        total_messages = count_current_messages(state)

        agenda = %{
          state.agenda
          | conditions: conditions,
            last_eval_turn: current_turn_count(state),
            last_eval_message_count: total_messages
        }

        state = %{state | agenda: agenda}
        persist_state(state)
        {state, indices}
    end
  end

  defp count_current_messages(state) do
    case Cranium.Store.get_messages(state.conversation_id, epoch_id: state.epoch_id) do
      {:ok, messages} -> length(messages)
      {:error, _} -> 0
    end
  end

  defp current_turn_count(state) do
    # Approximate from message count (each turn ≈ 2 messages)
    div(count_current_messages(state), 2)
  end

  # --- Auto-Close ---

  defp maybe_auto_close(state) do
    if state.agenda.active do
      pending = Enum.filter(state.agenda.conditions, &(&1.status == :pending))

      if pending == [] do
        name = state.agenda.definition_name

        Logger.info("Agenda: auto-closing '#{name}' — all conditions resolved",
          room: state.room_name
        )

        %{state | agenda: %{active: false}, just_auto_closed: true, auto_closed_name: name}
      else
        state
      end
    else
      state
    end
  end

  # --- Formatting ---

  defp format_activation_result(agenda) do
    conditions_text =
      agenda.sections
      |> Enum.map_join("\n\n", fn section ->
        conditions =
          section.conditions
          |> Enum.map_join("\n", fn c -> "- [ ] #{c}" end)

        children =
          (section[:children] || [])
          |> Enum.map_join("\n\n", fn child ->
            child_conditions =
              child.conditions
              |> Enum.map_join("\n", fn c -> "  - [ ] #{c}" end)

            "  ### #{child.topic}\n  #{child.prose}\n#{child_conditions}"
          end)

        base = "## #{section.topic}\n#{section.prose}\n#{conditions}"
        if children != "", do: "#{base}\n\n#{children}", else: base
      end)

    """
    Agenda '#{agenda.definition_name}' activated.

    #{agenda.body}

    ---

    Criteria:

    #{conditions_text}
    """
    |> String.trim()
  end

  defp format_reminder_injection(state, trigger) do
    agenda = state.agenda
    completed = Enum.count(agenda.conditions, &(&1.status == :complete))
    skipped = Enum.count(agenda.conditions, &(&1.status == :skipped))
    total = length(agenda.conditions)
    remaining_count = total - completed - skipped

    preamble =
      case trigger do
        :rehydration ->
          "FYI: You're mid-agenda from a prior session. Here's where you stand."

        :activation ->
          "Agenda '#{agenda.definition_name}' is active."

        :eval_update ->
          "Agenda progress update."
      end

    remaining_sections = format_remaining_sections(agenda)

    content = """
    <system-reminder>
    #{preamble}
    Progress: #{completed}/#{total} completed, #{skipped} skipped, #{remaining_count} remaining.

    #{remaining_sections}
    </system-reminder>
    """

    %{priority: state.injection_priority, content: String.trim(content)}
  end

  defp format_completion_injection(state) do
    name = state[:auto_closed_name] || state.agenda[:definition_name] || "unknown"

    content = """
    <system-reminder>
    Agenda '#{name}' is complete.
    All criteria have been met or skipped.
    </system-reminder>
    """

    %{priority: state.injection_priority, content: String.trim(content)}
  end

  defp format_remaining_sections(agenda) do
    # Group conditions by section
    by_section =
      agenda.conditions
      |> Enum.group_by(& &1.section_topic)

    # Find sections from the tree that have remaining conditions
    agenda.sections
    |> Enum.flat_map(fn section ->
      section_conditions = Map.get(by_section, section.topic, [])
      remaining = Enum.filter(section_conditions, &(&1.status in [:pending, :skipped]))

      children =
        (section[:children] || [])
        |> Enum.flat_map(fn child ->
          child_conditions = Map.get(by_section, child.topic, [])
          child_remaining = Enum.filter(child_conditions, &(&1.status in [:pending, :skipped]))

          if child_remaining != [] do
            lines =
              Enum.map_join(child_remaining, "\n", fn c ->
                marker = if c.status == :skipped, do: "[~]", else: "[ ]"
                "  - #{marker} #{c.criterion}"
              end)

            ["  ### #{child.topic}\n  #{child.prose}\n#{lines}"]
          else
            []
          end
        end)

      if remaining != [] or children != [] do
        lines =
          remaining
          |> Enum.filter(&(&1.section_topic == section.topic))
          |> Enum.map_join("\n", fn c ->
            marker = if c.status == :skipped, do: "[~]", else: "[ ]"
            "- #{marker} #{c.criterion}"
          end)

        base = "## #{section.topic}\n#{section.prose}\n#{lines}"
        if children != [], do: [base | children], else: [base]
      else
        []
      end
    end)
    |> Enum.join("\n\n")
  end

  defp format_full_status(agenda) do
    completed = Enum.count(agenda.conditions, &(&1.status == :complete))
    skipped = Enum.count(agenda.conditions, &(&1.status == :skipped))
    total = length(agenda.conditions)

    conditions_text =
      agenda.conditions
      |> Enum.map_join("\n", fn c ->
        marker =
          case c.status do
            :complete -> "[x]"
            :skipped -> "[~]"
            :pending -> "[ ]"
          end

        "#{marker} [#{c.index}] #{c.criterion} (#{c.section_topic})"
      end)

    """
    Agenda: #{agenda.definition_name}
    Progress: #{completed}/#{total} completed, #{skipped} skipped

    #{conditions_text}
    """
    |> String.trim()
  end

  defp format_completion_summary(conditions) do
    completed = Enum.count(conditions, &(&1.status == :complete))
    skipped = Enum.count(conditions, &(&1.status == :skipped))
    remaining = Enum.filter(conditions, &(&1.status == :pending))
    total = length(conditions)

    base = "#{completed}/#{total} completed, #{skipped} skipped"

    case remaining do
      [] ->
        base

      items ->
        names = Enum.map_join(items, ", ", & &1.criterion)
        "#{base}, #{length(items)} remaining: [#{names}]"
    end
  end

  defp is_first_turn_after_activation?(state, turn_context) do
    state.agenda.active and
      turn_context.turn_count == state.agenda.activated_at_turn + 1
  end

  # --- Definition Loading ---

  defp load_definitions(path) do
    path
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      case load_definition(file) do
        {:ok, definition} ->
          [definition]

        {:error, reason} ->
          Logger.warning("Agenda: failed to load #{file}: #{inspect(reason)}")
          []
      end
    end)
  end

  defp load_definition(file) do
    with {:ok, content} <- File.read(file),
         {:ok, json} <- Jason.decode(content),
         {:ok, definition} <- validate_definition(json) do
      {:ok, definition}
    end
  end

  defp validate_definition(%{"name" => name, "description" => description} = json)
       when is_binary(name) and is_binary(description) do
    has_init = is_binary(json["init"])
    has_body = is_binary(json["body"])
    has_criteria = is_list(json["criteria"])

    cond do
      has_init and (has_body or has_criteria) ->
        {:error, :init_and_body_mutually_exclusive}

      has_init ->
        {:ok, %{name: name, description: description, init: json["init"]}}

      has_body or has_criteria ->
        {:ok,
         %{
           name: name,
           description: description,
           body: json["body"],
           criteria: parse_criteria(json["criteria"] || [])
         }}

      true ->
        {:error, :no_body_or_init}
    end
  end

  defp validate_definition(_), do: {:error, :invalid_schema}

  defp parse_criteria(criteria) when is_list(criteria) do
    Enum.map(criteria, &parse_criterion_section/1)
  end

  defp parse_criterion_section(%{"topic" => topic} = section) do
    %{
      topic: topic,
      prose: section["prose"] || "",
      conditions: section["conditions"] || [],
      children:
        (section["children"] || [])
        |> Enum.map(&parse_criterion_section/1)
    }
  end

  # --- Agenda Instantiation ---

  defp find_definition(definitions, name) do
    Enum.find(definitions, &(&1.name == name))
  end

  defp instantiate_agenda(definition, params, turn_count, state) do
    case get_body_and_criteria(definition, params, state) do
      {:ok, body, criteria} ->
        conditions = flatten_conditions(criteria)

        {:ok,
         %{
           active: true,
           definition_name: definition.name,
           body: body,
           sections: criteria,
           conditions: conditions,
           activated_at_turn: turn_count,
           last_eval_turn: turn_count,
           last_eval_message_count: count_current_messages(state)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_body_and_criteria(%{init: init_script}, params, state)
       when is_binary(init_script) do
    script_path = Path.join(state.agendas_path, init_script)

    if not File.exists?(script_path) do
      {:error, "Init script not found: #{init_script}"}
    else
      env =
        params
        |> Enum.map(fn {k, v} -> {String.upcase(to_string(k)), to_string(v)} end)

      case System.cmd("sh", [script_path], env: env, stderr_to_stdout: false) do
        {output, 0} ->
          case Jason.decode(output) do
            {:ok, %{"body" => body, "criteria" => criteria}} when is_binary(body) ->
              {:ok, body, parse_criteria(criteria)}

            {:ok, _} ->
              {:error, "Init script output missing body or criteria"}

            {:error, _} ->
              {:error, "Init script output is not valid JSON"}
          end

        {_, code} ->
          {:error, "Init script exited with code #{code}"}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp get_body_and_criteria(definition, _params, _state) do
    {:ok, definition[:body] || "", definition[:criteria] || []}
  end

  defp flatten_conditions(criteria) do
    criteria
    |> do_flatten_conditions([])
    |> Enum.with_index()
    |> Enum.map(fn {{topic, criterion}, index} ->
      %{
        index: index,
        criterion: criterion,
        section_topic: topic,
        status: :pending
      }
    end)
  end

  defp do_flatten_conditions([], acc), do: Enum.reverse(acc)

  defp do_flatten_conditions([section | rest], acc) do
    own = Enum.map(section.conditions, fn c -> {section.topic, c} end)

    children =
      (section[:children] || [])
      |> Enum.flat_map(fn child ->
        Enum.map(child.conditions, fn c -> {child.topic, c} end)
      end)

    do_flatten_conditions(rest, Enum.reverse(children) ++ Enum.reverse(own) ++ acc)
  end

  # --- State Persistence ---

  defp persist_state(state) do
    path = state_file_path(state)
    json = encode_agenda_state(state.agenda)
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)

        Logger.warning("Agenda: failed to persist state",
          error: inspect(reason),
          room: state.room_name
        )
    end
  end

  defp read_persisted_state(state) do
    path = state_file_path(state)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> data
          {:error, _} -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp state_file_path(state) do
    Path.join(state.state_path, "#{state.room_name}.json")
  end

  defp encode_agenda_state(%{active: false}) do
    Jason.encode!(%{active: false})
  end

  defp encode_agenda_state(agenda) do
    Jason.encode!(%{
      active: true,
      definition_name: agenda.definition_name,
      body: agenda.body,
      sections: encode_sections(agenda.sections),
      conditions: encode_conditions(agenda.conditions),
      activated_at_turn: agenda.activated_at_turn,
      last_eval_turn: agenda.last_eval_turn,
      last_eval_message_count: agenda[:last_eval_message_count]
    })
  end

  defp encode_sections(sections) do
    Enum.map(sections, fn s ->
      %{
        topic: s.topic,
        prose: s.prose,
        conditions: s.conditions,
        children: encode_sections(s[:children] || [])
      }
    end)
  end

  defp encode_conditions(conditions) do
    Enum.map(conditions, fn c ->
      %{
        index: c.index,
        criterion: c.criterion,
        section_topic: c.section_topic,
        status: to_string(c.status)
      }
    end)
  end

  defp rehydrate_agenda(persisted) do
    %{
      active: true,
      definition_name: persisted["definition_name"],
      body: persisted["body"],
      sections: rehydrate_sections(persisted["sections"] || []),
      conditions: rehydrate_conditions(persisted["conditions"] || []),
      activated_at_turn: persisted["activated_at_turn"] || 0,
      last_eval_turn: persisted["last_eval_turn"] || 0,
      last_eval_message_count: persisted["last_eval_message_count"] || 0
    }
  end

  defp rehydrate_sections(sections) do
    Enum.map(sections, fn s ->
      %{
        topic: s["topic"],
        prose: s["prose"] || "",
        conditions: s["conditions"] || [],
        children: rehydrate_sections(s["children"] || [])
      }
    end)
  end

  defp rehydrate_conditions(conditions) do
    Enum.map(conditions, fn c ->
      %{
        index: c["index"],
        criterion: c["criterion"],
        section_topic: c["section_topic"],
        status: String.to_existing_atom(c["status"])
      }
    end)
  end

  # --- Tool Definitions ---

  defp build_tool_definitions(definitions) do
    agenda_list =
      definitions
      |> Enum.map_join("\n", fn d -> "- #{d.name}: #{d.description}" end)

    [
      %{
        name: "activate_agenda",
        description:
          "Activate a meeting agenda. Available agendas:\n#{agenda_list}",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "name" => %{
              "type" => "string",
              "description" => "Name of the agenda to activate"
            },
            "params" => %{
              "type" => "object",
              "description" =>
                "Optional parameters for dynamic agendas (passed as env vars to init script)"
            }
          },
          "required" => ["name"]
        }
      },
      %{
        name: "end_agenda",
        description: "End the current active agenda and get a completion summary.",
        input_schema: %{
          "type" => "object",
          "properties" => %{}
        }
      },
      %{
        name: "agenda_status",
        description: "Get the current agenda's full progress and status.",
        input_schema: %{
          "type" => "object",
          "properties" => %{}
        }
      },
      %{
        name: "agenda_skip",
        description:
          "Skip a condition in the active agenda. The sidecar may still mark it complete if the conversation addresses it.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "condition_index" => %{
              "type" => "integer",
              "description" => "Index of the condition to skip"
            },
            "condition_text" => %{
              "type" => "string",
              "description" => "Text of the condition to skip (alternative to index)"
            }
          }
        }
      }
    ]
  end
end
