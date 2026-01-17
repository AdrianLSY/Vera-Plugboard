defmodule PlugboardWeb.PathsLive.Index do
  use PlugboardWeb, :live_view

  alias Plugboard.Paths

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div>
        <.header>
          <p class="ui-text-primary">Paths</p>
          <:subtitle>
            <span class="ui-text-secondary">
              Manage your path hierarchy and mount points
            </span>
          </:subtitle>
        </.header>
        
    <!-- Create Path Form -->
        <div class="mt-8">
          <.form
            for={@form}
            id="create-path-form"
            phx-submit="create_path"
            class="flex gap-2 items-center"
          >
            <%= if @breadcrumbs != [] do %>
              <div class="bg-[var(--ui-foreground)] rounded-full px-4 py-2 overflow-x-auto max-w-xs flex-shrink-0">
                <div class="flex items-center gap-2 text-sm ui-text-secondary whitespace-nowrap">
                  <.link
                    navigate={~p"/paths"}
                    class="hover:ui-text-primary transition-colors"
                    data-test="breadcrumb-root"
                  >
                    Root
                  </.link>
                  <%= for {breadcrumb, index} <- Enum.with_index(@breadcrumbs) do %>
                    <span>/</span>
                    <%= if index == length(@breadcrumbs) - 1 do %>
                      <span class="ui-text-primary font-medium">{breadcrumb.path}</span>
                    <% else %>
                      <.link
                        navigate={~p"/paths?parent=#{breadcrumb.id}"}
                        class="hover:ui-text-primary transition-colors"
                        data-test={"breadcrumb-#{breadcrumb.path}"}
                      >
                        {breadcrumb.path}
                      </.link>
                    <% end %>
                  <% end %>
                </div>
              </div>
            <% end %>
            <div class="flex-1">
              <.input
                field={@form[:path]}
                type="text"
                placeholder="Create new path (e.g., 'users', 'to-do', 'shopping-cart')"
                autocomplete="off"
                phx-mounted={JS.focus()}
                data-test="path-input"
                class="w-full input ui-foreground ui-text-primary focus:outline-none focus:border-ui-inverted-foreground rounded-full"
              />
            </div>
            <.button
              type="submit"
              phx-disable-with="Creating..."
              data-test="create-path-button"
              class="!w-auto px-6"
            >
              ● Create Path
            </.button>
          </.form>
        </div>
        
    <!-- Paths List -->
        <div class="mt-8">
          <.paths_table
            id="paths-list"
            paths={@streams.paths}
            paths_empty?={@paths_empty?}
            on_path_click={&handle_path_click/1}
          >
            <:action :let={path}>
              <div class="group/actions relative inline-flex items-center gap-2">
                <!-- Settings icon (always visible) -->
                <div class="interactive-button-base icon-button flex items-center justify-center flex-shrink-0">
                  <.icon name="hero-cog-6-tooth" class="icon-button-icon" />
                </div>
                
    <!-- Expandable actions (visible on hover) -->
                <div class="flex items-center gap-2 overflow-hidden max-w-0 opacity-0 group-hover/actions:max-w-[14rem] group-hover/actions:opacity-100 transition-all duration-300 ease-in-out">
                  <button
                    type="button"
                    class="interactive-button-base icon-button flex-shrink-0"
                    phx-click="open_delete"
                    phx-value-id={path.id}
                    data-test="delete-button"
                    title="Delete"
                  >
                    <.icon name="hero-trash" class="icon-button-icon" />
                  </button>
                  <button
                    type="button"
                    class="interactive-button-base icon-button flex-shrink-0"
                    phx-click="open_edit"
                    phx-value-id={path.id}
                    data-test="edit-button"
                    title="Edit"
                  >
                    <.icon name="hero-pencil" class="icon-button-icon" />
                  </button>
                  <button
                    type="button"
                    class="interactive-button-base icon-button flex-shrink-0"
                    phx-click="toggle_mount"
                    phx-value-id={path.id}
                    data-test="mount-button"
                    title={if path.mount_point, do: "Unmount", else: "Mount"}
                  >
                    <%= if path.mount_point do %>
                      <.icon name="hero-link-slash" class="icon-button-icon" />
                    <% else %>
                      <.icon name="hero-link" class="icon-button-icon" />
                    <% end %>
                  </button>
                </div>
              </div>
            </:action>
            <:empty>
              No paths found.
            </:empty>
          </.paths_table>
        </div>
        
    <!-- Edit Path Modal -->
        <.pop_up_form
          :if={@editing_path}
          id="edit-path-modal"
          title="Edit Path"
          title_align="left"
          on_cancel={JS.push("close_edit")}
        >
          <:form>
            <.form for={@edit_form} id="edit-path-form" phx-submit="save_edit">
              <.input
                field={@edit_form[:path]}
                type="text"
                placeholder="Enter path name"
                phx-mounted={JS.focus()}
                class="w-full input ui-foreground focus:outline-none focus:border-ui-text-primary rounded-full ui-text-primary"
              />
              <.button type="submit" phx-disable-with="Saving...">
                ● Save Changes
              </.button>
            </.form>
          </:form>
        </.pop_up_form>
        
    <!-- Delete Path Modal -->
        <.pop_up_form
          :if={@deleting_path}
          id="delete-path-modal"
          title="Delete Path"
          title_align="left"
          on_cancel={JS.push("close_delete")}
        >
          <:form>
            <.form for={@delete_form} id="delete-path-form" phx-submit="confirm_delete">
              <p class="ui-text-primary mb-4">
                To confirm deletion, please enter the full path below:
              </p>
              <p class="font-mono font-semibold ui-text-primary mb-4">
                {@deleting_path.full_path}
              </p>
              <.input
                field={@delete_form[:confirmation]}
                type="text"
                placeholder="Enter full path to confirm"
                phx-mounted={JS.focus()}
                class="w-full input ui-foreground focus:outline-none focus:border-ui-text-primary rounded-full ui-text-primary"
              />
              <.button type="submit" phx-disable-with="Deleting...">
                ● Confirm Delete
              </.button>
            </.form>
          </:form>
        </.pop_up_form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_scope.user
    parent_id = params["parent"]

    # Determine current parent and load paths
    {current_parent, paths} =
      if parent_id do
        case Paths.get_path(parent_id) do
          nil ->
            {nil, Paths.list_paths_by_parent(user.id, nil)}

          parent ->
            # Verify user has access to this path via user_paths
            user_path = Paths.get_user_path(user.id, parent.id)

            if user_path do
              {parent, Paths.list_paths_by_parent(user.id, parent.id)}
            else
              {nil, Paths.list_paths_by_parent(user.id, nil)}
            end
        end
      else
        {nil, Paths.list_paths_by_parent(user.id, nil)}
      end

    # Build breadcrumbs if we have a current parent (uses efficient CTE query)
    breadcrumbs =
      if current_parent, do: Paths.get_path_with_ancestors(current_parent.id), else: []

    # Initialize form
    form = to_form(%{"path" => ""}, as: "path")

    {:ok,
     socket
     |> assign(
       form: form,
       current_parent: current_parent,
       breadcrumbs: breadcrumbs,
       paths_empty?: paths == [],
       editing_path: nil,
       edit_form: nil,
       deleting_path: nil,
       delete_form: nil
     )
     |> stream(:paths, paths)}
  end

  @impl true
  def handle_event("create_path", %{"path" => %{"path" => path_name}}, socket) do
    user = socket.assigns.current_scope.user

    # Create path attributes
    attrs = %{
      path: String.trim(path_name),
      user_id: user.id,
      parent_id:
        if(socket.assigns.current_parent, do: socket.assigns.current_parent.id, else: nil)
    }

    case Paths.create_path(attrs) do
      {:ok, _path} ->
        # Reload paths for current context
        parent_id =
          if socket.assigns.current_parent, do: socket.assigns.current_parent.id, else: nil

        paths = Paths.list_paths_by_parent(user.id, parent_id)

        # Reset form
        form = to_form(%{"path" => ""}, as: "path")

        {:noreply,
         socket
         |> assign(form: form, paths_empty?: paths == [])
         |> stream(:paths, paths, reset: true)
         |> put_flash(:info, "Path created successfully")}

      {:error, %Ecto.Changeset{} = changeset} ->
        # Extract and format validation errors
        error_message =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
            Enum.reduce(opts, msg, fn {key, value}, acc ->
              String.replace(acc, "%{#{key}}", to_string(value))
            end)
          end)
          |> Enum.map(fn {_field, errors} ->
            Enum.join(errors, ", ")
          end)
          |> Enum.join("; ")

        {:noreply,
         socket
         |> assign(form: to_form(changeset, as: "path"))
         |> put_flash(:error, "Failed to create path: #{error_message}")}
    end
  end

  @impl true
  def handle_event("toggle_mount", %{"id" => path_id}, socket) do
    user = socket.assigns.current_scope.user

    case Paths.get_path(path_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Path not found")}

      path ->
        # Check if path can be marked as mount (no children)
        can_mount? = Paths.can_mark_as_mount?(path)

        cond do
          # Trying to mount but path has children
          !path.mount_point && !can_mount? ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Cannot mark as mount point: path has children. Mount points must be terminal."
             )}

          # Toggle mount_point
          true ->
            case Paths.update_path(user.id, path, %{mount_point: !path.mount_point}) do
              {:ok, _updated_path} ->
                # Reload paths for current context
                parent_id =
                  if socket.assigns.current_parent,
                    do: socket.assigns.current_parent.id,
                    else: nil

                paths = Paths.list_paths_by_parent(user.id, parent_id)

                {:noreply,
                 socket
                 |> assign(paths_empty?: paths == [])
                 |> stream(:paths, paths, reset: true)
                 |> put_flash(
                   :info,
                   if(path.mount_point, do: "Unmounted path.", else: "Mounted path.")
                 )}

              {:error, :unauthorized} ->
                {:noreply,
                 put_flash(socket, :error, "You don't have permission to modify this path")}

              {:error, _changeset} ->
                {:noreply, put_flash(socket, :error, "Failed to update path")}
            end
        end
    end
  end

  @impl true
  def handle_event("open_edit", %{"id" => path_id}, socket) do
    case Paths.get_path(path_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Path not found")}

      path ->
        edit_form = to_form(%{"path" => path.path}, as: "edit")

        {:noreply, assign(socket, editing_path: path, edit_form: edit_form)}
    end
  end

  @impl true
  def handle_event("close_edit", _params, socket) do
    {:noreply, assign(socket, editing_path: nil, edit_form: nil)}
  end

  @impl true
  def handle_event("save_edit", %{"edit" => %{"path" => new_path_name}}, socket) do
    user = socket.assigns.current_scope.user
    path = socket.assigns.editing_path

    case Paths.update_path(user.id, path, %{path: String.trim(new_path_name)}) do
      {:ok, _updated_path} ->
        # Reload paths for current context
        parent_id =
          if socket.assigns.current_parent, do: socket.assigns.current_parent.id, else: nil

        paths = Paths.list_paths_by_parent(user.id, parent_id)

        {:noreply,
         socket
         |> assign(paths_empty?: paths == [], editing_path: nil, edit_form: nil)
         |> stream(:paths, paths, reset: true)
         |> put_flash(:info, "Path updated successfully")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> assign(editing_path: nil, edit_form: nil)
         |> put_flash(:error, "You don't have permission to modify this path")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(edit_form: to_form(changeset, as: "edit"))
         |> put_flash(:error, "Failed to update path")}
    end
  end

  @impl true
  def handle_event("open_delete", %{"id" => path_id}, socket) do
    case Paths.get_path(path_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Path not found")}

      path ->
        delete_form = to_form(%{"confirmation" => ""}, as: "delete")

        {:noreply, assign(socket, deleting_path: path, delete_form: delete_form)}
    end
  end

  @impl true
  def handle_event("close_delete", _params, socket) do
    {:noreply, assign(socket, deleting_path: nil, delete_form: nil)}
  end

  @impl true
  def handle_event("confirm_delete", %{"delete" => %{"confirmation" => confirmation}}, socket) do
    user = socket.assigns.current_scope.user
    path = socket.assigns.deleting_path

    if String.trim(confirmation) == path.full_path do
      case Paths.delete_path(user.id, path) do
        {:ok, _deleted_path} ->
          # Reload paths for current context
          parent_id =
            if socket.assigns.current_parent, do: socket.assigns.current_parent.id, else: nil

          paths = Paths.list_paths_by_parent(user.id, parent_id)

          {:noreply,
           socket
           |> assign(paths_empty?: paths == [], deleting_path: nil, delete_form: nil)
           |> stream(:paths, paths, reset: true)
           |> put_flash(:info, "Path deleted successfully")}

        {:error, :unauthorized} ->
          {:noreply,
           socket
           |> assign(deleting_path: nil, delete_form: nil)
           |> put_flash(:error, "You don't have permission to delete this path")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to delete path")}
      end
    else
      {:noreply,
       put_flash(socket, :error, "Confirmation does not match. Please enter the exact full path.")}
    end
  end

  defp handle_path_click(path) do
    if path.mount_point do
      JS.navigate(~p"/paths/#{path.id}/tokens")
    else
      JS.navigate(~p"/paths?parent=#{path.id}")
    end
  end
end
