defmodule CraniumTest.DataCase do
  @moduledoc """
  Test case for tests that require database access.

  Starts the Repo if not already running and wraps each test in
  an Ecto SQL Sandbox checkout for isolation.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Cranium.Store.Repo
      import Ecto.Query
    end
  end

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Cranium.Store.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
