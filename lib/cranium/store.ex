defmodule Cranium.Store do
  @moduledoc """
  Persistence stage.

  Central storage service with soft read/write locking during active
  inference. All database access from pipeline stages goes through this
  module — no direct Repo calls.

  ## Locking Model

  Store uses per-conversation soft locks:
  - Reads are always allowed (no lock needed)
  - Writes during active inference for the same conversation queue behind
    the inference (soft lock via GenServer message ordering)
  - Lock scope is per-conversation, never global

  ## Entities

  - **Epochs** — per-conversation state (status, saturation, turn count)
  - **Messages** — conversation history (role, content)
  - **Handoffs** — stored as a text field on the epoch row
  - **Summaries** — cross-conversation awareness cache
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Cranium.Store.{
    Repo,
    Epoch,
    Message,
    Summary,
    EnsembleSelection,
    RoomEvent,
    RoomReadMarker
  }

  defstruct locks: %{}

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  # Epoch operations

  @spec get_epoch(String.t()) :: {:ok, map()} | :not_found
  def get_epoch(conversation_id) do
    GenServer.call(__MODULE__, {:get_epoch, conversation_id})
  end

  @spec create_epoch(String.t(), map()) :: {:ok, String.t()}
  def create_epoch(conversation_id, attrs \\ %{}) do
    GenServer.call(__MODULE__, {:create_epoch, conversation_id, attrs})
  end

  @spec update_epoch(String.t(), map()) :: :ok
  def update_epoch(epoch_id, attrs) do
    GenServer.call(__MODULE__, {:update_epoch, epoch_id, attrs})
  end

  # Message operations

  @spec append_message(String.t(), String.t(), map()) :: {:ok, Cranium.Store.Message.t()}
  def append_message(conversation_id, epoch_id, message) do
    GenServer.call(__MODULE__, {:append_message, conversation_id, epoch_id, message})
  end

  @spec get_messages(String.t(), keyword()) :: {:ok, [map()]} | {:error, :db_error}
  def get_messages(conversation_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_messages, conversation_id, opts})
  end

  @doc """
  Apply Tiamat normalization assignments to already-persisted transcript rows.

  Tiamat selectors may address request messages by durable id or by request index.
  Cranium owns persisted message ids and inserted_at timestamps, so conflicting
  assignments for those fields are ignored; parentage and provenance are safe
  mechanical decorations and are applied when resolvable.
  """
  @spec apply_tiamat_normalization_delta(String.t(), String.t(), [map()], map() | nil) ::
          {:ok, %{applied: non_neg_integer(), skipped: non_neg_integer()}} | {:error, :db_error}
  def apply_tiamat_normalization_delta(conversation_id, epoch_id, request_messages, delta) do
    GenServer.call(
      __MODULE__,
      {:apply_tiamat_normalization_delta, conversation_id, epoch_id, request_messages, delta}
    )
  end

  @doc """
  Paginated message listing for API consumers.

  Options:
  - `:before` — `DateTime` cursor; only messages inserted before this time
  - `:limit` — max messages to return (default 50, clamped 1..200)

  Returns messages in reverse chronological order (newest first).
  Returns `{:ok, %{messages: [map()], has_more: boolean()}}`.
  """
  @spec list_messages(String.t(), keyword()) ::
          {:ok, %{messages: [map()], has_more: boolean()}} | {:error, :db_error}
  def list_messages(conversation_id, opts \\ []) do
    GenServer.call(__MODULE__, {:list_messages, conversation_id, opts})
  end

  @doc """
  Recent messages as raw Message structs for TranscriptMessage projection.

  Returns `{:ok, %{messages: [Message.t()], has_more: boolean()}}`.
  Messages are in chronological order (oldest first).
  """
  @spec recent_message_structs(String.t(), keyword()) ::
          {:ok, %{messages: [Message.t()], has_more: boolean()}} | {:error, :db_error}
  def recent_message_structs(conversation_id, opts \\ []) do
    GenServer.call(__MODULE__, {:recent_message_structs, conversation_id, opts})
  end

  @doc """
  Paginated transcript scrollback as raw Message structs.

  Options:
  - `:before` — message ID cursor; returns messages older than this
  - `:after` — message ID cursor; returns messages newer than this
  - `:limit` — max messages to return (default 50, clamped 1..200)

  With `:before`, returns messages in reverse chronological order (newest first).
  With `:after`, returns messages in chronological order (oldest first).
  Returns `{:ok, %{messages: [Message.t()], has_more: boolean()}}`.
  """
  @spec transcript_page(String.t(), keyword()) ::
          {:ok, %{messages: [Message.t()], has_more: boolean()}} | {:error, :db_error}
  def transcript_page(conversation_id, opts \\ []) do
    GenServer.call(__MODULE__, {:transcript_page, conversation_id, opts})
  end

  # Handoff operations

  @spec save_handoff(String.t(), String.t()) :: :ok
  def save_handoff(epoch_id, content) do
    GenServer.call(__MODULE__, {:save_handoff, epoch_id, content})
  end

  @spec get_latest_handoff(String.t()) :: {:ok, String.t()} | :not_found
  def get_latest_handoff(conversation_id) do
    GenServer.call(__MODULE__, {:get_latest_handoff, conversation_id})
  end

  @doc """
  Eagerly persist the CC session ID for a conversation's active epoch.

  Called mid-inference by the Agent so a process restart doesn't lose
  the session ID (which would cause CC to start a fresh session with
  no conversation history).
  """
  @spec update_epoch_session(String.t(), String.t()) :: :ok
  def update_epoch_session(conversation_id, session_id) do
    GenServer.call(__MODULE__, {:update_epoch_session, conversation_id, session_id})
  end

  @doc """
  Clear the active epoch for a conversation directly in the DB.

  Used when no Epoch GenServer is running (e.g., after a service restart).
  Marks the current epoch as cleared and creates a fresh one. Skips handoff
  generation since there's no running session to summarize.

  Returns `{:ok, new_epoch_id}` or `:not_found`.

  If `continuation` is provided, it's stored on the new epoch for the
  ContinuationDispatcher to pick up after handoff completes.
  """
  @spec clear_epoch(String.t(), String.t() | nil) :: {:ok, String.t()} | :not_found
  def clear_epoch(conversation_id, continuation \\ nil) do
    GenServer.call(__MODULE__, {:clear_epoch, conversation_id, continuation})
  end

  @doc """
  Get the injection context for a conversation's active epoch.

  Returns the fields TurnInjector needs: saturation, last_reminder_bucket,
  last_landscape_at, interrupted_context. Also includes epoch_id, turn_count,
  and cc_session_id for TurnAssembler's broader context assembly needs.

  Saturation is a 0..1 fraction — the canonical scale everywhere outside
  TurnInjector, whose percent conversion happens at its call site.

  Returns :not_found if no active epoch exists.
  """
  @spec get_injection_context(String.t()) :: {:ok, map()} | :not_found
  def get_injection_context(conversation_id) do
    GenServer.call(__MODULE__, {:get_injection_context, conversation_id})
  end

  @doc """
  Get or create the active epoch for a conversation, returning injection context.

  Like `get_injection_context/1` but creates a fresh epoch if none exists.
  Used by TurnAssembler for epoch resolution without needing an Epoch GenServer.
  """
  @spec get_or_create_epoch(String.t()) :: {:ok, map()}
  def get_or_create_epoch(conversation_id) do
    GenServer.call(__MODULE__, {:get_or_create_epoch, conversation_id})
  end

  @doc """
  Get the most recently cleared epoch ID for a conversation.

  Returns nil if no cleared epochs exist (first epoch ever).
  Used by on_epoch_start to give plugins predecessor context.
  """
  @spec get_predecessor_epoch_id(String.t()) :: String.t() | nil
  def get_predecessor_epoch_id(conversation_id) do
    GenServer.call(__MODULE__, {:get_predecessor_epoch_id, conversation_id})
  end

  # Message timestamp queries

  @spec get_last_message_at(String.t()) :: {:ok, DateTime.t()} | :not_found
  def get_last_message_at(epoch_id) do
    GenServer.call(__MODULE__, {:get_last_message_at, epoch_id})
  end

  # Ensemble selection operations

  @spec save_ensemble_selection(map()) :: :ok
  def save_ensemble_selection(attrs) do
    GenServer.call(__MODULE__, {:save_ensemble_selection, attrs})
  end

  # Summary operations

  @spec save_summary(String.t(), String.t()) :: :ok
  def save_summary(conversation_id, content) do
    GenServer.call(__MODULE__, {:save_summary, conversation_id, content})
  end

  @spec get_all_summaries() :: {:ok, [map()]} | {:error, term()}
  def get_all_summaries do
    GenServer.call(__MODULE__, :get_all_summaries)
  end

  @doc "Return all distinct conversation_ids that have at least one epoch."
  @spec list_conversation_ids() :: {:ok, [String.t()]} | {:error, term()}
  def list_conversation_ids do
    GenServer.call(__MODULE__, :list_conversation_ids)
  end

  @doc """
  Transcript export for external consumers (e.g. tiamat).

  Returns messages in ascending `inserted_at` order, formatted for JSONL export.
  Excludes orientation messages. Flattens tool_calls from content blocks and
  extracts model/token counts from the usage JSONB.

  Options:
  - `:since` — `DateTime`; only messages inserted after this time
  - `:after_id` — message id cursor paired with `:since`; includes rows at the same timestamp with id greater than this value
  - `:limit` — max messages to return (default 1000, clamped 1..5000)
  - `:room` — optional conversation_id filter
  """
  @spec list_transcripts(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_transcripts(opts \\ []) do
    GenServer.call(__MODULE__, {:list_transcripts, opts}, 30_000)
  end

  # Room event operations

  @doc """
  Emit a durable room event.

  Assigns the next seq for the room within a transaction (MAX(seq)+1)
  and inserts the event. Returns the created event with its assigned seq.
  """
  @spec emit_room_event(String.t(), String.t(), map(), String.t() | nil) ::
          {:ok, map()} | {:error, :db_error}
  def emit_room_event(room_id, type, payload, correlation_id \\ nil) do
    GenServer.call(__MODULE__, {:emit_room_event, room_id, type, payload, correlation_id})
  end

  @doc """
  Fetch room events after a given seq for cursor-based replay.

  Returns events in ascending seq order. If `since_seq` is 0,
  returns from the beginning of available history.
  """
  @spec list_room_events(String.t(), integer(), keyword()) ::
          {:ok, [map()]} | {:error, :db_error}
  def list_room_events(room_id, since_seq, opts \\ []) do
    GenServer.call(__MODULE__, {:list_room_events, room_id, since_seq, opts})
  end

  @doc """
  Get the latest event seq for a room. Returns 0 if no events exist.
  Used by snapshot endpoint to stamp the cursor.
  """
  @spec latest_room_event_seq(String.t()) :: {:ok, integer()} | {:error, :db_error}
  def latest_room_event_seq(room_id) do
    GenServer.call(__MODULE__, {:latest_room_event_seq, room_id})
  end

  @doc """
  Get the oldest (minimum) event seq for a room. Returns nil if no events exist.
  Used by EventStream to detect cursor_expired condition.
  """
  @spec oldest_room_event_seq(String.t()) :: {:ok, integer() | nil}
  def oldest_room_event_seq(room_id) do
    GenServer.call(__MODULE__, {:oldest_room_event_seq, room_id})
  end

  @doc """
  Delete room events older than the given timestamp.
  Used by the age-out cleanup job.
  """
  @spec purge_room_events_before(DateTime.t()) :: {:ok, integer()} | {:error, :db_error}
  def purge_room_events_before(before) do
    GenServer.call(__MODULE__, {:purge_room_events_before, before}, 30_000)
  end

  # Read marker operations

  @doc """
  Advance the read marker for a room.

  `seq` is the room event seq the client has read through. When nil, the
  marker advances to the room's latest event seq ("mark everything read").
  The seq is clamped to the latest known seq and the marker never moves
  backwards, so stale or duplicate marks are safe no-ops.

  Returns the resulting marker (which may be the unchanged existing one).
  """
  @spec mark_room_read(String.t(), integer() | nil) :: {:ok, map()} | {:error, :db_error}
  def mark_room_read(room_id, seq \\ nil) do
    GenServer.call(__MODULE__, {:mark_room_read, room_id, seq})
  end

  @doc """
  Get the read marker for a room. Returns `{:ok, nil}` if the room has
  never been marked read.
  """
  @spec get_room_read_marker(String.t()) :: {:ok, map() | nil} | {:error, :db_error}
  def get_room_read_marker(room_id) do
    GenServer.call(__MODULE__, {:get_room_read_marker, room_id})
  end

  # --- GenServer Implementation ---

  @impl true
  def init(_opts) do
    Logger.info("Store started", stage: :store)
    {:ok, %__MODULE__{}}
  end

  # All handle_call clauses route through a rescue wrapper so that
  # transient Repo errors (or Ecto sandbox teardown in tests) never
  # crash this GenServer — which would cascade via rest_for_one and
  # take down Manifest, Egress, and everything downstream.

  @impl true
  def handle_call(request, from, state) do
    try do
      do_handle_call(request, from, state)
    rescue
      e ->
        Logger.error("Store operation failed: #{Exception.message(e)}", stage: :store)
        {:reply, {:error, :db_error}, state}
    catch
      :exit, reason ->
        Logger.error("Store operation exit: #{inspect(reason)}", stage: :store)
        {:reply, {:error, :db_error}, state}
    end
  end

  defp do_handle_call({:get_epoch, conversation_id}, _from, state) do
    result =
      from(e in Epoch,
        where: e.conversation_id == ^conversation_id and e.status != "cleared",
        order_by: [desc: e.inserted_at],
        limit: 1
      )
      |> Repo.one()
      |> case do
        nil -> :not_found
        epoch -> {:ok, epoch_to_map(epoch)}
      end

    {:reply, result, state}
  end

  defp do_handle_call({:create_epoch, conversation_id, attrs}, _from, state) do
    epoch =
      %Epoch{}
      |> Epoch.changeset(Map.put(attrs, :conversation_id, conversation_id))
      |> Repo.insert!()

    {:reply, {:ok, epoch.id}, state}
  end

  defp do_handle_call({:update_epoch, epoch_id, attrs}, _from, state) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.get!(Epoch, epoch_id)
    |> Epoch.changeset(Map.put(attrs, :updated_at, now))
    |> Repo.update!()

    {:reply, :ok, state}
  end

  defp do_handle_call({:append_message, conversation_id, epoch_id, message}, _from, state) do
    inserted =
      %Message{}
      |> Message.changeset(%{
        conversation_id: conversation_id,
        epoch_id: epoch_id,
        role: to_string(message[:role] || "user"),
        content: message[:content] || [],
        origin: message[:origin],
        usage: message[:usage],
        parent_id: message[:parent_id],
        provenance: message[:provenance]
      })
      |> Repo.insert!()

    {:reply, {:ok, inserted}, state}
  end

  defp do_handle_call({:get_messages, conversation_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit)
    epoch_id = Keyword.get(opts, :epoch_id)

    base = from(m in Message, where: m.conversation_id == ^conversation_id)

    base =
      case epoch_id do
        id when is_binary(id) -> from(m in base, where: m.epoch_id == ^id)
        _ -> base
      end

    messages =
      if limit do
        recent = from(m in base, order_by: [desc: m.inserted_at, desc: m.id], limit: ^limit)

        from(m in subquery(recent), order_by: [asc: m.inserted_at, asc: m.id])
        |> Repo.all()
      else
        from(m in base, order_by: [asc: m.inserted_at, asc: m.id])
        |> Repo.all()
      end

    result = Enum.map(messages, &message_to_map/1)
    {:reply, {:ok, result}, state}
  end

  defp do_handle_call(
         {:apply_tiamat_normalization_delta, conversation_id, epoch_id, request_messages, delta},
         _from,
         state
       ) do
    result =
      do_apply_tiamat_normalization_delta(conversation_id, epoch_id, request_messages, delta)

    {:reply, result, state}
  end

  defp do_handle_call({:list_messages, conversation_id, opts}, _from, state) do
    limit = opts |> Keyword.get(:limit, 50) |> min(200) |> max(1)
    before_ts = Keyword.get(opts, :before)

    # Fetch limit+1 to derive has_more without a count query
    fetch = limit + 1

    # Exclude orientation messages — those are private to the model
    base =
      from(m in Message,
        where: m.conversation_id == ^conversation_id,
        where: m.origin != "orientation" or is_nil(m.origin)
      )

    base =
      case before_ts do
        %DateTime{} = ts -> from(m in base, where: m.inserted_at < ^ts)
        _ -> base
      end

    rows =
      from(m in base, order_by: [desc: m.inserted_at, desc: m.id], limit: ^fetch)
      |> Repo.all()

    has_more = length(rows) > limit
    messages = rows |> Enum.take(limit) |> Enum.map(&message_to_api_map/1)

    {:reply, {:ok, %{messages: messages, has_more: has_more}}, state}
  end

  defp do_handle_call({:recent_message_structs, conversation_id, opts}, _from, state) do
    limit = opts |> Keyword.get(:limit, 50) |> min(200) |> max(1)

    # Fetch limit+1 to derive has_more
    fetch = limit + 1

    # Exclude orientation messages
    base =
      from(m in Message,
        where: m.conversation_id == ^conversation_id,
        where: m.origin != "orientation" or is_nil(m.origin)
      )

    # Get most recent N, then reverse to chronological order
    recent =
      from(m in base, order_by: [desc: m.inserted_at, desc: m.id], limit: ^fetch)

    rows =
      from(m in subquery(recent), order_by: [asc: m.inserted_at, asc: m.id])
      |> Repo.all()

    has_more = length(rows) > limit
    # rows are in chronological order, so the limit+1 overflow row is the
    # OLDEST one — trim from the head, keeping the newest `limit` messages.
    messages = Enum.take(rows, -limit)

    {:reply, {:ok, %{messages: messages, has_more: has_more}}, state}
  end

  defp do_handle_call({:transcript_page, conversation_id, opts}, _from, state) do
    limit = opts |> Keyword.get(:limit, 50) |> min(200) |> max(1)
    before_id = Keyword.get(opts, :before)
    after_id = Keyword.get(opts, :after)

    fetch = limit + 1

    # Exclude orientation messages
    base =
      from(m in Message,
        where: m.conversation_id == ^conversation_id,
        where: m.origin != "orientation" or is_nil(m.origin)
      )

    {rows, reverse?} =
      cond do
        is_binary(before_id) ->
          # Look up the cursor message's inserted_at for the compound sort
          cursor = Repo.get(Message, before_id)

          if cursor do
            query =
              from(m in base,
                where:
                  m.inserted_at < ^cursor.inserted_at or
                    (m.inserted_at == ^cursor.inserted_at and m.id < ^before_id),
                order_by: [desc: m.inserted_at, desc: m.id],
                limit: ^fetch
              )

            {Repo.all(query), false}
          else
            {[], false}
          end

        is_binary(after_id) ->
          cursor = Repo.get(Message, after_id)

          if cursor do
            query =
              from(m in base,
                where:
                  m.inserted_at > ^cursor.inserted_at or
                    (m.inserted_at == ^cursor.inserted_at and m.id > ^after_id),
                order_by: [asc: m.inserted_at, asc: m.id],
                limit: ^fetch
              )

            {Repo.all(query), false}
          else
            {[], false}
          end

        true ->
          # No cursor — return most recent, newest first
          query =
            from(m in base,
              order_by: [desc: m.inserted_at, desc: m.id],
              limit: ^fetch
            )

          {Repo.all(query), false}
      end

    has_more = length(rows) > limit
    messages = Enum.take(rows, limit)
    messages = if reverse?, do: Enum.reverse(messages), else: messages

    {:reply, {:ok, %{messages: messages, has_more: has_more}}, state}
  end

  defp do_handle_call({:save_handoff, epoch_id, content}, _from, state) do
    Repo.get!(Epoch, epoch_id)
    |> Epoch.changeset(%{handoff: content})
    |> Repo.update!()

    {:reply, :ok, state}
  end

  defp do_handle_call({:get_latest_handoff, conversation_id}, _from, state) do
    result =
      from(e in Epoch,
        where: e.conversation_id == ^conversation_id and not is_nil(e.handoff),
        order_by: [desc: e.inserted_at],
        limit: 1
      )
      |> Repo.one()
      |> case do
        nil -> :not_found
        epoch -> {:ok, epoch.handoff}
      end

    {:reply, result, state}
  end

  defp do_handle_call({:update_epoch_session, conversation_id, session_id}, _from, state) do
    from(e in Epoch,
      where: e.conversation_id == ^conversation_id and e.status != "cleared",
      order_by: [desc: e.inserted_at],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil ->
        :ok

      epoch ->
        epoch
        |> Epoch.changeset(%{cc_session_id: session_id})
        |> Repo.update!()
    end

    {:reply, :ok, state}
  end

  defp do_handle_call({:get_injection_context, conversation_id}, _from, state) do
    result =
      from(e in Epoch,
        where: e.conversation_id == ^conversation_id and e.status != "cleared",
        order_by: [desc: e.inserted_at],
        limit: 1
      )
      |> Repo.one()
      |> case do
        nil ->
          :not_found

        epoch ->
          # Get last_invoked_at from most recent message in this epoch
          last_invoked_at =
            from(m in Message,
              where: m.epoch_id == ^epoch.id,
              select: max(m.inserted_at)
            )
            |> Repo.one()

          {:ok,
           %{
             epoch_id: epoch.id,
             turn_count: epoch.turn_count || 0,
             saturation: epoch.saturation || 0.0,
             last_reminder_bucket: epoch.last_reminder_bucket || 0,
             last_landscape_at: epoch.last_landscape_at,
             interrupted_context: epoch.interrupted_context,
             cc_session_id: epoch.cc_session_id,
             profile: epoch.profile,
             last_invoked_at: last_invoked_at
           }}
      end

    {:reply, result, state}
  end

  defp do_handle_call({:get_or_create_epoch, conversation_id}, _from, state) do
    epoch =
      from(e in Epoch,
        where: e.conversation_id == ^conversation_id and e.status != "cleared",
        order_by: [desc: e.inserted_at],
        limit: 1
      )
      |> Repo.one()

    epoch =
      case epoch do
        nil ->
          %Epoch{}
          |> Epoch.changeset(%{conversation_id: conversation_id})
          |> Repo.insert!()

        existing ->
          existing
      end

    last_invoked_at =
      from(m in Message,
        where: m.epoch_id == ^epoch.id,
        select: max(m.inserted_at)
      )
      |> Repo.one()

    result =
      {:ok,
       %{
         epoch_id: epoch.id,
         turn_count: epoch.turn_count || 0,
         saturation: epoch.saturation || 0.0,
         last_reminder_bucket: epoch.last_reminder_bucket || 0,
         last_landscape_at: epoch.last_landscape_at,
         interrupted_context: epoch.interrupted_context,
         cc_session_id: epoch.cc_session_id,
         profile: epoch.profile,
         last_invoked_at: last_invoked_at,
         last_belief_ids: epoch.last_belief_ids
       }}

    {:reply, result, state}
  end

  defp do_handle_call({:get_predecessor_epoch_id, conversation_id}, _from, state) do
    result =
      from(e in Epoch,
        where: e.conversation_id == ^conversation_id and e.status == "cleared",
        order_by: [desc: e.updated_at],
        limit: 1,
        select: e.id
      )
      |> Repo.one()

    {:reply, result, state}
  end

  defp do_handle_call({:get_last_message_at, epoch_id}, _from, state) do
    result =
      from(m in Message,
        where: m.epoch_id == ^epoch_id,
        select: max(m.inserted_at)
      )
      |> Repo.one()
      |> case do
        nil -> :not_found
        ts -> {:ok, ts}
      end

    {:reply, result, state}
  end

  defp do_handle_call({:save_summary, conversation_id, content}, _from, state) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get_by(Summary, conversation_id: conversation_id) do
      nil ->
        %Summary{}
        |> Summary.changeset(%{conversation_id: conversation_id, content: content})
        |> Repo.insert!()

      existing ->
        existing
        |> Summary.changeset(%{content: content, updated_at: now})
        |> Repo.update!()
    end

    {:reply, :ok, state}
  end

  defp do_handle_call(:get_all_summaries, _from, state) do
    summaries =
      from(s in Summary, order_by: [desc: s.updated_at])
      |> Repo.all()
      |> Enum.map(&summary_to_map/1)

    {:reply, {:ok, summaries}, state}
  end

  defp do_handle_call(:list_conversation_ids, _from, state) do
    ids =
      from(e in Epoch,
        select: e.conversation_id,
        distinct: true
      )
      |> Repo.all()

    {:reply, {:ok, ids}, state}
  end

  defp do_handle_call({:save_ensemble_selection, attrs}, _from, state) do
    %EnsembleSelection{}
    |> EnsembleSelection.changeset(attrs)
    |> Repo.insert!()

    {:reply, :ok, state}
  end

  defp do_handle_call({:list_transcripts, opts}, _from, state) do
    limit = opts |> Keyword.get(:limit, 1000) |> min(5000) |> max(1)
    since = Keyword.get(opts, :since)
    after_id = Keyword.get(opts, :after_id)
    room = Keyword.get(opts, :room)

    base =
      from(m in Message,
        where: m.origin != "orientation" or is_nil(m.origin),
        order_by: [asc: m.inserted_at, asc: m.id],
        limit: ^limit
      )

    base =
      cond do
        since && is_binary(after_id) ->
          from(m in base,
            where: m.inserted_at > ^since or (m.inserted_at == ^since and m.id > ^after_id)
          )

        since ->
          from(m in base, where: m.inserted_at > ^since)

        true ->
          base
      end

    base = if room, do: from(m in base, where: m.conversation_id == ^room), else: base

    messages = Repo.all(base)

    # Build a lookup of tool_use_id → tool_result from adjacent user messages.
    # Tool results follow their tool_use assistant messages sequentially.
    tool_results = build_tool_result_index(messages)

    # Compute turn_count per row: each non-tool-result user message starts a
    # new turn within its (conversation_id, epoch_id). All rows between two
    # user-turn boundaries share the same turn_count. This is the join key
    # for tiamat's decision log — do not reconstruct from seq or timestamps.
    turn_counts = compute_turn_counts(messages)

    records =
      messages
      |> Enum.with_index()
      |> Enum.map(fn {m, idx} ->
        m
        |> message_to_transcript(tool_results)
        |> Map.put(:turn_count, Map.get(turn_counts, idx, 0))
      end)

    {:reply, {:ok, records}, state}
  end

  defp do_handle_call({:clear_epoch, conversation_id, continuation}, _from, state) do
    result =
      from(e in Epoch,
        where: e.conversation_id == ^conversation_id and e.status != "cleared",
        order_by: [desc: e.inserted_at],
        limit: 1
      )
      |> Repo.one()
      |> case do
        nil ->
          :not_found

        epoch ->
          epoch
          |> Epoch.changeset(%{status: "cleared"})
          |> Repo.update!()

          new_epoch_attrs = %{conversation_id: conversation_id}

          new_epoch_attrs =
            if continuation,
              do: Map.put(new_epoch_attrs, :continuation, continuation),
              else: new_epoch_attrs

          new_epoch =
            %Epoch{}
            |> Epoch.changeset(new_epoch_attrs)
            |> Repo.insert!()

          {:ok, new_epoch.id}
      end

    {:reply, result, state}
  end

  # --- Room Event Handlers ---

  defp do_handle_call({:emit_room_event, room_id, type, payload, correlation_id}, _from, state) do
    result =
      Repo.transaction(fn ->
        next_seq =
          from(e in RoomEvent,
            where: e.room_id == ^room_id,
            select: max(e.seq)
          )
          |> Repo.one()
          |> case do
            nil -> 1
            max -> max + 1
          end

        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        %RoomEvent{}
        |> RoomEvent.changeset(%{
          room_id: room_id,
          seq: next_seq,
          type: type,
          occurred_at: now,
          correlation_id: correlation_id,
          payload: payload
        })
        |> Repo.insert!()
      end)

    case result do
      {:ok, event} ->
        {:reply, {:ok, room_event_to_map(event)}, state}

      {:error, reason} ->
        Logger.error("Failed to emit room event: #{inspect(reason)}", stage: :store)
        {:reply, {:error, :db_error}, state}
    end
  end

  defp do_handle_call({:list_room_events, room_id, since_seq, opts}, _from, state) do
    limit = opts |> Keyword.get(:limit, 500) |> min(5000) |> max(1)

    events =
      from(e in RoomEvent,
        where: e.room_id == ^room_id and e.seq > ^since_seq,
        order_by: [asc: e.seq],
        limit: ^limit
      )
      |> Repo.all()
      |> Enum.map(&room_event_to_map/1)

    {:reply, {:ok, events}, state}
  end

  defp do_handle_call({:latest_room_event_seq, room_id}, _from, state) do
    seq =
      from(e in RoomEvent,
        where: e.room_id == ^room_id,
        select: max(e.seq)
      )
      |> Repo.one()
      |> case do
        nil -> 0
        max -> max
      end

    {:reply, {:ok, seq}, state}
  end

  defp do_handle_call({:oldest_room_event_seq, room_id}, _from, state) do
    seq =
      from(e in RoomEvent,
        where: e.room_id == ^room_id,
        select: min(e.seq)
      )
      |> Repo.one()

    {:reply, {:ok, seq}, state}
  end

  defp do_handle_call({:purge_room_events_before, before}, _from, state) do
    {count, _} =
      from(e in RoomEvent, where: e.occurred_at < ^before)
      |> Repo.delete_all()

    {:reply, {:ok, count}, state}
  end

  # --- Read Marker Handlers ---

  defp do_handle_call({:mark_room_read, room_id, seq}, _from, state) do
    latest =
      from(e in RoomEvent,
        where: e.room_id == ^room_id,
        select: max(e.seq)
      )
      |> Repo.one()
      |> Kernel.||(0)

    # Clamp to the latest known seq — a client can't have read the future
    target_seq = if is_nil(seq) or seq > latest, do: latest, else: seq

    existing = Repo.get(RoomReadMarker, room_id)

    if existing && existing.last_read_seq >= target_seq do
      {:reply, {:ok, room_read_marker_to_map(existing)}, state}
    else
      marker =
        (existing || %RoomReadMarker{})
        |> RoomReadMarker.changeset(%{
          room_id: room_id,
          last_read_seq: target_seq,
          last_read_at: read_position_at(room_id, target_seq)
        })
        |> Repo.insert_or_update!()

      {:reply, {:ok, room_read_marker_to_map(marker)}, state}
    end
  end

  defp do_handle_call({:get_room_read_marker, room_id}, _from, state) do
    marker =
      case Repo.get(RoomReadMarker, room_id) do
        nil -> nil
        m -> room_read_marker_to_map(m)
      end

    {:reply, {:ok, marker}, state}
  end

  # The timestamp anchor for a read position: the occurred_at of the event
  # at that seq. Falls back to now() when the event is gone (seq 0, or the
  # event aged out of the retention window) — the marker then covers
  # everything up to the present, which is what "mark read" means for a
  # position we can no longer place in time.
  defp read_position_at(room_id, seq) do
    event_at =
      from(e in RoomEvent,
        where: e.room_id == ^room_id and e.seq == ^seq,
        select: e.occurred_at
      )
      |> Repo.one()

    event_at || DateTime.truncate(DateTime.utc_now(), :microsecond)
  end

  # --- Private ---

  defp do_apply_tiamat_normalization_delta(_conversation_id, _epoch_id, _request_messages, nil),
    do: {:ok, %{applied: 0, skipped: 0}}

  defp do_apply_tiamat_normalization_delta(conversation_id, epoch_id, request_messages, delta) do
    assignments = normalization_assignments(delta)

    messages =
      from(m in Message,
        where: m.conversation_id == ^conversation_id and m.epoch_id == ^epoch_id,
        order_by: [asc: m.inserted_at, asc: m.id]
      )
      |> Repo.all()

    request_by_index =
      request_messages
      |> Enum.with_index()
      |> Map.new(fn {message, index} -> {index, map_value(message, "id")} end)

    message_by_id = Map.new(messages, &{&1.id, &1})

    {applied, skipped} =
      Enum.reduce(assignments, {0, 0}, fn assignment, {applied, skipped} ->
        with {:ok, message_id} <- assignment_message_id(assignment, request_by_index),
             %Message{} = message <- Map.get(message_by_id, message_id),
             changes when changes != %{} <- safe_normalization_changes(message, assignment) do
          message
          |> Message.changeset(changes)
          |> Repo.update!()

          {applied + 1, skipped}
        else
          _ -> {applied, skipped + 1}
        end
      end)

    {:ok, %{applied: applied, skipped: skipped}}
  end

  defp normalization_assignments(%{"assignments" => assignments}) when is_list(assignments),
    do: assignments

  defp normalization_assignments(%{assignments: assignments}) when is_list(assignments),
    do: assignments

  defp normalization_assignments(_), do: []

  defp assignment_message_id(assignment, request_by_index) do
    selector = map_value(assignment, "selector") || %{}

    cond do
      is_binary(map_value(selector, "id")) ->
        {:ok, map_value(selector, "id")}

      is_integer(map_value(selector, "index")) ->
        case Map.get(request_by_index, map_value(selector, "index")) do
          id when is_binary(id) -> {:ok, id}
          _ -> :error
        end

      true ->
        :error
    end
  end

  defp safe_normalization_changes(%Message{} = message, assignment) do
    assigned = map_value(assignment, "assigned") || %{}

    %{}
    |> maybe_put_parent_id(
      message,
      map_value(assigned, "parent_id") || map_value(assignment, "assigned_parent_id")
    )
    |> maybe_merge_provenance(message, map_value(assigned, "provenance"))
    |> maybe_put_content_block_assignments(message, assignment, assigned)
  end

  defp maybe_put_content_block_assignments(
         changes,
         %Message{content: content},
         assignment,
         assigned
       )
       when is_list(content) do
    content_index = map_value(assignment, "content_index")

    assigned_tool_use_id =
      map_value(assignment, "assigned_tool_use_id") || map_value(assigned, "tool_use_id")

    assigned_tool_result_for =
      map_value(assignment, "assigned_tool_result_for") || map_value(assigned, "tool_result_for")

    cond do
      not is_integer(content_index) ->
        changes

      not is_binary(assigned_tool_use_id) and not is_binary(assigned_tool_result_for) ->
        changes

      content_index < 0 or content_index >= length(content) ->
        changes

      true ->
        updated =
          List.update_at(content, content_index, fn block ->
            block
            |> maybe_put_block_key("tool_use_id", assigned_tool_use_id)
            |> maybe_put_block_key("tool_result_for", assigned_tool_result_for)
          end)

        if updated == content, do: changes, else: Map.put(changes, :content, updated)
    end
  end

  defp maybe_put_content_block_assignments(changes, _message, _assignment, _assigned), do: changes

  defp maybe_put_block_key(block, _key, nil), do: block

  defp maybe_put_block_key(block, key, value) when is_map(block) and is_binary(value) do
    current = Map.get(block, key) || Map.get(block, String.to_atom(key))

    if current == value do
      block
    else
      Map.put(block, key, value)
    end
  end

  defp maybe_put_block_key(block, _key, _value), do: block

  defp maybe_put_parent_id(changes, %Message{parent_id: current}, assigned)
       when is_binary(assigned) or is_nil(assigned) do
    if current == assigned, do: changes, else: Map.put(changes, :parent_id, assigned)
  end

  defp maybe_put_parent_id(changes, _message, _assigned), do: changes

  defp maybe_merge_provenance(changes, %Message{provenance: current}, assigned)
       when is_map(assigned) do
    merged = Map.merge(current || %{}, stringify_keys(assigned))

    if merged == (current || %{}), do: changes, else: Map.put(changes, :provenance, merged)
  end

  defp maybe_merge_provenance(changes, _message, _assigned), do: changes

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp epoch_to_map(%Epoch{} = e) do
    %{
      id: e.id,
      conversation_id: e.conversation_id,
      status: e.status,
      system_prompt: e.system_prompt,
      turn_count: e.turn_count,
      saturation: e.saturation,
      handoff: e.handoff,
      last_reminder_bucket: e.last_reminder_bucket,
      cc_session_id: e.cc_session_id,
      profile: e.profile,
      last_landscape_at: e.last_landscape_at,
      interrupted_context: e.interrupted_context,
      continuation: e.continuation,
      inserted_at: e.inserted_at,
      updated_at: e.updated_at
    }
  end

  defp message_to_map(%Message{} = m) do
    %{
      id: m.id,
      conversation_id: m.conversation_id,
      epoch_id: m.epoch_id,
      parent_id: m.parent_id,
      role: String.to_existing_atom(m.role),
      content: m.content,
      origin: m.origin,
      usage: m.usage,
      provenance: m.provenance,
      inserted_at: m.inserted_at
    }
  end

  defp message_to_map(%{role: role, content: content} = m) do
    %{
      id: Map.get(m, :id),
      conversation_id: Map.get(m, :conversation_id),
      epoch_id: Map.get(m, :epoch_id),
      parent_id: Map.get(m, :parent_id),
      role: String.to_existing_atom(to_string(role)),
      content: content,
      origin: Map.get(m, :origin),
      usage: Map.get(m, :usage),
      provenance: Map.get(m, :provenance),
      inserted_at: Map.get(m, :inserted_at)
    }
  end

  defp message_to_api_map(%Message{} = m) do
    base = %{
      id: m.id,
      role: m.role,
      content: m.content,
      text: extract_text(m.content),
      origin: m.origin,
      created_at: m.inserted_at,
      epoch_id: m.epoch_id,
      parent_id: m.parent_id
    }

    base = if m.provenance, do: Map.put(base, :provenance, m.provenance), else: base
    base = if m.usage, do: Map.put(base, :usage, m.usage), else: base
    base
  end

  @doc "Extract concatenated text from content blocks."
  @spec extract_text(list() | binary() | nil) :: String.t()
  def extract_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) and (&1["type"] == "text" or &1[:type] == "text")))
    |> Enum.map_join("", &(&1["text"] || &1[:text] || ""))
  end

  def extract_text(text) when is_binary(text), do: text
  def extract_text(_), do: ""

  defp summary_to_map(%Summary{} = s) do
    %{
      conversation_id: s.conversation_id,
      content: s.content,
      updated_at: s.updated_at
    }
  end

  # --- Transcript helpers ---

  defp message_to_transcript(%Message{} = m, tool_results) do
    usage = m.usage || %{}

    tool_calls = extract_tool_calls(m.content, tool_results)

    base = %{
      id: m.id,
      parent_id: m.parent_id,
      conversation_id: m.conversation_id,
      epoch_id: m.epoch_id,
      timestamp: DateTime.to_iso8601(m.inserted_at),
      role: m.role,
      content: extract_text(m.content),
      text: extract_text(m.content),
      content_blocks: m.content
    }

    base = if m.origin, do: Map.put(base, :origin, m.origin), else: base
    base = if m.usage, do: Map.put(base, :usage, m.usage), else: base
    base = if m.provenance, do: Map.put(base, :provenance, m.provenance), else: base

    # Only include model and token counts for assistant messages with usage
    base =
      if usage["model"] || usage[:model],
        do: Map.put(base, :model, usage["model"] || usage[:model]),
        else: base

    base =
      if usage["input_tokens"] || usage[:input_tokens],
        do:
          base
          |> Map.put(:tokens_in, usage["input_tokens"] || usage[:input_tokens])
          |> Map.put(:tokens_out, usage["output_tokens"] || usage[:output_tokens]),
        else: base

    if tool_calls != [], do: Map.put(base, :tool_calls, tool_calls), else: base
  end

  # Compute turn_count for each message index. A "turn" starts at each
  # non-tool-result user message within a (conversation_id, epoch_id) group.
  # Tool-result user messages and assistant messages inherit the current
  # turn's count. Counter resets when the group key changes.
  #
  # 0-based to match epoch_ctx.turn_count (what TiamatRouter sends).
  # The join predicate is: tiamat.turn_count == transcript.turn_count.
  defp compute_turn_counts(messages) do
    {counts, _, _} =
      Enum.reduce(Enum.with_index(messages), {%{}, %{}, -1}, fn {m, idx}, {acc, prev_key, tc} ->
        key = {m.conversation_id, m.epoch_id}
        tc = if key != prev_key, do: -1, else: tc

        is_user_turn = m.role == "user" && !is_tool_result_message?(m)
        tc = if is_user_turn, do: tc + 1, else: tc

        {Map.put(acc, idx, tc), key, tc}
      end)

    counts
  end

  defp is_tool_result_message?(%{content: content}) when is_list(content) do
    Enum.any?(content, fn block ->
      (block["type"] || block[:type]) == "tool_result"
    end)
  end

  defp is_tool_result_message?(_), do: false

  # Build a map of tool_use_id → tool_result content from tool-result messages.
  # Older Cranium transcripts stored tool results as user messages with
  # tool_use_id; Tiamat-normalized transcripts store role=tool with
  # tool_result_for. Accept both shapes while exporting history.
  defp build_tool_result_index(messages) do
    Enum.reduce(messages, %{}, fn m, acc ->
      if m.role in ["user", "tool"] do
        Enum.reduce(m.content || [], acc, fn block, inner_acc ->
          type = block["type"] || block[:type]

          tool_use_id =
            block["tool_result_for"] || block[:tool_result_for] || block["tool_use_id"] ||
              block[:tool_use_id]

          if type == "tool_result" && tool_use_id do
            Map.put(inner_acc, tool_use_id, block)
          else
            inner_acc
          end
        end)
      else
        acc
      end
    end)
  end

  # Extract tool_use blocks from assistant message content, correlate with results
  defp extract_tool_calls(content, tool_results) when is_list(content) do
    content
    |> Enum.filter(fn block ->
      (block["type"] || block[:type]) == "tool_use"
    end)
    |> Enum.map(fn block ->
      id = block["tool_use_id"] || block[:tool_use_id] || block["id"] || block[:id]
      name = block["tool_name"] || block[:tool_name] || block["name"] || block[:name]
      result = Map.get(tool_results, id)

      success = tool_call_success?(result)
      entry = %{name: name, success: success}

      if !success && result do
        result_content = result["content"] || result[:content] || ""
        snippet = result_content |> to_string() |> String.slice(0, 200)
        Map.put(entry, :error_snippet, snippet)
      else
        entry
      end
    end)
  end

  defp extract_tool_calls(_, _), do: []

  defp tool_call_success?(nil), do: true

  defp tool_call_success?(result) do
    is_error = result["is_error"] || result[:is_error]
    content = to_string(result["content"] || result[:content] || "")

    cond do
      is_error == true -> false
      String.contains?(content, "error") -> false
      true -> true
    end
  end

  defp room_event_to_map(%RoomEvent{} = e) do
    %{
      event_id: e.id,
      room_id: e.room_id,
      seq: e.seq,
      type: e.type,
      occurred_at: e.occurred_at,
      correlation_id: e.correlation_id,
      payload: e.payload
    }
  end

  defp room_read_marker_to_map(%RoomReadMarker{} = m) do
    %{
      room_id: m.room_id,
      last_read_seq: m.last_read_seq,
      last_read_at: m.last_read_at
    }
  end
end
