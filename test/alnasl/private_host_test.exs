defmodule Alnasl.PrivateHostTest do
  use ExUnit.Case, async: true

  alias Alnasl.OpenPairings.{Code, Connect}
  alias Alnasl.PrivateHost
  alias Alnasl.Takeover.Client

  test "plain http is for the hall's own network only" do
    for host <-
          ~w(127.0.0.1 localhost 10.0.0.4 172.16.5.5 192.168.1.9 100.64.0.1 hall.local [::1] [fd12::1]) do
      assert PrivateHost.private?(host), host
    end

    for host <- ~w(example.org 8.8.8.8 172.32.0.1 100.128.0.1 [2001:db8::1]) do
      refute PrivateHost.private?(host), host
    end
  end

  test "a pairing link over plain http to a public host is refused" do
    assert {:error, :insecure} = Client.parse("http://example.org/takeover/join/ABC-1234")
    assert {:ok, _server, "ABC-1234"} = Client.parse("https://example.org/takeover/join/ABC-1234")
    assert {:ok, _server, _code} = Client.parse("http://192.168.1.5:4006/takeover/join/ABC-1234")
  end

  test "a connect code and an OpenPairings address likewise" do
    assert {:error, :insecure} = Code.parse("http://pairings.example.org#oplt_abc")
    assert {:ok, _} = Code.parse("https://pairings.example.org#oplt_abc")
    assert {:ok, _} = Code.parse("http://127.0.0.1:4000#oplt_abc")
    assert {:error, :insecure} = Connect.normalize("http://pairings.example.org")
    assert {:ok, "https://pairings.example.org"} = Connect.normalize("pairings.example.org")
    assert {:ok, "http://10.0.0.2:4000"} = Connect.normalize("http://10.0.0.2:4000")
  end
end
