defmodule PlugboardWeb.TextButton do
  @moduledoc """
  Provides a reusable text button component for forms and actions.

  The text_button component provides consistent styling for text-based
  buttons throughout the application, with support for different button types.
  """
  use Phoenix.Component

  @doc """
  Renders a text button with consistent styling.

  Supports button types for form submissions and custom classes.

  ## Examples

      <.text_button type="submit">
        Log in with email
      </.text_button>

      <.text_button type="button" phx-click="cancel">
        Cancel
      </.text_button>

      <.text_button type="submit" class="mt-4" name="remember_me" value="true">
        Log in and stay logged in
      </.text_button>
  """
  attr :type, :string, default: "submit", doc: "the button type"
  attr :class, :string, default: nil, doc: "additional CSS classes"
  attr :rest, :global, doc: "arbitrary HTML attributes to add to the button"
  slot :inner_block, required: true, doc: "the button text content"

  def text_button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "text-button w-full px-4 rounded-full transition-colors group",
        "[[data-theme=light]_&]:hover:bg-[var(--ui-foreground-dark)]",
        "[[data-theme=dark]_&]:hover:bg-[var(--ui-foreground-light)]",
        "focus:outline-none",
        @class
      ]}
      {@rest}
    >
      <span class="text-button-text font-medium">
        {render_slot(@inner_block)}
      </span>
    </button>
    """
  end
end
