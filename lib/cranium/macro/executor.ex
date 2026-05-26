defmodule Cranium.Macro.Executor do
  @moduledoc """
  Executes macro bodies (prompt, script, sequence).

  Returns `{:ok, output, new_state}` or `{:error, reason}`.

  - **Prompt**: template variable resolution + optional XML tag wrapping →
    injection `%{priority: integer(), content: String.t()}`
  - **Script**: shell out with macro env vars, respect timeout, capture stdout
  - **Sequence**: ordered step execution with on_failure handling and tempdir
  """

  require Logger

  alias Cranium.Macro.Definition

  @type context :: %{
          optional(:conversation_id) => String.t(),
          optional(:epoch_id) => String.t(),
          optional(:room_name) => String.t(),
          optional(:turn_count) => integer(),
          optional(atom()) => term()
        }

  @type injection :: %{priority: integer(), content: String.t()}
  @type output :: injection() | String.t() | nil | [injection() | String.t() | nil]
  @type result :: {:ok, output(), map()} | {:error, String.t()}

  @default_priority 50
  @default_timeout_ms 30_000

  @doc """
  Execute a macro body.

  Returns `{:ok, output, new_state}` where output is:
  - `%{priority: _, content: _}` for prompt bodies (injection)
  - `String.t()` for script bodies (stdout)
  - `nil` when there's nothing to inject (empty template, etc.)
  """
  @spec execute(Definition.t(), map(), context(), keyword()) :: result()
  def execute(macro, state, context, opts \\ [])

  def execute(%Definition{body_type: :prompt} = macro, state, context, _opts) do
    execute_prompt(macro, state, context)
  end

  def execute(%Definition{body_type: :script} = macro, state, context, _opts) do
    execute_script(macro, state, context)
  end

  def execute(%Definition{body_type: :sequence} = macro, state, context, opts) do
    execute_sequence(macro, state, context, opts)
  end

  # --- Prompt execution ---

  defp execute_prompt(%{prompt_body: %{text: text} = body}, state, context) do
    vars = Map.merge(context_to_string_map(context), state)
    resolved = resolve_template(text, vars)

    if resolved == "" do
      {:ok, nil, state}
    else
      content = wrap_tag(resolved, body[:tag])
      priority = body[:priority] || @default_priority

      {:ok, %{priority: priority, content: content}, state}
    end
  end

  # --- Script execution ---

  defp execute_script(%{script_body: body, name: name}, state, context) do
    %{command: command} = body
    timeout_ms = (body[:timeout_seconds] || div(@default_timeout_ms, 1000)) * 1000

    env = build_env(name, state, context)

    task =
      Task.async(fn ->
        try do
          System.cmd("sh", ["-c", command], env: env, stderr_to_stdout: true)
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {stdout, 0}} ->
        {:ok, String.trim(stdout), state}

      {:ok, {stdout, exit_code}} when is_integer(exit_code) ->
        {:error, "script exited with code #{exit_code}: #{String.trim(stdout)}"}

      {:ok, {:error, reason}} ->
        {:error, "script failed: #{reason}"}

      nil ->
        {:error, "script timed out after #{timeout_ms}ms"}
    end
  end

  # --- Sequence execution ---

  defp execute_sequence(%{sequence_body: %{steps: steps, on_failure: on_failure}}, state, context, opts) do
    tmpdir = create_tmpdir()
    resolver = Keyword.get(opts, :resolver, &default_resolver/1)

    try do
      execute_steps(steps, state, context, on_failure, tmpdir, resolver, [])
    after
      File.rm_rf(tmpdir)
    end
  end

  defp execute_steps([], state, _context, _on_failure, _tmpdir, _resolver, outputs) do
    {:ok, Enum.reverse(outputs), state}
  end

  defp execute_steps([step | rest], state, context, on_failure, tmpdir, resolver, outputs) do
    case resolve_step(step, resolver) do
      {:ok, macro} ->
        context_with_tmpdir = Map.put(context, :tmpdir, tmpdir)

        case execute(macro, state, context_with_tmpdir, resolver: resolver) do
          {:ok, output, new_state} ->
            execute_steps(rest, new_state, context, on_failure, tmpdir, resolver, [output | outputs])

          {:error, reason} ->
            handle_step_failure(reason, rest, state, context, on_failure, tmpdir, resolver, outputs)
        end

      {:error, reason} ->
        handle_step_failure(reason, rest, state, context, on_failure, tmpdir, resolver, outputs)
    end
  end

  defp handle_step_failure(reason, rest, state, context, on_failure, tmpdir, resolver, outputs) do
    case on_failure do
      :halt ->
        {:error, "sequence halted: #{reason}"}

      :skip ->
        Logger.warning("Macro.Executor: skipping failed step: #{reason}")
        execute_steps(rest, state, context, on_failure, tmpdir, resolver, outputs)

      :abort ->
        {:error, "sequence aborted: #{reason}"}
    end
  end

  defp resolve_step(%{inline: %Definition{} = inline}, _resolver), do: {:ok, inline}
  defp resolve_step(%{name: name}, resolver) when is_binary(name), do: resolver.(name)
  defp resolve_step(_, _), do: {:error, "step must have either name or inline definition"}

  defp default_resolver(name) do
    case Cranium.Macro.Registry.get(name) do
      {:ok, macro} -> {:ok, macro}
      :error -> {:error, "macro '#{name}' not found in registry"}
    end
  end

  # --- Template resolution ---

  defp resolve_template(text, vars) do
    Regex.replace(~r/%\{(\w+)\}/, text, fn _match, key ->
      resolve_var(vars, key)
    end)
    |> String.trim()
  end

  defp resolve_var(vars, key) do
    case Map.get(vars, key) do
      nil ->
        # Try atom key — guard against non-existent atoms
        atom_key =
          try do
            String.to_existing_atom(key)
          rescue
            ArgumentError -> nil
          end

        case atom_key && Map.get(vars, atom_key) do
          nil -> ""
          value when is_binary(value) -> value
          value -> inspect(value)
        end

      value when is_binary(value) ->
        value

      value ->
        inspect(value)
    end
  end

  # --- Helpers ---

  defp wrap_tag(content, nil), do: content
  defp wrap_tag(content, tag), do: "<#{tag}>#{content}</#{tag}>"

  defp build_env(macro_name, state, context) do
    base = [
      {"MACRO_NAME", macro_name},
      {"MACRO_CONVERSATION_ID", to_string(context[:conversation_id] || "")},
      {"MACRO_EPOCH_ID", to_string(context[:epoch_id] || "")},
      {"MACRO_ROOM_NAME", to_string(context[:room_name] || "")},
      {"MACRO_TURN_COUNT", to_string(context[:turn_count] || 0)},
      {"MACRO_TMPDIR", to_string(context[:tmpdir] || "")}
    ]

    state_vars =
      state
      |> Enum.map(fn {k, v} -> {"MACRO_STATE_#{String.upcase(to_string(k))}", to_string(v)} end)

    base ++ state_vars
  end

  defp context_to_string_map(context) do
    context
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
    |> Map.new()
  end

  defp create_tmpdir do
    dir = Path.join(System.tmp_dir!(), "cranium_macro_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end
end
