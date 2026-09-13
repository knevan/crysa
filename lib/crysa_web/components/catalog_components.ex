defmodule CrysaWeb.CatalogComponents do
  @moduledoc """
  Reusable UI components for the catalog read model.
  """

  use CrysaWeb, :html

  attr :series, Crysa.Catalog.Series, required: true

  def series_card(assigns) do
    ~H"""
    <a href={~p"/series/#{@series.slug}"} class="card bg-transparent transition hover:opacity-95">
      <figure class="aspect-3/4 overflow-hidden rounded-lg border border-base-300 bg-base-200">
        <img
          src={Crysa.Catalog.cover_url(@series) || ~p"/images/placeholder-cover.svg"}
          alt={@series.title}
          loading="lazy"
          onerror="this.onerror=null;this.src='/images/placeholder-cover.svg'"
          class="h-full w-full object-cover"
        />
      </figure>
      <div class="card-body gap-1 p-4">
        <h2 class="card-title line-clamp-2 min-h-10 text-sm leading-5">{@series.title}</h2>
        <div class="flex items-center justify-between text-xs text-base-content/60">
          <span>{@series.chapter_count} chapters</span>
          <span
            :if={last_update = last_update_at(@series)}
            class="inline-flex items-center gap-1"
            title={Calendar.strftime(last_update, "%Y-%m-%d %H:%M UTC")}
          >
            <.icon name="hero-clock" class="size-3.5" />
            <time datetime={DateTime.to_iso8601(last_update)}>{time_ago(last_update)}</time>
          </span>
        </div>
      </div>
    </a>
    """
  end

  attr :pagination, Crysa.Pagination, required: true
  attr :path, :string, required: true
  attr :params, :map, default: %{}

  def pagination(assigns) do
    ~H"""
    <nav :if={@pagination.total_pages > 1} class="join">
      <a
        :if={Crysa.Pagination.has_previous?(@pagination)}
        href={page_url(@path, @params, Crysa.Pagination.previous_page(@pagination))}
        class="btn join-item btn-outline"
      >
        Previous
      </a>
      <span class="btn join-item btn-ghost no-animation">
        Page {@pagination.page} of {@pagination.total_pages}
      </span>
      <a
        :if={Crysa.Pagination.has_next?(@pagination)}
        href={page_url(@path, @params, Crysa.Pagination.next_page(@pagination))}
        class="btn join-item btn-outline"
      >
        Next
      </a>
    </nav>
    """
  end

  defp page_url(path, params, page) do
    params
    |> Map.put("page", to_string(page))
    |> URI.encode_query()
    |> then(&"#{path}?#{&1}")
  end

  # Last-update timestamp for the card meta row: newest chapter first,
  # falling back to the series update time so chapterless series still
  # render a consistent row.
  defp last_update_at(%{last_chapter_at: %DateTime{} = at}), do: at
  defp last_update_at(%{updated_at: %DateTime{} = at}), do: at
  defp last_update_at(_), do: nil

  # Compact relative time ("5m ago") for the icon-only last-update meta.
  defp time_ago(%DateTime{} = at) do
    seconds = max(DateTime.diff(DateTime.utc_now(), at), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      seconds < 604_800 -> "#{div(seconds, 86_400)}d ago"
      seconds < 2_592_000 -> "#{div(seconds, 604_800)}w ago"
      seconds < 31_536_000 -> "#{div(seconds, 2_592_000)}mo ago"
      true -> "#{div(seconds, 31_536_000)}y ago"
    end
  end
end
