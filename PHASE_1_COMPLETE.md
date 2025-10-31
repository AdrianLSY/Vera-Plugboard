# Phase 1: Core Data Model & Routing - COMPLETE ✅

**Completion Date:** October 31, 2024

## Overview

Phase 1 of the Plugboard project has been successfully completed. This phase focused on implementing the core data model for hierarchical path management, database triggers for data integrity, and the foundational API for CRUD operations on paths.

## Deliverables Completed

### 1. Database Schema & Migration

**File:** `priv/repo/migrations/20251031092344_create_paths_table.exs`

Implemented the `paths` table with the following features:

- **Binary UUID primary keys** for distributed system compatibility
- **Hierarchical structure** using self-referential `parent_id` foreign key
- **Soft delete support** via `deleted_at` timestamp
- **Mount point designation** via `mount_point` boolean flag
- **Automatic path computation** via `full_path` field (computed by trigger)
- **Proper indexing** for performance:
  - Unique constraint on `(user_id, parent_id, path)` with NULL handling via COALESCE
  - Index on `full_path` for fast lookups
  - Composite index on `(mount_point, full_path)` for routing queries
  - Index on `user_id` for ownership queries

### 2. Database Triggers

Implemented four critical PostgreSQL triggers to enforce business rules and maintain data consistency:

#### a. `compute_full_path()`
- **Type:** BEFORE INSERT OR UPDATE
- **Purpose:** Automatically computes the canonical full path by traversing the parent hierarchy
- **Example:** Parent `/xyz` + child `todo` → `/xyz/todo`

#### b. `prevent_child_under_mount()`
- **Type:** BEFORE INSERT OR UPDATE
- **Purpose:** Enforces that mount points are terminal nodes (no children allowed)
- **Error:** Raises `check_violation` with descriptive message

#### c. `prevent_mount_when_has_children()`
- **Type:** BEFORE UPDATE
- **Purpose:** Prevents marking a path as a mount point if it has active children
- **Error:** Raises `check_violation` with descriptive message

#### d. `update_descendant_full_paths()`
- **Type:** AFTER UPDATE
- **Purpose:** Recursively updates `full_path` for all descendants when a parent's path changes
- **Implementation:** Uses recursive CTE for efficient bulk updates

### 3. Elixir Schema & Context

**Files:**
- `lib/plugboard/paths/path.ex` - Ecto schema
- `lib/plugboard/paths.ex` - Context module

#### Path Schema Features:
- Proper associations (`belongs_to`, `has_many`)
- Multiple changesets for different operations:
  - `create_changeset/2` - For creating new paths
  - `update_changeset/2` - For updating existing paths
  - `restore_changeset/2` - For restoring soft-deleted paths
  - `delete_changeset/1` - For soft-deleting paths
- Validations:
  - Path segments must not contain slashes
  - Path segments must be alphanumeric with hyphens, underscores, dots
  - Length constraints (1-255 characters)

#### Context API:
- `list_paths/1` - List all active paths for a user
- `list_mount_points/1` - List only mount points for a user
- `get_path/1` - Get a single path by ID (excluding soft-deleted)
- `get_path_by_full_path/2` - Get path by full_path string
- `create_path/1` - Create new path **with automatic soft-delete restoration**
- `update_path/2` - Update path properties
- `delete_path/1` - Soft-delete a path (cascades to children)
- `get_children/1` - Get direct children of a path
- `get_descendants/1` - Get all descendants recursively
- `can_mark_as_mount?/1` - Check if path can be marked as mount
- `can_add_child?/1` - Check if path can have children

### 4. Soft-Delete Restoration Logic

**Key Feature:** When creating a path that matches an existing soft-deleted record, the system automatically **restores** the deleted record instead of creating a duplicate.

**Behavior:**
1. Check if path with same `user_id`, `parent_id`, and `path` exists with `deleted_at IS NOT NULL`
2. If found, restore it by setting `deleted_at = NULL` and `mount_point = FALSE`
3. If not found, create new record as normal
4. Prevents duplicate records and maintains referential integrity
5. Audit trail preserved through timestamp history

### 5. Comprehensive Test Suite

**File:** `test/plugboard/paths_test.exs`

**38 tests covering:**
- ✅ Basic CRUD operations
- ✅ Hierarchical path creation (root, children, deeply nested)
- ✅ Full path computation by triggers
- ✅ Unique constraint enforcement
- ✅ Soft-delete and restoration logic
- ✅ Cascade soft-delete to children
- ✅ Mount point terminal node constraints
- ✅ Prevention of marking nodes with children as mounts
- ✅ Descendant full_path cascade updates
- ✅ User isolation (paths from other users not visible)
- ✅ Database trigger behavior verification
- ✅ Error handling and validation

