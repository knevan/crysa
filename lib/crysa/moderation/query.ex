defmodule Crysa.Moderation.Query do
  @moduledoc """
  Read-model queries for reports.
  """

  import Ecto.Query

  alias Crysa.Moderation.Report
  alias Crysa.Pagination
  alias Crysa.Repo

  @default_page_size 20
  @max_page_size 50

  @spec list_reports(map()) :: {[Report.t()], Pagination.t()}
  def list_reports(params \\ %{}) when is_map(params) do
    base =
      from(r in Report,
        order_by: [desc: r.inserted_at, desc: r.id],
        preload: [:reporter, :chapter, :comment, :resolved_by]
      )
      |> filter_status(params)

    paginate(base, params)
  end

  @spec list_pending_reports(map()) :: {[Report.t()], Pagination.t()}
  def list_pending_reports(params \\ %{}) when is_map(params) do
    params
    |> Map.put("status", "pending")
    |> list_reports()
  end

  @spec get_report(integer()) :: Report.t() | nil
  def get_report(id) when is_integer(id) do
    from(r in Report,
      where: r.id == ^id,
      preload: [:reporter, :chapter, :comment, :resolved_by]
    )
    |> Repo.one()
  end

  @spec count_pending() :: non_neg_integer()
  def count_pending do
    from(r in Report, where: r.status == "pending")
    |> Repo.aggregate(:count, :id)
  end

  defp filter_status(query, %{"status" => status}) when status in ~w(pending resolved rejected) do
    where(query, [r], r.status == ^status)
  end

  defp filter_status(query, %{status: status}) when status in ~w(pending resolved rejected) do
    where(query, [r], r.status == ^status)
  end

  defp filter_status(query, _), do: query

  defp paginate(query, params) do
    page = parse_page(params)
    page_size = parse_page_size(params)
    total = Repo.aggregate(query, :count, :id)
    page = clamp_page(page, page_size, total)

    results =
      query
      |> limit(^page_size)
      |> offset(^((page - 1) * page_size))
      |> Repo.all()

    {results, Pagination.build(page, page_size, total)}
  end

  defp parse_page(params) do
    case parse_integer(params, "page", 1) do
      page when page > 0 -> page
      _ -> 1
    end
  end

  defp clamp_page(page, page_size, total) do
    total_pages = max(div(total + page_size - 1, page_size), 1)
    min(page, total_pages)
  end

  defp parse_page_size(params, default \\ @default_page_size, max \\ @max_page_size) do
    params
    |> parse_integer("page_size", default)
    |> clamp(1, max)
  end

  defp parse_integer(params, key, default) do
    case params do
      %{^key => value} when is_integer(value) ->
        value

      %{^key => value} when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value
end
