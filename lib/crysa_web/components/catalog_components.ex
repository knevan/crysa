defmodule CrysaWeb.CatalogComponents do
  @moduledoc """
  Reusable UI components for the catalog read model.
  """

  use CrysaWeb, :html

  attr :series, Crysa.Catalog.Series, required: true

  def series_card(assigns) do
    ~H"""
    <a href={~p"/series/#{@series.slug}"} class="card bg-base-100 shadow hover:shadow-lg transition">
      <figure class="aspect-[3/4] overflow-hidden">
        <img
          src={@series.cover_url || ~p"/images/placeholder-cover.svg"}
          alt={@series.title}
          loading="lazy"
          class="h-full w-full object-cover"
        />
      </figure>
      <div class="card-body gap-1 p-4">
        <h2 class="card-title line-clamp-1 text-sm">{@series.title}</h2>
        <div class="flex items-center justify-between text-xs text-base-content/60">
          <span>{@series.chapter_count} chapters</span>
          <span class="badge badge-outline badge-sm">{@series.publication_status}</span>
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
end
