defmodule Crysa.Processing.Jobs.PasswordResetTokenCleanup do
  @moduledoc """
  Deletes expired password-reset tokens and long-consumed used tokens.

  Token digests are never reused; removing them keeps the table bounded
  without a retention policy decision blocking the flow.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  alias Crysa.Repo

  @used_retention_days 7

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    used_cutoff = DateTime.add(now, -@used_retention_days, :day)

    {expired, _} =
      from(t in "password_reset_tokens", where: t.expires_at < ^now)
      |> Repo.delete_all()

    {used, _} =
      from(t in "password_reset_tokens",
        where: not is_nil(t.used_at) and t.used_at < ^used_cutoff
      )
      |> Repo.delete_all()

    {:ok, %{expired_deleted: expired, used_deleted: used}}
  end
end
