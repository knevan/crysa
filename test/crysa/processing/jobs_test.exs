defmodule Crysa.Processing.JobsTest do
  @moduledoc false

  use Crysa.DataCase, async: false

  import Oban.Testing
  import Crysa.CatalogFixtures
  import Crysa.ScrapingFixtures

  alias Crysa.Accounts.PasswordResetToken
  alias Crysa.Catalog
  alias Crysa.Library.SeriesViewLog

  alias Crysa.Processing.Jobs.{
    PasswordResetTokenCleanup,
    SeriesCheckScheduler,
    SeriesCheckWorker,
    SeriesDeletionWorker,
    ViewLogCleanup
  }

  alias Crysa.Repo

  describe "SeriesCheckScheduler" do
    test "enqueues a check worker for due-and-eligible series" do
      _due = series_fixture(%{next_check_at: DateTime.add(DateTime.utc_now(), -60)})

      # Not due yet.
      _future = series_fixture(%{next_check_at: DateTime.add(DateTime.utc_now(), 3_600)})

      # Due but unschedulable publication status.
      _discontinued =
        series_fixture(%{
          publication_status: "discontinued",
          next_check_at: DateTime.add(DateTime.utc_now(), -60)
        })

      # Due but pending deletion.
      _deleting =
        series_fixture(%{
          processing_status: "pending_deletion",
          next_check_at: DateTime.add(DateTime.utc_now(), -60)
        })

      {:ok, %{due: due, enqueued: enqueued}} = perform_job(SeriesCheckScheduler, %{}, [])

      assert due == 1
      assert enqueued == 1
    end

    test "no due series is a no-op" do
      assert {:ok, %{due: 0, enqueued: 0}} = perform_job(SeriesCheckScheduler, %{}, [])
    end
  end

  describe "SeriesCheckWorker" do
    setup do
      # Inject a stubbed fetcher for the worker under test (global env; this
      # module runs async: false).
      Application.put_env(:crysa, SeriesCheckWorker,
        fetch_html: fn _url -> {:ok, "<html><body></body></html>"} end
      )

      on_exit(fn -> Application.delete_env(:crysa, SeriesCheckWorker) end)
      :ok
    end

    test "reschedules on success and resets the failure counter" do
      %{site: site} = published_site_fixture()

      series =
        series_fixture(%{
          source_url: "https://#{site.host}/s/1",
          check_retry_count: 3,
          last_error: "previous failure",
          manual_check_interval_minutes: 120
        })

      assert :ok = perform_job(SeriesCheckWorker, %{"series_id" => series.id}, [])

      reloaded = Catalog.get_series(series.id)
      assert reloaded.check_retry_count == 0
      assert is_nil(reloaded.last_error)
      refute is_nil(reloaded.next_check_at)

      minutes = DateTime.diff(reloaded.next_check_at, DateTime.utc_now(), :second) / 60
      assert minutes > 100 and minutes < 140
    end

    test "applies backoff and records the error on failure" do
      %{site: site} = published_site_fixture()

      series =
        series_fixture(%{
          source_url: "https://#{site.host}/s/1",
          manual_check_interval_minutes: 60
        })

      Application.put_env(:crysa, SeriesCheckWorker,
        fetch_html: fn _url -> {:error, :timeout} end
      )

      assert {:error, {:fetch_failed, :timeout}} =
               perform_job(SeriesCheckWorker, %{"series_id" => series.id}, [])

      reloaded = Catalog.get_series(series.id)
      assert reloaded.check_retry_count == 1
      assert reloaded.last_error =~ "timeout"

      minutes = DateTime.diff(reloaded.next_check_at, DateTime.utc_now(), :second) / 60
      # base 60 × backoff 2 ± jitter
      assert minutes > 105 and minutes < 135
    end

    test "missing series completes quietly" do
      assert {:ok, :series_gone} = perform_job(SeriesCheckWorker, %{"series_id" => 999_999}, [])
    end
  end

  describe "SeriesDeletionWorker" do
    test "deletes storage objects then the series row" do
      series =
        series_fixture(%{
          source_url: "https://deletion.example.test/s/1",
          cover_key: "covers/abc.jpg",
          processing_status: "pending_deletion"
        })

      chapter = chapter_fixture(series, %{status: "available"})

      _image =
        Catalog.create_chapter_image(%{
          chapter_id: chapter.id,
          image_order: 1,
          storage_key: "chapters/#{series.id}/12/0001.webp"
        })

      assert :ok = perform_job(SeriesDeletionWorker, %{"series_id" => series.id}, [])

      assert is_nil(Catalog.get_series(series.id))
      # Chapter rows cascaded away.
      assert is_nil(Catalog.get_chapter(chapter.id))
    end

    test "ignores series not pending deletion" do
      series = series_fixture(%{processing_status: "available"})

      assert {:ok, :not_pending_deletion} =
               perform_job(SeriesDeletionWorker, %{"series_id" => series.id}, [])
    end
  end

  describe "PasswordResetTokenCleanup" do
    test "deletes expired tokens and old used tokens" do
      user = user_fixture()

      expired = token_fixture(user, expires_at: DateTime.add(DateTime.utc_now(), -1))
      fresh = token_fixture(user, expires_at: DateTime.add(DateTime.utc_now(), 3600))

      used_old =
        token_fixture(user,
          expires_at: DateTime.add(DateTime.utc_now(), 3600),
          used_at: DateTime.add(DateTime.utc_now(), -30 * 86_400)
        )

      assert {:ok, %{expired_deleted: 1, used_deleted: 1}} =
               perform_job(PasswordResetTokenCleanup, %{}, [])

      assert is_nil(Repo.reload(expired))
      assert is_nil(Repo.reload(used_old))
      refute is_nil(Repo.reload(fresh))
    end
  end

  describe "ViewLogCleanup" do
    test "deletes view logs beyond retention" do
      series = series_fixture()

      old =
        view_log_fixture(series, inserted_at: DateTime.add(DateTime.utc_now(), -200 * 86_400))

      recent = view_log_fixture(series)

      assert {:ok, %{deleted: 1}} = perform_job(ViewLogCleanup, %{}, [])

      assert is_nil(Repo.reload(old))
      refute is_nil(Repo.reload(recent))
    end
  end

  # -- fixtures -----------------------------------------------------------------

  defp user_fixture do
    role = Repo.get_by!(Crysa.Accounts.Role, name: "user")

    {:ok, user} =
      Repo.insert(%Crysa.Accounts.User{
        email: "user#{System.unique_integer([:positive])}@test.example",
        username: "user#{System.unique_integer([:positive])}",
        password_hash: Argon2.hash_pwd_salt("password123"),
        role_id: role.id
      })

    user
  end

  defp token_fixture(user, attrs) do
    defaults = %{
      user_id: user.id,
      token_digest: :crypto.strong_rand_bytes(32),
      expires_at: DateTime.add(DateTime.utc_now(), 3600)
    }

    {:ok, token} =
      struct(PasswordResetToken, Map.merge(defaults, Map.new(attrs)))
      |> Repo.insert()

    token
  end

  defp view_log_fixture(series, attrs \\ []) do
    defaults = %{
      series_id: series.id,
      inserted_at: DateTime.utc_now()
    }

    {:ok, log} =
      struct(SeriesViewLog, Map.merge(defaults, Map.new(attrs)))
      |> Repo.insert()

    log
  end
end
