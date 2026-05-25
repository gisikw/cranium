defmodule Cranium.Macro.Trigger do
  @moduledoc """
  Evaluates macro triggers against a user message.

  Given a list of macro definitions, the user's message text, and session
  state (seen-sets, discovered macros), determines which macros should fire
  and which discoverable macros should be newly advertised.

  Trigger types:
  - `explicit` — skipped (handled by tool routing, not trigger eval)
  - `match` — run pattern matcher, respect once flag via seen-set
  - `ambient` — always fires
  - `passive` — skipped (invoked by parent/sequence, not trigger eval)
  """

  alias Cranium.Macro.{Definition, Matcher}

  @type session_state :: %{
          optional(:seen) => MapSet.t(String.t()),
          optional(:discovered) => MapSet.t(String.t()),
          optional(:versions) => %{String.t() => integer()}
        }

  @type result :: %{
          firing: [Definition.t()],
          discovered: [Definition.t()],
          seen: MapSet.t(String.t()),
          discovered_set: MapSet.t(String.t())
        }

  @doc """
  Evaluate triggers for all macros against a message.

  Returns a result map with:
  - `firing` — macros that should execute this turn
  - `discovered` — macros newly discovered this turn (advertising = discoverable)
  - `seen` — updated seen-set (for once=true tracking)
  - `discovered_set` — updated discovered-set

  Session state tracks:
  - `:seen` — MapSet of macro names that have already fired (for once=true)
  - `:discovered` — MapSet of macro names already discovered
  - `:versions` — map of macro name to version when last seen (for once reset)
  """
  @spec evaluate([Definition.t()], String.t(), session_state()) :: result()
  def evaluate(macros, message_text, session_state \\ %{}) do
    seen = Map.get(session_state, :seen, MapSet.new())
    discovered = Map.get(session_state, :discovered, MapSet.new())
    versions = Map.get(session_state, :versions, %{})

    {firing, new_seen} = evaluate_triggers(macros, message_text, seen, versions)
    {newly_discovered, new_discovered} = evaluate_discovery(macros, message_text, discovered)

    %{
      firing: firing,
      discovered: newly_discovered,
      seen: new_seen,
      discovered_set: new_discovered
    }
  end

  # --- Trigger evaluation ---

  defp evaluate_triggers(macros, message_text, seen, versions) do
    Enum.reduce(macros, {[], seen}, fn macro, {acc, seen_acc} ->
      case evaluate_single(macro, message_text, seen_acc, versions) do
        {:fire, updated_seen} ->
          {[macro | acc], updated_seen}

        :skip ->
          {acc, seen_acc}
      end
    end)
    |> then(fn {firing, seen} -> {Enum.reverse(firing), seen} end)
  end

  defp evaluate_single(%{trigger: :explicit}, _text, _seen, _versions), do: :skip
  defp evaluate_single(%{trigger: :passive}, _text, _seen, _versions), do: :skip

  defp evaluate_single(%{trigger: :ambient} = _macro, _text, seen, _versions) do
    {:fire, seen}
  end

  defp evaluate_single(%{trigger: :match} = macro, text, seen, versions) do
    %{match_config: %{patterns: patterns, once: once}} = macro

    case Matcher.compile_patterns(patterns) do
      {:ok, compiled} ->
        if Matcher.match?(text, compiled) do
          if once do
            # Check if version changed (reset seen on version bump)
            was_seen = MapSet.member?(seen, macro.name)

            version_changed =
              case Map.get(versions, macro.name) do
                nil -> false
                prev_version -> prev_version != macro.version
              end

            if was_seen and not version_changed do
              :skip
            else
              {:fire, MapSet.put(seen, macro.name)}
            end
          else
            {:fire, seen}
          end
        else
          :skip
        end

      {:error, _reason} ->
        :skip
    end
  end

  # --- Discoverable advertising evaluation ---

  defp evaluate_discovery(macros, message_text, discovered) do
    macros
    |> Enum.filter(&(&1.advertising == :discoverable))
    |> Enum.reduce({[], discovered}, fn macro, {acc, disc_acc} ->
      if MapSet.member?(disc_acc, macro.name) do
        {acc, disc_acc}
      else
        keywords = get_in(macro, [Access.key(:discoverable_config), Access.key(:keywords)]) || []

        case Matcher.compile_patterns(keywords) do
          {:ok, compiled} ->
            if Matcher.match?(message_text, compiled) do
              {[macro | acc], MapSet.put(disc_acc, macro.name)}
            else
              {acc, disc_acc}
            end

          {:error, _} ->
            {acc, disc_acc}
        end
      end
    end)
    |> then(fn {newly, disc} -> {Enum.reverse(newly), disc} end)
  end
end
