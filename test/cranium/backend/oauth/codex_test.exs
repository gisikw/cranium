defmodule Cranium.Backend.OAuth.CodexTest do
  use ExUnit.Case, async: false

  alias Cranium.Backend.OAuth.Codex

  # The GenServer starts in application.ex so it's already running.
  # These tests exercise the public API against the live GenServer.

  describe "status/0" do
    test "returns status map" do
      status = Codex.status()
      assert is_map(status)
      assert Map.has_key?(status, :authenticated)
      assert Map.has_key?(status, :account_id)
      assert Map.has_key?(status, :expires_at)
    end
  end

  describe "authenticated?/0" do
    test "returns boolean" do
      result = Codex.authenticated?()
      assert is_boolean(result)
    end
  end

  describe "get_headers/0" do
    test "returns error when not authenticated" do
      # Fresh test env has no tokens
      assert {:error, :not_authenticated} = Codex.get_headers()
    end
  end

  describe "start_auth_flow/1" do
    test "returns authorization URL" do
      {:ok, url} = Codex.start_auth_flow("http://localhost:4000/auth/openai/callback")

      assert String.starts_with?(url, "https://auth.openai.com/oauth/authorize")
      assert url =~ "client_id="
      assert url =~ "code_challenge="
      assert url =~ "redirect_uri="
      assert url =~ "codex_cli_simplified_flow=true"
    end
  end

  describe "exchange_code/2" do
    test "returns error with invalid code" do
      # First start a flow so there's a pending verifier
      Codex.start_auth_flow("http://localhost:4000/callback")

      # Then try exchanging a bogus code — will fail at the HTTP level
      result = Codex.exchange_code("bogus_code", "http://localhost:4000/callback")
      assert {:error, _} = result
    end
  end
end
