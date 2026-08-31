defmodule Crysa.Audit do
  @moduledoc """
  Audit context for traceable admin and moderator actions.

  All mutating admin operations should be recorded via `log_admin_action/1`.
  The log is append-only and never updated. Failures to write the audit log
  must not crash the main operation; they are reported via `Logger` and
  `Telemetry`.

  ## Security notes

  * Metadata is allowlisted and bounded (max 20 keys, 5KB) to prevent injection or bloat.
  * Sensitive fields (`password`, `token`, `secret`) are never stored; callers must
    sanitize before passing metadata.
  * `ip_address` and `user_agent` are taken from `Plug.Conn` or `LiveView` socket
    connect info and truncated to safe lengths.
  """

  import Ecto.Query, warn: false

  alias Crysa.Audit.AdminAuditLog
  alias Crysa.Repo

  require Logger

  @type actor :: %Crysa.Accounts.User{} | map() | nil
  @type audit_attrs :: %{
          required(:action) => String.t(),
          required(:target_type) => String.t(),
          optional(:target_id) => integer() | nil,
          optional(:target_identifier) => String.t() | nil,
          optional(:metadata) => map(),
          optional(:actor) => actor(),
          optional(:actor_id) => integer() | nil,
          optional(:actor_role) => String.t() | nil,
          optional(:actor_username) => String.t() | nil,
          optional(:ip_address) => String.t() | nil,
          optional(:user_agent) => String.t() | nil
        }

  @doc """
  Records an admin audit log.

  Accepts a map with string or atom keys. Required: `action`, `target_type`.
  Optional: `target_id`, `target_identifier`, `metadata`, `actor` (User struct),
  `actor_id`, `actor_role`, `ip_address`, `user_agent`.

  When `actor` is given, `actor_id`, `actor_role` and `actor_username` are
  derived automatically unless explicitly overridden.

  Returns `{:ok, log}` or `{:error, changeset}`. Never raises for valid
  inputs; database errors are logged and returned as `{:error, reason}`.
  """
  @spec log_admin_action(audit_attrs() | map()) ::
          {:ok, AdminAuditLog.t()} | {:error, Ecto.Changeset.t()} | {:error, term()}
  def log_admin_action(attrs) when is_map(attrs) do
    normalized = normalize_attrs(attrs)

    %AdminAuditLog{}
    |> AdminAuditLog.changeset(normalized)
    |> Repo.insert()
    |> case do
      {:ok, log} ->
        :telemetry.execute(
          [:crysa, :audit, :admin_action],
          %{count: 1},
          %{
            action: log.action,
            target_type: log.target_type,
            actor_id: log.actor_id,
            actor_role: log.actor_role
          }
        )

        Logger.info("admin audit",
          action: log.action,
          target_type: log.target_type,
          target_id: log.target_id,
          actor_id: log.actor_id,
          actor_role: log.actor_role
        )

        {:ok, log}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning("admin audit failed",
          action: Map.get(normalized, :action),
          target_type: Map.get(normalized, :target_type),
          errors: inspect(changeset.errors)
        )

        {:error, changeset}

      {:error, reason} ->
        Logger.warning("admin audit insert error", reason: inspect(reason))
        {:error, reason}
    end
  end

  @doc """
  Same as `log_admin_action/1` but never returns error.

  Useful for fire-and-forget logging inside LiveView handlers where the
  main operation must succeed even if audit fails. Errors are logged.
  """
  @spec log_admin_action!(audit_attrs() | map()) :: :ok
  def log_admin_action!(attrs) when is_map(attrs) do
    case log_admin_action(attrs) do
      {:ok, _log} ->
        :ok

      {:error, reason} ->
        Logger.warning("audit log_admin_action! failed", reason: inspect(reason))
    end

    :ok
  end

  @doc """
  Lists audit logs with bounded pagination and optional filters.

  Filters: `action`, `target_type`, `actor_id`. Pagination: `page`/`page_size`
  clamped to `1..100`, default `25`. Ordered by `inserted_at DESC, id DESC` for
  stability.

  Returns `{logs, pagination}`.
  """
  @spec list_audit_logs(map()) :: {[AdminAuditLog.t()], Crysa.Pagination.t()}
  def list_audit_logs(params \\ %{}) when is_map(params) do
    page = parse_page(params)
    page_size = parse_page_size(params)

    base =
      from(l in AdminAuditLog, as: :log)
      |> filter_action(params)
      |> filter_target_type(params)
      |> filter_actor_id(params)
      |> order_by([l], desc: l.inserted_at, desc: l.id)

    total = Repo.aggregate(base, :count, :id)
    page = clamp_page(page, page_size, total)

    logs =
      base
      |> preload([:actor])
      |> limit(^page_size)
      |> offset(^((page - 1) * page_size))
      |> Repo.all()

    {logs, Crysa.Pagination.build(page, page_size, total)}
  end

  @doc """
  Gets a single audit log by id.
  """
  @spec get_audit_log(integer()) :: AdminAuditLog.t() | nil
  def get_audit_log(id) when is_integer(id), do: Repo.get(AdminAuditLog, id)

  @doc """
  Extracts a safe IP string from a `Plug.Conn` or `Phoenix.LiveView.Socket`.

  For LiveView, uses `get_connect_info(socket, :peer_data)` and `:x_headers`.
  Falls back to `"unknown"`-like handling in the changeset (nil).
  """
  @spec extract_ip(Plug.Conn.t() | Phoenix.LiveView.Socket.t() | map() | nil) ::
          String.t() | nil
  def extract_ip(nil), do: nil

  def extract_ip(%Plug.Conn{} = conn) do
    case conn.remote_ip do
      nil -> nil
      ip when is_tuple(ip) -> ip |> :inet.ntoa() |> to_string() |> String.slice(0, 45)
      ip when is_binary(ip) -> String.slice(ip, 0, 45)
      _ -> nil
    end
  end

  def extract_ip(%Phoenix.LiveView.Socket{} = socket) do
    peer =
      try do
        Phoenix.LiveView.get_connect_info(socket, :peer_data)
      rescue
        _ -> nil
      end

    case peer do
      %{address: addr} when is_tuple(addr) ->
        addr |> :inet.ntoa() |> to_string() |> String.slice(0, 45)

      %{address: addr} when is_binary(addr) ->
        String.slice(addr, 0, 45)

      _ ->
        # Fallback to connect params
        nil
    end
  end

  def extract_ip(%{} = map) do
    case Map.get(map, :ip_address) || Map.get(map, "ip_address") do
      nil -> nil
      ip when is_binary(ip) -> String.slice(ip, 0, 45)
      _ -> nil
    end
  end

  @doc """
  Extracts user agent from conn or socket.
  """
  @spec extract_user_agent(Plug.Conn.t() | Phoenix.LiveView.Socket.t() | map() | nil) ::
          String.t() | nil
  def extract_user_agent(nil), do: nil

  def extract_user_agent(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> String.slice(ua, 0, 500)
      _ -> nil
    end
  end

  def extract_user_agent(%Phoenix.LiveView.Socket{} = socket) do
    # LiveView connect_info may contain user agent via x_headers
    ua =
      try do
        case Phoenix.LiveView.get_connect_info(socket, :x_headers) do
          headers when is_list(headers) ->
            headers
            |> Enum.find_value(fn {k, v} -> if String.downcase(k) == "user-agent", do: v end)

          _ ->
            nil
        end
      rescue
        _ -> nil
      end

    if is_binary(ua), do: String.slice(ua, 0, 500), else: nil
  end

  def extract_user_agent(%{} = map) do
    case Map.get(map, :user_agent) || Map.get(map, "user_agent") do
      nil -> nil
      ua when is_binary(ua) -> String.slice(ua, 0, 500)
      _ -> nil
    end
  end

  # ---- helpers ----

  defp normalize_attrs(attrs) when is_map(attrs) do
    # Normalize keys to atoms where safe (allowlisted)
    attrs
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      key =
        cond do
          is_atom(k) ->
            k

          is_binary(k) ->
            # Only convert known keys to existing atoms to avoid atom table bloat
            case k do
              "action" -> :action
              "target_type" -> :target_type
              "target_id" -> :target_id
              "target_identifier" -> :target_identifier
              "metadata" -> :metadata
              "actor" -> :actor
              "actor_id" -> :actor_id
              "actor_role" -> :actor_role
              "actor_username" -> :actor_username
              "ip_address" -> :ip_address
              "user_agent" -> :user_agent
              _ -> k
            end

          true ->
            k
        end

      Map.put(acc, key, v)
    end)
    |> maybe_put_actor_fields()
    |> sanitize_metadata()
    |> truncate_fields()
  end

  defp maybe_put_actor_fields(attrs) do
    case Map.get(attrs, :actor) do
      %Crysa.Accounts.User{} = user ->
        attrs
        |> Map.put_new(:actor_id, user.id)
        |> Map.put_new(:actor_role, actor_role(user))
        |> Map.put_new(:actor_username, user.username)
        |> Map.delete(:actor)

      %{id: id} = actor when is_map(actor) ->
        attrs
        |> Map.put_new(:actor_id, id)
        |> Map.put_new(:actor_role, Map.get(actor, :role) || Map.get(actor, "role") || "unknown")
        |> Map.put_new(:actor_username, Map.get(actor, :username) || Map.get(actor, "username"))
        |> Map.delete(:actor)

      _ ->
        attrs
        |> Map.delete(:actor)
        |> Map.put_new(:actor_role, "system")
    end
  end

  defp actor_role(%Crysa.Accounts.User{role: %Crysa.Accounts.Role{name: name}})
       when is_binary(name),
       do: name

  defp actor_role(%Crysa.Accounts.User{}), do: "unknown"

  defp sanitize_metadata(attrs) do
    case Map.get(attrs, :metadata) do
      nil ->
        attrs

      metadata when is_map(metadata) ->
        sanitized =
          metadata
          |> Enum.reject(fn {k, _v} -> k in ~w(password password_hash token secret) end)
          |> Enum.map(fn {k, v} -> {to_string(k), sanitize_value(v)} end)
          |> Map.new()

        Map.put(attrs, :metadata, sanitized)

      _ ->
        Map.put(attrs, :metadata, %{})
    end
  end

  defp sanitize_value(v) when is_binary(v), do: String.slice(v, 0, 1_000)
  defp sanitize_value(v) when is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp sanitize_value(v) when is_atom(v), do: Atom.to_string(v) |> String.slice(0, 100)
  defp sanitize_value(v) when is_list(v), do: Enum.map(v, &sanitize_value/1) |> Enum.take(20)
  defp sanitize_value(v), do: inspect(v) |> String.slice(0, 1_000)

  defp truncate_fields(attrs) do
    attrs
    |> maybe_truncate(:target_identifier, 500)
    |> maybe_truncate(:actor_username, 100)
    |> maybe_truncate(:actor_role, 50)
  end

  defp maybe_truncate(attrs, key, max) do
    case Map.get(attrs, key) do
      v when is_binary(v) -> Map.put(attrs, key, String.slice(v, 0, max))
      _ -> attrs
    end
  end

  defp parse_page(params) do
    case params["page"] || params[:page] do
      v when is_integer(v) and v > 0 ->
        v

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} when n > 0 -> n
          _ -> 1
        end

      _ ->
        1
    end
  end

  defp parse_page_size(params) do
    raw = params["page_size"] || params[:page_size] || 25

    size =
      cond do
        is_integer(raw) ->
          raw

        is_binary(raw) ->
          case Integer.parse(raw) do
            {n, ""} -> n
            _ -> 25
          end

        true ->
          25
      end

    size |> max(1) |> min(100)
  end

  defp clamp_page(page, page_size, total) do
    total_pages = max(div(total + page_size - 1, page_size), 1)
    min(page, total_pages)
  end

  defp filter_action(query, params) do
    case params["action"] || params[:action] do
      nil -> query
      "" -> query
      action when is_binary(action) -> where(query, [l], l.action == ^action)
      _ -> query
    end
  end

  defp filter_target_type(query, params) do
    case params["target_type"] || params[:target_type] do
      nil -> query
      "" -> query
      t when is_binary(t) -> where(query, [l], l.target_type == ^t)
      _ -> query
    end
  end

  defp filter_actor_id(query, params) do
    case params["actor_id"] || params[:actor_id] do
      nil ->
        query

      id when is_integer(id) ->
        where(query, [l], l.actor_id == ^id)

      id when is_binary(id) ->
        case Integer.parse(id) do
          {n, ""} -> where(query, [l], l.actor_id == ^n)
          _ -> query
        end

      _ ->
        query
    end
  end
end
