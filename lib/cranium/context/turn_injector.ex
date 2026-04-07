defmodule Cranium.Context.TurnInjector do
  @moduledoc """
  Adds per-turn context injections to the message.

  These are conditional, position-sensitive additions to the user message
  that provide temporal and state awareness. They are prepended to the
  user's message as `<system-reminder>` blocks.

  ## Injections

  - **Landscape** — cross-conversation awareness. Injected on turn 1
    (full) and on idle return (delta since last injection).
  - **Time-gap reminder** — if >30 minutes since last invocation, inject
    elapsed time and current time
  - **Saturation warning** — rising-edge detection at 5% bucket boundaries
    above 50% context utilization
  - **Interrupted context** — if the previous invocation was cancelled,
    include a breadcrumb summarizing what was in progress

  ## Design Note

  This was called "System Reminder Decorator" in the original architecture
  diagram. Renamed to TurnInjector because it's not limited to system
  reminders — any per-turn, conditional context addition belongs here.
  The step name should describe the mechanism, not one use case.
  """

  @time_gap_threshold_seconds 1800
  @default_saturation_warn 50
  @default_saturation_critical 80
  @saturation_bucket_size 5

  @spec process(map(), map()) :: {:ok, map()}
  def process(message, context) do
    {injections, landscape_injected, saturation_bucket} = build_injections(message, context)

    message =
      case injections do
        [] ->
          message

        _ ->
          prefix = Enum.join(injections, "\n\n")
          text = prefix <> "\n" <> (message[:text] || "")
          %{message | text: text}
      end

    message =
      if landscape_injected,
        do: Map.put(message, :landscape_injected, true),
        else: message

    message =
      if saturation_bucket,
        do: Map.put(message, :saturation_warned_bucket, saturation_bucket),
        else: message

    {:ok, message}
  end

  @doc """
  Build the list of injections for this turn.

  Returns `{injections, landscape_injected}` where the boolean signals
  to the Epoch that `last_landscape_at` should be updated.
  """
  @spec build_injections(map(), map()) :: {[String.t()], boolean(), non_neg_integer() | nil}
  def build_injections(message, context) do
    {landscape_block, landscape_injected} = resolve_landscape(message, context)

    injections =
      []
      |> maybe_add_time_gap(message, context)
      |> maybe_add_fresh_time(message, context)
      |> maybe_prepend(landscape_block)
      |> maybe_add_saturation(message, context)
      |> maybe_add_interrupted(message, context)
      |> Enum.reverse()

    saturation_bucket = saturation_fired_bucket(context)

    {injections, landscape_injected, saturation_bucket}
  end

  defp maybe_add_time_gap(injections, _message, context) do
    last_invoked = get_in(context, [:epoch, :last_invoked_at])
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

  # On fresh epochs (no prior messages), inject the current time so the session
  # isn't flying blind until the first idle gap fires.
  defp maybe_add_fresh_time(injections, message, context) do
    last_invoked = get_in(context, [:epoch, :last_invoked_at])

    if message[:is_fresh] == true and is_nil(last_invoked) do
      now = Map.get(context, :now, DateTime.utc_now())
      [format_current_time(now) | injections]
    else
      injections
    end
  end

  defp maybe_add_saturation(injections, _message, context) do
    current = get_in(context, [:epoch, :saturation]) || 0
    last_bucket = get_in(context, [:epoch, :last_reminder_bucket]) || 0
    warn = context[:saturation_warn] || @default_saturation_warn
    critical = context[:saturation_critical] || @default_saturation_critical
    current_bucket = div(trunc(current), @saturation_bucket_size) * @saturation_bucket_size

    if current >= warn and current_bucket > last_bucket do
      advice = saturation_advice(current, critical)

      reminder =
        "<system-reminder>Context window saturation: #{trunc(current)}%. #{advice}</system-reminder>"

      [reminder | injections]
    else
      injections
    end
  end

  # Returns the bucket value when a saturation warning fires, nil otherwise.
  # Mirrors the condition in maybe_add_saturation/3.
  defp saturation_fired_bucket(context) do
    current = get_in(context, [:epoch, :saturation]) || 0
    last_bucket = get_in(context, [:epoch, :last_reminder_bucket]) || 0
    warn = context[:saturation_warn] || @default_saturation_warn
    current_bucket = div(trunc(current), @saturation_bucket_size) * @saturation_bucket_size

    if current >= warn and current_bucket > last_bucket do
      current_bucket
    end
  end

  defp maybe_add_interrupted(injections, _message, context) do
    case get_in(context, [:epoch, :interrupted_context]) do
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

  defp format_time_gap(elapsed, now) do
    human_elapsed = humanize_duration(elapsed)

    "<system-reminder>It's been #{human_elapsed} since the last message in this conversation. #{format_central_time(now)}</system-reminder>"
  end

  defp format_current_time(now) do
    "<system-reminder>#{format_central_time(now)}</system-reminder>"
  end

  defp format_central_time(now) do
    local = DateTime.add(now, central_offset(now), :second)
    formatted_time = Calendar.strftime(local, "%a %b %-d, %-I:%M %p")
    "The current time is #{formatted_time} Central."
  end

  # US Central: CDT (UTC-5) from 2nd Sunday in March to 1st Sunday in November,
  # CST (UTC-6) otherwise.
  defp central_offset(utc_dt) do
    year = utc_dt.year

    # 2nd Sunday in March
    march_start = dst_transition(year, 3, 2)
    # 1st Sunday in November
    nov_end = dst_transition(year, 11, 1)

    date = DateTime.to_date(utc_dt)

    if Date.compare(date, march_start) in [:gt, :eq] and Date.compare(date, nov_end) == :lt do
      -5 * 3600
    else
      -6 * 3600
    end
  end

  defp dst_transition(year, month, nth_sunday) do
    first = Date.new!(year, month, 1)
    day_of_week = Date.day_of_week(first)
    # Days until first Sunday (Sunday = 7 in ISO)
    days_to_sunday = rem(7 - day_of_week, 7)
    Date.add(first, days_to_sunday + (nth_sunday - 1) * 7)
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

  defp saturation_advice(pct, critical) when pct >= critical do
    "Context is getting full. Wrap up current work, capture any loose threads as tickets, and suggest a !clear."
  end

  defp saturation_advice(pct, critical) when pct >= critical - 10 do
    "Context is filling up. Start wrapping up — finish current task, note open threads."
  end

  defp saturation_advice(_pct, _critical) do
    "Context is past halfway. Be mindful of scope — avoid starting large new tasks."
  end

  # --- Landscape ---

  defp resolve_landscape(message, context) do
    now = context_now(context)

    cond do
      message[:is_fresh] ->
        case Cranium.Inference.Landscape.build(message[:conversation_id], now: now) do
          nil -> {nil, false}
          block -> {block, true}
        end

      time_gap_elapsed?(context) ->
        last_landscape = get_in(context, [:epoch, :last_landscape_at])

        case Cranium.Inference.Landscape.build(message[:conversation_id],
               since: last_landscape,
               now: now
             ) do
          nil -> {nil, false}
          block -> {block, true}
        end

      true ->
        {nil, false}
    end
  end

  defp time_gap_elapsed?(context) do
    last_invoked = get_in(context, [:epoch, :last_invoked_at])
    now = context_now(context)

    case last_invoked do
      nil -> false
      ts -> DateTime.diff(now, ts, :second) >= @time_gap_threshold_seconds
    end
  end

  defp maybe_prepend(injections, nil), do: injections
  defp maybe_prepend(injections, block), do: [block | injections]

  defp context_now(context), do: Map.get(context, :now, DateTime.utc_now())
end
