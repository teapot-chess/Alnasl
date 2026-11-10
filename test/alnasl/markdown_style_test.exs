defmodule Alnasl.MarkdownStyleTest do
  use ExUnit.Case, async: true

  alias Alnasl.Markdown

  test "style survives only as table alignment and the step counter" do
    assert Markdown.render_ast([{"td", [{"style", "text-align: left"}], ["x"], %{}}]) =~
             ~s(style="text-align: left")

    assert Markdown.render_ast([{"ol", [{"style", "counter-reset: step 4"}], [], %{}}]) =~
             ~s(style="counter-reset: step 4")

    refute Markdown.render_ast([
             {"p", [{"style", "position:fixed;inset:0;background:url(//evil)"}], ["x"], %{}}
           ]) =~ "style"
  end
end
