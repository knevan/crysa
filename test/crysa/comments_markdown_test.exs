defmodule Crysa.CommentsMarkdownTest do
  use ExUnit.Case, async: true

  alias Crysa.Comments.Markdown

  describe "render/1 XSS protection" do
    test "escapes raw HTML tags" do
      html = Markdown.render("<script>alert(1)</script>")
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "strips javascript: URLs in links" do
      html = Markdown.render("[click](javascript:alert(1))")
      refute html =~ "javascript:"
      assert html =~ "click"
      refute html =~ "click)"
    end

    test "strips javascript in image URLs and downgrades to text" do
      html = Markdown.render("![alt](javascript:alert(1))")
      refute html =~ "javascript:"
      assert html =~ "alt"
      refute html =~ "<img"
    end

    test "allows https links with safe attributes" do
      html = Markdown.render("[ok](https://example.com)")
      assert html =~ ~s(href="https://example.com")
      assert html =~ "rel=\"nofollow noopener\""
    end

    test "escapes code block content" do
      html = Markdown.render("```\n<script>alert(1)</script>\n```")
      assert html =~ "&lt;script&gt;"
      assert html =~ "<pre><code>"
      refute html =~ "<script>"
    end
  end

  describe "render/1 markdown features" do
    test "renders bold and italic" do
      assert Markdown.render("**bold**") =~ "<strong>bold</strong>"
      assert Markdown.render("*italic*") =~ "<em>italic</em>"
      assert Markdown.render("__bold__") =~ "<strong>bold</strong>"
      assert Markdown.render("_italic_") =~ "<em>italic</em>"
      assert Markdown.render("~~strike~~") =~ "<del>strike</del>"
    end

    test "renders inline code without being mangled by italic/bold" do
      assert Markdown.render("hello `a code` world") ==
               "<p>hello <code>a code</code> world</p>"

      assert Markdown.render("hello `a_code` world") ==
               "<p>hello <code>a_code</code> world</p>"

      assert Markdown.render("hello `a *code*` world") ==
               "<p>hello <code>a *code*</code> world</p>"

      assert Markdown.render("**bold** and `code`") ==
               "<p><strong>bold</strong> and <code>code</code></p>"
    end

    test "renders fenced code block" do
      html = Markdown.render("```\nhello\n```")
      assert html =~ "<pre><code>hello</code></pre>"
    end

    test "renders heading, blockquote, list and hr" do
      assert Markdown.render("# Title") =~ "<h1>Title</h1>"
      assert Markdown.render("## Title") =~ "<h2>Title</h2>"
      assert Markdown.render("> quote") =~ "<blockquote>quote</blockquote>"
      assert Markdown.render("- a\n- b") =~ "<ul>"
      assert Markdown.render("1. a\n1. b") =~ "<ol>"
      assert Markdown.render("---") =~ "<hr>"
    end

    test "handles javascript URL with nested parentheses without stray )" do
      assert Markdown.render("[bad](javascript:alert(1))") == "<p>bad</p>"
      assert Markdown.render("[bad](javascript:alert(1)) and more") == "<p>bad and more</p>"
    end

    test "renders link with parentheses in URL" do
      html = Markdown.render("[x](https://example.com/a(b)c)")
      assert html =~ "https://example.com/a(b)c"
    end

    test "encodes & in URLs as single &amp; (no double-encoding)" do
      html = Markdown.render("[x](https://example.com/a?x=1&y=2)")
      assert html =~ ~s(href="https://example.com/a?x=1&amp;y=2")
      refute html =~ "&amp;amp;"

      html2 = Markdown.render("[x](/search?q=a&b=1)")
      assert html2 =~ ~s(href="/search?q=a&amp;b=1")
      refute html2 =~ "&amp;amp;"
    end
  end
end
