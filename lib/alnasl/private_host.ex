defmodule Alnasl.PrivateHost do
  @moduledoc """
  Where plain http is acceptable: a host that only this computer or the
  hall's own network can reach - loopback, the private ranges (10/8,
  172.16/12, 192.168/16), link-local, 100.64/10 (CGNAT, Tailscale), fc00::/7,
  fe80::/10 - and `.local` names. Anywhere else a join must be https: a code,
  a key or an account would otherwise cross the internet in the clear.
  """

  @doc "Is `host` (a name or an address, brackets allowed) one where plain http is fine?"
  def private?(host) when is_binary(host) do
    host = host |> String.trim("[") |> String.trim("]") |> String.downcase()

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> private_ip?(ip)
      {:error, _} -> host == "localhost" or String.ends_with?(host, ".local")
    end
  end

  def private?(_host), do: false

  @doc """
  `:ok` for an https address or an http one at a private host; `{:error,
  :insecure}` for plain http anywhere else.
  """
  def check(%URI{scheme: "https"}), do: :ok

  def check(%URI{scheme: "http", host: host}),
    do: if(private?(host), do: :ok, else: {:error, :insecure})

  def check(_other), do: :ok

  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b in 16..31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({100, b, _, _}) when b in 64..127, do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true
  defp private_ip?(_ip), do: false
end
