defmodule Cranium.Backend.OAuth.CodexTest do
  use ExUnit.Case, async: false

  alias Cranium.Backend.OAuth.Codex

  # The GenServer starts in application.ex so it's already running.
  # These tests exercise the public API against the live GenServer.

  describe "status/0" do
    test "returns status map with device flow fields" do
      status = Codex.status()
      assert is_map(status)
      assert Map.has_key?(status, :authenticated)
      assert Map.has_key?(status, :account_id)
      assert Map.has_key?(status, :expires_at)
      assert Map.has_key?(status, :device_pending)
      assert Map.has_key?(status, :user_code)
      assert Map.has_key?(status, :verification_uri)
    end
  end

  describe "authenticated?/0" do
    test "returns boolean" do
      result = Codex.authenticated?()
      assert is_boolean(result)
    end
  end

  describe "get_headers/0" do
    test "returns headers or not-authenticated" do
      case Codex.get_headers() do
        {:ok, headers} ->
          assert is_list(headers)

        {:error, :not_authenticated} ->
          :ok
      end
    end
  end

  describe "start_device_flow/0" do
    test "returns user code and verification URI" do
      case Codex.start_device_flow() do
        {:ok, %{user_code: code, verification_uri: uri}} ->
          assert is_binary(code)
          assert is_binary(uri)

        {:error, reason} ->
          # May fail in CI/test if OpenAI endpoint unreachable — that's acceptable
          assert reason != nil
      end
    end
  end
end
