ExUnit.start(exclude: [unboxed: true])
Ecto.Adapters.SQL.Sandbox.mode(Crysa.Repo, :manual)

# Tests tagged `:unboxed` bypass the SQL sandbox via `unboxed_run/2` and commit
# globally-visible rows, so they must never run concurrently with the suite.
# Run them explicitly and serially: `mix test.unboxed` (see `mix.exs` aliases).
