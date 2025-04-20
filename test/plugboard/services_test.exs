defmodule Plugboard.ServicesTest do
  use Plugboard.DataCase

  describe "services" do
    alias Plugboard.Services.Service
    alias Plugboard.Services.Services
    import Plugboard.ServicesFixtures

    @invalid_attrs %{name: nil}

    test "list_services/0 returns all services" do
      service = service_fixture()
      assert Services.list_services() == [service]
    end

    test "get_service!/1 returns the service with given id" do
      service = service_fixture()
      assert Services.get_service!(service.id) == service
    end

    test "create_service/1 with valid data creates a service" do
      valid_attrs = %{name: "some name"}

      assert {:ok, %Service{} = service} = Services.create_service(valid_attrs)
      assert service.name == "some name"
    end

    test "create_service/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Services.create_service(@invalid_attrs)
    end

    test "update_service/2 with valid data updates the service" do
      service = service_fixture()
      update_attrs = %{name: "some updated name"}

      assert {:ok, %Service{} = service} = Services.update_service(service, update_attrs)
      assert service.name == "some updated name"
    end

    test "update_service/2 with invalid data returns error changeset" do
      service = service_fixture()
      assert {:error, %Ecto.Changeset{}} = Services.update_service(service, @invalid_attrs)
      assert service == Services.get_service!(service.id)
    end

    test "delete_service/1 deletes the service" do
      service = service_fixture()
      assert {:ok, %Service{}} = Services.delete_service(service)
      assert_raise Ecto.NoResultsError, fn -> Services.get_service!(service.id) end
    end

    test "change_service/1 returns a service changeset" do
      service = service_fixture()
      assert %Ecto.Changeset{} = Services.change_service(service)
    end

    test "list_services/0 excludes soft deleted services" do
      service = service_fixture()
      {:ok, deleted_service} = Services.delete_service(service)

      assert Services.list_services() == []
      assert deleted_service.deleted_at != nil
    end

    test "create_service/1 with parent creates child service" do
      parent = service_fixture(%{name: "Parent"})
      attrs = %{name: "Child", parent_id: parent.id}

      assert {:ok, %Service{} = child} = Services.create_service(attrs)
      assert child.name == "Child"
      assert child.parent_id == parent.id
    end

    test "descendants/1 returns all nested children" do
      parent = service_fixture(%{name: "Parent"})
      {:ok, child1} = Services.create_service(%{name: "Child 1", parent_id: parent.id})
      {:ok, child2} = Services.create_service(%{name: "Child 2", parent_id: parent.id})
      {:ok, grandchild} = Services.create_service(%{name: "Grandchild", parent_id: child1.id})

      descendants = Service.descendants(parent)

      assert length(descendants) == 3
      assert Enum.map(descendants, & &1.id) |> Enum.sort() ==
             [child1.id, child2.id, grandchild.id] |> Enum.sort()
    end

    test "full_path/1 returns path from root to service" do
      parent = service_fixture(%{name: "Parent"})
      {:ok, child} = Services.create_service(%{name: "Child", parent_id: parent.id})
      {:ok, grandchild} = Services.create_service(%{name: "Grandchild", parent_id: child.id})

      path = Service.full_path(grandchild)

      assert length(path) == 3
      assert Enum.map(path, & &1.id) == [parent.id, child.id, grandchild.id]
    end

    test "delete_service/1 soft deletes service and all descendants" do
      parent = service_fixture(%{name: "Parent"})
      {:ok, child} = Services.create_service(%{name: "Child", parent_id: parent.id})
      {:ok, grandchild} = Services.create_service(%{name: "Grandchild", parent_id: child.id})

      assert {:ok, deleted_parent} = Services.delete_service(parent)

      assert deleted_parent.deleted_at != nil
      assert Services.list_services() == []
      assert Service.descendants(parent) == []
      assert_raise Ecto.NoResultsError, fn -> Services.get_service!(child.id) end
      assert_raise Ecto.NoResultsError, fn -> Services.get_service!(grandchild.id) end
    end

    test "update_service/2 maintains parent-child relationships" do
      parent1 = service_fixture(%{name: "Parent 1"})
      parent2 = service_fixture(%{name: "Parent 2"})
      {:ok, child} = Services.create_service(%{name: "Child", parent_id: parent1.id})

      assert {:ok, updated_child} = Services.update_service(child, %{parent_id: parent2.id})
      assert updated_child.parent_id == parent2.id

      reloaded_child = Services.get_service!(child.id)
      assert reloaded_child.parent_id == parent2.id
    end

    test "create_service/1 broadcasts to appropriate topics for root service" do
      Phoenix.PubSub.subscribe(Plugboard.PubSub, "services")

      {:ok, service} = Services.create_service(%{name: "Root Service"})

      assert_receive {:service_created, ^service}
    end

    test "create_service/1 broadcasts to appropriate topics for child service" do
      parent = service_fixture()
      Phoenix.PubSub.subscribe(Plugboard.PubSub, "service/#{parent.id}")

      {:ok, child} = Services.create_service(%{name: "Child", parent_id: parent.id})

      assert_receive {:service_created, ^child}
    end

    test "update_service/2 broadcasts updates and path changes" do
      parent = service_fixture()
      {:ok, child} = Services.create_service(%{name: "Child", parent_id: parent.id})
      {:ok, grandchild} = Services.create_service(%{name: "Grandchild", parent_id: child.id})

      Phoenix.PubSub.subscribe(Plugboard.PubSub, "service/#{child.id}")
      Phoenix.PubSub.subscribe(Plugboard.PubSub, "service/#{parent.id}")
      Phoenix.PubSub.subscribe(Plugboard.PubSub, "service/#{grandchild.id}")

      {:ok, updated_child} = Services.update_service(child, %{name: "Updated Child"})

      assert_receive {:service_updated, ^updated_child}
      assert_receive {:path_updated, path} when is_list(path)
    end

    test "delete_service/1 broadcasts deletion to all affected services" do
      parent = service_fixture()
      {:ok, child} = Services.create_service(%{name: "Child", parent_id: parent.id})
      {:ok, grandchild} = Services.create_service(%{name: "Grandchild", parent_id: child.id})

      Phoenix.PubSub.subscribe(Plugboard.PubSub, "service/#{parent.id}")
      Phoenix.PubSub.subscribe(Plugboard.PubSub, "service/#{child.id}")
      Phoenix.PubSub.subscribe(Plugboard.PubSub, "service/#{grandchild.id}")

      {:ok, _} = Services.delete_service(parent)

      assert_receive {:service_deleted, %Service{id: _parent_id}, _}
      assert_receive {:service_deleted, %Service{id: _child_id}, _}
      assert_receive {:service_deleted, %Service{id: _grandchild_id}, _}
    end

    test "update_service/2 with failed changeset returns error" do
      service = service_fixture()

      result = Services.update_service(service, %{name: nil})
      assert {:error, %Ecto.Changeset{}} = result
    end

    test "create_service/1 with failed changeset doesn't broadcast" do
      Phoenix.PubSub.subscribe(Plugboard.PubSub, "services")

      {:error, _changeset} = Services.create_service(%{name: nil})

      refute_receive {:service_created, _}
    end

    test "update_service/2 broadcasts to services topic for root service update" do
      service = service_fixture()
      Phoenix.PubSub.subscribe(Plugboard.PubSub, "services")

      {:ok, updated_service} = Services.update_service(service, %{name: "Updated Root"})

      assert_receive {:service_updated, ^updated_service}
    end

    test "delete_service/1 broadcasts to services topic for root service deletion" do
      service = service_fixture()
      Phoenix.PubSub.subscribe(Plugboard.PubSub, "services")

      {:ok, _} = Services.delete_service(service)

      assert_receive {:service_deleted, %Service{}}
    end
  end
end
