defmodule Crysa.Moderation do
  @moduledoc """
  Moderation context for user reports and resolution metadata.

  Reports target exactly one chapter or comment. Resolution is restricted to
  moderators and admins and records who resolved, when, and why. The context
  validates that the report reason matches the target type so chapter-specific
  reasons cannot be used to report comments and vice versa.
  """

  alias Crysa.Accounts.User
  alias Crysa.Moderation.{Query, Report}
  alias Crysa.Repo

  @report_reasons ~w(
    broken_image wrong_chapter duplicated_chapter missing_image missing_chapter slow_loading
    broken_text toxic racist spam other
  )
  @chapter_reasons ~w(
    broken_image wrong_chapter duplicated_chapter missing_image missing_chapter slow_loading
    broken_text other
  )
  @comment_reasons ~w(toxic racist spam other)
  @report_statuses ~w(pending resolved rejected)
  @moderator_roles ~w(superadmin admin moderator)

  @spec report_reasons() :: [String.t()]
  def report_reasons, do: @report_reasons

  @spec chapter_report_reasons() :: [String.t()]
  def chapter_report_reasons, do: @chapter_reasons

  @spec comment_report_reasons() :: [String.t()]
  def comment_report_reasons, do: @comment_reasons

  @spec report_statuses() :: [String.t()]
  def report_statuses, do: @report_statuses

  @doc """
  Creates a report.

  Validates that the reason matches the target type (`chapter_id` vs
  `comment_id`). `other` is allowed for either target.
  """
  @spec create_report(map()) :: {:ok, Report.t()} | {:error, Ecto.Changeset.t()}
  def create_report(attrs) when is_map(attrs) do
    changeset = Report.create_changeset(%Report{}, normalize_attrs(attrs))

    case validate_reason_for_target(changeset) do
      :ok -> Repo.insert(changeset)
      {:error, reason} -> {:error, add_report_reason_error(changeset, reason)}
    end
  end

  @spec get_report(integer()) :: Report.t() | nil
  def get_report(id) when is_integer(id), do: Query.get_report(id)

  @spec get_report!(integer()) :: Report.t()
  def get_report!(id) when is_integer(id) do
    case Query.get_report(id) do
      nil -> raise Ecto.NoResultsError, queryable: Report
      report -> report
    end
  end

  @spec list_reports(map()) :: {[Report.t()], Crysa.Pagination.t()}
  def list_reports(params \\ %{}), do: Query.list_reports(params)

  @spec list_pending_reports(map()) :: {[Report.t()], Crysa.Pagination.t()}
  def list_pending_reports(params \\ %{}), do: Query.list_pending_reports(params)

  @spec count_pending() :: non_neg_integer()
  def count_pending, do: Query.count_pending()

  @doc """
  Resolves or rejects a report.

  Only moderators and admins may resolve reports. The report must currently
  be `pending`; resolving an already-resolved report returns
  `{:error, :already_resolved}`. Validates `resolution_note` length and
  required resolution fields.
  """
  @spec resolve_report(Report.t(), User.t(), map()) ::
          {:ok, Report.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :unauthorized | :already_resolved}
  def resolve_report(%Report{} = report, %User{} = actor, attrs) when is_map(attrs) do
    cond do
      not moderator?(actor) ->
        {:error, :unauthorized}

      report.status != "pending" ->
        {:error, :already_resolved}

      true ->
        enriched =
          attrs
          |> normalize_attrs()
          |> Map.put(:resolved_by_id, actor.id)
          |> Map.put(:resolved_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
          |> ensure_status()

        report
        |> Report.resolution_changeset(enriched)
        |> Repo.update()
    end
  end

  @doc "Marks a report as resolved."
  @spec mark_resolved(Report.t(), User.t(), map()) ::
          {:ok, Report.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :unauthorized | :already_resolved}
  def mark_resolved(%Report{} = report, %User{} = actor, attrs \\ %{}) do
    resolve_report(report, actor, Map.put(normalize_attrs(attrs), :status, "resolved"))
  end

  @doc "Marks a report as rejected."
  @spec mark_rejected(Report.t(), User.t(), map()) ::
          {:ok, Report.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :unauthorized | :already_resolved}
  def mark_rejected(%Report{} = report, %User{} = actor, attrs \\ %{}) do
    resolve_report(report, actor, Map.put(normalize_attrs(attrs), :status, "rejected"))
  end

  # Validates that the chosen reason is allowed for the target type.
  defp validate_reason_for_target(changeset) do
    reason = Ecto.Changeset.get_field(changeset, :reason)
    chapter_id = Ecto.Changeset.get_field(changeset, :chapter_id)
    comment_id = Ecto.Changeset.get_field(changeset, :comment_id)

    cond do
      is_nil(reason) ->
        :ok

      not is_nil(chapter_id) and reason not in @chapter_reasons ->
        {:error, "is not allowed for chapter reports"}

      not is_nil(comment_id) and reason not in @comment_reasons ->
        {:error, "is not allowed for comment reports"}

      true ->
        :ok
    end
  end

  defp add_report_reason_error(changeset, message) do
    Ecto.Changeset.add_error(changeset, :reason, message)
  end

  defp ensure_status(attrs) do
    case Map.get(attrs, :status) do
      s when s in ~w(resolved rejected) -> attrs
      _ -> Map.put(attrs, :status, "resolved")
    end
  end

  defp moderator?(actor) do
    case actor do
      %User{role: %{name: name}} when name in @moderator_roles ->
        true

      %User{} = user ->
        case Repo.preload(user, :role) do
          %{role: %{name: name}} when name in @moderator_roles -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) ->
        try do
          {String.to_existing_atom(k), v}
        rescue
          ArgumentError -> {k, v}
        end

      {k, v} ->
        {k, v}
    end)
  end
end
