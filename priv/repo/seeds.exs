alias Crysa.Accounts

import Nvir

role_descriptions = %{
  "superadmin" => "Full system administrator",
  "admin" => "Application administrator",
  "moderator" => "Content moderator",
  "user" => "Default registered user"
}

Enum.each(role_descriptions, fn {name, description} ->
  Accounts.upsert_role!(name, description)
end)

admin_email = env!("CRYSA_BOOTSTRAP_ADMIN_EMAIL", :string!)
admin_username = env!("CRYSA_BOOTSTRAP_ADMIN_USERNAME", :string!)

# Support both plain password (CRYSA_BOOTSTRAP_ADMIN_PASSWORD) and pre-hashed (CRYSA_BOOTSTRAP_ADMIN_PASSWORD_HASH)
# If value looks like an Argon2 hash ($argon2...), use directly, otherwise hash it
admin_password_raw =
  System.get_env("CRYSA_BOOTSTRAP_ADMIN_PASSWORD") ||
    env!("CRYSA_BOOTSTRAP_ADMIN_PASSWORD_HASH", :string!)

admin_password_hash =
  if is_binary(admin_password_raw) and String.starts_with?(admin_password_raw, "$argon2") do
    admin_password_raw
  else
    Accounts.hash_password(admin_password_raw)
  end

if admin_email && admin_username && admin_password_hash do
  superadmin_role = Accounts.get_role_by_name("superadmin")

  case Accounts.create_bootstrap_user(%{
         email: admin_email,
         username: admin_username,
         password_hash: admin_password_hash,
         role_id: superadmin_role.id,
         active: true
       }) do
    {:ok, _user} ->
      :ok

    {:error, changeset} ->
      if changeset.errors[:email] || changeset.errors[:username] do
        :ok
      else
        raise "failed to create bootstrap admin: #{inspect(changeset.errors)}"
      end
  end
end
