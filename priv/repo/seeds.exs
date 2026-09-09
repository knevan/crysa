alias Crysa.Accounts

import Nvir

alias Crysa.{Catalog, Comments, Library, Moderation, Audit, Notifications, Repo}
alias Crysa.Catalog.Series

import Ecto.Query, only: [from: 2]

# Real R2 object keys reused as deterministic seed media (objects already
# exist in the bucket; seeds only reference their keys, never re-upload).
seed_avatar_key = "avatars/user_1_dAE5YlDGinc8k00jMIsoLQ.png"
seed_cover_key = "covers/EhpKEsW58zSgWpCgP25cnQ.jpg"

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

# Seed avatar from the real R2 object (idempotent via avatar_key guard)
profile = Accounts.get_or_create_profile(normal_user)

if is_nil(profile.avatar_key) or profile.avatar_key == "" do
  {:ok, _} = Accounts.update_profile(normal_user, %{avatar_key: seed_avatar_key})
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

series3 =
  find_or_create_series.(%{
    title: "Jujutsu Kaisen",
    slug: "jujutsu-kaisen",
    description: "A boy swallows a cursed finger and joins the war against curses.",
    source_url: "https://example.test/series/jujutsu-kaisen",
    publication_status: "ongoing",
    processing_status: "available"
  })

series4 =
  find_or_create_series.(%{
    title: "Berserk",
    slug: "berserk",
    description: "A lone swordsman walks a dark path of vengeance.",
    source_url: "https://example.test/series/berserk",
    publication_status: "hiatus",
    processing_status: "available"
  })

# All seed series share one real R2 cover (idempotent: only fills blank keys,
# so rows created before this seed keep their existing covers).
all_series = [series1, series2, series3, series4]

all_series =
  Enum.map(all_series, fn series ->
    if is_nil(series.cover_key) or series.cover_key == "" do
      {:ok, updated} = Catalog.update_series(series, %{cover_key: seed_cover_key})
      updated
    else
      series
    end
  end)

# Ensure at least one chapter per series (for report target)
for series <- all_series do
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

# Seed series-update notifications for the normal user (idempotent:
# bookmarking and chapter fan-out both dedupe, so reseeds insert nothing).
for series <- all_series do
  {:ok, _} = Library.bookmark_series(normal_user, series)

  case Repo.get_by(Crysa.Catalog.Chapter, series_id: series.id, chapter_key: "ch-1") do
    nil -> :ok
    chapter -> {:ok, _} = Notifications.notify_series_chapter(series.id, chapter.id)
  end
end

# Seed a "new chapter arrival" on series1 (idempotent via chapter_key guard
# plus fan-out dedupe): gives the bookmarked user a second, newer notification.
new_chapter =
  case Repo.get_by(Crysa.Catalog.Chapter, series_id: series1.id, chapter_key: "ch-2") do
    nil ->
      {:ok, ch} =
        Catalog.create_chapter(%{
          series_id: series1.id,
          chapter_key: "ch-2",
          display_number: "2",
          sort_key: "000002",
          source_url: "https://example.test/series/#{series1.slug}/ch-2",
          status: "available",
          title: "Chapter 2"
        })

      ch

    %Crysa.Catalog.Chapter{} = ch ->
      ch
  end

{:ok, _} = Notifications.notify_series_chapter(series1.id, new_chapter.id)

# Seed reports (1 pending, 1 resolved) — idempotent via reporter + target + reason
admin_user = Accounts.get_user_by_email(admin_email) || normal_user
chapter1 = Repo.get_by(Crysa.Catalog.Chapter, series_id: series1.id, chapter_key: "ch-1")
chapter2 = Repo.get_by(Crysa.Catalog.Chapter, series_id: series2.id, chapter_key: "ch-1")

# Seed comment thread + reply/vote notifications via the domain APIs (which
# auto-notify). Idempotent: comments are found by author + target + body,
# repeat votes with the same value are no-ops, so reseeds notify nothing new.
# A distinct actor is required (self-actions never notify) — skipped only if
# no bootstrap admin exists and admin falls back to the normal user.
seed_actor =
  if admin_user.id != normal_user.id, do: admin_user, else: nil

if seed_actor do
  # `get_by` forbids nil comparisons, so root lookup uses is_nil/1.
  find_root = fn body ->
    Repo.one(
      from(c in Crysa.Comments.Comment,
        where:
          c.series_id == ^series1.id and c.user_id == ^normal_user.id and
            is_nil(c.parent_id) and c.body_markdown == ^body
      )
    )
  end

  seed_root =
    case find_root.("Seed: this series hooked me from chapter 1.") do
      nil ->
        {:ok, comment} =
          Comments.create_comment(%{
            user_id: normal_user.id,
            series_id: series1.id,
            body_markdown: "Seed: this series hooked me from chapter 1."
          })

        comment

      %Crysa.Comments.Comment{} = comment ->
        comment
    end

  # Admin reply -> comment_reply notification for normal_user (found by
  # parent + author so reseeds never duplicate the reply).
  if is_nil(Repo.get_by(Crysa.Comments.Comment, parent_id: seed_root.id, user_id: seed_actor.id)) do
    {:ok, _} =
      Comments.create_comment(%{
        user_id: seed_actor.id,
        series_id: series1.id,
        parent_id: seed_root.id,
        body_markdown: "Seed: welcome aboard!"
      })
  end

  # Admin upvote -> comment_upvote notification (same-value revotes no-op).
  {:ok, _} = Comments.vote_comment(seed_actor, seed_root, 1)

  seed_root2 =
    case find_root.("Seed: the art in chapter 2 is stunning.") do
      nil ->
        {:ok, comment} =
          Comments.create_comment(%{
            user_id: normal_user.id,
            series_id: series1.id,
            body_markdown: "Seed: the art in chapter 2 is stunning."
          })

        comment

      %Crysa.Comments.Comment{} = comment ->
        comment
    end

  # Admin downvote on a separate comment -> comment_downvote notification.
  # (Voting the same comment up then down would flip-flop and duplicate
  # notifications on every reseed, hence two root comments.)
  {:ok, _} = Comments.vote_comment(seed_actor, seed_root2, -1)
end

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

IO.puts(
  "Seeded: normal user (user@example.com, avatar), 4 series (covers), 5 chapters, 8 notifications, 3 comments, 2 reports, 2 audit logs"
)
