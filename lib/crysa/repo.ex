defmodule Crysa.Repo do
  use Ecto.Repo,
    otp_app: :crysa,
    adapter: Ecto.Adapters.Postgres
end
