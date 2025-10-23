defmodule PlugboardWeb.CoreComponentsTest do
  use PlugboardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import PlugboardWeb.CoreComponents

  describe "flash/1" do
    test "renders info flash with proper ARIA role and styling" do
      assigns = %{
        flash: %{"info" => "Success message"},
        kind: :info
      }

      html =
        rendered_to_string(~H"""
        <.flash kind={@kind} flash={@flash} />
        """)

      assert html =~ "Success message"
      assert html =~ "alert-info"
      assert html =~ ~s(role="alert")
      assert html =~ "hero-information-circle"
    end

    test "renders error flash with proper ARIA role and styling" do
      assigns = %{
        flash: %{"error" => "Error message"},
        kind: :error
      }

      html =
        rendered_to_string(~H"""
        <.flash kind={@kind} flash={@flash} />
        """)

      assert html =~ "Error message"
      assert html =~ "alert-error"
      assert html =~ ~s(role="alert")
      assert html =~ "hero-exclamation-circle"
    end

    test "renders flash with inner block overriding flash map value" do
      assigns = %{
        flash: %{"info" => "This should be ignored"},
        kind: :info
      }

      html =
        rendered_to_string(~H"""
        <.flash kind={@kind} flash={@flash}>Custom message</.flash>
        """)

      assert html =~ "Custom message"
      refute html =~ "This should be ignored"
    end

    test "renders flash with title and message" do
      assigns = %{
        flash: %{"info" => "Message content"},
        kind: :info,
        title: "Important"
      }

      html =
        rendered_to_string(~H"""
        <.flash kind={@kind} flash={@flash} title={@title} />
        """)

      assert html =~ "Important"
      assert html =~ "font-semibold"
      assert html =~ "Message content"
    end

    test "does not render when flash map is empty" do
      assigns = %{
        flash: %{},
        kind: :info
      }

      html =
        rendered_to_string(~H"""
        <.flash kind={@kind} flash={@flash} />
        """)

      assert html == ""
    end

    test "does not render when message is nil" do
      assigns = %{
        flash: %{"info" => nil},
        kind: :info
      }

      html =
        rendered_to_string(~H"""
        <.flash kind={@kind} flash={@flash} />
        """)

      assert html == ""
    end

    test "generates unique DOM id based on kind" do
      assigns = %{
        flash: %{"error" => "Error"},
        kind: :error
      }

      html =
        rendered_to_string(~H"""
        <.flash kind={@kind} flash={@flash} />
        """)

      assert html =~ ~s(id="flash-error")
    end

    test "allows custom id to override default" do
      assigns = %{
        flash: %{"info" => "Info"},
        kind: :info,
        custom_id: "my-custom-flash"
      }

      html =
        rendered_to_string(~H"""
        <.flash id={@custom_id} kind={@kind} flash={@flash} />
        """)

      assert html =~ ~s(id="my-custom-flash")
      refute html =~ ~s(id="flash-info")
    end

    test "includes close button with aria-label" do
      assigns = %{
        flash: %{"info" => "Message"},
        kind: :info
      }

      html =
        rendered_to_string(~H"""
        <.flash kind={@kind} flash={@flash} />
        """)

      assert html =~ ~s(aria-label="close")
      assert html =~ "hero-x-mark"
    end
  end

  describe "button/1" do
    test "renders regular button with default primary soft styling" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button>Click me</.button>
        """)

      assert html =~ "Click me"
      assert html =~ "btn-primary"
      assert html =~ "btn-soft"
      assert html =~ "<button"
      refute html =~ "<a"
    end

    test "renders button with explicit primary variant" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button variant="primary">Submit</.button>
        """)

      assert html =~ "Submit"
      assert html =~ "btn-primary"
      refute html =~ "btn-soft"
    end

    test "renders as link when navigate prop is provided" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button navigate="/home">Go Home</.button>
        """)

      assert html =~ "Go Home"
      assert html =~ "<a"
      assert html =~ ~s(data-phx-link="redirect")
      assert html =~ ~s(href="/home")
      refute html =~ "<button"
    end

    test "renders as link when patch prop is provided" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button patch="/users/1">Edit</.button>
        """)

      assert html =~ "Edit"
      assert html =~ "<a"
      assert html =~ ~s(data-phx-link="patch")
      assert html =~ ~s(href="/users/1")
    end

    test "renders as link when href prop is provided" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button href="https://example.com">External</.button>
        """)

      assert html =~ "External"
      assert html =~ "<a"
      assert html =~ ~s(href="https://example.com")
    end

    test "renders disabled button with disabled attribute" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button disabled>Disabled</.button>
        """)

      assert html =~ "Disabled"
      assert html =~ "disabled"
      assert html =~ "<button"
    end

    test "renders button with custom class" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button class="my-custom-class">Custom</.button>
        """)

      assert html =~ "my-custom-class"
      refute html =~ "btn-primary"
      refute html =~ "btn-soft"
    end

    test "button supports name and value attributes for forms" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button name="action" value="delete">Delete</.button>
        """)

      assert html =~ ~s(name="action")
      assert html =~ ~s(value="delete")
    end

    test "button supports method attribute for RESTful actions" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button href="/logout" method="delete">Logout</.button>
        """)

      assert html =~ ~s(data-method="delete")
    end
  end

  describe "input/1" do
    test "renders text input with label and proper attributes" do
      form = to_form(%{"name" => "John Doe"})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:name]} label="Full Name" />
        """)

      assert html =~ "Full Name"
      assert html =~ "John Doe"
      assert html =~ ~s(type="text")
      assert html =~ ~s(name="name")
      assert html =~ ~s(id="name")
      assert html =~ "w-full input"
    end

    test "renders input without label when not provided" do
      form = to_form(%{"email" => "test@example.com"})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:email]} type="email" />
        """)

      assert html =~ "test@example.com"
      refute html =~ "<span"
    end

    test "renders required input with required attribute" do
      form = to_form(%{"email" => ""})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:email]} type="email" required />
        """)

      assert html =~ "required"
    end

    test "renders input with placeholder" do
      form = to_form(%{"search" => ""})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:search]} placeholder="Search..." />
        """)

      assert html =~ ~s(placeholder="Search...")
    end

    test "renders checkbox with proper hidden input and checked state" do
      form = to_form(%{"accept" => "true"})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:accept]} type="checkbox" label="Accept terms" />
        """)

      assert html =~ "Accept terms"
      assert html =~ ~s(type="checkbox")
      assert html =~ ~s(type="hidden")
      assert html =~ ~s(value="false")
      assert html =~ "checked"
      assert html =~ "checkbox checkbox-sm"
    end

    test "renders unchecked checkbox when value is false" do
      form = to_form(%{"accept" => "false"})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:accept]} type="checkbox" label="Accept" />
        """)

      refute html =~ "checked"
    end

    test "renders select input with options" do
      form = to_form(%{"role" => "admin"})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input
          field={@form[:role]}
          type="select"
          label="Role"
          options={[{"Admin", "admin"}, {"User", "user"}, {"Guest", "guest"}]}
        />
        """)

      assert html =~ "<select"
      assert html =~ "Role"
      assert html =~ "Admin"
      assert html =~ "User"
      assert html =~ "Guest"
      assert html =~ ~s(value="admin")
    end

    test "renders select with prompt option" do
      form = to_form(%{"role" => ""})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input
          field={@form[:role]}
          type="select"
          prompt="Choose a role"
          options={[{"Admin", "admin"}]}
        />
        """)

      assert html =~ "Choose a role"
      assert html =~ ~s(<option value="">)
    end

    test "renders multiple select when multiple is true" do
      form = to_form(%{"tags" => ["elixir", "phoenix"]})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input
          field={@form[:tags]}
          type="select"
          multiple
          options={[{"Elixir", "elixir"}, {"Phoenix", "phoenix"}, {"Ecto", "ecto"}]}
        />
        """)

      assert html =~ "multiple"
      assert html =~ ~s(name="tags[]")
    end

    test "renders textarea with proper attributes and content" do
      form = to_form(%{"bio" => "Software developer"})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:bio]} type="textarea" label="Bio" rows="5" />
        """)

      assert html =~ "Bio"
      assert html =~ "<textarea"
      assert html =~ "Software developer"
      assert html =~ ~s(rows="5")
      assert html =~ "w-full textarea"
    end

    test "renders number input with min and max attributes" do
      form = to_form(%{"age" => "25"})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:age]} type="number" min="0" max="120" />
        """)

      assert html =~ ~s(type="number")
      assert html =~ ~s(min="0")
      assert html =~ ~s(max="120")
      assert html =~ "25"
    end

    test "renders password input with type password" do
      form = to_form(%{"password" => "secret123"})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:password]} type="password" />
        """)

      assert html =~ ~s(type="password")
      # Note: Phoenix does render password values in the value attribute
      # Browser behavior hides them visually
      assert html =~ "secret123"
    end

    test "renders date input with proper type" do
      form = to_form(%{"birthday" => "2000-01-01"})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:birthday]} type="date" />
        """)

      assert html =~ ~s(type="date")
      assert html =~ "2000-01-01"
    end

    test "renders input with validation errors and error styling" do
      changeset =
        {%{}, %{email: :string}}
        |> Ecto.Changeset.cast(%{email: "invalid"}, [:email])
        |> Ecto.Changeset.add_error(:email, "must be a valid email address")
        |> Map.put(:action, :validate)

      form = to_form(changeset, as: :user)
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:email]} type="email" label="Email" />
        """)

      assert html =~ "must be a valid email address"
      assert html =~ "input-error"
      assert html =~ "text-error"
      assert html =~ "hero-exclamation-circle"
    end

    test "renders input with multiple validation errors" do
      changeset =
        {%{}, %{password: :string}}
        |> Ecto.Changeset.cast(%{password: "12"}, [:password])
        |> Ecto.Changeset.add_error(:password, "is too short")
        |> Ecto.Changeset.add_error(:password, "must contain special characters")
        |> Map.put(:action, :validate)

      form = to_form(changeset, as: :user)
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:password]} type="password" />
        """)

      assert html =~ "is too short"
      assert html =~ "must contain special characters"
    end

    test "does not show errors when field has not been used" do
      changeset =
        {%{}, %{email: :string}}
        |> Ecto.Changeset.cast(%{}, [:email])
        |> Ecto.Changeset.add_error(:email, "is required")

      form = to_form(changeset, as: :user)
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:email]} type="email" />
        """)

      refute html =~ "is required"
      refute html =~ "input-error"
    end

    test "renders input with custom class overriding defaults" do
      form = to_form(%{"name" => "John"})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:name]} class="my-custom-input-class" />
        """)

      assert html =~ "my-custom-input-class"
      refute html =~ "w-full input"
    end

    test "renders input with custom error class" do
      changeset =
        {%{}, %{email: :string}}
        |> Ecto.Changeset.cast(%{email: "bad"}, [:email])
        |> Ecto.Changeset.add_error(:email, "is invalid")
        |> Map.put(:action, :validate)

      form = to_form(changeset, as: :user)
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:email]} type="email" error_class="border-red-500" />
        """)

      assert html =~ "border-red-500"
      refute html =~ "input-error"
    end

    test "renders disabled input" do
      form = to_form(%{"name" => "John"})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:name]} disabled />
        """)

      assert html =~ "disabled"
    end
  end

  describe "header/1" do
    test "renders header with title in proper heading tag" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.header>My Page Title</.header>
        """)

      assert html =~ "My Page Title"
      assert html =~ "<header"
      assert html =~ "<h1"
      assert html =~ "text-lg font-semibold"
    end

    test "renders header with subtitle" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.header>
          Title
          <:subtitle>This is a subtitle with more details</:subtitle>
        </.header>
        """)

      assert html =~ "Title"
      assert html =~ "This is a subtitle with more details"
      assert html =~ "text-sm"
    end

    test "renders header with actions slot" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.header>
          Users
          <:actions>
            <button>Add User</button>
          </:actions>
        </.header>
        """)

      assert html =~ "Users"
      assert html =~ "Add User"
      assert html =~ "flex items-center justify-between"
    end

    test "renders header without actions flex layout when no actions" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.header>Simple Title</.header>
        """)

      refute html =~ "flex items-center justify-between"
    end

    test "renders header with both subtitle and actions" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.header>
          Dashboard
          <:subtitle>Overview of your account</:subtitle>
          <:actions>
            <button>Settings</button>
          </:actions>
        </.header>
        """)

      assert html =~ "Dashboard"
      assert html =~ "Overview of your account"
      assert html =~ "Settings"
    end
  end

  describe "table/1" do
    test "renders table with rows and columns" do
      assigns = %{
        users: [
          %{id: 1, name: "Alice", email: "alice@example.com"},
          %{id: 2, name: "Bob", email: "bob@example.com"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <.table id="users" rows={@users}>
          <:col :let={user} label="ID">{user.id}</:col>
          <:col :let={user} label="Name">{user.name}</:col>
          <:col :let={user} label="Email">{user.email}</:col>
        </.table>
        """)

      assert html =~ "<table"
      assert html =~ "table table-zebra"
      assert html =~ "<thead>"
      assert html =~ "ID"
      assert html =~ "Name"
      assert html =~ "Email"
      assert html =~ "Alice"
      assert html =~ "alice@example.com"
      assert html =~ "Bob"
      assert html =~ "bob@example.com"
    end

    test "renders table with action column" do
      assigns = %{
        users: [%{id: 1, name: "Alice"}]
      }

      html =
        rendered_to_string(~H"""
        <.table id="users" rows={@users}>
          <:col :let={user} label="Name">{user.name}</:col>
          <:action :let={user}>
            <button>Edit {user.name}</button>
            <button>Delete</button>
          </:action>
        </.table>
        """)

      assert html =~ "Alice"
      assert html =~ "Edit Alice"
      assert html =~ "Delete"
      assert html =~ ~s(<span class="sr-only">)
      assert html =~ "Actions"
    end

    test "renders empty table with headers but no data rows" do
      assigns = %{users: []}

      html =
        rendered_to_string(~H"""
        <.table id="users" rows={@users}>
          <:col :let={user} label="Name">{user.name}</:col>
          <:col :let={user} label="Email">{user.email}</:col>
        </.table>
        """)

      assert html =~ "<table"
      assert html =~ "Name"
      assert html =~ "Email"
      assert html =~ "<tbody id=\"users\""
      # Header row exists, but no data rows in tbody
      assert html =~ "<thead>"
      refute html =~ "<tbody id=\"users\">\n    <tr"
    end

    test "renders table with row_click handler and cursor styling" do
      assigns = %{
        users: [%{id: 1, name: "Alice"}]
      }

      html =
        rendered_to_string(~H"""
        <.table id="users" rows={@users} row_click={fn user -> "show-#{user.id}" end}>
          <:col :let={user} label="Name">{user.name}</:col>
        </.table>
        """)

      assert html =~ "Alice"
      assert html =~ "hover:cursor-pointer"
      assert html =~ "phx-click"
    end

    test "renders table with custom row_id function" do
      assigns = %{
        users: [
          %{uuid: "abc-123", name: "Alice"},
          %{uuid: "def-456", name: "Bob"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <.table id="users" rows={@users} row_id={fn user -> "user-#{user.uuid}" end}>
          <:col :let={user} label="Name">{user.name}</:col>
        </.table>
        """)

      assert html =~ ~s(id="user-abc-123")
      assert html =~ ~s(id="user-def-456")
    end

    test "renders table with row_item transformation function" do
      assigns = %{
        raw_data: [
          {1, "Alice"},
          {2, "Bob"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <.table
          id="users"
          rows={@raw_data}
          row_item={fn {id, name} -> %{id: id, name: name} end}
        >
          <:col :let={user} label="ID">{user.id}</:col>
          <:col :let={user} label="Name">{user.name}</:col>
        </.table>
        """)

      assert html =~ "Alice"
      assert html =~ "Bob"
    end
  end

  describe "list/1" do
    test "renders list with title and content" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.list>
          <:item title="Full Name">John Doe</:item>
          <:item title="Email">john@example.com</:item>
          <:item title="Status">Active</:item>
        </.list>
        """)

      assert html =~ "<ul"
      assert html =~ "list"
      assert html =~ "Full Name"
      assert html =~ "John Doe"
      assert html =~ "Email"
      assert html =~ "john@example.com"
      assert html =~ "Status"
      assert html =~ "Active"
      assert html =~ "font-bold"
    end

    test "renders list with empty content" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.list>
          <:item title="Notes"></:item>
        </.list>
        """)

      assert html =~ "Notes"
      assert html =~ "<ul"
    end

    test "renders list with HTML content in items" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.list>
          <:item title="Actions">
            <button>Edit</button>
            <button>Delete</button>
          </:item>
        </.list>
        """)

      assert html =~ "Actions"
      assert html =~ "Edit"
      assert html =~ "Delete"
    end
  end

  describe "icon/1" do
    test "renders heroicon with default size" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.icon name="hero-x-mark" />
        """)

      assert html =~ "hero-x-mark"
      assert html =~ "<span"
      assert html =~ "size-4"
    end

    test "renders icon with custom class" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.icon name="hero-check" class="size-6 text-green-500" />
        """)

      assert html =~ "hero-check"
      assert html =~ "size-6"
      assert html =~ "text-green-500"
      refute html =~ "size-4"
    end

    test "renders solid icon variant" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.icon name="hero-heart-solid" />
        """)

      assert html =~ "hero-heart-solid"
    end

    test "renders mini icon variant" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.icon name="hero-star-mini" class="size-3" />
        """)

      assert html =~ "hero-star-mini"
      assert html =~ "size-3"
    end
  end

  describe "translate_error/1" do
    test "translates error with count interpolation" do
      error = {"must be at least %{count} characters", [count: 5]}
      result = translate_error(error)
      assert result =~ "5"
      assert result =~ "characters"
    end

    test "translates error without count" do
      error = {"is invalid", []}
      result = translate_error(error)
      assert result == "is invalid"
    end

    test "translates error with count of 1 for singular form" do
      error = {"must be at least %{count} character", [count: 1]}
      result = translate_error(error)
      assert result =~ "1"
      assert result =~ "character"
    end

    test "translates error with multiple interpolations" do
      error = {"must be between %{min} and %{max}", [min: 1, max: 10]}
      result = translate_error(error)
      assert result =~ "1"
      assert result =~ "10"
    end
  end

  describe "translate_errors/2" do
    test "translates all errors for a specific field" do
      errors = [
        name: {"can't be blank", []},
        name: {"must be at least %{count} characters", [count: 3]},
        email: {"is invalid", []}
      ]

      result = translate_errors(errors, :name)
      assert length(result) == 2
      assert "can't be blank" in result
      assert Enum.any?(result, &String.contains?(&1, "3"))
    end

    test "returns empty list when field has no errors" do
      errors = [email: {"is invalid", []}]
      result = translate_errors(errors, :name)
      assert result == []
    end

    test "translates errors with mixed interpolations" do
      errors = [
        password: {"must be at least %{count} characters", [count: 8]},
        password: {"must contain %{type} characters", [type: "special"]}
      ]

      result = translate_errors(errors, :password)
      assert length(result) == 2
      assert Enum.any?(result, &String.contains?(&1, "8"))
      assert Enum.any?(result, &String.contains?(&1, "special"))
    end

    test "handles field with no matching errors in list" do
      errors = [
        email: {"is invalid", []},
        password: {"is too short", []}
      ]

      result = translate_errors(errors, :username)
      assert result == []
    end
  end
end
