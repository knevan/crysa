alias Crysa.Accounts

role_descriptions = %{
  "superadmin" => "Full system administrator",
  "admin" => "Application administrator",
  "moderator" => "Content moderator",
  "user" => "Default registered user"
}

Enum.each(role_descriptions, fn {name, description} ->
  Accounts.upsert_role!(name, description)
end)

admin_email = System.get_env("CRYSA_BOOTSTRAP_ADMIN_EMAIL")
admin_username = System.get_env("CRYSA_BOOTSTRAP_ADMIN_USERNAME")
admin_password_hash = System.get_env("CRYSA_BOOTSTRAP_ADMIN_PASSWORD_HASH")

if admin_email && admin_username && admin_password_hash do
  superadmin_role = Accounts.get_role_by_name("superadmin")

  case Accounts.create_user(%{
         email: admin_email,
         username: admin_username,
         password_hash: admin_password_hash,
         role_id: superadmin_role.id,
         active: true
       }) do
    {:ok, _user} -> :ok
    {:error, changeset} ->
      if changeset.errors[:email] || changeset.errors[:username] do
        :ok
      else
        raise "failed to create bootstrap admin: #{inspect(changeset.errors)}"
      end
  end
end
