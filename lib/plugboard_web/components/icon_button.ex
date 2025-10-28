defmodule PlugboardWeb.IconButton do
  @moduledoc """
  Provides a reusable icon button component for navigation and actions.

  The icon_button component provides consistent styling for icon-based
  navigation buttons throughout the application, with support for both
  regular links and Phoenix.Component links with HTTP methods.
  """
  use Phoenix.Component
  import PlugboardWeb.CoreComponents, only: [icon: 1]
  import PlugboardWeb.Tooltip

  @doc """
  Renders an icon button with consistent styling.

  Supports both regular links and Phoenix.Component links with methods (for delete operations).

  ## Examples

      <.icon_button href={~p"/users/settings"} icon="hero-cog-6-tooth" tooltip="Settings" />

      <.icon_button href={~p"/users/log-out"} icon="hero-arrow-right-on-rectangle" tooltip="Log out" method="delete" />

      <.icon_button href={~p"/dashboard"} icon="hero-home" tooltip="Dashboard" tooltip_position="right" class="mt-4" />
  """
  attr :href, :string, required: true, doc: "the path to link to"
  attr :icon, :string, required: true, doc: "the hero icon name to display"
  attr :tooltip, :string, default: nil, doc: "optional tooltip text to display on hover"

  attr :tooltip_position, :string,
    default: "right",
    doc: "position of the tooltip (top, bottom, left, right)"

  attr :method, :string, default: nil, doc: "the HTTP method for the link (e.g., 'delete')"
  attr :class, :string, default: nil, doc: "additional CSS classes"
  attr :rest, :global, doc: "arbitrary HTML attributes to add to the button"

  def icon_button(assigns) do
    ~H"""
    <%= if @tooltip do %>
      <.tooltip text={@tooltip} position={@tooltip_position}>
        <%= if @method do %>
          <.link
            href={@href}
            method={@method}
            class={[
              "flex items-center justify-center w-8 h-8 rounded-full [[data-theme=dark]_&]:hover:bg-white [[data-theme=light]_&]:hover:bg-gray-800 transition-colors group",
              @class
            ]}
            {@rest}
          >
            <.icon
              name={@icon}
              class="w-5 h-5 pointer-events-none [[data-theme=dark]_&]:group-hover:text-gray-800 [[data-theme=light]_&]:group-hover:text-white"
            />
          </.link>
        <% else %>
          <a
            href={@href}
            class={[
              "flex items-center justify-center w-8 h-8 rounded-full [[data-theme=dark]_&]:hover:bg-white [[data-theme=light]_&]:hover:bg-gray-800 transition-colors group",
              @class
            ]}
            {@rest}
          >
            <.icon
              name={@icon}
              class="w-5 h-5 pointer-events-none [[data-theme=dark]_&]:group-hover:text-gray-800 [[data-theme=light]_&]:group-hover:text-white"
            />
          </a>
        <% end %>
      </.tooltip>
    <% else %>
      <%= if @method do %>
        <.link
          href={@href}
          method={@method}
          class={[
            "flex items-center justify-center w-8 h-8 rounded-full [[data-theme=dark]_&]:hover:bg-white [[data-theme=light]_&]:hover:bg-gray-800 transition-colors group",
            @class
          ]}
          {@rest}
        >
          <.icon
            name={@icon}
            class="w-5 h-5 pointer-events-none [[data-theme=dark]_&]:group-hover:text-gray-800 [[data-theme=light]_&]:group-hover:text-white"
          />
        </.link>
      <% else %>
        <a
          href={@href}
          class={[
            "flex items-center justify-center w-8 h-8 rounded-full [[data-theme=dark]_&]:hover:bg-white [[data-theme=light]_&]:hover:bg-gray-800 transition-colors group",
            @class
          ]}
          {@rest}
        >
          <.icon
            name={@icon}
            class="w-5 h-5 pointer-events-none [[data-theme=dark]_&]:group-hover:text-gray-800 [[data-theme=light]_&]:group-hover:text-white"
          />
        </a>
      <% end %>
    <% end %>
    """
  end
end
