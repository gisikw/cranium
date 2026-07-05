defmodule Cranium.Context.BeliefInjection do
  @moduledoc """
  Pure decision logic for the gee belief-block injection.

  Session start: inject the pinned core-self set plus the surfaced band as
  one compact block. Mid-session: reinject only when the set of belief IDs
  changes between bridge snapshots (a belief entering or leaving the band)
  — never every turn.

  Budget: a hard ceiling (default 5%) of the working context, enforced
  here. Pinned beliefs are kept first, then the surfaced band in the
  artifact's activation order — when the block would exceed budget the
  tail is dropped (highest activation wins), and the drop count is
  reported for the injection manifest.
  """

  @default_budget_fraction 0.05
  @default_context_window 200_000
  # Matches the estimate heuristic in Cranium.Inference.Harness: ~4 chars
  # per token, conservative for English/code.
  @chars_per_token 4

  @type meta :: %{
          block: String.t(),
          ids: [String.t()],
          tokens: non_neg_integer(),
          kind: :session_start | :delta,
          dropped: non_neg_integer()
        }

  @doc """
  Decide whether this turn gets a belief block.

  Options:

    * `:is_fresh` — first turn of the epoch (session start)
    * `:last_belief_ids` — IDs injected last time, `nil` if never injected
      this epoch
    * `:context_window` — working context size in tokens (default 200k)
    * `:budget_fraction` — ceiling as a fraction of context (default 0.05)
  """
  @spec decide(Cranium.Context.BeliefBridge.snapshot(), map()) :: {:inject, meta()} | :skip
  def decide(snapshot, opts) do
    kind = injection_kind(snapshot, opts)

    if kind do
      budget = budget_tokens(opts)
      {pinned, surfaced, dropped} = fit_to_budget(snapshot.pinned, snapshot.surfaced, budget)

      case pinned ++ surfaced do
        [] ->
          :skip

        included ->
          block = format_block(pinned, surfaced)

          {:inject,
           %{
             block: block,
             ids: Enum.map(included, & &1.id),
             tokens: estimate_tokens(block),
             kind: kind,
             dropped: dropped
           }}
      end
    else
      :skip
    end
  end

  defp injection_kind(snapshot, opts) do
    cond do
      opts[:is_fresh] -> :session_start
      changed?(snapshot, opts[:last_belief_ids]) -> :delta
      true -> nil
    end
  end

  # Membership change only — confidence or status drift on a belief already
  # in context does not retrigger injection.
  defp changed?(snapshot, last_ids) do
    current = MapSet.new(snapshot.pinned ++ snapshot.surfaced, & &1.id)
    MapSet.new(last_ids || []) != current
  end

  defp budget_tokens(opts) do
    window = opts[:context_window] || @default_context_window
    fraction = opts[:budget_fraction] || @default_budget_fraction
    trunc(window * fraction)
  end

  # Reminder wrapper + preamble + counts line, approximate. Only an
  # initial guess — the exact check below formats the candidate block.
  @frame_overhead_tokens 50

  # Keep a prefix of pinned-then-surfaced (already activation-descending
  # from the bridge) whose formatted block fits the budget — pinned
  # outrank the band, higher activation outranks lower. The ceiling is
  # hard: the guess from per-line estimates is shrunk until the actual
  # block estimate fits.
  defp fit_to_budget(pinned, surfaced, budget) do
    total = length(pinned) + length(surfaced)

    guess =
      (pinned ++ surfaced)
      |> Enum.map(&(estimate_tokens(&1.line) + 1))
      |> Enum.scan(@frame_overhead_tokens, &(&1 + &2))
      |> Enum.take_while(&(&1 <= budget))
      |> length()

    kept_count = shrink_until_fits(pinned, surfaced, min(guess + 1, total), budget)
    {pinned_kept, surfaced_kept} = split_kept(pinned, surfaced, kept_count)
    {pinned_kept, surfaced_kept, total - kept_count}
  end

  defp shrink_until_fits(_pinned, _surfaced, 0, _budget), do: 0

  defp shrink_until_fits(pinned, surfaced, count, budget) do
    {p, s} = split_kept(pinned, surfaced, count)

    if estimate_tokens(format_block(p, s)) <= budget do
      count
    else
      shrink_until_fits(pinned, surfaced, count - 1, budget)
    end
  end

  defp split_kept(pinned, surfaced, count) do
    p = Enum.take(pinned, min(length(pinned), count))
    {p, Enum.take(surfaced, count - length(p))}
  end

  defp format_block(pinned, surfaced) do
    lines =
      [~s(<beliefs pinned="#{length(pinned)}" surfaced="#{length(surfaced)}">)] ++
        Enum.map(pinned, & &1.line) ++
        separator(pinned, surfaced) ++
        Enum.map(surfaced, & &1.line) ++
        ["</beliefs>"]

    "<system-reminder>\nYour beliefs (gee ledger; pinned core-self first, then the surfaced band; id, statement, confidence, flags):\n" <>
      Enum.join(lines, "\n") <> "\n</system-reminder>"
  end

  defp separator([_ | _], [_ | _]), do: ["---"]
  defp separator(_, _), do: []

  @doc "Estimate token count for a block of injected text."
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  def estimate_tokens(text), do: div(String.length(text) + @chars_per_token - 1, @chars_per_token)
end
