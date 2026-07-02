defmodule Cranium.RoomSync.TimestampTest do
  use ExUnit.Case, async: true

  alias Cranium.RoomSync.Timestamp

  test "truncates microsecond DateTimes to second precision" do
    dt = ~U[2026-07-02 03:34:46.573954Z]
    assert Timestamp.iso8601(dt) == "2026-07-02T03:34:46Z"
  end

  test "leaves second-precision DateTimes as-is" do
    dt = ~U[2026-07-02 01:18:10Z]
    assert Timestamp.iso8601(dt) == "2026-07-02T01:18:10Z"
  end

  test "normalizes NaiveDateTimes as UTC" do
    naive = ~N[2026-07-02 03:34:46.573954]
    assert Timestamp.iso8601(naive) == "2026-07-02T03:34:46Z"
  end

  test "re-normalizes ISO 8601 strings with sub-second precision" do
    assert Timestamp.iso8601("2026-07-02T03:34:46.573954Z") == "2026-07-02T03:34:46Z"
    assert Timestamp.iso8601("2026-07-02T01:18:10Z") == "2026-07-02T01:18:10Z"
  end

  test "passes unparseable strings and nil through unchanged" do
    assert Timestamp.iso8601("not a timestamp") == "not a timestamp"
    assert Timestamp.iso8601(nil) == nil
  end
end
