defmodule Crysa.Pagination do
  @moduledoc """
  Bounded pagination metadata shared by read-model queries.

  Page numbers are 1-based and `page_size` is always clamped to a
  safe range by the query layer that builds it.
  """

  @enforce_keys [:page, :page_size, :total_entries, :total_pages]
  defstruct [:page, :page_size, :total_entries, :total_pages]

  @type t :: %__MODULE__{
          page: pos_integer(),
          page_size: pos_integer(),
          total_entries: non_neg_integer(),
          total_pages: pos_integer()
        }

  @spec build(pos_integer(), pos_integer(), non_neg_integer()) :: t()
  def build(page, page_size, total_entries) do
    total_pages = max(div(total_entries + page_size - 1, page_size), 1)

    %__MODULE__{
      page: page,
      page_size: page_size,
      total_entries: total_entries,
      total_pages: total_pages
    }
  end

  @spec has_previous?(t()) :: boolean()
  def has_previous?(%__MODULE__{page: page}), do: page > 1

  @spec has_next?(t()) :: boolean()
  def has_next?(%__MODULE__{page: page, total_pages: total_pages}), do: page < total_pages

  @spec previous_page(t()) :: pos_integer()
  def previous_page(%__MODULE__{page: page}), do: max(page - 1, 1)

  @spec next_page(t()) :: pos_integer()
  def next_page(%__MODULE__{page: page, total_pages: total_pages}), do: min(page + 1, total_pages)
end
