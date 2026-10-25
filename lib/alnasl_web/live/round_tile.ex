defmodule AlnaslWeb.RoundTile do
  @moduledoc """
  One board on the Round page - a tile, or a row of the list - as a
  component of its own.

  Not for its state: it has none, and its buttons still talk to
  `AlnaslWeb.RoundLive`. For the browser's sake. A page that changes is
  patched whole, every element of it walked again, unless the change is
  inside a component; then only the component is. In a hall the tiles are
  what changes, several times a second, and a small box's browser that
  walked the whole round for every clock tick had no time left to open the
  board somebody had just clicked.
  """

  use AlnaslWeb, :live_component

  @impl true
  def render(%{row?: true} = assigns) do
    ~H"""
    <tr id={"row-#{@tile.dom}"} class={["board-row", tone(@tile.state)]}>
      <AlnaslWeb.RoundLive.row_cells tile={@tile} ctx={@ctx} />
    </tr>
    """
  end

  def render(assigns) do
    ~H"""
    <div id={"tile-wrap-#{@tile.dom}"} class="tile-wrap">
      <AlnaslWeb.RoundLive.tile_body tile={@tile} ctx={@ctx} many?={@many?} />
    </div>
    """
  end
end
