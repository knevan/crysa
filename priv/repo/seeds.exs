alias Crysa.Accounts

import Nvir

alias Crysa.{Catalog, Moderation, Audit, Repo}
alias Crysa.Catalog.Series

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

# ---- Demo seeds for ecto.reset (1-2 each, idempotent) ----
# Normal user for quick login (user@example.com / password1234)
normal_user =
  case Accounts.get_user_by_email("user@example.com") do
    nil ->
      user_role = Accounts.get_role_by_name("user")
      # precomputed hash for "password1234" to avoid Argon2 cost in seeds
      normal_hash =
        "$argon2id$v=19$m=65536,t=3,p=4$78JyFzqWW/mw6Qu/eRX4Cg$nEBInAvysn57TBn13d2VFi7Hr93Zm5VI2Bel5vvqNJk"

      {:ok, u} =
        Accounts.create_bootstrap_user(%{
          email: "user@example.com",
          username: "user",
          password_hash: normal_hash,
          role_id: user_role.id,
          active: true
        })

      u

    %Accounts.User{} = u ->
      Repo.preload(u, :role)
  end

# Ensure categories exist
["Action", "Drama"]
|> Enum.each(fn name ->
  {:ok, _} = Catalog.get_or_create_category(name)
end)

# Helper to find or create series by slug (idempotent for ecto.reset)
find_or_create_series = fn attrs ->
  case Repo.get_by(Series, slug: attrs.slug) do
    nil ->
      {:ok, s} = Catalog.create_series(attrs)
      s

    %Series{} = s ->
      s
  end
end

series1 =
  find_or_create_series.(%{
    title: "Solo Leveling",
    slug: "solo-leveling",
    description: "A weak hunter becomes the strongest after a mysterious dungeon.",
    source_url: "https://example.test/series/solo-leveling",
    publication_status: "ongoing",
    processing_status: "available"
  })

series2 =
  find_or_create_series.(%{
    title: "One Piece",
    slug: "one-piece",
    description: "Pirate adventure to find the One Piece.",
    source_url: "https://example.test/series/one-piece",
    publication_status: "completed",
    processing_status: "available"
  })

# Ensure at least one chapter per series (for report target)
for series <- [series1, series2] do
  case Crysa.Repo.get_by(Crysa.Catalog.Chapter, series_id: series.id, chapter_key: "ch-1") do
    nil ->
      {:ok, _} =
        Catalog.create_chapter(%{
          series_id: series.id,
          chapter_key: "ch-1",
          display_number: "1",
          sort_key: "000001",
          source_url: "https://example.test/series/#{series.slug}/ch-1",
          status: "available",
          title: "Chapter 1"
        })

      :ok

    _ ->
      :ok
  end
end

# Seed reports (1 pending, 1 resolved) — idempotent via reporter + target + reason
admin_user = Accounts.get_user_by_email(admin_email) || normal_user
chapter1 = Repo.get_by(Crysa.Catalog.Chapter, series_id: series1.id, chapter_key: "ch-1")
chapter2 = Repo.get_by(Crysa.Catalog.Chapter, series_id: series2.id, chapter_key: "ch-1")

if chapter1 && chapter2 do
  # Pending report on chapter1 by normal_user
  case Repo.get_by(Crysa.Moderation.Report,
         reporter_id: normal_user.id,
         chapter_id: chapter1.id,
         reason: "broken_image"
       ) do
    nil ->
      {:ok, _} =
        Moderation.create_report(%{
          reporter_id: normal_user.id,
          chapter_id: chapter1.id,
          reason: "broken_image",
          details: "Seed: image not loading on ch-1"
        })

    _ ->
      :ok
  end

  # Resolved report on chapter2
  case Repo.get_by(Crysa.Moderation.Report,
         reporter_id: normal_user.id,
         chapter_id: chapter2.id,
         reason: "other"
       ) do
    nil ->
      {:ok, rep} =
        Moderation.create_report(%{
          reporter_id: normal_user.id,
          chapter_id: chapter2.id,
          reason: "other",
          details: "Seed: will be resolved"
        })

      {:ok, _} = Moderation.mark_resolved(rep, admin_user, %{resolution_note: "Seed resolved"})

    %Crysa.Moderation.Report{status: "pending"} = rep ->
      {:ok, _} = Moderation.mark_resolved(rep, admin_user, %{resolution_note: "Seed resolved"})

    _ ->
      :ok
  end
end

# Seed audit logs (1-2) — idempotent via action + target
if admin_user do
  existing = Repo.aggregate(Crysa.Audit.AdminAuditLog, :count, :id)

  if existing < 2 do
    {:ok, _} =
      Audit.log_admin_action(%{
        action: "series.create",
        target_type: "series",
        target_id: series1.id,
        target_identifier: series1.slug,
        metadata: %{title: series1.title, seed: true},
        actor: admin_user,
        ip_address: "127.0.0.1",
        user_agent: "seed"
      })

    {:ok, _} =
      Audit.log_admin_action(%{
        action: "user.update",
        target_type: "user",
        target_id: normal_user.id,
        target_identifier: normal_user.username,
        metadata: %{seed: true, note: "seed audit"},
        actor: admin_user,
        ip_address: "127.0.0.1",
        user_agent: "seed"
      })
  end
end

IO.puts("Seeded: normal user (user@example.com), 2 series, 2 chapters, 2 reports, 2 audit logs")
