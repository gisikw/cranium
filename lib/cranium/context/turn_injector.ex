defmodule Cranium.Context.TurnInjector do
  @moduledoc """
  Adds per-turn context injections to the message.

  These are conditional, position-sensitive additions to the user message
  that provide temporal and state awareness. They are prepended to the
  user's message as `<system-reminder>` blocks.

  ## Injections

  - **Time-gap reminder** — if >30 minutes since last invocation, inject
    elapsed time, current time, and optionally the cross-room landscape
  - **Saturation warning** — rising-edge detection at 5% bucket boundaries
    above 50% context utilization
  - **Interrupted context** — if the previous invocation was cancelled,
    include a breadcrumb summarizing what was in progress
  - **Resume breadcrumb** — after a process restart, include context about
    the prior session state

  ## Design Note

  This was called "System Reminder Decorator" in the original architecture
  diagram. Renamed to TurnInjector because it's not limited to system
  reminders — any per-turn, conditional context addition belongs here.
  The step name should describe the mechanism, not one use case.
  """

  @time_gap_threshold_seconds 1800
  @saturation_warn_threshold 50
  @saturation_bucket_size 5

  @spec process(map(), map()) :: {:ok, map()}
  def process(message, context) do
    injections = build_injections(message, context)

    case injections do
      [] ->
        {:ok, message}

      _ ->
        prefix = Enum.join(injections, "\n\n")
        text = prefix <> "\n" <> (message[:text] || "")
        {:ok, %{message | text: text}}
    end
  end

  @doc """
  Build the list of injections for this turn. Pure function.
  """
  @spec build_injections(map(), map()) :: [String.t()]
  def build_injections(message, context) do
    []
    |> maybe_add_time_gap(message, context)
    |> maybe_add_saturation(message, context)
    |> maybe_add_interrupted(message, context)
    |> maybe_add_resume(message, context)
    |> Enum.reverse()
  end

  defp maybe_add_time_gap(injections, _message, context) do
    last_invoked = get_in(context, [:session, :last_invoked_at])
    now = Map.get(context, :now, DateTime.utc_now())

    case last_invoked do
      nil ->
        injections

      ts ->
        elapsed = DateTime.diff(now, ts, :second)

        if elapsed >= @time_gap_threshold_seconds do
          reminder = format_time_gap(elapsed, now)
          [reminder | injections]
        else
          injections
        end
    end
  end

  defp maybe_add_saturation(injections, _message, context) do
    current = get_in(context, [:session, :saturation]) || 0
    last_bucket = get_in(context, [:session, :last_reminder_bucket]) || 0
    current_bucket = div(trunc(current), @saturation_bucket_size) * @saturation_bucket_size

    if current >= @saturation_warn_threshold and current_bucket > last_bucket do
      advice = saturation_advice(current)

      reminder =
        "<system-reminder>Context window saturation: #{trunc(current)}%. #{advice}</system-reminder>"

      [reminder | injections]
    else
      injections
    end
  end

  defp maybe_add_interrupted(injections, _message, context) do
    case get_in(context, [:session, :interrupted_context]) do
      nil ->
        injections

      "" ->
        injections

      ctx ->
        reminder =
          "<system-reminder>Your previous response was interrupted. Here's what you were working on:\n\n#{ctx}</system-reminder>"

        [reminder | injections]
    end
  end

  defp maybe_add_resume(injections, _message, context) do
    case get_in(context, [:session, :resume_breadcrumb]) do
      nil ->
        injections

      "" ->
        injections

      crumb ->
        reminder =
          "<system-reminder>Session was restarted. Previous context:\n\n#{crumb}</system-reminder>"

        [reminder | injections]
    end
  end

  defp format_time_gap(elapsed, now) do
    formatted_time = Calendar.strftime(now, "%a %b %-d, %-I:%M %p")
    human_elapsed = humanize_duration(elapsed)

    "<system-reminder>It's been #{human_elapsed} since the last message in this conversation. The current time is #{formatted_time}.</system-reminder>"
  end

  defp humanize_duration(seconds) when seconds < 3600 do
    "about #{div(seconds, 60)} minutes"
  end

  defp humanize_duration(seconds) when seconds < 86400 do
    hours = div(seconds, 3600)
    "about #{hours} #{if hours == 1, do: "hour", else: "hours"}"
  end

  defp humanize_duration(seconds) do
    days = div(seconds, 86400)
    "about #{days} #{if days == 1, do: "day", else: "days"}"
  end

  defp saturation_advice(pct) when pct >= 80 do
    "Context is getting full. Wrap up current work, capture any loose threads as tickets, and suggest a !clear."
  end

  defp saturation_advice(pct) when pct >= 70 do
    "Context is filling up. Start wrapping up — finish current task, note open threads."
  end

  defp saturation_advice(_pct) do
    "Context is past halfway. Be mindful of scope — avoid starting large new tasks."
  end
end
