defmodule CrysaWeb.CatalogController do
  use CrysaWeb, :controller

  alias Crysa.Catalog

  def index(conn, params) do
    {series, pagination} = Catalog.browse_series(params)
    categories = Catalog.list_categories_with_counts()

    render(conn, :index,
      page_title: "Browse Series",
      series: series,
      pagination: pagination,
      categories: categories,
      params: params
    )
  end

  def popular(conn, params) do
    {series, pagination} = Catalog.list_most_viewed(params)

    render(conn, :popular,
      page_title: "Most Viewed",
      series: series,
      pagination: pagination,
      params: params
    )
  end

  def updates(conn, params) do
    {series, pagination} = Catalog.list_latest_updates(params)

    render(conn, :updates,
      page_title: "Latest Updates",
      series: series,
      pagination: pagination,
      params: params
    )
  end

  def tags(conn, _params) do
    categories = Catalog.list_categories_with_counts()

    render(conn, :tags, page_title: "Tags", categories: categories)
  end

  def show(conn, %{"slug" => slug} = params) do
    case Catalog.get_series_by_slug(slug) do
      nil ->
        not_found(conn)

      series ->
        {chapters, pagination} = Catalog.list_chapters(series.id, params)
        latest_chapter = Catalog.get_latest_chapter(series.id)

        render(conn, :show,
          page_title: series.title,
          series: series,
          chapters: chapters,
          pagination: pagination,
          latest_chapter: latest_chapter
        )
    end
  end

  def reader(conn, %{"slug" => slug, "chapter_key" => chapter_key}) do
    case Catalog.get_series_by_slug(slug) do
      nil ->
        not_found(conn)

      series ->
        case Catalog.get_reader_chapter(series.id, chapter_key) do
          nil ->
            not_found(conn)

          chapter ->
            {previous, next} = Catalog.chapter_navigation(series.id, chapter_key)

            render(conn, :reader,
              page_title: "#{series.title} - Chapter #{chapter.display_number}",
              series: series,
              chapter: chapter,
              previous: previous,
              next: next
            )
        end
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(404)
    |> put_view(html: CrysaWeb.ErrorHTML)
    |> render("404.html")
    |> halt()
  end
end
