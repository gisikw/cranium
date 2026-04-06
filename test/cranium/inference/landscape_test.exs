defmodule Cranium.Inference.LandscapeTest do
  use ExUnit.Case, async: false

  alias Cranium.Inference.Landscape

  @now ~U[2026-03-18 12:00:00Z]

  setup do
    # Create a temporary directory with hoard-format summary files
    tmp_dir =
      Path.join(System.tmp_dir!(), "landscape_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    # Save original paths so we can restore them — put_env in tests clobbers
    # keys that other concurrent test modules depend on (e.g. :skills).
    original_paths = Application.get_env(:cranium, :paths)

    on_exit(fn ->
      Application.put_env(:cranium, :paths, original_paths)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  defp write_hoard_summary(dir, filename, attrs) do
    json =
      Jason.encode!(%{
        "room_id" => Map.get(attrs, :room_id, "!test"),
        "room_name" => Map.get(attrs, :room_name, Path.basename(filename, ".json")),
        "summary" => Map.get(attrs, :summary, "Test summary"),
        "last_message_ts" => Map.get(attrs, :last_message_ts, DateTime.to_unix(@now)),
        "last_summary_ts" => Map.get(attrs, :last_summary_ts, DateTime.to_unix(@now)),
        "turns_since_summary" => Map.get(attrs, :turns_since_summary, 0)
      })

    File.write!(Path.join(dir, filename), json)
  end

  # Start a fresh Landscape GenServer with a unique name for test isolation.
  # Must be called AFTER hoard files are written (the server loads on init).
  defp start_landscape(dir) do
    Application.put_env(:cranium, :paths,
      Keyword.merge(Application.get_env(:cranium, :paths), summaries: dir)
    )

    name = :"landscape_#{:erlang.unique_integer([:positive])}"
    {:ok, _pid} = Landscape.start_link(name: name)
    name
  end

  describe "build/2 with hoard disk source" do
    test "formats entries from hoard JSON files", %{tmp_dir: dir} do
      two_hours_ago = DateTime.add(@now, -7200, :second) |> DateTime.to_unix()
      one_day_ago = DateTime.add(@now, -86400, :second) |> DateTime.to_unix()

      write_hoard_summary(dir, "fort-nix.json", %{
        room_name: "fort-nix",
        summary: "Working on NixOS infra",
        last_message_ts: two_hours_ago
      })

      write_hoard_summary(dir, "nerve.json", %{
        room_name: "nerve",
        summary: "Building Tauri client",
        last_message_ts: one_day_ago
      })

      name = start_landscape(dir)

      result = Landscape.build("test-room", now: @now, name: name)
      assert result =~ "<cross-room-context>"
      assert result =~ "</cross-room-context>"
      assert result =~ "**fort-nix**"
      assert result =~ "**nerve**"
      assert result =~ "Working on NixOS infra"
      assert result =~ "Building Tauri client"
      assert result =~ "2h00m ago"
      assert result =~ "1 day ago"
    end

    test "excludes current conversation", %{tmp_dir: dir} do
      write_hoard_summary(dir, "my-room.json", %{
        room_name: "my-room",
        summary: "Should be excluded"
      })

      write_hoard_summary(dir, "other-room.json", %{
        room_name: "other-room",
        summary: "Should be included"
      })

      name = start_landscape(dir)

      result = Landscape.build("my-room", now: @now, name: name)
      assert result =~ "other-room"
      refute result =~ "Should be excluded"
    end

    test "returns nil when no entries exist", %{tmp_dir: dir} do
      name = start_landscape(dir)
      assert Landscape.build("test-room", now: @now, name: name) == nil
    end

    test "returns nil when only current conversation exists", %{tmp_dir: dir} do
      write_hoard_summary(dir, "only-room.json", %{
        room_name: "only-room",
        summary: "Just me"
      })

      name = start_landscape(dir)
      assert Landscape.build("only-room", now: @now, name: name) == nil
    end

    test "filters by :since option", %{tmp_dir: dir} do
      one_hour_ago = DateTime.add(@now, -3600, :second)
      two_hours_ago = DateTime.add(@now, -7200, :second)

      write_hoard_summary(dir, "recent.json", %{
        room_name: "recent",
        summary: "Recent activity",
        last_message_ts: DateTime.to_unix(DateTime.add(@now, -1800, :second))
      })

      write_hoard_summary(dir, "stale.json", %{
        room_name: "stale",
        summary: "Old activity",
        last_message_ts: DateTime.to_unix(DateTime.add(@now, -7200, :second))
      })

      name = start_landscape(dir)

      # Filter: only things after one_hour_ago
      result = Landscape.build("test-room", since: one_hour_ago, now: @now, name: name)
      assert result =~ "recent"
      refute result =~ "stale"

      # Filter: everything after two_hours_ago (both should appear since stale is exactly at boundary)
      result2 =
        Landscape.build("test-room",
          since: DateTime.add(two_hours_ago, -1, :second),
          now: @now,
          name: name
        )

      assert result2 =~ "recent"
      assert result2 =~ "stale"
    end

    test "returns nil when all entries are before :since", %{tmp_dir: dir} do
      write_hoard_summary(dir, "old.json", %{
        room_name: "old",
        summary: "Ancient history",
        last_message_ts: DateTime.to_unix(DateTime.add(@now, -86400, :second))
      })

      name = start_landscape(dir)
      one_hour_ago = DateTime.add(@now, -3600, :second)
      assert Landscape.build("test-room", since: one_hour_ago, now: @now, name: name) == nil
    end

    test "sorts entries by recency (most recent first)", %{tmp_dir: dir} do
      write_hoard_summary(dir, "older.json", %{
        room_name: "older",
        summary: "Older room",
        last_message_ts: DateTime.to_unix(DateTime.add(@now, -7200, :second))
      })

      write_hoard_summary(dir, "newer.json", %{
        room_name: "newer",
        summary: "Newer room",
        last_message_ts: DateTime.to_unix(DateTime.add(@now, -1800, :second))
      })

      name = start_landscape(dir)

      result = Landscape.build("test-room", now: @now, name: name)
      newer_pos = :binary.match(result, "newer") |> elem(0)
      older_pos = :binary.match(result, "older") |> elem(0)
      assert newer_pos < older_pos
    end

    test "skips malformed JSON files", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "broken.json"), "not json at all")

      write_hoard_summary(dir, "good.json", %{
        room_name: "good",
        summary: "Valid entry"
      })

      name = start_landscape(dir)
      result = Landscape.build("test-room", now: @now, name: name)
      assert result =~ "good"
    end

    test "skips files with empty summaries", %{tmp_dir: dir} do
      write_hoard_summary(dir, "empty.json", %{
        room_name: "empty",
        summary: ""
      })

      name = start_landscape(dir)
      assert Landscape.build("test-room", now: @now, name: name) == nil
    end
  end

  describe "summary_updated/3 cache invalidation" do
    test "updates cache with new summary", %{tmp_dir: dir} do
      write_hoard_summary(dir, "existing.json", %{
        room_name: "existing",
        summary: "Old summary",
        last_message_ts: DateTime.to_unix(DateTime.add(@now, -3600, :second))
      })

      name = start_landscape(dir)

      # Verify old summary is served
      result = Landscape.build("test-room", now: @now, name: name)
      assert result =~ "Old summary"

      # Push a summary update via cast
      GenServer.cast(name, {:summary_updated, "existing", "New summary", @now})

      # Cast is async — give it a moment to process
      :sys.get_state(name)

      result = Landscape.build("test-room", now: @now, name: name)
      assert result =~ "New summary"
      refute result =~ "Old summary"
    end

    test "adds new conversation to cache", %{tmp_dir: dir} do
      name = start_landscape(dir)

      # Empty initially
      assert Landscape.build("test-room", now: @now, name: name) == nil

      # Push a new summary
      GenServer.cast(name, {:summary_updated, "new-room", "Brand new", @now})
      :sys.get_state(name)

      result = Landscape.build("test-room", now: @now, name: name)
      assert result =~ "new-room"
      assert result =~ "Brand new"
    end
  end

  describe "humanize_ago formatting" do
    test "just now for < 60 seconds", %{tmp_dir: dir} do
      write_hoard_summary(dir, "recent.json", %{
        room_name: "recent",
        summary: "Very recent",
        last_message_ts: DateTime.to_unix(DateTime.add(@now, -30, :second))
      })

      name = start_landscape(dir)
      result = Landscape.build("test-room", now: @now, name: name)
      assert result =~ "just now"
    end

    test "minutes for < 1 hour", %{tmp_dir: dir} do
      write_hoard_summary(dir, "recent.json", %{
        room_name: "recent",
        summary: "Pretty recent",
        last_message_ts: DateTime.to_unix(DateTime.add(@now, -900, :second))
      })

      name = start_landscape(dir)
      result = Landscape.build("test-room", now: @now, name: name)
      assert result =~ "15m ago"
    end

    test "days for >= 24 hours", %{tmp_dir: dir} do
      write_hoard_summary(dir, "old.json", %{
        room_name: "old",
        summary: "Old stuff",
        last_message_ts: DateTime.to_unix(DateTime.add(@now, -172_800, :second))
      })

      name = start_landscape(dir)
      result = Landscape.build("test-room", now: @now, name: name)
      assert result =~ "2 days ago"
    end
  end
end
