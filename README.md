# gmod-dimensions — Commands

All commands start with `dim_`. Superadmin-only commands are marked.

- dim_changedim <id>  [superadmin]
  - Change your dimension to <id>.
- dim_tp <target>  [superadmin]
  - Put target in your dimension and teleport them to you.
- dim_bubble [radius]  [superadmin]
  - Move you and players within radius (default 250) to a new dimension.
- dim_pair_newdim <target>  [superadmin]
  - Put you and target together in a new dimension and teleport them to you.
- dim_resync  [superadmin]
  - Rebuild visibility for all players.
- dim_menu  [superadmin]
  - Open the dimensions admin menu.

## API (for other addons)

Global table: `Dimensions`

- GetDimension(ent): number
- EntitiesShareDimension(a, b): boolean
- IsGlobal(ent): boolean
- SetDimension(ent, id): boolean
- SetGlobal(ent, bool): boolean
- Resync([target]): boolean
- AllocateNewDimension(): number
- PairInNewDimension(ply, target): number

Hook:
- `Dimensions_EntityDimensionChanged(ent, oldId, newId)`

### Examples

```lua
-- Get a player's current dimension
local id = Dimensions.GetDimension(ply)

-- Move a player to dimension 5
Dimensions.SetDimension(ply, 5)

-- Check if two entities can see/collide/interact
if Dimensions.EntitiesShareDimension(ply, ent) then
	-- allowed
end

-- Make an entity global across all dimensions
Dimensions.SetGlobal(ent, true)

-- Resync visibility for everyone (e.g., after batch changes)
Dimensions.Resync()

-- Resync a single player or entity
Dimensions.Resync(ply)
Dimensions.Resync(ent)

-- Allocate a fresh private dimension
local newId = Dimensions.AllocateNewDimension()

-- Pair two players into a new private dimension
local pairedId = Dimensions.PairInNewDimension(ply, other)

-- Listen for changes to react in your addon
hook.Add("Dimensions_EntityDimensionChanged", "MyAddon_OnDimChange", function(ent, oldId, newId)
	print("Dim changed:", ent, oldId, "->", newId)
end)
```
