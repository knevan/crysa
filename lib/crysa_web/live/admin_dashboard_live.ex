defmodule CrysaWeb.Live.AdminDashboardLive do
  @moduledoc """
  Admin dashboard LiveView.

  Thin orchestration over `Crysa.Catalog.admin_list_series/1` and
  `Crysa.Accounts.admin_list_users/1`. All business rules, search escaping and
  pagination clamping live in the context/query layer; this module only maps
  server rows to client props and handles the TanStack table events.

  Both Series and Users tables are TanStack-backed with server pagination and
  folder-like tab navigation matching the provided image. Reports remains a
  placeholder until moderation is wired. Layout: centered title, folder tabs
  overlapping the bordered card, search + page-size controls above each grid.
  """

  use CrysaWeb, :live_view

  alias Crysa.Accounts
  alias Crysa.Catalog
  alias Crysa.Moderation

  @default_page_size 25

  on_mount {CrysaWeb.UserAuth, :mount_current_user}
  on_mount {CrysaWeb.UserAuth, :require_authenticated}
  on_mount {CrysaWeb.UserAuth, :require_admin}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="sr-only" aria-hidden="true">Admin dashboard</div>
    <.vue
      v-component="AdminDashboard"
      v-ssr={false}
      seriesRows={@series_rows}
      pagination={@pagination}
      query={@query}
      pageSize={@page_size}
      userRows={@user_rows}
      userPagination={@user_pagination}
      userQuery={@user_query}
      userPageSize={@user_page_size}
      tags={@tags}
      coverUpload={@uploads.cover}
      reportRows={@report_rows}
      reportPagination={@report_pagination}
      reportStatus={@report_status}
    />
    """
  end

  @impl true
  def mount(params, _session, socket) do
    socket =
      allow_upload(socket, :cover,
        accept: ~w(.jpg .jpeg .png .webp .gif),
        max_entries: 1,
        max_file_size: 5_000_000,
        auto_upload: true
      )

    # Series
    s_query = parse_query(params, "q")
    s_page = parse_page(params, "page")
    s_page_size = parse_page_size(params, "page_size")

    {series, s_pagination} =
      Catalog.admin_list_series(%{
        "q" => s_query,
        "page" => s_page,
        "page_size" => s_page_size
      })

    # Users
    u_query = parse_query(params, "user_q")
    u_page = parse_page(params, "user_page")
    u_page_size = parse_page_size(params, "user_page_size")

    {users, u_pagination} =
      Accounts.admin_list_users(%{
        "q" => u_query,
        "page" => u_page,
        "page_size" => u_page_size
      })

    tags = load_tags()
    r_status = parse_report_status(params)
    r_page = parse_page(params, "report_page")
    r_page_size = parse_page_size(params, "report_page_size")
    {reports, r_pagination} = Moderation.list_reports(%{"status" => r_status, "page" => r_page, "page_size" => r_page_size} |> compact_report_params())

    {:ok,
     assign(socket,
       series_rows: Enum.map(series, &to_series_row/1),
       pagination: to_pagination_map(s_pagination),
       query: s_query,
       page: s_pagination.page,
       page_size: s_pagination.page_size,
       user_rows: Enum.map(users, &to_user_row/1),
       user_pagination: to_pagination_map(u_pagination),
       user_query: u_query,
       user_page: u_pagination.page,
       user_page_size: u_pagination.page_size,
       tags: tags,
       report_rows: Enum.map(reports, &to_report_row/1),
       report_pagination: to_pagination_map(r_pagination),
       report_status: r_status || "all"
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Series
    s_query = parse_query(params, "q")
    s_page = parse_page(params, "page")
    s_page_size = parse_page_size(params, "page_size")

    {series, s_pagination} =
      Catalog.admin_list_series(%{
        "q" => s_query,
        "page" => s_page,
        "page_size" => s_page_size
      })

    # Users
    u_query = parse_query(params, "user_q")
    u_page = parse_page(params, "user_page")
    u_page_size = parse_page_size(params, "user_page_size")

    {users, u_pagination} =
      Accounts.admin_list_users(%{
        "q" => u_query,
        "page" => u_page,
        "page_size" => u_page_size
      })

    tags = load_tags()
    r_status = parse_report_status(params)
    r_page = parse_page(params, "report_page")
    r_page_size = parse_page_size(params, "report_page_size")
    {reports, r_pagination} = Moderation.list_reports(%{"status" => r_status, "page" => r_page, "page_size" => r_page_size} |> compact_report_params())

    {:noreply,
     assign(socket,
       series_rows: Enum.map(series, &to_series_row/1),
       pagination: to_pagination_map(s_pagination),
       query: s_query,
       page: s_pagination.page,
       page_size: s_pagination.page_size,
       user_rows: Enum.map(users, &to_user_row/1),
       user_pagination: to_pagination_map(u_pagination),
       user_query: u_query,
       user_page: u_pagination.page,
       user_page_size: u_pagination.page_size,
       tags: tags,
       report_rows: Enum.map(reports, &to_report_row/1),
       report_pagination: to_pagination_map(r_pagination),
       report_status: r_status || "all"
     )}
  end

  # ---- Tags events ----

  @impl true
  def handle_event("admin:add_tag", %{"name" => name}, socket) do
    case Catalog.create_category(%{name: name}) do
      {:ok, _category} ->
        {:noreply, assign(socket, tags: load_tags())}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, format_category_error(changeset))}
    end
  end

  @impl true
  def handle_event("admin:remove_tag", %{"id" => raw_id}, socket) do
    id = parse_integer(raw_id, nil)

    case id && Catalog.get_category(id) do
      %Crysa.Catalog.Category{} = category ->
        case Catalog.delete_category(category) do
          {:ok, _} -> {:noreply, assign(socket, tags: load_tags())}
          {:error, _} -> {:noreply, put_flash(socket, :error, "Could not delete tag")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Tag not found")}
    end
  end


  @impl true
  def handle_event("admin:create_series", params, socket) do
    title = params["title"] |> to_string() |> String.trim()
    description = params["description"] |> to_string() |> String.trim()
    source_url = params["sourceUrl"] |> to_string() |> String.trim()
    authors = Map.get(params, "authors", [])
    tag_ids = Map.get(params, "selectedTagIds", [])

    # Handle cover upload: consume the uploaded file (buffered in temp/RAM) and store to S3/R2/local
    # The file is first uploaded to LiveView's temp (RAM/disk) via allow_upload, then we move it to Storage
    cover_result =
      consume_uploaded_entries(socket, :cover, fn %{path: path}, entry ->
        upload = %Plug.Upload{
          path: path,
          filename: entry.client_name,
          content_type: entry.client_type
        }

        case Crysa.Storage.store_cover(upload) do
          {:ok, %{url: url}} -> {:ok, url}
          {:error, reason} -> {:postpone, reason}
        end
      end)

    cover_url =
      case cover_result do
        [] -> nil
        [{:ok, url}] -> url
        [{:postpone, _reason}] -> nil
        _ -> nil
      end

    slug = slugify(title)

    attrs =
      %{title: title, slug: slug, description: description, source_url: source_url, publication_status: "ongoing", processing_status: "available"}
      |> maybe_put_cover(cover_url)

    case Catalog.create_series(attrs) do
      {:ok, series} ->
        Enum.each(authors, fn name when is_binary(name) ->
          trimmed = String.trim(name)
          if trimmed != "" do
            {:ok, author} = Catalog.get_or_create_author(trimmed)
            Catalog.add_series_author(series, author)
          end
        end)

        categories =
          tag_ids
          |> Enum.map(&parse_integer(&1, nil))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&Catalog.get_category/1)
          |> Enum.reject(&is_nil/1)

        if categories != [] do
          {:ok, _} = Catalog.set_series_categories(series, categories)
        end

        query = socket.assigns.query
        page_size = socket.assigns.page_size

        {series_list, pagination} =
          Catalog.admin_list_series(%{"q" => query, "page" => 1, "page_size" => page_size})

        {:noreply,
         socket
         |> put_flash(:info, "Series \"#{series.title}\" created")
         |> assign(
           series_rows: Enum.map(series_list, &to_series_row/1),
           pagination: to_pagination_map(pagination),
           page: 1
         )}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, format_series_error(changeset))}
    end
  end

  # ---- Series events (keep legacy names for existing tests) ----

  @impl true
  def handle_event("admin:search", %{"q" => q}, socket) do
    query = q |> to_string() |> String.trim() |> String.slice(0, 100)
    page_size = socket.assigns.page_size

    {series, pagination} =
      Catalog.admin_list_series(%{
        "q" => query,
        "page" => 1,
        "page_size" => page_size
      })

    {:noreply,
     assign(socket,
       series_rows: Enum.map(series, &to_series_row/1),
       pagination: to_pagination_map(pagination),
       query: query,
       page: 1
     )}
  end

  @impl true
  def handle_event("admin:page_change", %{"page" => raw_page}, socket) do
    query = socket.assigns.query
    page_size = socket.assigns.page_size
    page = parse_integer(raw_page, 1)

    {series, pagination} =
      Catalog.admin_list_series(%{
        "q" => query,
        "page" => page,
        "page_size" => page_size
      })

    {:noreply,
     assign(socket,
       series_rows: Enum.map(series, &to_series_row/1),
       pagination: to_pagination_map(pagination),
       page: pagination.page
     )}
  end

  @impl true
  def handle_event("admin:page_size_change", %{"page_size" => raw_size}, socket) do
    query = socket.assigns.query
    page_size = parse_integer(raw_size, @default_page_size) |> clamp(1, 100)

    {series, pagination} =
      Catalog.admin_list_series(%{
        "q" => query,
        "page" => 1,
        "page_size" => page_size
      })

    {:noreply,
     assign(socket,
       series_rows: Enum.map(series, &to_series_row/1),
       pagination: to_pagination_map(pagination),
       query: query,
       page: 1,
       page_size: pagination.page_size
     )}
  end

  # ---- Users events ----

  @impl true
  def handle_event("admin:users_search", %{"q" => q}, socket) do
    query = q |> to_string() |> String.trim() |> String.slice(0, 100)
    page_size = socket.assigns.user_page_size

    {users, pagination} =
      Accounts.admin_list_users(%{
        "q" => query,
        "page" => 1,
        "page_size" => page_size
      })

    {:noreply,
     assign(socket,
       user_rows: Enum.map(users, &to_user_row/1),
       user_pagination: to_pagination_map(pagination),
       user_query: query,
       user_page: 1
     )}
  end

  @impl true
  def handle_event("admin:users_page_change", %{"page" => raw_page}, socket) do
    query = socket.assigns.user_query
    page_size = socket.assigns.user_page_size
    page = parse_integer(raw_page, 1)

    {users, pagination} =
      Accounts.admin_list_users(%{
        "q" => query,
        "page" => page,
        "page_size" => page_size
      })

    {:noreply,
     assign(socket,
       user_rows: Enum.map(users, &to_user_row/1),
       user_pagination: to_pagination_map(pagination),
       user_page: pagination.page
     )}
  end

  @impl true
  def handle_event("admin:users_page_size_change", %{"page_size" => raw_size}, socket) do
    query = socket.assigns.user_query
    page_size = parse_integer(raw_size, @default_page_size) |> clamp(1, 100)

    {users, pagination} =
      Accounts.admin_list_users(%{
        "q" => query,
        "page" => 1,
        "page_size" => page_size
      })

    {:noreply,
     assign(socket,
       user_rows: Enum.map(users, &to_user_row/1),
       user_pagination: to_pagination_map(pagination),
       user_query: query,
       user_page: 1,
       user_page_size: pagination.page_size
     )}
  end

  # ---- Reports events ----

  @impl true
  def handle_event("admin:reports_page_change", %{"page" => raw_page}, socket) do
    status = socket.assigns.report_status
    page_size = socket.assigns.report_pagination.pageSize
    page = parse_integer(raw_page, 1)

    {reports, pagination} =
      Moderation.list_reports(%{"status" => status, "page" => page, "page_size" => page_size} |> compact_report_params())

    {:noreply,
     assign(socket,
       report_rows: Enum.map(reports, &to_report_row/1),
       report_pagination: to_pagination_map(pagination),
       report_status: status
     )}
  end

  @impl true
  def handle_event("admin:reports_page_size_change", %{"page_size" => raw_size}, socket) do
    status = socket.assigns.report_status
    page_size = parse_integer(raw_size, @default_page_size) |> clamp(1, 100)

    {reports, pagination} =
      Moderation.list_reports(%{"status" => status, "page" => 1, "page_size" => page_size} |> compact_report_params())

    {:noreply,
     assign(socket,
       report_rows: Enum.map(reports, &to_report_row/1),
       report_pagination: to_pagination_map(pagination),
       report_status: status
     )}
  end

  @impl true
  def handle_event("admin:reports_status_change", %{"status" => raw_status}, socket) do
    status = parse_report_status(%{"status" => raw_status})
    page_size = socket.assigns.report_pagination.pageSize

    {reports, pagination} =
      Moderation.list_reports(%{"status" => status, "page" => 1, "page_size" => page_size} |> compact_report_params())

    {:noreply,
     assign(socket,
       report_rows: Enum.map(reports, &to_report_row/1),
       report_pagination: to_pagination_map(pagination),
       report_status: status || "all"
     )}
  end

  @impl true
  def handle_event("admin:resolve_report", %{"id" => raw_id}, socket) do
    id = parse_integer(raw_id, nil)
    actor = socket.assigns.current_user

    case id && Moderation.get_report(id) do
      %Crysa.Moderation.Report{} = report ->
        case Moderation.mark_resolved(report, actor, %{}) do
          {:ok, _} ->
            status = socket.assigns.report_status
            page = socket.assigns.report_pagination.page
            page_size = socket.assigns.report_pagination.pageSize
            {reports, pagination} = Moderation.list_reports(%{"status" => status, "page" => page, "page_size" => page_size} |> compact_report_params())
            {:noreply, assign(socket, report_rows: Enum.map(reports, &to_report_row/1), report_pagination: to_pagination_map(pagination))}

          {:error, :already_resolved} ->
            {:noreply, put_flash(socket, :error, "Report already resolved")}

          {:error, :unauthorized} ->
            {:noreply, put_flash(socket, :error, "Not authorized")}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, format_report_error(changeset))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Report not found")}
    end
  end

  @impl true
  def handle_event("admin:reject_report", %{"id" => raw_id}, socket) do
    id = parse_integer(raw_id, nil)
    actor = socket.assigns.current_user

    case id && Moderation.get_report(id) do
      %Crysa.Moderation.Report{} = report ->
        case Moderation.mark_rejected(report, actor, %{}) do
          {:ok, _} ->
            status = socket.assigns.report_status
            page = socket.assigns.report_pagination.page
            page_size = socket.assigns.report_pagination.pageSize
            {reports, pagination} = Moderation.list_reports(%{"status" => status, "page" => page, "page_size" => page_size} |> compact_report_params())
            {:noreply, assign(socket, report_rows: Enum.map(reports, &to_report_row/1), report_pagination: to_pagination_map(pagination))}

          {:error, :already_resolved} ->
            {:noreply, put_flash(socket, :error, "Report already resolved")}

          {:error, :unauthorized} ->
            {:noreply, put_flash(socket, :error, "Not authorized")}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, format_report_error(changeset))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Report not found")}
    end
  end

  defp load_tags do
    Catalog.list_categories()
    |> Enum.map(fn c -> %{id: c.id, name: c.name} end)
    |> Enum.sort_by(& &1.name, :asc)
  end

  defp format_category_error(changeset) do
    case changeset.errors[:name] do
      {msg, _} -> "Tag #{msg}"
      _ -> "Could not create tag"
    end
  end

  defp parse_report_status(%{"status" => s}) when s in ~w(pending resolved rejected), do: s
  defp parse_report_status(%{status: s}) when s in ~w(pending resolved rejected), do: s
  defp parse_report_status(%{"status" => "all"}), do: nil
  defp parse_report_status(%{status: "all"}), do: nil
  defp parse_report_status(_), do: nil

  defp compact_report_params(params) when is_map(params) do
    case Map.get(params, "status") || Map.get(params, :status) do
      s when s in ~w(pending resolved rejected) -> params
      _ -> Map.drop(params, ["status", :status])
    end
  end

  defp to_report_row(report) do
    %{
      id: report.id,
      reason: report.reason,
      details: report.details,
      status: report.status,
      reporter: report.reporter && report.reporter.username,
      targetType: if(report.chapter_id, do: "chapter", else: "comment"),
      targetId: report.chapter_id || report.comment_id,
      insertedAt: format_datetime(report.inserted_at),
      resolvedAt: format_datetime(report.resolved_at)
    }
  end

  defp format_report_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join(", ", fn {k, msgs} -> "#{k} #{Enum.join(msgs, ", ")}" end)
    |> case do
      "" -> "Could not update report"
      msg -> msg
    end
  end

  defp slugify(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp slugify(_), do: ""

  defp maybe_put_cover(attrs, nil), do: attrs
  defp maybe_put_cover(attrs, url) when is_binary(url), do: Map.put(attrs, :cover_url, url)

  defp format_series_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join(", ", fn {k, msgs} -> "#{k} #{Enum.join(msgs, ", ")}" end)
    |> case do
      "" -> "Could not create series"
      msg -> msg
    end
  end

  # ---- Mappers ----

  defp to_series_row(series) do
    authors =
      case series do
        %{authors: authors} when is_list(authors) -> Enum.map(authors, & &1.name)
        _ -> []
      end

    %{
      id: series.id,
      title: series.title,
      slug: series.slug,
      authors: authors,
      publicationStatus: series.publication_status,
      processingStatus: series.processing_status,
      sourceUrl: series.source_url,
      coverUrl: series.cover_url,
      updatedAt: format_datetime(series.updated_at),
      insertedAt: format_datetime(series.inserted_at)
    }
  end

  defp to_user_row(user) do
    %{
      id: user.id,
      username: user.username,
      email: user.email,
      role: user.role && user.role.name,
      active: user.active,
      insertedAt: format_datetime(user.inserted_at),
      updatedAt: format_datetime(user.updated_at)
    }
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_datetime(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp to_pagination_map(%Crysa.Pagination{} = p) do
    %{
      page: p.page,
      pageSize: p.page_size,
      totalEntries: p.total_entries,
      totalPages: p.total_pages,
      hasPrevious: p.page > 1,
      hasNext: p.page < p.total_pages
    }
  end

  defp parse_query(params, key) when is_binary(key) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      q when is_binary(q) -> q |> String.trim() |> String.slice(0, 100)
      _ -> ""
    end
  end

  defp parse_page(params, key) when is_binary(key) do
    raw = Map.get(params, key) || Map.get(params, String.to_atom(key))
    parse_integer(raw, 1)
  end

  defp parse_page_size(params, key) when is_binary(key) do
    raw = Map.get(params, key) || Map.get(params, String.to_atom(key))
    parse_integer(raw, @default_page_size)
  end

  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp parse_integer(_, default), do: default

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value
end
