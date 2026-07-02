defmodule Cranium.Macro.Definition do
  @moduledoc """
  Macro definition struct and JSON parser.

  A macro is defined by six axes (trigger, advertising, lifecycle, learning,
  revision, disposition) plus a body type (prompt, script, sequence). This
  module handles parsing JSON definitions into validated structs.
  """

  defstruct [
    # Bare atoms (required fields — no default)
    :name,
    :description,
    :trigger,
    :advertising,
    :lifecycle,
    :learning,
    :revision,
    :disposition,
    :body_type,
    # Keyword pairs (optional/defaulted fields)
    version: nil,
    match_config: nil,
    discoverable_config: nil,
    sidecar_config: nil,
    revision_config: nil,
    prompt_body: nil,
    script_body: nil,
    sequence_body: nil,
    tools: [],
    children: [],
    conditions: [],
    input_schema: nil,
    state_schema: nil,
    tags: [],
    source: nil,
    source_path: nil
  ]

  @type trigger :: :explicit | :match | :ambient | :passive
  @type advertising :: :listed | :discoverable | :searchable | :hidden
  @type lifecycle :: :turn | :epoch | :session | :condition | :parent
  @type learning :: :none | :self_report | :sidecar | :structured
  @type revision :: :never | :session_end | :on_condition
  @type disposition :: :foreground | :background | :gated
  @type body_type :: :prompt | :script | :sequence
  @type on_failure :: :halt | :skip | :abort
  @type tool_handler :: :script | :self_report

  @type match_config :: %{patterns: [String.t()], once: boolean()}
  @type discoverable_config :: %{keywords: [String.t()]}
  @type sidecar_config :: %{model: String.t() | nil, interval: pos_integer(), prompt: String.t()}
  @type revision_config :: %{prompt: String.t(), condition: String.t() | nil}
  @type prompt_body :: %{text: String.t(), tag: String.t() | nil, priority: integer() | nil}
  @type script_body :: %{
          command: String.t(),
          timeout_seconds: integer() | nil,
          sandbox: boolean() | nil
        }
  @type sequence_body :: %{steps: [macro_ref()], on_failure: on_failure()}
  @type macro_ref :: %{name: String.t() | nil, inline: t() | nil}
  @type tool_def :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          handler: tool_handler()
        }
  @type condition_def :: %{description: String.t(), section: String.t() | nil}

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          version: integer() | nil,
          trigger: trigger(),
          match_config: match_config() | nil,
          advertising: advertising(),
          discoverable_config: discoverable_config() | nil,
          lifecycle: lifecycle(),
          learning: learning(),
          sidecar_config: sidecar_config() | nil,
          revision: revision(),
          revision_config: revision_config() | nil,
          disposition: disposition(),
          body_type: body_type(),
          prompt_body: prompt_body() | nil,
          script_body: script_body() | nil,
          sequence_body: sequence_body() | nil,
          tools: [tool_def()],
          children: [t()],
          conditions: [condition_def()],
          state_schema: map() | nil,
          tags: [String.t()],
          source: String.t() | nil,
          source_path: String.t() | nil
        }

  # --- Axis enums ---

  @triggers ~w(explicit match ambient passive)a
  @advertisings ~w(listed discoverable searchable hidden)a
  @lifecycles ~w(turn epoch session condition parent)a
  @learnings ~w(none self_report sidecar structured)a
  @revisions ~w(never session_end on_condition)a
  @dispositions ~w(foreground background gated)a
  @body_types ~w(prompt script sequence)a
  @on_failures ~w(halt skip abort)a
  @tool_handlers ~w(script self_report)a

  # --- Public API ---

  @doc "Parse a decoded JSON map into a validated MacroDefinition."
  @spec parse(map()) :: {:ok, t()} | {:error, String.t()}
  def parse(json) when is_map(json) do
    with {:ok, name} <- require_string(json, "name"),
         {:ok, description} <- require_string(json, "description"),
         {:ok, trigger} <- parse_enum(json, "trigger", @triggers),
         {:ok, advertising} <- parse_enum(json, "advertising", @advertisings),
         {:ok, lifecycle} <- parse_enum(json, "lifecycle", @lifecycles),
         {:ok, learning} <- parse_enum(json, "learning", @learnings),
         {:ok, revision} <- parse_enum(json, "revision", @revisions),
         {:ok, disposition} <- parse_enum(json, "disposition", @dispositions),
         {:ok, body_type} <- parse_enum(json, "body_type", @body_types),
         {:ok, match_config} <- parse_match_config(json, trigger),
         {:ok, discoverable_config} <- parse_discoverable_config(json, advertising),
         {:ok, sidecar_config} <- parse_sidecar_config(json, learning),
         {:ok, revision_config} <- parse_revision_config(json, revision),
         {:ok, prompt_body} <- parse_prompt_body(json, body_type),
         {:ok, script_body} <- parse_script_body(json, body_type),
         {:ok, sequence_body} <- parse_sequence_body(json, body_type),
         {:ok, tools} <- parse_tools(json),
         {:ok, children} <- parse_children(json),
         {:ok, conditions} <- parse_conditions(json) do
      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         version: json["version"],
         trigger: trigger,
         match_config: match_config,
         advertising: advertising,
         discoverable_config: discoverable_config,
         lifecycle: lifecycle,
         learning: learning,
         sidecar_config: sidecar_config,
         revision: revision,
         revision_config: revision_config,
         disposition: disposition,
         body_type: body_type,
         prompt_body: prompt_body,
         script_body: script_body,
         sequence_body: sequence_body,
         tools: tools,
         children: children,
         conditions: conditions,
         input_schema: json["input_schema"],
         state_schema: json["state_schema"],
         tags: json["tags"] || [],
         source: json["source"]
       }}
    end
  end

  def parse(_), do: {:error, "definition must be a JSON object"}

  # --- Axis config parsers ---

  defp parse_match_config(json, :match) do
    case json["match_config"] do
      %{"patterns" => patterns} when is_list(patterns) and patterns != [] ->
        unless Enum.all?(patterns, &is_binary/1) do
          {:error, "match_config.patterns must be a list of strings"}
        else
          {:ok, %{patterns: patterns, once: json["match_config"]["once"] == true}}
        end

      nil ->
        {:error, "match_config is required when trigger = match"}

      _ ->
        {:error, "match_config.patterns must be a non-empty list of strings"}
    end
  end

  defp parse_match_config(_json, _trigger), do: {:ok, nil}

  defp parse_discoverable_config(json, :discoverable) do
    case json["discoverable_config"] do
      %{"keywords" => keywords} when is_list(keywords) and keywords != [] ->
        unless Enum.all?(keywords, &is_binary/1) do
          {:error, "discoverable_config.keywords must be a list of strings"}
        else
          {:ok, %{keywords: keywords}}
        end

      nil ->
        {:error, "discoverable_config is required when advertising = discoverable"}

      _ ->
        {:error, "discoverable_config.keywords must be a non-empty list of strings"}
    end
  end

  defp parse_discoverable_config(_json, _advertising), do: {:ok, nil}

  defp parse_sidecar_config(json, :sidecar) do
    case json["sidecar_config"] do
      %{"prompt" => prompt, "interval" => interval}
      when is_binary(prompt) and is_integer(interval) and interval > 0 ->
        {:ok, %{model: json["sidecar_config"]["model"], interval: interval, prompt: prompt}}

      nil ->
        {:error, "sidecar_config is required when learning = sidecar"}

      _ ->
        {:error, "sidecar_config requires prompt (string) and interval (positive integer)"}
    end
  end

  defp parse_sidecar_config(_json, _learning), do: {:ok, nil}

  defp parse_revision_config(json, revision) when revision in [:session_end, :on_condition] do
    case json["revision_config"] do
      %{"prompt" => prompt} when is_binary(prompt) ->
        {:ok, %{prompt: prompt, condition: json["revision_config"]["condition"]}}

      nil ->
        {:error, "revision_config is required when revision != never"}

      _ ->
        {:error, "revision_config.prompt must be a string"}
    end
  end

  defp parse_revision_config(_json, :never), do: {:ok, nil}

  # --- Body parsers ---

  defp parse_prompt_body(json, :prompt) do
    case json["prompt_body"] do
      %{"text" => text} when is_binary(text) ->
        {:ok,
         %{text: text, tag: json["prompt_body"]["tag"], priority: json["prompt_body"]["priority"]}}

      nil ->
        {:error, "prompt_body is required when body_type = prompt"}

      _ ->
        {:error, "prompt_body.text must be a string"}
    end
  end

  defp parse_prompt_body(_json, _body_type), do: {:ok, nil}

  defp parse_script_body(json, :script) do
    case json["script_body"] do
      %{"command" => command} when is_binary(command) ->
        {:ok,
         %{
           command: command,
           timeout_seconds: json["script_body"]["timeout_seconds"],
           sandbox: json["script_body"]["sandbox"]
         }}

      nil ->
        {:error, "script_body is required when body_type = script"}

      _ ->
        {:error, "script_body.command must be a string"}
    end
  end

  defp parse_script_body(_json, _body_type), do: {:ok, nil}

  defp parse_sequence_body(json, :sequence) do
    case json["sequence_body"] do
      %{"steps" => steps} when is_list(steps) and steps != [] ->
        with {:ok, on_failure} <- parse_on_failure(json["sequence_body"]),
             {:ok, parsed_steps} <- parse_steps(steps) do
          {:ok, %{steps: parsed_steps, on_failure: on_failure}}
        end

      nil ->
        {:error, "sequence_body is required when body_type = sequence"}

      _ ->
        {:error, "sequence_body.steps must be a non-empty list"}
    end
  end

  defp parse_sequence_body(_json, _body_type), do: {:ok, nil}

  defp parse_on_failure(%{"on_failure" => value}) when is_binary(value) do
    parse_enum(%{"on_failure" => value}, "on_failure", @on_failures)
  end

  defp parse_on_failure(_), do: {:ok, :halt}

  defp parse_steps(steps) do
    steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {step, idx}, {:ok, acc} ->
      case parse_step(step, idx) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp parse_step(%{"name" => name}, _idx) when is_binary(name) do
    {:ok, %{name: name, inline: nil}}
  end

  defp parse_step(%{"inline" => inline_json}, idx) when is_map(inline_json) do
    case parse(inline_json) do
      {:ok, definition} -> {:ok, %{name: nil, inline: definition}}
      {:error, reason} -> {:error, "step[#{idx}].inline: #{reason}"}
    end
  end

  defp parse_step(_, idx) do
    {:error, "step[#{idx}] must have either 'name' (string) or 'inline' (object)"}
  end

  # --- Tools parser ---

  defp parse_tools(%{"tools" => tools}) when is_list(tools) do
    tools
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {tool, idx}, {:ok, acc} ->
      case parse_tool(tool, idx) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp parse_tools(_), do: {:ok, []}

  defp parse_tool(tool, idx) do
    with {:ok, name} <- require_string(tool, "name", "tools[#{idx}]"),
         {:ok, description} <- require_string(tool, "description", "tools[#{idx}]"),
         {:ok, handler} <- parse_enum(tool, "handler", @tool_handlers, "tools[#{idx}]") do
      {:ok,
       %{
         name: name,
         description: description,
         input_schema: tool["input_schema"] || %{},
         handler: handler
       }}
    end
  end

  # --- Children parser (recursive) ---

  defp parse_children(%{"children" => children}) when is_list(children) do
    children
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {child, idx}, {:ok, acc} ->
      case parse(child) do
        {:ok, definition} -> {:cont, {:ok, [definition | acc]}}
        {:error, reason} -> {:halt, {:error, "children[#{idx}]: #{reason}"}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp parse_children(_), do: {:ok, []}

  # --- Conditions parser ---

  defp parse_conditions(%{"conditions" => conditions}) when is_list(conditions) do
    conditions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {cond_json, idx}, {:ok, acc} ->
      case parse_condition(cond_json, idx) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp parse_conditions(_), do: {:ok, []}

  defp parse_condition(cond_json, idx) do
    case cond_json do
      %{"description" => desc} when is_binary(desc) ->
        {:ok, %{description: desc, section: cond_json["section"]}}

      _ ->
        {:error, "conditions[#{idx}].description must be a string"}
    end
  end

  # --- Helpers ---

  defp require_string(map, key, prefix \\ nil) do
    case map[key] do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        label = if prefix, do: "#{prefix}.#{key}", else: key
        {:error, "#{label} is required and must be a non-empty string"}
    end
  end

  defp parse_enum(map, key, allowed, prefix \\ nil) do
    label = if prefix, do: "#{prefix}.#{key}", else: key

    case map[key] do
      value when is_binary(value) ->
        atom = String.to_atom(value)

        if atom in allowed do
          {:ok, atom}
        else
          {:error, "#{label} must be one of: #{Enum.join(allowed, ", ")}"}
        end

      nil ->
        {:error, "#{label} is required"}

      _ ->
        {:error, "#{label} must be a string"}
    end
  end
end
