defmodule Alnasl.StartScreenTest do
  use ExUnit.Case, async: true

  @page Path.expand("../../rel/start/start.html", __DIR__)

  test "the start screen reaches for nothing outside itself" do
    html = File.read!(@page)

    # The only absolute URLs allowed: the SVG namespace, and the app on the
    # loopback name, which is the whole point of the page.
    urls =
      ~r{(?:https?:)?//[^\s"'<>)]+}
      |> Regex.scan(html)
      |> List.flatten()
      |> Enum.reject(&String.starts_with?(&1, "http://www.w3.org/2000/svg"))
      |> Enum.reject(&String.starts_with?(&1, "http://localhost"))

    assert urls == []
    refute html =~ ~r/<link[^>]+href/i
    refute html =~ ~r/<script[^>]+src=/i
    refute html =~ ~r/@import|(?<![A-Za-z])url\(/
  end

  test "it speaks both languages and respects the system's preferences" do
    html = File.read!(@page)
    assert html =~ "Alnasl is starting"
    assert html =~ "Alnasl start"
    assert html =~ "prefers-reduced-motion"
    assert html =~ "prefers-color-scheme"
  end
end
