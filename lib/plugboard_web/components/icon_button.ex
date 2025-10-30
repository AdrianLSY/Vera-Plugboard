defmodule PlugboardWeb.IconButton do
  @moduledoc """
  Provides a reusable icon button component for navigation and actions.

  The icon_button component provides consistent styling for icon-based
  navigation buttons throughout the application, with support for both
  regular links and Phoenix.Component links with HTTP methods, as well
  as button elements for custom interactions.
  """
  use Phoenix.Component
  import PlugboardWeb.CoreComponents, only: [icon: 1]
  import PlugboardWeb.Tooltip

  @doc """
  Renders an icon button with consistent styling.

  Supports both links (with optional HTTP methods) and buttons (with onclick handlers).

  ## Examples

      <.icon_button href={~p"/users/settings"} icon="hero-cog-6-tooth" tooltip="Settings" />

      <.icon_button href={~p"/users/log-out"} icon="hero-arrow-right-on-rectangle" tooltip="Log out" method="delete" />

      <.icon_button href={~p"/dashboard"} icon="hero-home" tooltip="Dashboard" tooltip_position="right" class="mt-4" />

      <.icon_button icon="hero-sun" tooltip="Toggle theme" onclick="toggleTheme()" />
  """
  attr :href, :string, default: nil, doc: "the path to link to (omit for button mode)"
  attr :icon, :string, required: true, doc: "the hero icon name to display"
  attr :tooltip, :string, default: nil, doc: "optional tooltip text to display on hover"

  attr :tooltip_position, :string,
    default: "right",
    doc: "position of the tooltip (top, bottom, left, right)"

  attr :method, :string, default: nil, doc: "the HTTP method for the link (e.g., 'delete')"
  attr :onclick, :string, default: nil, doc: "JavaScript to execute on click (button mode)"
  attr :class, :string, default: nil, doc: "additional CSS classes"
  attr :rest, :global, doc: "arbitrary HTML attributes to add to the button"

  def icon_button(assigns) do
    ~H"""
    <%= if @tooltip do %>
      <.tooltip text={@tooltip} position={@tooltip_position}>
        <.icon_button_element
          href={@href}
          icon={@icon}
          method={@method}
          onclick={@onclick}
          class={@class}
          {@rest}
        />
      </.tooltip>
    <% else %>
      <.icon_button_element
        href={@href}
        icon={@icon}
        method={@method}
        onclick={@onclick}
        class={@class}
        {@rest}
      />
    <% end %>
    """
  end

  # Private component that renders the actual button/link element
  attr :href, :string, default: nil
  attr :icon, :string, required: true
  attr :method, :string, default: nil
  attr :onclick, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global

  defp icon_button_element(assigns) do
    ~H"""
    <%= cond do %>
      <% @href && @method -> %>
        <.link
          href={@href}
          method={@method}
          class={["interactive-button-base icon-button", @class]}
          {@rest}
        >
          <.icon name={@icon} class="icon-button-icon" />
        </.link>
      <% @href -> %>
        <a href={@href} class={["interactive-button-base icon-button", @class]} {@rest}>
          <.icon name={@icon} class="icon-button-icon" />
        </a>
      <% true -> %>
        <button
          type="button"
          onclick={@onclick}
          class={["interactive-button-base icon-button", @class]}
          {@rest}
        >
          <.icon name={@icon} class="icon-button-icon" />
        </button>
    <% end %>
    """
  end
end
