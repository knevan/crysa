defmodule Crysa.Accounts.UserEmail do
  @moduledoc """
  Transactional emails sent to users.
  """

  import Swoosh.Email

  alias Crysa.Accounts.User
  alias Crysa.Mailer

  @spec deliver_reset_password_instructions(User.t(), String.t()) :: {:ok, Swoosh.Email.t()}
  def deliver_reset_password_instructions(%User{} = user, url) do
    deliver(user.email, "Reset your password", """
    Hi #{user.username},

    You recently requested to reset your password.

    Please visit the URL below to choose a new password:

    #{url}

    If you did not request this, you can safely ignore this email.
    The link expires in one hour.
    """)
  end

  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(from_address())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  defp from_address do
    Application.get_env(:crysa, Crysa.Mailer, [])
    |> Keyword.get(:from, {"CrysA", "noreply@crysa.example"})
  end
end
