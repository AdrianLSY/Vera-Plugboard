defmodule Plugboard.MountStoreTest do
  use Plugboard.DataCase, async: false

  import Plugboard.AccountsFixtures

  alias Plugboard.MountStore
  alias Plugboard.Paths

  setup do
    # Ensure MountStore is running and ETS table exists
    # The application supervisor should have started it, but we reload to ensure clean state
    MountStore.reload_all()
    :ok
  end

  describe "match/1" do
    test "matches exact mount point path" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      assert {:ok, {"/xyz", "/", _mount_id}} = MountStore.match("/xyz")
    end

    test "matches mount point with additional path segments" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      assert {:ok, {"/xyz", "/todo/items", _mount_id}} = MountStore.match("/xyz/todo/items")
    end

    test "matches nested mount point" do
      user = user_fixture()

      {:ok, parent} =
        Paths.create_path(%{
          path: "abc",
          user_id: user.id
        })

      {:ok, child} =
        Paths.create_path(%{
          path: "todo",
          parent_id: parent.id,
          user_id: user.id
        })

      {:ok, _child} = Paths.update_path(child, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      assert {:ok, {"/abc/todo", "/list", _mount_id}} = MountStore.match("/abc/todo/list")
    end

    test "matches the most specific mount point" do
      user = user_fixture()

      # Create two separate mount hierarchies to test specificity
      # /services mount
      {:ok, services_path} =
        Paths.create_path(%{
          path: "services",
          user_id: user.id
        })

      {:ok, _services_path} = Paths.update_path(services_path, %{mount_point: true})

      # /services-v2 mount (more specific in terms of path length)
      {:ok, services_v2_path} =
        Paths.create_path(%{
          path: "services-v2",
          user_id: user.id
        })

      {:ok, _services_v2_path} = Paths.update_path(services_v2_path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      # Should match /services-v2 for longer path
      assert {:ok, {"/services-v2", "/users", _mount_id}} =
               MountStore.match("/services-v2/users")

      # Should match /services for shorter path
      assert {:ok, {"/services", "/users", _mount_id}} = MountStore.match("/services/users")
    end

    test "returns error when no mount point matches" do
      assert {:error, :not_found} = MountStore.match("/nonexistent")
      assert {:error, :not_found} = MountStore.match("/some/random/path")
    end

    test "normalizes request path by adding leading slash" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "test",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      # Should work even without leading slash
      assert {:ok, {"/test", "/path", _mount_id}} = MountStore.match("test/path")
    end

    test "normalizes request path by removing trailing slash" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "test",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      # Should work with trailing slash
      assert {:ok, {"/test", "/", _mount_id}} = MountStore.match("/test/")
    end

    test "handles root path correctly" do
      # Root path alone should not match anything
      assert {:error, :not_found} = MountStore.match("/")
    end

    test "computes correct forwarded path for exact match" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "service",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      # Exact match should forward "/"
      assert {:ok, {"/service", "/", _mount_id}} = MountStore.match("/service")
    end

    test "computes correct forwarded path with nested segments" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      assert {:ok, {"/api", "/v1/users/123/profile", _mount_id}} =
               MountStore.match("/api/v1/users/123/profile")
    end
  end

  describe "refresh_mount/1" do
    test "adds a new mount to ETS" do
      user = user_fixture()

      # Create path but don't mark as mount initially
      {:ok, path} =
        Paths.create_path(%{
          path: "newmount",
          user_id: user.id
        })

      # Should not match yet
      assert {:error, :not_found} = MountStore.match("/newmount")

      # Mark as mount
      {:ok, updated} = Paths.update_path(path, %{mount_point: true})

      # Wait a bit for NOTIFY to propagate, then verify with reload
      :timer.sleep(50)
      MountStore.reload_all()

      # Should now match
      assert {:ok, {"/newmount", "/", _mount_id}} = MountStore.match("/newmount")
      assert updated.id == elem(elem(MountStore.match("/newmount"), 1), 2)
    end

    test "removes a mount from ETS when unmarked" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "tempmount",
          user_id: user.id
        })

      {:ok, mounted_path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      # Should match
      assert {:ok, {"/tempmount", "/", _mount_id}} = MountStore.match("/tempmount")

      # Unmark as mount (use the mounted_path, not the original path)
      {:ok, _unmounted_path} = Paths.update_path(mounted_path, %{mount_point: false})

      # Reload to ensure ETS is updated
      MountStore.reload_all()

      # Should no longer match
      assert {:error, :not_found} = MountStore.match("/tempmount")
    end
  end

  describe "remove_mount/1" do
    test "removes deleted mount from ETS" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "deleteme",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      # Should match
      assert {:ok, {"/deleteme", "/", _mount_id}} = MountStore.match("/deleteme")

      # Delete the path
      {:ok, _path} = Paths.delete_path(path)

      # Reload to ensure ETS is updated
      MountStore.reload_all()

      # Should no longer match
      assert {:error, :not_found} = MountStore.match("/deleteme")
    end
  end

  describe "reload_all/1" do
    test "reloads all mounts from database" do
      user = user_fixture()

      # Create multiple mounts
      {:ok, path1} =
        Paths.create_path(%{
          path: "mount1",
          user_id: user.id
        })

      {:ok, _path1} = Paths.update_path(path1, %{mount_point: true})

      {:ok, path2} =
        Paths.create_path(%{
          path: "mount2",
          user_id: user.id
        })

      {:ok, _path2} = Paths.update_path(path2, %{mount_point: true})

      # Force reload
      {:ok, count, _domain_count} = MountStore.reload_all()

      # Should have at least our 2 mounts (may have more from other tests)
      assert count >= 2

      # Both should match
      assert {:ok, {"/mount1", "/", _}} = MountStore.match("/mount1")
      assert {:ok, {"/mount2", "/", _}} = MountStore.match("/mount2")
    end
  end

  describe "list_mounts/0" do
    test "returns all mounts in ETS" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "listtest",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      mounts = MountStore.list_mounts()

      # Should include our mount
      assert Enum.any?(mounts, fn {full_path, _} -> full_path == "/listtest" end)
    end
  end

  describe "telemetry events" do
    test "emits telemetry on successful match" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "telemetry-test",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated
      MountStore.reload_all()

      # Attach telemetry handler
      test_pid = self()

      :telemetry.attach(
        "test-mount-store-match",
        [:plugboard, :mount_store, :match],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      # Perform match
      assert {:ok, {"/telemetry-test", "/", _}} = MountStore.match("/telemetry-test")

      # Verify telemetry event was emitted
      assert_receive {:telemetry_event, [:plugboard, :mount_store, :match], measurements,
                      metadata}

      assert is_integer(measurements.duration)
      assert measurements.duration > 0
      assert metadata.result == :ok
      assert metadata.path == "/telemetry-test"

      # Clean up
      :telemetry.detach("test-mount-store-match")
    end

    test "emits telemetry on failed match" do
      # Attach telemetry handler
      test_pid = self()

      :telemetry.attach(
        "test-mount-store-match-fail",
        [:plugboard, :mount_store, :match],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      # Attempt to match non-existent path
      assert {:error, :not_found} = MountStore.match("/nonexistent/path")

      # Verify telemetry event was emitted with error result
      assert_receive {:telemetry_event, [:plugboard, :mount_store, :match], measurements,
                      metadata}

      assert is_integer(measurements.duration)
      assert measurements.duration > 0
      assert metadata.result == :error
      assert metadata.path == "/nonexistent/path"

      # Clean up
      :telemetry.detach("test-mount-store-match-fail")
    end
  end

  describe "error handling and resilience" do
    test "GenServer survives refresh_mount errors for non-existent paths" do
      # Attempt to refresh a mount that doesn't exist
      # This should not crash the GenServer
      MountStore.refresh_mount("/definitely-does-not-exist-path-12345")

      # Give it time to process
      :timer.sleep(100)

      # Verify GenServer is still alive and functional
      assert Process.whereis(Plugboard.MountStore) != nil

      # Verify it can still perform normal operations
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "still-works",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      assert {:ok, {"/still-works", "/", _}} = MountStore.match("/still-works")
    end

    test "handle_info :reconcile runs without crashing" do
      # Get the MountStore process
      mount_store_pid = Process.whereis(Plugboard.MountStore)
      assert mount_store_pid != nil

      # Send reconcile message directly
      send(mount_store_pid, :reconcile)

      # Give it time to process
      :timer.sleep(100)

      # Verify GenServer is still alive
      assert Process.whereis(Plugboard.MountStore) == mount_store_pid

      # Verify it's still functional
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "reconcile-test",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      assert {:ok, {"/reconcile-test", "/", _}} = MountStore.match("/reconcile-test")
    end

    test "remove_mount/1 removes mount from ETS directly" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "direct-remove",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      # Verify mount exists
      assert {:ok, {"/direct-remove", "/", _}} = MountStore.match("/direct-remove")

      # Remove directly using remove_mount (simulates NOTIFY)
      MountStore.remove_mount("/direct-remove")

      # Give it time to process the cast
      :timer.sleep(50)

      # Should no longer match
      assert {:error, :not_found} = MountStore.match("/direct-remove")
    end

    test "refresh_mount/1 updates existing mount in ETS" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "refresh-update",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      # Get original mount data
      [{"/refresh-update", {original_id, _original_updated_at}}] =
        :ets.lookup(:plugboard_mounts, "/refresh-update")

      # Trigger refresh
      MountStore.refresh_mount("/refresh-update")

      # Give it time to process
      :timer.sleep(50)

      # Verify mount still exists with same ID
      [{"/refresh-update", {new_id, _new_updated_at}}] =
        :ets.lookup(:plugboard_mounts, "/refresh-update")

      assert original_id == new_id
    end

    test "reload_all emits telemetry" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:plugboard, :mount_store, :reload],
          [:plugboard, :mount_store, :size]
        ])

      # Trigger reload
      {:ok, _count, _domain_count} = MountStore.reload_all()

      # Verify reload telemetry was emitted
      assert_receive {[:plugboard, :mount_store, :reload], ^ref, %{duration: _, count: _},
                      %{trigger: :manual}},
                     1000

      # Verify size telemetry was emitted
      assert_receive {[:plugboard, :mount_store, :size], ^ref, %{count: _}, %{}}, 1000

      :telemetry.detach(ref)
    end

    test "reconcile emits telemetry with :periodic trigger" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:plugboard, :mount_store, :reload]
        ])

      # Trigger reconcile directly
      mount_store_pid = Process.whereis(Plugboard.MountStore)
      send(mount_store_pid, :reconcile)

      # Verify reload telemetry was emitted with periodic trigger
      assert_receive {[:plugboard, :mount_store, :reload], ^ref, %{duration: _, count: _},
                      %{trigger: :periodic}},
                     1000

      :telemetry.detach(ref)
    end
  end

  describe "match_by_domain/1" do
    setup do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})

      %{path: path}
    end

    test "matches exact domain", %{path: path} do
      {:ok, _da} =
        Plugboard.DomainAffinities.create_domain_affinity(%{
          domain: "api.example.com",
          path_id: path.id
        })

      MountStore.reload_all()

      assert {:ok, {_path_id, "/api"}} = MountStore.match_by_domain("api.example.com")
    end

    test "normalizes domain before matching", %{path: path} do
      {:ok, _da} =
        Plugboard.DomainAffinities.create_domain_affinity(%{
          domain: "api.example.com",
          path_id: path.id
        })

      MountStore.reload_all()

      # Test with uppercase
      assert {:ok, {_path_id, "/api"}} = MountStore.match_by_domain("API.EXAMPLE.COM")
    end

    test "strips port before matching", %{path: path} do
      {:ok, _da} =
        Plugboard.DomainAffinities.create_domain_affinity(%{
          domain: "api.example.com",
          path_id: path.id
        })

      MountStore.reload_all()

      # Test with port
      assert {:ok, {_path_id, "/api"}} = MountStore.match_by_domain("api.example.com:8080")
    end

    test "matches wildcard domain", %{path: path} do
      {:ok, _da} =
        Plugboard.DomainAffinities.create_domain_affinity(%{
          domain: "*.api.example.com",
          path_id: path.id
        })

      MountStore.reload_all()

      # Should match any subdomain
      assert {:ok, {_path_id, "/api"}} = MountStore.match_by_domain("v1.api.example.com")
      assert {:ok, {_path_id, "/api"}} = MountStore.match_by_domain("v2.api.example.com")
      assert {:ok, {_path_id, "/api"}} = MountStore.match_by_domain("foo.api.example.com")
    end

    test "wildcard does not match base domain", %{path: path} do
      {:ok, _da} =
        Plugboard.DomainAffinities.create_domain_affinity(%{
          domain: "*.api.example.com",
          path_id: path.id
        })

      MountStore.reload_all()

      # Wildcard should not match the base domain itself
      assert {:error, :not_found} = MountStore.match_by_domain("api.example.com")
    end

    test "exact match takes precedence over wildcard", %{path: path} do
      user = user_fixture()

      {:ok, other_path} =
        Paths.create_path(%{
          path: "users",
          user_id: user.id
        })

      {:ok, other_path} = Paths.update_path(other_path, %{mount_point: true})

      # Create wildcard that would match
      {:ok, _da1} =
        Plugboard.DomainAffinities.create_domain_affinity(%{
          domain: "*.example.com",
          path_id: path.id
        })

      # Create exact match
      {:ok, _da2} =
        Plugboard.DomainAffinities.create_domain_affinity(%{
          domain: "users.example.com",
          path_id: other_path.id
        })

      MountStore.reload_all()

      # Should match exact, not wildcard
      assert {:ok, {path_id, "/users"}} = MountStore.match_by_domain("users.example.com")
      # path_id from ETS is binary, convert string UUID to binary for comparison
      {:ok, expected_id} = Ecto.UUID.dump(other_path.id)
      assert path_id == expected_id
    end

    test "most specific wildcard wins", %{path: path} do
      user = user_fixture()

      {:ok, other_path} =
        Paths.create_path(%{
          path: "users",
          user_id: user.id
        })

      {:ok, other_path} = Paths.update_path(other_path, %{mount_point: true})

      # Create broad wildcard
      {:ok, _da1} =
        Plugboard.DomainAffinities.create_domain_affinity(%{
          domain: "*.example.com",
          path_id: path.id
        })

      # Create more specific wildcard
      {:ok, _da2} =
        Plugboard.DomainAffinities.create_domain_affinity(%{
          domain: "*.api.example.com",
          path_id: other_path.id
        })

      MountStore.reload_all()

      # Should match more specific wildcard
      assert {:ok, {path_id, "/users"}} = MountStore.match_by_domain("v1.api.example.com")
      # path_id from ETS is binary, convert string UUID to binary for comparison
      {:ok, expected_id} = Ecto.UUID.dump(other_path.id)
      assert path_id == expected_id

      # Should match broad wildcard for other subdomains
      assert {:ok, {path_id, "/api"}} = MountStore.match_by_domain("other.example.com")
      {:ok, expected_id} = Ecto.UUID.dump(path.id)
      assert path_id == expected_id
    end

    test "returns not_found for unknown domain" do
      assert {:error, :not_found} = MountStore.match_by_domain("unknown.example.com")
    end

    test "returns not_found for domain with no affinity" do
      assert {:error, :not_found} = MountStore.match_by_domain("noaffinity.example.com")
    end
  end

  describe "list_domain_affinities/0" do
    setup do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})

      %{path: path}
    end

    test "returns all domain affinities from ETS", %{path: path} do
      {:ok, _da} =
        Plugboard.DomainAffinities.create_domain_affinity(%{
          domain: "api.example.com",
          path_id: path.id
        })

      MountStore.reload_all()

      affinities = MountStore.list_domain_affinities()

      assert length(affinities) == 1
      # path_id from ETS is binary
      {:ok, expected_id} = Ecto.UUID.dump(path.id)
      assert {"api.example.com", {expected_id, "/api"}} in affinities
    end
  end
end
