defmodule KbaseBot.Policy.ScopesTest do
  use ExUnit.Case, async: true

  alias KbaseBot.Policy.Scopes

  @policy %{
    "defaults" => %{
      "Journal/**" => %{"scopes" => ["journal"]},
      "medical_history/**" => %{"scopes" => ["medical"]},
      "user_profile.md" => %{"scopes" => ["medical"]},
      "**" => %{"scopes" => ["private"]}
    },
    "non_grantable" => ["medical", "journal"]
  }

  describe "for_file/3 precedence" do
    test "frontmatter scopes win over path defaults" do
      content = "---\nscopes: [movies]\n---\nbody"
      assert Scopes.for_file("Journal/2026-07-06.md", content, @policy) == ["movies"]
    end

    test "path defaults apply when unlabeled" do
      assert Scopes.for_file("Journal/2026-07-06.md", "no frontmatter", @policy) == ["journal"]
      assert Scopes.for_file("medical_history/exams.md", "x", @policy) == ["medical"]
    end

    test "most-specific glob wins over catch-all" do
      assert Scopes.for_file("user_profile.md", "x", @policy) == ["medical"]
    end

    test "unlabeled + no specific default falls to catch-all private" do
      assert Scopes.for_file("ttrpg/notes.md", "x", @policy) == ["private"]
    end

    test "empty policy still yields private" do
      assert Scopes.for_file("anything.md", "x", %{}) == ["private"]
    end
  end

  describe "glob_match?/2" do
    test "** matches any depth" do
      assert Scopes.glob_match?("Journal/**", "Journal/a.md")
      assert Scopes.glob_match?("Journal/**", "Journal/2026/07/a.md")
      refute Scopes.glob_match?("Journal/**", "other/a.md")
    end

    test "* stays within one segment" do
      assert Scopes.glob_match?("*.md", "top.md")
      refute Scopes.glob_match?("*.md", "dir/nested.md")
    end

    test "bare ** matches everything" do
      assert Scopes.glob_match?("**", "any/path/at/all.md")
    end

    test "literal dots are escaped" do
      refute Scopes.glob_match?("a.md", "aXmd")
    end
  end

  describe "non_grantable/1" do
    test "always includes private" do
      assert "private" in Scopes.non_grantable(%{})
    end

    test "includes policy-listed scopes" do
      assert Enum.sort(Scopes.non_grantable(@policy)) ==
               Enum.sort(["private", "medical", "journal"])
    end
  end
end
