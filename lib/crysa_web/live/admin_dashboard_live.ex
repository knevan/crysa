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

  Extensions in this phase (8):
    * Chapter list/delete/repair — improved over Castra: stable `chapter_id`
      identity, bounded pagination, storage cleanup before DB delete, durable
      Oban repair jobs with host validation.
    * User update/delete — modal dialog with hierarchy enforcement (cannot
      edit self, cannot edit equal/higher role, cannot promote to own level).
    * Per-series check scheduling — status-derived intervals, manual override
      (`nil` = auto), effective interval display and immediate `next_check_at`
      recompute on status/manual change.
  """

  use CrysaWeb, :live_view

  alias Crysa.Accounts
  alias Crysa.Audit
  alias Crysa.Catalog
  alias Crysa.Moderation
  alias Crysa.Processing.CheckSchedule

  @default_page_size 25
  @chapter_default_page_size 25

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
      chapterRows={@chapter_rows}
      chapterPagination={@chapter_pagination}
      chapterSeriesId={@chapter_series_id}
      chapterSeriesTitle={@chapter_series_title}
      auditRows={@audit_rows}
      auditPagination={@audit_pagination}
      auditAction={@audit_action}
      auditTargetType={@audit_target_type}
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

    {reports, r_pagination} =
      Moderation.list_reports(
        %{"status" => r_status, "page" => r_page, "page_size" => r_page_size}
        |> compact_report_params()
      )

    # Audit logs
    audit_action = parse_audit_action(params)
    audit_target_type = parse_audit_target_type(params)
    audit_page = parse_page(params, "audit_page")
    audit_page_size = parse_page_size(params, "audit_page_size")

    {audit_logs, audit_pagination} =
      Audit.list_audit_logs(%{
        "action" => audit_action,
        "target_type" => audit_target_type,
        "page" => audit_page,
        "page_size" => audit_page_size
      })

    empty_chapter_pagination =
      to_pagination_map(Crysa.Pagination.build(1, @chapter_default_page_size, 0))

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
       report_status: r_status || "all",
       audit_rows: Enum.map(audit_logs, &to_audit_row/1),
       audit_pagination: to_pagination_map(audit_pagination),
       audit_action: audit_action || "all",
       audit_target_type: audit_target_type || "all",
       audit_page: audit_pagination.page,
       audit_page_size: audit_pagination.page_size,
       chapter_rows: [],
       chapter_pagination: empty_chapter_pagination,
       chapter_series_id: nil,
       chapter_series_title: nil,
       chapter_page: 1,
       chapter_page_size: @chapter_default_page_size
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

    {reports, r_pagination} =
      Moderation.list_reports(
        %{"status" => r_status, "page" => r_page, "page_size" => r_page_size}
        |> compact_report_params()
      )

    audit_action = parse_audit_action(params)
    audit_target_type = parse_audit_target_type(params)
    audit_page = parse_page(params, "audit_page")
    audit_page_size = parse_page_size(params, "audit_page_size")

    {audit_logs, audit_pagination} =
      Audit.list_audit_logs(%{
        "action" => audit_action,
        "target_type" => audit_target_type,
        "page" => audit_page,
        "page_size" => audit_page_size
      })

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
       report_status: r_status || "all",
       audit_rows: Enum.map(audit_logs, &to_audit_row/1),
       audit_pagination: to_pagination_map(audit_pagination),
       audit_action: audit_action || "all",
       audit_target_type: audit_target_type || "all",
       audit_page: audit_pagination.page,
       audit_page_size: audit_pagination.page_size
     )}
  end

  # ---- Tags events ----

  @impl true
  def handle_event("admin:add_tag", %{"name" => name}, socket) do
    case Catalog.create_category(%{name: name}) do
      {:ok, category} ->
        audit(socket, "category.create", "category", category.id, category.name, %{name: name})
        {:noreply, socket |> assign(tags: load_tags()) |> refresh_audit_rows()}

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
          {:ok, _} ->
            audit(socket, "category.delete", "category", category.id, category.name, %{})
            {:noreply, socket |> assign(tags: load_tags()) |> refresh_audit_rows()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not delete tag")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Tag not found")}
    end
  end

  @impl true
  def handle_event("validate_cover", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  # Drops a staged cover entry when the admin dismisses the dialog without
  # creating. Idempotent: unknown refs (already consumed or never staged)
  # are ignored so a late cancel after a successful create is harmless.
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, maybe_cancel_cover_upload(socket, ref)}
  end

  def handle_event("cancel-upload", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("admin:create_series", params, socket) do
    title = params["title"] |> to_string() |> String.trim()
    description = params["description"] |> to_string() |> String.trim()
    source_url = params["sourceUrl"] |> to_string() |> String.trim()
    authors = Map.get(params, "authors", [])
    tag_ids = Map.get(params, "selectedTagIds", [])
    cover_file_name = params["coverFileName"] |> to_string() |> String.trim()

    # NOTE: `consume_uploaded_entries/3` returns UNWRAPPED `{:ok, value}`
    # payloads (bare values, never `{:ok, ...}` tuples), so the fun tags its
    # own outcomes (`:stored` / `:storage_error`) — same pattern as
    # `UserSettingsLive` avatar upload.
    cover_result =
      consume_uploaded_entries(socket, :cover, fn %{path: path}, entry ->
        upload = %Plug.Upload{
          path: path,
          filename: entry.client_name,
          content_type: entry.client_type
        }

        case Crysa.Storage.store_cover(upload) do
          {:ok, %{key: key}} ->
            {:ok, {:stored, key}}

          {:error, reason} ->
            require Logger

            Logger.error("cover upload failed",
              reason: inspect(reason),
              filename: entry.client_name
            )

            {:ok, {:storage_error, reason}}
        end
      end)

    # Detect upload validation or storage errors
    upload_errors = socket.assigns.uploads.cover.errors

    {cover_key, cover_error} =
      resolve_cover_outcome(cover_result, upload_errors, cover_file_name)

    if cover_error do
      {:noreply,
       put_flash(
         socket,
         :error,
         case cover_error do
           {:validation, errors} ->
             "Cover upload failed: #{inspect(errors)}"

           {:storage, reason} ->
             "Cover upload to R2 failed: #{inspect(reason)} — check S3 config and bucket"

           {:pending, _} ->
             "Cover upload was not received yet — wait until 100% uploaded, then try again"

           _ ->
             "Cover upload failed"
         end
       )}
    else
      slug = slugify(title)

      attrs =
        %{
          title: title,
          slug: slug,
          description: description,
          source_url: source_url,
          publication_status: "ongoing",
          processing_status: "available"
        }
        |> maybe_put_cover_key(cover_key)

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

          audit(socket, "series.create", "series", series.id, series.slug, %{
            title: series.title,
            source_url: series.source_url,
            authors: authors,
            category_ids: tag_ids
          })

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
           )
           |> refresh_audit_rows()}

        {:error, changeset} ->
          {:noreply, put_flash(socket, :error, format_series_error(changeset))}
      end
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

  # ---- Chapter events ----

  @impl true
  def handle_event("admin:list_chapters", %{"series_id" => raw_id} = params, socket) do
    series_id = parse_integer(raw_id, nil)

    if is_nil(series_id) do
      {:noreply, put_flash(socket, :error, "Invalid series")}
    else
      page = parse_integer(Map.get(params, "page", socket.assigns.chapter_page), 1)

      page_size =
        parse_integer(
          Map.get(params, "page_size", socket.assigns.chapter_page_size),
          @chapter_default_page_size
        )
        |> clamp(1, 100)

      series = Catalog.get_series(series_id)

      if is_nil(series) do
        {:noreply, put_flash(socket, :error, "Series not found")}
      else
        {chapters, pagination} =
          Catalog.admin_list_chapters(series_id, %{"page" => page, "page_size" => page_size})

        {:noreply,
         assign(socket,
           chapter_rows: Enum.map(chapters, &to_chapter_row/1),
           chapter_pagination: to_pagination_map(pagination),
           chapter_series_id: series_id,
           chapter_series_title: series.title,
           chapter_page: pagination.page,
           chapter_page_size: pagination.page_size
         )}
      end
    end
  end

  @impl true
  def handle_event("admin:chapters_page_change", %{"page" => raw_page}, socket) do
    series_id = socket.assigns.chapter_series_id

    if is_nil(series_id) do
      {:noreply, socket}
    else
      page = parse_integer(raw_page, 1)
      page_size = socket.assigns.chapter_page_size

      {chapters, pagination} =
        Catalog.admin_list_chapters(series_id, %{"page" => page, "page_size" => page_size})

      {:noreply,
       assign(socket,
         chapter_rows: Enum.map(chapters, &to_chapter_row/1),
         chapter_pagination: to_pagination_map(pagination),
         chapter_page: pagination.page
       )}
    end
  end

  @impl true
  def handle_event("admin:chapters_page_size_change", %{"page_size" => raw_size}, socket) do
    series_id = socket.assigns.chapter_series_id

    if is_nil(series_id) do
      {:noreply, socket}
    else
      page_size = parse_integer(raw_size, @chapter_default_page_size) |> clamp(1, 100)

      {chapters, pagination} =
        Catalog.admin_list_chapters(series_id, %{"page" => 1, "page_size" => page_size})

      {:noreply,
       assign(socket,
         chapter_rows: Enum.map(chapters, &to_chapter_row/1),
         chapter_pagination: to_pagination_map(pagination),
         chapter_page: 1,
         chapter_page_size: pagination.page_size
       )}
    end
  end

  @impl true
  def handle_event("admin:delete_chapter", %{"id" => raw_id}, socket) do
    chapter_id = parse_integer(raw_id, nil)

    if is_nil(chapter_id) do
      {:noreply, put_flash(socket, :error, "Invalid chapter")}
    else
      case Catalog.admin_delete_chapter(chapter_id) do
        {:ok, deleted} ->
          audit(socket, "chapter.delete", "chapter", deleted.id, deleted.chapter_key, %{
            series_id: deleted.series_id,
            display_number: deleted.display_number
          })

          socket = put_flash(socket, :info, "Chapter deleted")
          # Refresh chapter list for current series and series table counters
          socket = socket |> refresh_series_rows() |> refresh_audit_rows()
          refresh_chapter_list(socket)

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Chapter not found")}

        {:error, {:storage_delete_failed, reason}} ->
          {:noreply, put_flash(socket, :error, "Storage delete failed: #{inspect(reason)}")}

        {:error, %Ecto.Changeset{} = cs} ->
          {:noreply, put_flash(socket, :error, format_series_error(cs))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not delete chapter: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("admin:repair_chapter", %{"id" => raw_id} = params, socket) do
    chapter_id = parse_integer(raw_id, nil)
    new_url = Map.get(params, "new_source_url") || Map.get(params, "newSourceUrl")

    if is_nil(chapter_id) do
      {:noreply, put_flash(socket, :error, "Invalid chapter")}
    else
      trimmed_url =
        case new_url do
          v when is_binary(v) -> String.trim(v)
          _ -> nil
        end

      url_for_validation =
        if trimmed_url in [nil, ""], do: nil, else: trimmed_url

      case Catalog.admin_repair_chapter(chapter_id, url_for_validation) do
        {:ok, _job} ->
          audit(
            socket,
            "chapter.repair",
            "chapter",
            chapter_id,
            url_for_validation || "existing_url",
            %{
              new_source_url: url_for_validation
            }
          )

          {:noreply,
           socket |> put_flash(:info, "Chapter repair enqueued") |> refresh_audit_rows()}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Chapter not found")}

        {:error, :invalid_url} ->
          {:noreply, put_flash(socket, :error, "Invalid replacement URL")}

        {:error, reason} when reason in [:unknown_host, :no_published_config, :site_disabled] ->
          {:noreply, put_flash(socket, :error, "No published scraping config for that host")}

        {:error, {:already_exists, _}} ->
          {:noreply, put_flash(socket, :info, "Repair already queued for this chapter")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not enqueue repair: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("admin:delete_series", %{"id" => raw_id}, socket) do
    series_id = parse_integer(raw_id, nil)

    if is_nil(series_id) do
      {:noreply, put_flash(socket, :error, "Invalid series")}
    else
      case Catalog.admin_delete_series(series_id) do
        {:ok, pending} ->
          audit(socket, "series.delete", "series", pending.id, pending.slug, %{
            title: pending.title,
            source_url: pending.source_url
          })

          socket =
            socket
            |> put_flash(
              :info,
              "Series \"#{pending.title}\" queued for deletion (storage + DB will be removed by worker)"
            )
            |> then(&refresh_series_rows(&1))
            |> refresh_audit_rows()

          socket =
            if socket.assigns.chapter_series_id == series_id do
              assign(socket,
                chapter_rows: [],
                chapter_series_id: nil,
                chapter_series_title: nil
              )
            else
              socket
            end

          {:noreply, socket}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Series not found")}

        {:error, :already_pending_deletion} ->
          {:noreply, put_flash(socket, :error, "Series already pending deletion")}

        {:error, %Ecto.Changeset{} = cs} ->
          {:noreply, put_flash(socket, :error, format_series_error(cs))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not delete series: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("admin:archive_series", %{"id" => raw_id}, socket) do
    series_id = parse_integer(raw_id, nil)

    if is_nil(series_id) do
      {:noreply, put_flash(socket, :error, "Invalid series")}
    else
      case Catalog.get_series(series_id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Series not found")}

        %Catalog.Series{} = series ->
          case Catalog.archive_series(series) do
            {:ok, archived} ->
              audit(socket, "series.archive", "series", archived.id, archived.slug, %{
                title: archived.title
              })

              {:noreply,
               socket
               |> put_flash(
                 :info,
                 "Series \"#{archived.title}\" archived — delisted from user UI"
               )
               |> then(&refresh_series_rows(&1))
               |> refresh_audit_rows()}

            {:error, %Ecto.Changeset{} = cs} ->
              {:noreply, put_flash(socket, :error, format_series_error(cs))}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Could not archive: #{inspect(reason)}")}
          end
      end
    end
  end

  @impl true
  def handle_event("admin:unarchive_series", %{"id" => raw_id}, socket) do
    series_id = parse_integer(raw_id, nil)

    if is_nil(series_id) do
      {:noreply, put_flash(socket, :error, "Invalid series")}
    else
      case Catalog.get_series(series_id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Series not found")}

        %Catalog.Series{} = series ->
          case Catalog.unarchive_series(series) do
            {:ok, unarchived} ->
              audit(socket, "series.unarchive", "series", unarchived.id, unarchived.slug, %{
                title: unarchived.title
              })

              {:noreply,
               socket
               |> put_flash(:info, "Series \"#{unarchived.title}\" unarchived — visible again")
               |> then(&refresh_series_rows(&1))
               |> refresh_audit_rows()}

            {:error, %Ecto.Changeset{} = cs} ->
              {:noreply, put_flash(socket, :error, format_series_error(cs))}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Could not unarchive: #{inspect(reason)}")}
          end
      end
    end
  end

  # ---- Scheduling events ----

  @impl true
  def handle_event("admin:update_series_schedule", %{"id" => raw_id} = params, socket) do
    series_id = parse_integer(raw_id, nil)

    if is_nil(series_id) do
      {:noreply, put_flash(socket, :error, "Invalid series")}
    else
      case Catalog.get_series(series_id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Series not found")}

        %Catalog.Series{} = series ->
          attrs = %{}

          attrs =
            if Map.has_key?(params, "publication_status"),
              do: Map.put(attrs, :publication_status, params["publication_status"]),
              else: attrs

          attrs =
            if Map.has_key?(params, "publicationStatus"),
              do: Map.put(attrs, :publication_status, params["publicationStatus"]),
              else: attrs

          attrs =
            if Map.has_key?(params, "manual_check_interval_minutes"),
              do:
                Map.put(
                  attrs,
                  :manual_check_interval_minutes,
                  params["manual_check_interval_minutes"]
                ),
              else: attrs

          attrs =
            if Map.has_key?(params, "manualCheckIntervalMinutes"),
              do:
                Map.put(
                  attrs,
                  :manual_check_interval_minutes,
                  params["manualCheckIntervalMinutes"]
                ),
              else: attrs

          # Also handle camelCase from Vue: manualInterval
          attrs =
            if Map.has_key?(params, "manualInterval"),
              do: Map.put(attrs, :manual_check_interval_minutes, params["manualInterval"]),
              else: attrs

          # Normalize empty string to nil (auto)
          attrs =
            case Map.get(attrs, :manual_check_interval_minutes) do
              v when is_binary(v) ->
                trimmed = String.trim(v)

                if trimmed == "" or trimmed == "auto",
                  do: Map.put(attrs, :manual_check_interval_minutes, nil),
                  else: attrs

              _ ->
                attrs
            end

          case Catalog.update_series_schedule(series, attrs) do
            {:ok, updated} ->
              audit(socket, "series.update_schedule", "series", updated.id, updated.slug, %{
                publication_status: updated.publication_status,
                manual_interval: updated.manual_check_interval_minutes,
                effective_interval: CheckSchedule.effective_interval_minutes(updated)
              })

              socket =
                socket
                |> put_flash(:info, "Schedule updated for \"#{updated.title}\"")
                |> then(&refresh_series_rows(&1))
                |> refresh_audit_rows()

              # If chapter dialog is open for this series, keep it; otherwise no-op
              {:noreply, socket}

            {:error, %Ecto.Changeset{} = cs} ->
              {:noreply, put_flash(socket, :error, format_series_error(cs))}
          end
      end
    end
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

  @impl true
  def handle_event("admin:update_user", %{"id" => raw_id} = params, socket) do
    user_id = parse_integer(raw_id, nil)
    actor = socket.assigns.current_user

    if is_nil(user_id) do
      {:noreply, put_flash(socket, :error, "Invalid user")}
    else
      attrs =
        %{}
        |> maybe_put_attr(params, "username", "username")
        |> maybe_put_attr(params, "email", "email")
        |> maybe_put_attr(params, "role", "role")
        |> maybe_put_attr(params, "active", "active")
        |> maybe_put_attr(params, "is_active", "active")
        |> maybe_put_attr(params, "isActive", "active")

      case Accounts.admin_update_user(user_id, attrs, actor) do
        {:ok, updated} ->
          audit(socket, "user.update", "user", updated.id, updated.username, %{
            changes: Map.take(attrs, ["username", "email", "role", "active"])
          })

          {users, pagination} =
            Accounts.admin_list_users(%{
              "q" => socket.assigns.user_query,
              "page" => socket.assigns.user_page,
              "page_size" => socket.assigns.user_page_size
            })

          {:noreply,
           socket
           |> put_flash(:info, "User updated")
           |> assign(
             user_rows: Enum.map(users, &to_user_row/1),
             user_pagination: to_pagination_map(pagination)
           )
           |> refresh_audit_rows()}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "User not found")}

        {:error, :cannot_update_self} ->
          {:noreply, put_flash(socket, :error, "You cannot update your own account")}

        {:error, :forbidden} ->
          {:noreply, put_flash(socket, :error, "Not authorized to update that user")}

        {:error, :cannot_assign_higher_role} ->
          {:noreply,
           put_flash(socket, :error, "Cannot assign a role equal or higher than your own")}

        {:error, :invalid_role} ->
          {:noreply, put_flash(socket, :error, "Invalid role")}

        {:error, %Ecto.Changeset{} = cs} ->
          {:noreply, put_flash(socket, :error, format_user_error(cs))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Update failed: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("admin:delete_user", %{"id" => raw_id}, socket) do
    user_id = parse_integer(raw_id, nil)
    actor = socket.assigns.current_user

    if is_nil(user_id) do
      {:noreply, put_flash(socket, :error, "Invalid user")}
    else
      case Accounts.admin_delete_user(user_id, actor) do
        {:ok, deleted} ->
          audit(socket, "user.delete", "user", deleted.id, deleted.username, %{
            email: deleted.email
          })

          {users, pagination} =
            Accounts.admin_list_users(%{
              "q" => socket.assigns.user_query,
              "page" => socket.assigns.user_page,
              "page_size" => socket.assigns.user_page_size
            })

          {:noreply,
           socket
           |> put_flash(:info, "User deleted")
           |> assign(
             user_rows: Enum.map(users, &to_user_row/1),
             user_pagination: to_pagination_map(pagination)
           )
           |> refresh_audit_rows()}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "User not found")}

        {:error, :cannot_delete_self} ->
          {:noreply, put_flash(socket, :error, "You cannot delete your own account")}

        {:error, :forbidden} ->
          {:noreply, put_flash(socket, :error, "Not authorized to delete that user")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
      end
    end
  end

  # ---- Reports events ----

  @impl true
  def handle_event("admin:reports_page_change", %{"page" => raw_page}, socket) do
    status = socket.assigns.report_status
    page_size = socket.assigns.report_pagination.pageSize
    page = parse_integer(raw_page, 1)

    {reports, pagination} =
      Moderation.list_reports(
        %{"status" => status, "page" => page, "page_size" => page_size}
        |> compact_report_params()
      )

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
      Moderation.list_reports(
        %{"status" => status, "page" => 1, "page_size" => page_size}
        |> compact_report_params()
      )

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
      Moderation.list_reports(
        %{"status" => status, "page" => 1, "page_size" => page_size}
        |> compact_report_params()
      )

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
          {:ok, resolved} ->
            audit(socket, "report.resolve", "report", resolved.id, resolved.reason, %{
              previous_status: report.status,
              target_type: if(resolved.chapter_id, do: "chapter", else: "comment")
            })

            status = socket.assigns.report_status
            page = socket.assigns.report_pagination.page
            page_size = socket.assigns.report_pagination.pageSize

            {reports, pagination} =
              Moderation.list_reports(
                %{"status" => status, "page" => page, "page_size" => page_size}
                |> compact_report_params()
              )

            {:noreply,
             socket
             |> assign(
               report_rows: Enum.map(reports, &to_report_row/1),
               report_pagination: to_pagination_map(pagination)
             )
             |> refresh_audit_rows()}

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
          {:ok, rejected} ->
            audit(socket, "report.reject", "report", rejected.id, rejected.reason, %{
              previous_status: report.status,
              target_type: if(rejected.chapter_id, do: "chapter", else: "comment")
            })

            status = socket.assigns.report_status
            page = socket.assigns.report_pagination.page
            page_size = socket.assigns.report_pagination.pageSize

            {reports, pagination} =
              Moderation.list_reports(
                %{"status" => status, "page" => page, "page_size" => page_size}
                |> compact_report_params()
              )

            {:noreply,
             socket
             |> assign(
               report_rows: Enum.map(reports, &to_report_row/1),
               report_pagination: to_pagination_map(pagination)
             )
             |> refresh_audit_rows()}

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

  # ---- Audit events ----

  @impl true
  def handle_event("admin:audit_page_change", %{"page" => raw_page}, socket) do
    page = parse_integer(raw_page, 1)
    action = socket.assigns[:audit_action]
    target_type = socket.assigns[:audit_target_type]
    page_size = socket.assigns[:audit_page_size] || @default_page_size

    {logs, pagination} =
      Audit.list_audit_logs(%{
        "action" => action,
        "target_type" => target_type,
        "page" => page,
        "page_size" => page_size
      })

    {:noreply,
     assign(socket,
       audit_rows: Enum.map(logs, &to_audit_row/1),
       audit_pagination: to_pagination_map(pagination),
       audit_page: pagination.page
     )}
  end

  @impl true
  def handle_event("admin:audit_page_size_change", %{"page_size" => raw_size}, socket) do
    page_size = parse_integer(raw_size, @default_page_size) |> clamp(1, 100)
    action = socket.assigns[:audit_action]
    target_type = socket.assigns[:audit_target_type]

    {logs, pagination} =
      Audit.list_audit_logs(%{
        "action" => action,
        "target_type" => target_type,
        "page" => 1,
        "page_size" => page_size
      })

    {:noreply,
     assign(socket,
       audit_rows: Enum.map(logs, &to_audit_row/1),
       audit_pagination: to_pagination_map(pagination),
       audit_page: 1,
       audit_page_size: pagination.page_size
     )}
  end

  @impl true
  def handle_event("admin:audit_filter_change", params, socket) do
    action =
      Map.get(params, "action") || Map.get(params, :action) || socket.assigns[:audit_action]

    target_type =
      Map.get(params, "target_type") || Map.get(params, :target_type) ||
        socket.assigns[:audit_target_type]

    # Normalize "all" to nil
    action =
      if action in [nil, "", "all"],
        do: nil,
        else: parse_audit_action(%{"action" => action}) || action

    target_type =
      if target_type in [nil, "", "all"],
        do: nil,
        else: parse_audit_target_type(%{"target_type" => target_type}) || target_type

    page_size = socket.assigns[:audit_page_size] || @default_page_size

    {logs, pagination} =
      Audit.list_audit_logs(%{
        "action" => action,
        "target_type" => target_type,
        "page" => 1,
        "page_size" => page_size
      })

    {:noreply,
     assign(socket,
       audit_rows: Enum.map(logs, &to_audit_row/1),
       audit_pagination: to_pagination_map(pagination),
       audit_action: action || "all",
       audit_target_type: target_type || "all",
       audit_page: 1
     )}
  end

  defp load_tags do
    Catalog.list_categories()
    |> Enum.map(fn c -> %{id: c.id, name: c.name} end)
    |> Enum.sort_by(& &1.name, :asc)
  end

  defp audit(socket, action, target_type, target_id, target_identifier, metadata) do
    actor = socket.assigns[:current_user]

    Audit.log_admin_action!(%{
      action: action,
      target_type: target_type,
      target_id: target_id,
      target_identifier: target_identifier,
      metadata: metadata,
      actor: actor,
      ip_address: Audit.extract_ip(socket),
      user_agent: Audit.extract_user_agent(socket)
    })
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
    normalized = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    case Map.get(normalized, "status") do
      s when s in ~w(pending resolved rejected) -> params
      _ -> Map.drop(params, ["status", :status])
    end
  end

  defp parse_audit_action(%{"action" => a})
       when a in ~w(category.create category.delete series.create series.delete series.archive series.unarchive series.update_schedule chapter.delete chapter.repair user.update user.delete report.resolve report.reject),
       do: a

  defp parse_audit_action(%{action: a})
       when a in ~w(category.create category.delete series.create series.delete series.archive series.unarchive series.update_schedule chapter.delete chapter.repair user.update user.delete report.resolve report.reject),
       do: a

  defp parse_audit_action(%{"action" => "all"}), do: nil
  defp parse_audit_action(%{action: "all"}), do: nil
  defp parse_audit_action(_), do: nil

  defp parse_audit_target_type(%{"target_type" => t})
       when t in ~w(category series chapter user report),
       do: t

  defp parse_audit_target_type(%{target_type: t})
       when t in ~w(category series chapter user report),
       do: t

  defp parse_audit_target_type(%{"target_type" => "all"}), do: nil
  defp parse_audit_target_type(%{target_type: "all"}), do: nil
  defp parse_audit_target_type(_), do: nil

  defp to_audit_row(log) do
    %{
      id: log.id,
      actorId: log.actor_id,
      actorRole: log.actor_role,
      actorUsername: log.actor_username,
      action: log.action,
      targetType: log.target_type,
      targetId: log.target_id,
      targetIdentifier: log.target_identifier,
      metadata: log.metadata,
      ipAddress: log.ip_address,
      userAgent: log.user_agent && String.slice(log.user_agent, 0, 200),
      insertedAt: format_datetime(log.inserted_at)
    }
  end

  defp refresh_audit_rows(socket) do
    action = socket.assigns[:audit_action]
    target_type = socket.assigns[:audit_target_type]
    page = socket.assigns[:audit_page] || 1
    page_size = socket.assigns[:audit_page_size] || @default_page_size

    {logs, pagination} =
      Audit.list_audit_logs(%{
        "action" => action,
        "target_type" => target_type,
        "page" => page,
        "page_size" => page_size
      })

    assign(socket,
      audit_rows: Enum.map(logs, &to_audit_row/1),
      audit_pagination: to_pagination_map(pagination)
    )
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

  defp maybe_put_cover_key(attrs, nil), do: attrs

  defp maybe_put_cover_key(attrs, key) when is_binary(key),
    do: Map.put(attrs, :cover_key, key)

  @spec maybe_cancel_cover_upload(Phoenix.LiveView.Socket.t(), term()) ::
          Phoenix.LiveView.Socket.t()
  defp maybe_cancel_cover_upload(socket, ref) when is_binary(ref) do
    staged_refs = Enum.map(socket.assigns.uploads.cover.entries, & &1.ref)

    if ref in staged_refs do
      cancel_upload(socket, :cover, ref)
    else
      socket
    end
  end

  defp maybe_cancel_cover_upload(socket, _ref), do: socket

  @doc """
  Resolves an `admin:create_series` cover outcome from consumed entry results,
  upload errors and the client-declared file name.

  Pure decision function, extracted for direct testing. `consumed` holds the
  unwrapped `{:ok, value}` payloads returned by `consume_uploaded_entries/3`
  (bare values, never `{:ok, ...}` tuples). A stored entry resolves to its
  opaque storage key; URL construction happens at the presentation boundary
  (`Catalog.cover_url/1`).
  """
  @spec resolve_cover_outcome(list(), list(), String.t()) ::
          {String.t() | nil,
           nil
           | {:validation, list()}
           | {:storage, term()}
           | {:pending, term()}
           | {:unknown, term()}}
  def resolve_cover_outcome(consumed, upload_errors, cover_file_name \\ "") do
    case {consumed, upload_errors} do
      {[{:stored, key}], _} when is_binary(key) ->
        {key, nil}

      {[{:storage_error, reason}], _} ->
        {nil, {:storage, reason}}

      {[], []} when cover_file_name == "" ->
        # No file selected — cover is optional for now
        {nil, nil}

      {[], []} ->
        # Client claimed a file but none reached the server (still uploading
        # or never enqueued) — fail loudly instead of saving without cover.
        {nil, {:pending, cover_file_name}}

      {[], errors} when errors != [] ->
        {nil, {:validation, errors}}

      _ ->
        {nil, {:unknown, consumed}}
    end
  end

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

  defp format_user_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join(", ", fn {k, msgs} -> "#{k} #{Enum.join(msgs, ", ")}" end)
    |> case do
      "" -> "Could not update user"
      msg -> msg
    end
  end

  defp maybe_put_attr(attrs, params, key, normalized_key) do
    value = fetch_param(params, key)
    if is_nil(value), do: attrs, else: Map.put(attrs, normalized_key, value)
  end

  # Safe param lookup without atom table exhaustion. LiveView `params`
  # is string-keyed, but we support existing atom keys for test convenience
  # via `to_existing_atom` (never creates new atoms).
  defp fetch_param(params, key) when is_binary(key) do
    case Map.fetch(params, key) do
      {:ok, val} ->
        val

      :error ->
        try do
          Map.get(params, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp fetch_param(params, key) when is_atom(key) do
    case Map.fetch(params, Atom.to_string(key)) do
      {:ok, val} -> val
      :error -> Map.get(params, key)
    end
  end

  defp refresh_series_rows(socket) do
    query = socket.assigns.query
    page = socket.assigns.page
    page_size = socket.assigns.page_size

    {series, pagination} =
      Catalog.admin_list_series(%{"q" => query, "page" => page, "page_size" => page_size})

    assign(socket,
      series_rows: Enum.map(series, &to_series_row/1),
      pagination: to_pagination_map(pagination)
    )
  end

  defp refresh_chapter_list(socket) do
    series_id = socket.assigns.chapter_series_id

    if is_nil(series_id) do
      {:noreply, socket}
    else
      page = socket.assigns.chapter_page
      page_size = socket.assigns.chapter_page_size

      {chapters, pagination} =
        Catalog.admin_list_chapters(series_id, %{"page" => page, "page_size" => page_size})

      {:noreply,
       assign(socket,
         chapter_rows: Enum.map(chapters, &to_chapter_row/1),
         chapter_pagination: to_pagination_map(pagination)
       )}
    end
  end

  # ---- Mappers ----

  defp to_series_row(series) do
    authors =
      case series do
        %{authors: authors} when is_list(authors) -> Enum.map(authors, & &1.name)
        _ -> []
      end

    effective = CheckSchedule.effective_interval_minutes(series)

    %{
      id: series.id,
      title: series.title,
      slug: series.slug,
      authors: authors,
      publicationStatus: series.publication_status,
      processingStatus: series.processing_status,
      sourceUrl: series.source_url,
      coverUrl: Catalog.cover_url(series),
      updatedAt: format_datetime(series.updated_at),
      insertedAt: format_datetime(series.inserted_at),
      manualCheckIntervalMinutes: series.manual_check_interval_minutes,
      effectiveIntervalMinutes: effective,
      nextCheckAt: format_datetime(series.next_check_at),
      lastCheckedAt: format_datetime(series.last_checked_at),
      checkRetryCount: series.check_retry_count || 0,
      lastError: series.last_error && String.slice(series.last_error, 0, 500),
      archivedAt: format_datetime(series.archived_at)
    }
  end

  defp to_chapter_row(chapter) do
    %{
      id: chapter.id,
      seriesId: chapter.series_id,
      chapterKey: chapter.chapter_key,
      displayNumber: chapter.display_number,
      title: chapter.title,
      sortKey: chapter.sort_key,
      sourceUrl: chapter.source_url,
      status: chapter.status,
      retryCount: chapter.retry_count || 0,
      lastError: chapter.last_error && String.slice(chapter.last_error, 0, 500),
      publishedAt: format_datetime(chapter.published_at),
      updatedAt: format_datetime(chapter.updated_at),
      insertedAt: format_datetime(chapter.inserted_at)
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
    case fetch_param(params, key) do
      q when is_binary(q) -> q |> String.trim() |> String.slice(0, 100)
      _ -> ""
    end
  end

  defp parse_page(params, key) when is_binary(key) do
    raw = fetch_param(params, key)
    parse_integer(raw, 1)
  end

  defp parse_page_size(params, key) when is_binary(key) do
    raw = fetch_param(params, key)
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