**Test Results:** All 223 tests passing ✅

## Technical Challenges Solved

### 1. NULL Handling in Unique Constraints
**Problem:** PostgreSQL treats NULL values as distinct in unique indexes, allowing duplicate root paths.

**Solution:** Used `COALESCE(parent_id::text, '')` in unique index to convert NULL to empty string for constraint checking.

### 2. Trigger Execution Order
**Problem:** `update_descendant_full_paths` trigger wasn't firing because `UPDATE OF full_path` only fires when full_path is explicitly in the SET clause.

**Solution:** Changed to `AFTER UPDATE OF path, parent_id` since those are the fields that cause full_path changes.

### 3. DateTime Microseconds
**Problem:** Ecto's `:utc_datetime` type doesn't support microseconds, but `DateTime.utc_now()` includes them.

**Solution:** Always truncate to seconds using `DateTime.truncate(:second)` before storing.

### 4. Soft-Delete Cascade
**Problem:** `ON DELETE CASCADE` only works for hard deletes, not soft deletes.

**Solution:** Implemented application-level cascade using recursive CTE to soft-delete all descendants before deleting parent.

### 5. UUID Parameter Binding
**Problem:** Raw SQL queries with binary_id parameters need binary format, not string format.

**Solution:** Use `Ecto.UUID.dump/1` to convert UUID strings to binary format for Postgrex.

## Database Integrity Guarantees

1. ✅ **No orphaned paths** - Foreign key constraints ensure parent exists
2. ✅ **No duplicate sibling paths** - Unique constraint with NULL handling
3. ✅ **No children under mount points** - Database trigger enforcement
4. ✅ **No mounts with children** - Database trigger enforcement
5. ✅ **Consistent full_paths** - Automatic computation and cascade updates
6. ✅ **Referential integrity** - Soft-delete restoration prevents duplicates

## API Usage Examples

```elixir
# Create a root path
{:ok, root} = Paths.create_path(%{
  path: "xyz",
  user_id: user.id,
  created_by_user_id: user.id
})
# => %Path{full_path: "/xyz"}

# Create a child path
{:ok, child} = Paths.create_path(%{
  path: "todo",
  parent_id: root.id,
  user_id: user.id,
  created_by_user_id: user.id
})
# => %Path{full_path: "/xyz/todo"}

# Soft-delete a path
{:ok, deleted} = Paths.delete_path(root)
# => %Path{deleted_at: ~U[2024-10-31 14:00:00Z]}
# Children are also soft-deleted automatically

# Recreate same path - restores instead of duplicating
{:ok, restored} = Paths.create_path(%{
  path: "xyz",
  user_id: user.id,
  created_by_user_id: user.id
})
# => %Path{id: <same as original>, deleted_at: nil, mount_point: false}

# Mark as mount point
{:ok, mount} = Paths.update_path(restored, %{mount_point: true})

# Attempt to create child under mount - ERROR
Paths.create_path(%{
  path: "child",
  parent_id: mount.id,
  user_id: user.id,
  created_by_user_id: user.id
})
# => ** (Postgrex.Error) Cannot create child path under a mount point
```

## Next Steps: Phase 2

With Phase 1 complete, we're ready to move to **Phase 2: In-Memory Routing & HTTP Handling**:

- [ ] Implement ETS-based mount store
- [ ] Implement DB NOTIFY/LISTEN for cache synchronization
- [ ] Create Phoenix endpoint for `/proxies/*path`
- [ ] Implement routing algorithm with longest-prefix matching
- [ ] Add integration tests for routing behavior

## Files Changed/Created

### New Files:
- `lib/plugboard/paths/path.ex` - Path schema
- `lib/plugboard/paths.ex` - Paths context
- `test/plugboard/paths_test.exs` - Comprehensive test suite
- `priv/repo/migrations/20251031092344_create_paths_table.exs` - Migration

### Modified Files:
- `test/plugboard/accounts_test.exs` - Fixed unrelated test issue

## Performance Considerations

- **Indexes:** All key queries are covered by appropriate indexes
- **Recursive operations:** Use PostgreSQL CTEs for efficient bulk updates
- **Soft deletes:** WHERE clauses on `deleted_at IS NULL` use partial indexes
- **UUID format:** Binary format for space efficiency

## Conclusion

Phase 1 is complete and production-ready. The foundation is solid for building the routing layer in Phase 2. All acceptance criteria have been met:

✅ Path hierarchy with parent-child relationships  
✅ Full path automatic computation  
✅ Mount points are terminal (enforced by triggers)  
✅ Soft-delete with restoration  
✅ Comprehensive test coverage  
✅ All constraints enforced at database level  
