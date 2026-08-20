defmodule Crysa.Comments.Markdown do
  @moduledoc """
  Markdown-to-HTML renderer with allowlist-based sanitization.

  Converts a subset of Markdown to safe HTML and strips any raw HTML or
  disallowed tags. All user input is escaped before Markdown transforms run,
  so injected HTML, script tags, and event handlers can never survive.

  Supported Markdown:
  - fenced code blocks (```) and inline code (`code`)
  - headings `#`, `##`, `###`
  - blockquotes `> ...`
  - unordered lists `- ` / `* ` and ordered lists `1. `
  - horizontal rules `---`, `***`, `___`
  - bold `**text**` / `__text__`, italic `*text*` / `_text_`,
    strikethrough `~~text~~`
  - links `[text](url)` (only http/https or relative URLs are kept)
  - paragraphs and line breaks

  Images `![alt](url)` are intentionally not rendered as `<img>` — they are
  downgraded to a safe link to prevent arbitrary external image loading in
  comments. Attachments have their own strict upload flow.

  The output is truncated to 20 000 bytes to match `comments.body_html`
  limits and is safe to render with `raw/1` in HEEx templates.
  """

  @max_markdown_length 10_000
  @max_html_length 20_000
  @allowed_tags ~w(p br strong b em i u s del code pre blockquote ul ol li h1 h2 h3 hr a)

  @doc "Renders Markdown to sanitized HTML. Returns a safe HTML string."
  @spec render(String.t() | nil) :: String.t()
  def render(nil), do: ""

  def render(markdown) when is_binary(markdown) do
    markdown
    |> String.trim()
    |> String.slice(0, @max_markdown_length)
    |> normalize_newlines()
    |> render_trimmed()
  end

  defp render_trimmed(""), do: ""

  defp render_trimmed(text) do
    {with_placeholders, store} = extract_code_blocks(text)

    with_placeholders
    |> convert_blocks()
    |> restore_code_blocks(store)
    |> sanitize_tags()
    |> truncate_html()
  end

  @doc "Escapes HTML entities."
  @spec escape_html(String.t()) :: String.t()
  def escape_html(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  # Normalizes Windows and old Mac line endings.
  defp normalize_newlines(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  # Extracts fenced and inline code blocks into placeholders so their
  # contents are not interpreted as Markdown or escaped twice.
  defp extract_code_blocks(text) do
    {text, store} = extract_fenced(text, %{}, 0)
    extract_inline(text, store, map_size(store))
  end

  defp extract_fenced(text, store, counter) do
    case Regex.run(~r/```(?:\w+)?\n?(.*?)\n?```/s, text, return: :index) do
      nil ->
        {text, store}

      [{start, len} | _] ->
        full = binary_part(text, start, len)

        [_ | [code]] = Regex.run(~r/```(?:\w+)?\n?(.*?)\n?```/s, full)
        placeholder = "CRYSAFENCED#{counter}X"
        new_store = Map.put(store, placeholder, {:fenced, code})
        new_text = String.replace(text, full, placeholder, global: false)
        extract_fenced(new_text, new_store, counter + 1)
    end
  end

  defp extract_inline(text, store, counter) do
    case Regex.run(~r/`([^`]+?)`/, text, return: :index) do
      nil ->
        {text, store}

      [{start, len} | _] ->
        full = binary_part(text, start, len)
        [_ | [code]] = Regex.run(~r/`([^`]+?)`/, full)
        placeholder = "CRYSAINLINE#{counter}X"
        new_store = Map.put(store, placeholder, {:inline, code})
        new_text = String.replace(text, full, placeholder, global: false)
        extract_inline(new_text, new_store, counter + 1)
    end
  end

  # Splits into blocks on blank lines and converts each block.
  defp convert_blocks(text) do
    text
    |> String.split(~r/\n{2,}/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join("\n", &convert_block/1)
  end

  defp convert_block("CRYSAFENCED" <> _ = placeholder) do
    if Regex.match?(~r/\ACRYSAFENCED\d+X\z/, placeholder),
      do: placeholder,
      else: "<p>#{convert_inline(placeholder)}</p>"
  end

  defp convert_block("CRYSAINLINE" <> _ = placeholder) do
    if Regex.match?(~r/\ACRYSAINLINE\d+X\z/, placeholder),
      do: "<p>#{placeholder}</p>",
      else: "<p>#{convert_inline(placeholder)}</p>"
  end

  defp convert_block(block) do
    cond do
      Regex.match?(~r/^\s*(?:---|\*\*\*|___)\s*$/, block) ->
        "<hr>"

      Regex.match?(~r/^\s*\#{1,3}\s+.+/, block) ->
        convert_heading(block)

      Regex.match?(~r/^\s*>\s*.+/s, block) ->
        convert_blockquote(block)

      Regex.match?(~r/^\s*(?:[-*]\s+|\d+\.\s+).+/s, block) ->
        convert_list(block)

      true ->
        "<p>#{convert_inline(block)}</p>"
    end
  end

  defp convert_heading(block) do
    case Regex.run(~r/^\s*(\#{1,3})\s+(.+)/s, block) do
      [_, hashes, content] ->
        level = String.length(hashes)
        tag = "h#{level}"
        inner = content |> String.trim() |> convert_inline()
        "<#{tag}>#{inner}</#{tag}>"

      _ ->
        "<p>#{convert_inline(block)}</p>"
    end
  end

  defp convert_blockquote(block) do
    content =
      block
      |> String.split("\n")
      |> Enum.map_join("\n", fn line ->
        case Regex.run(~r/^\s*>\s?(.*)/, line) do
          [_, rest] -> rest
          _ -> line
        end
      end)
      |> String.trim()
      |> convert_inline()

    "<blockquote>#{content}</blockquote>"
  end

  defp convert_list(block) do
    lines = String.split(block, "\n")

    ordered? = Enum.all?(lines, fn line -> Regex.match?(~r/^\s*\d+\.\s+/, line) end)

    items =
      Enum.map_join(lines, "", fn line ->
        content =
          case Regex.run(~r/^\s*(?:[-*]\s+|\d+\.\s+)(.*)/, line) do
            [_, rest] -> rest
            _ -> line
          end

        "<li>#{convert_inline(String.trim(content))}</li>"
      end)

    if ordered? do
      "<ol>#{items}</ol>"
    else
      "<ul>#{items}</ul>"
    end
  end

  # Inline transforms: escape then images -> links, links, bold, italic, strikethrough, breaks.
  defp convert_inline(text) do
    text
    |> escape_html()
    |> convert_images()
    |> convert_links()
    |> convert_bold()
    |> convert_italic()
    |> convert_strikethrough()
    |> convert_line_breaks()
  end

  # Downgrade image markdown to a safe link; never emit <img>.
  defp convert_images(text) do
    Regex.replace(~r/!\[([^\]]*)\]\(([^()]*(?:\([^()]*\)[^()]*)*)\)/, text, fn _, alt, url ->
      decoded_url = decode_entities(url)
      safe = sanitize_url(decoded_url)
      escaped_alt = alt

      if safe do
        ~s(<a href="#{escape_attr(safe)}">#{escaped_alt}</a>)
      else
        escaped_alt
      end
    end)
  end

  defp convert_links(text) do
    Regex.replace(~r/\[([^\]]+)\]\(([^()]*(?:\([^()]*\)[^()]*)*)\)/, text, fn _, label, url ->
      decoded_url = decode_entities(url)
      safe = sanitize_url(decoded_url)

      if safe do
        ~s(<a href="#{escape_attr(safe)}" rel="nofollow noopener" target="_blank">#{label}</a>)
      else
        label
      end
    end)
  end

  defp decode_entities(value) when is_binary(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end

  defp convert_bold(text) do
    text
    |> then(&Regex.replace(~r/\*\*(.+?)\*\*/s, &1, "<strong>\\1</strong>"))
    |> then(&Regex.replace(~r/__([^_]+?)__/s, &1, "<strong>\\1</strong>"))
  end

  defp convert_italic(text) do
    text
    |> then(&Regex.replace(~r/\*(.+?)\*/s, &1, "<em>\\1</em>"))
    |> then(&Regex.replace(~r/_([^_]+?)_/s, &1, "<em>\\1</em>"))
  end

  defp convert_strikethrough(text) do
    Regex.replace(~r/~~(.+?)~~/s, text, "<del>\\1</del>")
  end

  defp convert_line_breaks(text) do
    String.replace(text, "\n", "<br>")
  end

  defp restore_code_blocks(html, store) when map_size(store) == 0, do: html

  defp restore_code_blocks(html, store) do
    Enum.reduce(store, html, fn {placeholder, {kind, code}}, acc ->
      escaped = escape_html(code)

      replacement =
        case kind do
          :fenced -> "<pre><code>#{escaped}</code></pre>"
          :inline -> "<code>#{escaped}</code>"
        end

      String.replace(acc, placeholder, replacement)
    end)
  end

  @doc false
  @spec sanitize_url(String.t()) :: String.t() | nil
  def sanitize_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    cond do
      trimmed == "" -> nil
      contains_quote?(trimmed) -> nil
      dangerous_scheme?(trimmed) -> nil
      Regex.match?(~r/^https?:\/\//i, trimmed) -> trimmed
      relative_path?(trimmed) -> trimmed
      String.starts_with?(trimmed, "#") -> trimmed
      true -> nil
    end
  end

  def sanitize_url(_), do: nil

  defp contains_quote?(value) do
    String.contains?(value, "\"") or String.contains?(value, "'") or
      String.contains?(value, "`")
  end

  defp dangerous_scheme?(value) do
    down = String.downcase(value)

    String.starts_with?(down, "javascript:") or String.starts_with?(down, "data:") or
      String.starts_with?(down, "vbscript:")
  end

  defp relative_path?(value) do
    String.starts_with?(value, "/") and not String.starts_with?(value, "//")
  end

  defp escape_attr(value) when is_binary(value) do
    value
    |> decode_entities()
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # Strips disallowed tags and sanitizes attributes.
  defp sanitize_tags(html) do
    Regex.replace(~r/<\/?([a-zA-Z0-9]+)([^>]*)>/, html, fn full, tag, attrs ->
      tag_down = String.downcase(tag)
      is_closing = String.starts_with?(full, "</")

      if tag_down in @allowed_tags do
        sanitize_allowed_tag(tag_down, is_closing, attrs)
      else
        ""
      end
    end)
  end

  defp sanitize_allowed_tag(tag, true, _attrs), do: "</#{tag}>"

  defp sanitize_allowed_tag("br", false, _attrs), do: "<br>"
  defp sanitize_allowed_tag("hr", false, _attrs), do: "<hr>"
  defp sanitize_allowed_tag("a", false, attrs), do: sanitize_a_tag(attrs)

  defp sanitize_allowed_tag(tag, false, _attrs)
       when tag in ~w(p strong b em i u s del code pre blockquote ul ol li h1 h2 h3),
       do: "<#{tag}>"

  defp sanitize_allowed_tag(tag, false, _attrs), do: "<#{tag}>"

  defp sanitize_a_tag(attrs) do
    case Regex.run(~r/href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i, attrs) do
      nil ->
        "<a>"

      [_, d1, d2, d3] ->
        raw = Enum.find([d1, d2, d3], &(&1 != ""))
        safe = sanitize_url(raw || "")

        if safe do
          ~s(<a href="#{escape_attr(safe)}" rel="nofollow noopener" target="_blank">)
        else
          "<a>"
        end

      [_, href] ->
        safe = sanitize_url(href)

        if safe do
          ~s(<a href="#{escape_attr(safe)}" rel="nofollow noopener" target="_blank">)
        else
          "<a>"
        end
    end
  end

  defp truncate_html(html) when byte_size(html) <= @max_html_length, do: html

  defp truncate_html(html) do
    html
    |> String.slice(0, @max_html_length)
    |> String.trim()
  end
end
