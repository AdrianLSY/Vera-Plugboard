defmodule PlugboardWeb.Tooltip do
  @moduledoc """
  Provides a reusable tooltip component for displaying contextual information.

  The tooltip component wraps any content and displays a tooltip on hover.
  It supports multiple positions and can be used with any HTML element.
  """
  use Phoenix.Component

  @doc """
  Renders a tooltip that appears on hover.

  The tooltip wraps the inner content and displays the tooltip text
  in a styled container on hover. Supports multiple positions.

  ## Examples

      <.tooltip text="Click to edit">
        <button>Edit</button>
      </.tooltip>

      <.tooltip text="Navigate to settings" position="bottom">
        <a href="/settings">Settings</a>
      </.tooltip>

      <.tooltip text="Delete this item" position="left" class="ml-2">
        <button>Delete</button>
      </.tooltip>
  """
  attr :text, :string, required: true, doc: "the tooltip text to display"

  attr :position, :string,
    default: "top",
    values: ["top", "bottom", "left", "right"],
    doc: "the position of the tooltip relative to the content"

  attr :class, :string, default: nil, doc: "additional CSS classes for the wrapper"
  attr :rest, :global, doc: "arbitrary HTML attributes to add to the wrapper"

  slot :inner_block, required: true, doc: "the content to wrap with the tooltip"

  def tooltip(assigns) do
    ~H"""
    <div class={["relative flex group", @class]} {@rest}>
      {render_slot(@inner_block)}
      <div
        class={[
          "absolute z-50 px-2 py-1 text-xs font-medium rounded-lg shadow-sm opacity-0 invisible group-hover:opacity-100 group-hover:visible transition-all duration-200 whitespace-nowrap pointer-events-none tooltip-container",
          position_classes(@position)
        ]}
        role="tooltip"
      >
        {@text}
        <div class={[
          "absolute w-2 h-2 rotate-45 tooltip-arrow",
          arrow_classes(@position)
        ]}>
        </div>
      </div>
    </div>
    """
  end

  # Position classes for the tooltip container
  defp position_classes("top") do
    "bottom-full left-1/2 -translate-x-1/2 mb-2"
  end

  defp position_classes("bottom") do
    "top-full left-1/2 -translate-x-1/2 mt-2"
  end

  defp position_classes("left") do
    "right-full top-1/2 -translate-y-1/2 mr-2"
  end

  defp position_classes("right") do
    "left-full top-1/2 -translate-y-1/2 ml-2"
  end

  # Arrow positioning classes
  defp arrow_classes("top") do
    "top-full left-1/2 -translate-x-1/2 -mt-1"
  end

  defp arrow_classes("bottom") do
    "bottom-full left-1/2 -translate-x-1/2 -mb-1"
  end

  defp arrow_classes("left") do
    "left-full top-1/2 -translate-y-1/2 -ml-1"
  end

  defp arrow_classes("right") do
    "right-full top-1/2 -translate-y-1/2 -mr-1"
  end
end
