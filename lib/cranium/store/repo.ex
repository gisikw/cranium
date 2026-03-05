defmodule Cranium.Store.Repo do
  use Ecto.Repo,
    otp_app: :cranium,
    adapter: Ecto.Adapters.Postgres
end
