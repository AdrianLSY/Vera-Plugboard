defmodule PlugboardWeb.Sidebar do
  @moduledoc """
  Provides a reusable sidebar component that can be used in different contexts.

  The sidebar is a simple container that accepts content via slots, making it
  flexible and reusable across your application.
  """
  use Phoenix.Component

  @doc """
  Renders a sidebar container.

  ## Examples

      <.sidebar>
        <div>Your custom content here</div>
      </.sidebar>

      <.sidebar class="w-20">
        <.icon name="hero-home" />
      </.sidebar>
  """
  attr :class, :string, default: nil
  attr :rest, :global, doc: "arbitrary HTML attributes to add to the sidebar"

  slot :inner_block, required: true, doc: "the content to render inside the sidebar"

  def sidebar(assigns) do
    ~H"""
    <div
      class={[
        "fixed left-0 top-0 h-full bg-base-200 shadow-lg w-12 flex flex-col items-center py-4",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end
end
