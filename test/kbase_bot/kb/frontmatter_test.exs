defmodule KbaseBot.KB.FrontmatterTest do
  use ExUnit.Case, async: true

  alias KbaseBot.KB.Frontmatter

  test "parses fenced frontmatter and body" do
    content = """
    ---
    name: Movie log
    scopes: [movies, lists]
    ---
    # Movies

    body text
    """

    assert {:ok, meta, body} = Frontmatter.parse(content)
    assert meta["name"] == "Movie log"
    assert meta["scopes"] == ["movies", "lists"]
    assert String.starts_with?(body, "# Movies")
  end

  test "returns :none without frontmatter" do
    assert Frontmatter.parse("# Just markdown\n") == :none
    assert Frontmatter.parse("") == :none
  end

  test "returns :none for unterminated fence" do
    assert Frontmatter.parse("---\nname: x\nno closing fence") == :none
  end

  test "scopes/1 extracts scopes list" do
    assert Frontmatter.scopes("---\nscopes: [movies]\n---\nbody") == ["movies"]
  end

  test "scopes/1 is nil when absent or unlabeled" do
    assert Frontmatter.scopes("---\nname: x\n---\nbody") == nil
    assert Frontmatter.scopes("plain content") == nil
  end

  test "scopes/1 handles yaml list syntax" do
    content = """
    ---
    scopes:
      - movies
      - books
    ---
    body
    """

    assert Frontmatter.scopes(content) == ["movies", "books"]
  end
end
