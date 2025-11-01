defmodule PlugboardWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: PlugboardWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap text-[var(--ui-background-light)] rounded-4xl",
        @kind == :info && "border-l-4 border-[var(--ui-info)] bg-[var(--ui-info)]",
        @kind == :success && "border-l-4 border-[var(--ui-success)] bg-[var(--ui-success)]",
        @kind == :warning && "border-l-4 border-[var(--ui-warning)] bg-[var(--ui-warning)]",
        @kind == :error && "border-l-4 border-[var(--ui-error)] bg-[var(--ui-error)]"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button
          type="button"
          class="group self-start cursor-pointer rounded-full p-1 hover:bg-[var(--ui-background-light)] hover:text-[var(--ui-background-dark)] transition-colors"
          aria-label={gettext("close")}
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a text button with consistent styling.

  Supports button types for form submissions and custom classes.

  ## Examples

      <.button type="submit">
        Log in with email
      </.button>

      <.button type="button" phx-click="cancel">
        Cancel
      </.button>

      <.button type="submit" class="mt-4" name="remember_me" value="true">
        Log in and stay logged in
      </.button>
  """
  attr :type, :string, default: "submit", doc: "the button type"
  attr :name, :string, default: nil, doc: "the button name for form submission"
  attr :value, :string, default: nil, doc: "the button value for form submission"
  attr :disabled, :boolean, default: false, doc: "whether the button is disabled"
  attr :class, :string, default: nil, doc: "additional CSS classes"
  attr :rest, :global, doc: "arbitrary HTML attributes to add to the button"
  slot :inner_block, required: true, doc: "the button text content"

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      name={@name}
      value={@value}
      disabled={@disabled}
      class={["interactive-button-base text-button text-button-text", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

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
    <div class={["relative inline-block group", @class]} {@rest}>
      {render_slot(@inner_block)}
      <div
        class={[
          "absolute z-50 px-2 py-1 text-xs font-medium rounded-lg shadow-sm opacity-0 invisible group-hover:opacity-100 group-hover:visible transition-all duration-200 whitespace-nowrap pointer-events-none tooltip-container",
          tooltip_position_classes(@position)
        ]}
        role="tooltip"
      >
        {@text}
        <div class={[
          "absolute w-2 h-2 rotate-45 tooltip-arrow",
          tooltip_arrow_classes(@position)
        ]}>
        </div>
      </div>
    </div>
    """
  end

  # Position classes for the tooltip container
  defp tooltip_position_classes("top") do
    "bottom-full left-1/2 -translate-x-1/2 mb-2"
  end

  defp tooltip_position_classes("bottom") do
    "top-full left-1/2 -translate-x-1/2 mt-2"
  end

  defp tooltip_position_classes("left") do
    "right-full top-1/2 -translate-y-1/2 mr-2"
  end

  defp tooltip_position_classes("right") do
    "left-full top-1/2 -translate-y-1/2 ml-2"
  end

  # Arrow positioning classes
  defp tooltip_arrow_classes("top") do
    "top-full left-1/2 -translate-x-1/2 -mt-1"
  end

  defp tooltip_arrow_classes("bottom") do
    "bottom-full left-1/2 -translate-x-1/2 -mb-1"
  end

  defp tooltip_arrow_classes("left") do
    "left-full top-1/2 -translate-y-1/2 -ml-1"
  end

  defp tooltip_arrow_classes("right") do
    "right-full top-1/2 -translate-y-1/2 -mr-1"
  end

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
        "h-screen ui-foreground shadow-lg drop-shadow-lg w-12 flex flex-col items-center py-4 flex-shrink-0",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

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
  attr :disabled, :boolean, default: false, doc: "whether the button is disabled"
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
          disabled={@disabled}
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
        disabled={@disabled}
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
  attr :disabled, :boolean, default: false
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
          disabled={@disabled}
          class={["interactive-button-base icon-button", @class]}
          {@rest}
        >
          <.icon name={@icon} class="icon-button-icon" />
        </button>
    <% end %>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as hidden and radio,
  are best written directly in your templates.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :string, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :string, default: nil, doc: "the input error class to use over defaults"
  attr :label_class, :string, default: nil, doc: "the label class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label>
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class={[@label_class || "label", "mb-3 block text-center"]}>{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[
            @class ||
              "w-full select ui-foreground focus:outline-none focus:border-ui-inverted-foreground rounded-full",
            @errors != [] && (@error_class || "select-error")
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class={[@label_class || "label", "mb-3 block text-center"]}>{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class ||
              "w-full textarea ui-foreground focus:outline-none focus:border-ui-inverted-foreground rounded-full",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class={[@label_class || "label", "mb-3 block text-center"]}>{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class ||
              "w-full input ui-foreground focus:outline-none focus:border-ui-inverted-foreground rounded-full",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm" style="color: var(--ui-error);">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(PlugboardWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(PlugboardWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  @doc """
  Renders a paths table with consistent styling for file-browser-like navigation.

  This component displays a list of paths with visual distinction between
  regular paths (folders) and mount points (connection endpoints). It supports
  navigation, actions, and customizable rendering.

  ## Examples

      <.paths_table
        id="paths"
        paths={@paths}
        on_path_click={fn path -> JS.navigate(~p"/paths?parent=\#{path.id}") end}
      >
        <:action :let={path}>
          <button phx-click="delete" phx-value-id={path.id}>Delete</button>
        </:action>
      </.paths_table>

      # With custom empty state
      <.paths_table id="mount-points" paths={@mount_points}>
        <:empty>No mount points configured yet</:empty>
      </.paths_table>
  """
  attr :id, :string, required: true, doc: "unique identifier for the table"
  attr :paths, :list, required: true, doc: "list of path structs to display"

  attr :on_path_click, :any,
    default: nil,
    doc: "function to handle path clicks, receives path struct"

  attr :show_full_path, :boolean,
    default: false,
    doc: "whether to show full path or just segment"

  attr :class, :string, default: nil, doc: "additional CSS classes for the table container"

  slot :action, doc: "action buttons/links to display for each path" do
    attr :path, :any
  end

  slot :empty, doc: "content to display when paths list is empty"

  def paths_table(assigns) do
    ~H"""
    <div class={["w-full", @class]}>
      <%= if @paths == [] do %>
        <div class="text-center py-8 ui-text-secondary">
          <%= if @empty != [] do %>
            {render_slot(@empty)}
          <% else %>
            No paths found
          <% end %>
        </div>
      <% else %>
        <table class="w-full border-separate border-spacing-y-1">
          <tbody>
            <tr
              :for={path <- @paths}
              id={"#{@id}-#{path.id}"}
              class="group transition-colors"
            >
              <td class="py-3 px-4 rounded-full group-hover:bg-[var(--ui-foreground)]">
                <div class="flex items-center justify-between gap-3">
                  <!-- Icon: Folder for paths, connection for mount points -->
                  <div class="flex-shrink-0">
                    <%= if path.mount_point do %>
                      <.icon name="hero-link" class="size-5 ui-text-primary" />
                    <% else %>
                      <.icon name="hero-folder" class="size-5 ui-text-primary" />
                    <% end %>
                  </div>
                  <!-- Path name (clickable if on_path_click provided and not a mount point) -->
                  <div class="flex-1 min-w-0">
                    <%= if @on_path_click && !path.mount_point do %>
                      <button
                        type="button"
                        phx-click={@on_path_click.(path)}
                        class="text-left w-full ui-text-primary hover:underline focus:outline-none"
                      >
                        <span class="font-medium">
                          {if @show_full_path, do: path.full_path, else: path.path}
                        </span>
                        <%= if path.mount_point do %>
                          <span class="ml-2 text-xs ui-text-secondary">(mounted)</span>
                        <% end %>
                      </button>
                    <% else %>
                      <div class="ui-text-primary">
                        <span class="font-medium">
                          {if @show_full_path, do: path.full_path, else: path.path}
                        </span>
                        <%= if path.mount_point do %>
                          <span class="ml-2 text-xs ui-text-secondary">(mounted)</span>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                  <!-- Actions integrated into path column -->
                  <%= if @action != [] do %>
                    <div class="flex justify-end items-center gap-2 flex-shrink-0">
                      <%= for action <- @action do %>
                        {render_slot(action, path)}
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a modal popup form with overlay.

  This component creates a modal dialog that appears in the foreground with
  a semi-transparent backdrop. It includes a title, form content area, and
  action buttons.

  ## Examples

      <.pop_up_form
        :if={@show_edit_form}
        id="edit-path-modal"
        title="Edit Path"
        on_cancel={JS.push("close_edit")}
      >
        <:form>
          <.input field={@form[:path]} type="text" label="Path Name" />
        </:form>
        <:actions>
          <.button phx-click="save_edit">Save</.button>
          <.button phx-click="close_edit">Cancel</.button>
        </:actions>
      </.pop_up_form>
  """
  attr :id, :string, required: true, doc: "unique identifier for the modal"
  attr :title, :string, required: true, doc: "title displayed at the top of the modal"

  attr :on_cancel, :any,
    default: nil,
    doc: "JS command to execute when clicking backdrop or close button"

  attr :class, :string, default: nil, doc: "additional CSS classes for the modal content"

  attr :title_align, :string,
    default: "center",
    doc: "alignment of the title (left, center, right)"

  slot :form, required: true, doc: "the form content to display in the modal"
  slot :actions, doc: "action buttons to display at the bottom of the modal"

  def pop_up_form(assigns) do
    ~H"""
    <div
      id={@id}
      class="fixed inset-0 z-50 flex items-center justify-center"
      phx-mounted={show("##{@id}")}
      phx-remove={hide("##{@id}")}
    >
      <!-- Backdrop -->
      <div
        class="absolute inset-0 bg-black/50 backdrop-blur-sm transition-opacity"
        phx-click={@on_cancel}
      >
      </div>
      
    <!-- Modal Content -->
      <div class={[
        "relative ui-foreground rounded-4xl shadow-2xl w-full max-w-sm mx-4 p-6 space-y-4",
        @class
      ]}>
        <!-- Header with close button -->
        <div class="flex items-center justify-between">
          <div class={"text-#{@title_align} flex-1"}>
            <.header>
              <p class="ui-text-primary">{@title}</p>
            </.header>
          </div>
          <button
            :if={@on_cancel}
            type="button"
            class="interactive-button-base icon-button flex-shrink-0"
            phx-click={@on_cancel}
          >
            <.icon name="hero-x-mark" class="icon-button-icon" />
          </button>
        </div>
        
    <!-- Form Content -->
        <div>
          {render_slot(@form)}
        </div>
      </div>
    </div>
    """
  end
end
