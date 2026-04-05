defmodule Cranium.ConfigTest do
  use ExUnit.Case, async: false

  alias Cranium.Config

  describe "resolve_profile/1" do
    test "resolves a known profile" do
      assert {:ok, resolved} = Config.resolve_profile("test")
      assert resolved.name == "test"
      assert resolved.backend == :mock
      assert resolved.backend_module == Cranium.Backend.LLM.Mock
      assert resolved.model == "test-model"
      assert resolved.identity == nil
    end

    test "resolves ollama profile" do
      assert {:ok, resolved} = Config.resolve_profile("test-ollama")
      assert resolved.backend == :ollama
      assert resolved.backend_module == Cranium.Backend.LLM.Ollama
      assert resolved.model == "test-ollama-model"
    end

    test "resolves claudecode profile" do
      assert {:ok, resolved} = Config.resolve_profile("test-cc")
      assert resolved.backend == :claudecode
      assert resolved.backend_module == Cranium.Backend.LLM.ClaudeCode
    end

    test "returns error for unknown profile" do
      assert {:error, :not_found} = Config.resolve_profile("nonexistent")
    end

    test "resolves identity content from file" do
      assert {:ok, resolved} = Config.resolve_profile("test-with-identity")
      assert resolved.identity == "You are a test identity."
    end
  end

  describe "default_profile_name/0" do
    test "returns the configured default" do
      assert Config.default_profile_name() == "test"
    end
  end

  describe "ollama_url/0" do
    test "returns the configured URL" do
      assert Config.ollama_url() == "http://localhost:11434"
    end
  end

  describe "read_identity/1" do
    test "reads and caches identity file" do
      path = Path.join(File.cwd!(), "test/fixtures/test-identity.txt")
      assert Config.read_identity(path) == "You are a test identity."

      # Second call should return cached (same result)
      assert Config.read_identity(path) == "You are a test identity."
    end

    test "returns nil for nonexistent file" do
      assert Config.read_identity("/tmp/nonexistent-identity-#{:rand.uniform(999_999)}.txt") == nil
    end
  end
end
