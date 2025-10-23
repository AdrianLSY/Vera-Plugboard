defmodule PlugboardWeb.CoreComponentsTest do
  use PlugboardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import PlugboardWeb.CoreComponents

  describe "flash/1" do
    test "renders info flash with message" do
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
    end

    test "renders error flash with message" do
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
    end

    test "renders flash with inner block" do
      assigns = %{
        flash: %{},
        kind: :info
      }

      html =
        rendered_to_string(~H"""
        <.flash kind={@kind} flash={@flash}>Custom message</.flash>
        """)

      assert html =~ "Custom message"
    end

    test "renders flash with title" do
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
      assert html =~ "Message content"
    end

    test "does not render when no message" do
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
  end

  describe "button/1" do
    test "renders button with default styling" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button>Click me</.button>
        """)

      assert html =~ "Click me"
      assert html =~ "btn"
      assert html =~ "btn-primary"
      assert html =~ "<button"
    end

    test "renders button with primary variant" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button variant="primary">Submit</.button>
        """)

      assert html =~ "Submit"
      assert html =~ "btn-primary"
    end

    test "renders link button with navigate" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button navigate="/home">Go Home</.button>
        """)

      assert html =~ "Go Home"
      assert html =~ "href"
      assert html =~ "/home"
    end

    test "renders link button with patch" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button patch="/users/1">Edit</.button>
        """)

      assert html =~ "Edit"
      assert html =~ "patch"
    end

    test "renders disabled button" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.button disabled>Disabled</.button>
        """)

      assert html =~ "Disabled"
      assert html =~ "disabled"
    end
  end

  describe "input/1" do
    test "renders text input with label" do
      form = to_form(%{"name" => "John"})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:name]} label="Name" />
        """)

      assert html =~ "Name"
      assert html =~ "John"
      assert html =~ ~s(type="text")
    end

    test "renders email input" do
      form = to_form(%{"email" => "test@example.com"})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:email]} type="email" />
        """)

      assert html =~ "test@example.com"
      assert html =~ ~s(type="email")
    end

    test "renders checkbox input" do
      form = to_form(%{"accept" => "true"})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:accept]} type="checkbox" label="Accept terms" />
        """)

      assert html =~ "Accept terms"
      assert html =~ ~s(type="checkbox")
      assert html =~ "checkbox"
    end

    test "renders select input" do
      form = to_form(%{"role" => "admin"})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:role]} type="select" options={[{"Admin", "admin"}, {"User", "user"}]} />
        """)

      assert html =~ "<select"
      assert html =~ "Admin"
      assert html =~ "User"
    end

    test "renders select with prompt" do
      form = to_form(%{"role" => ""})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:role]} type="select" prompt="Choose role" options={[{"Admin", "admin"}]} />
        """)

      assert html =~ "Choose role"
    end

    test "renders textarea input" do
      form = to_form(%{"bio" => "My bio"})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:bio]} type="textarea" label="Bio" />
        """)

      assert html =~ "Bio"
      assert html =~ "<textarea"
      assert html =~ "My bio"
    end

    test "renders input with errors" do
      changeset =
        {%{}, %{email: :string}}
        |> Ecto.Changeset.cast(%{email: "invalid"}, [:email])
        |> Ecto.Changeset.add_error(:email, "is invalid")
        |> Map.put(:action, :validate)

      form = to_form(changeset, as: :user)
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:email]} type="email" />
        """)

      assert html =~ "is invalid"
      assert html =~ "input-error"
    end

    test "renders number input" do
      form = to_form(%{"age" => "25"})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:age]} type="number" />
        """)

      assert html =~ ~s(type="number")
      assert html =~ "25"
    end

    test "renders password input" do
      form = to_form(%{"password" => ""})
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <.input field={@form[:password]} type="password" />
        """)

      assert html =~ ~s(type="password")
    end
  end

  describe "header/1" do
    test "renders header with title" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.header>My Page</.header>
        """)

      assert html =~ "My Page"
      assert html =~ "<header"
    end

    test "renders header with subtitle" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.header>
          Title
          <:subtitle>Subtitle text</:subtitle>
        </.header>
        """)

      assert html =~ "Title"
      assert html =~ "Subtitle text"
    end

    test "renders header with actions" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.header>
          Title
          <:actions>
            <button>Action</button>
          </:actions>
        </.header>
        """)

      assert html =~ "Title"
      assert html =~ "Action"
    end
  end

  describe "table/1" do
    test "renders table with rows" do
      assigns = %{
        users: [
          %{id: 1, name: "Alice"},
          %{id: 2, name: "Bob"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <.table id="users" rows={@users}>
          <:col :let={user} label="ID">{user.id}</:col>
          <:col :let={user} label="Name">{user.name}</:col>
        </.table>
        """)

      assert html =~ "Alice"
      assert html =~ "Bob"
      assert html =~ "ID"
      assert html =~ "Name"
    end

    test "renders table with actions" do
      assigns = %{
        users: [%{id: 1, name: "Alice"}]
      }

      html =
        rendered_to_string(~H"""
        <.table id="users" rows={@users}>
          <:col :let={user} label="Name">{user.name}</:col>
          <:action :let={user}>
            <button>Edit {user.name}</button>
          </:action>
        </.table>
        """)

      assert html =~ "Alice"
      assert html =~ "Edit Alice"
    end

    test "renders empty table" do
      assigns = %{users: []}

      html =
        rendered_to_string(~H"""
        <.table id="users" rows={@users}>
          <:col :let={user} label="Name">{user.name}</:col>
        </.table>
        """)

      assert html =~ "<table"
      assert html =~ "Name"
    end
  end

  describe "list/1" do
    test "renders list with items" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.list>
          <:item title="Title 1">Content 1</:item>
          <:item title="Title 2">Content 2</:item>
        </.list>
        """)

      assert html =~ "Title 1"
      assert html =~ "Content 1"
      assert html =~ "Title 2"
      assert html =~ "Content 2"
    end
  end

  describe "icon/1" do
    test "renders heroicon" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.icon name="hero-x-mark" />
        """)

      assert html =~ "hero-x-mark"
      assert html =~ "<span"
    end

    test "renders icon with custom class" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.icon name="hero-check" class="size-6" />
        """)

      assert html =~ "hero-check"
      assert html =~ "size-6"
    end
  end

  describe "translate_error/1" do
    test "translates error tuple" do
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
  end

  describe "translate_errors/2" do
    test "translates errors for specific field" do
      errors = [
        name: {"can't be blank", []},
        name: {"must be at least %{count} characters", [count: 3]},
        email: {"is invalid", []}
      ]

      result = translate_errors(errors, :name)
      assert length(result) == 2
      assert "can't be blank" in result
    end

    test "returns empty list when field has no errors" do
      errors = [email: {"is invalid", []}]
      result = translate_errors(errors, :name)
      assert result == []
    end
  end
end
