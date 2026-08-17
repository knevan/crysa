defmodule Crysa.Catalog.Normalization do
  @moduledoc false

  @spec normalized_name(String.t() | nil) :: String.t() | nil
  def normalized_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end

  def normalized_name(value), do: value
end
