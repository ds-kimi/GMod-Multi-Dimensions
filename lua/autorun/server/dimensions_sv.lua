---@diagnostic disable: undefined-global
-- Multi-Dimension System (Server)
-- Assigns each entity a DimensionID and ensures players only see/interact with entities in their dimension.

local DEFAULT_DIMENSION = 0

-- Forward declaration to allow references before its definition
local updateTransmitForEntity

-- Debug
local DEBUG = istable(DimensionsConfig) and DimensionsConfig.Debug == true
local function dprint(...)
	if not DEBUG then return end
	MsgC(Color(120,180,255), "[Dimensions:SV] ") print(...)
end

-- Networking
util.AddNetworkString("dim_clear_decals")
util.AddNetworkString("dim_overview_request")
util.AddNetworkString("dim_overview_data")
util.AddNetworkString("dim_config_update")
util.AddNetworkString("dim_stop_sound")

-- Server HUD config (from shared config)
local SERVER_SHOWHUD = true
if istable(DimensionsConfig) and DimensionsConfig.ShowHUD ~= nil then
	SERVER_SHOWHUD = DimensionsConfig.ShowHUD and true or false
end

local function sendHudConfig(ply)
	net.Start("dim_config_update")
	net.WriteBool(SERVER_SHOWHUD)
	if IsValid(ply) then net.Send(ply) else net.Broadcast() end
end

-- Ensure custom collision checks are enabled so ShouldCollide is respected
local function ensureCustomCollision(ent)
	if not IsValid(ent) then return end
	if ent.SetCustomCollisionCheck then
		ent:SetCustomCollisionCheck(true)
	end
	if ent.CollisionRulesChanged then
		ent:CollisionRulesChanged()
	end
end

-- Helper: Find a player from a string (name, SteamID, SteamID64) or userID
local function findPlayerByArg(s)
	dprint("findPlayerByArg", s)
	if not s or s == "" then return nil end
	-- Try by UserID number
	local uid = tonumber(s)
	if uid then
		for _, p in ipairs(player.GetAll()) do
			if p:UserID() == uid then return p end
		end
	end
	s = tostring(s)
	local sLower = string.lower(s)
	for _, p in ipairs(player.GetAll()) do
		if string.find(string.lower(p:Nick()), sLower, 1, true) then return p end
		if p:SteamID() == s or p:SteamID64() == s then return p end
	end
	return nil
end

-- Helper: apply action to target(s); supports '*' for all players
local function forEachTarget(targetArg, action)
	if targetArg == "*" then
		for _, p in ipairs(player.GetAll()) do
			if IsValid(p) then action(p) end
		end
		return true
	end
	local target = findPlayerByArg(targetArg)
	if not IsValid(target) then return false end
	action(target)
	return true
end

-- Autocomplete helpers
local function ac_Players(cmd, args)
	local out = {}
	for _, p in ipairs(player.GetAll()) do
		out[#out+1] = cmd .. " " .. p:Nick()
		out[#out+1] = cmd .. " " .. tostring(p:UserID())
		out[#out+1] = cmd .. " " .. p:SteamID()
	end
	out[#out+1] = cmd .. " *"
	return out
end

local function ac_Changedim(cmd, args)
	local out = {cmd .. " 0", cmd .. " 1", cmd .. " 2"}
	for _, p in ipairs(player.GetAll()) do
		out[#out+1] = cmd .. " 0 " .. p:Nick()
		out[#out+1] = cmd .. " 1 " .. p:Nick()
		out[#out+1] = cmd .. " 2 " .. p:Nick()
	end
	out[#out+1] = cmd .. " 0 *"
	out[#out+1] = cmd .. " 1 *"
	out[#out+1] = cmd .. " 2 *"
	return out
end

-- Helper: Safely get an entity's dimension (defaults to 0)
local function getEntityDimension(ent)
	dprint("getEntityDimension", ent)
	if not IsValid(ent) then return DEFAULT_DIMENSION end
	local id = ent.DimensionID
	if id == nil then return DEFAULT_DIMENSION end
	return id
end

-- Helper: Do two entities share the same dimension?
local function entitiesShareDimension(a, b)
	dprint("entitiesShareDimension", a, b)
	if not IsValid(a) or not IsValid(b) then return true end
	if a.DimensionGlobal or b.DimensionGlobal then return true end
	return getEntityDimension(a) == getEntityDimension(b)
end

-- Helper: Is `child` parented somewhere under `ancestor`?
local function isDescendantOf(child, ancestor)
	dprint("isDescendantOf", child, ancestor)
	if not IsValid(child) or not IsValid(ancestor) then return false end
	local guard = 0
	local current = child
	while IsValid(current) and guard < 64 do
		if current == ancestor then return true end
		current = current:GetParent()
		guard = guard + 1
	end
	return false
end

-- Helper: Propagate a dimension to an entity's immediate children (and optionally deeper)
local function propagateDimensionToChildren(root, id, deep)
	dprint("propagateDimensionToChildren", root, id, deep)
	if not IsValid(root) then return end
	for _, child in ipairs(root:GetChildren()) do
		if IsValid(child) then
			child.DimensionID = id
			ensureCustomCollision(child)
			updateTransmitForEntity(child)
			if deep then
				propagateDimensionToChildren(child, id, true)
			end
		end
	end
end

-- Helper: Propagate the global dimension flag to children
local function propagateGlobalToChildren(root, deep)
	dprint("propagateGlobalToChildren", root, deep)
	if not IsValid(root) then return end
	for _, child in ipairs(root:GetChildren()) do
		if IsValid(child) then
			child.DimensionGlobal = true
			ensureCustomCollision(child)
			updateTransmitForEntity(child)
			if deep then
				propagateGlobalToChildren(child, true)
			end
		end
	end
end

-- Helper: Propagate to constrained entities (wheels/parts)
local function propagateDimensionToConstrained(root, id)
	dprint("propagateDimensionToConstrained", root, id)
	if not IsValid(root) then return end
	if not constraint or not constraint.GetAllConstrainedEntities then return end
	local constrained = constraint.GetAllConstrainedEntities(root)
	if not constrained then return end
	for ent, _ in pairs(constrained) do
		if IsValid(ent) then
			ent.DimensionID = id
			ensureCustomCollision(ent)
			updateTransmitForEntity(ent)
			propagateDimensionToChildren(ent, id, true)
		end
	end
end

-- Mark any map-spawned entity (MapCreationID > 0) as global across all dimensions
local function markGlobalIfMapProp(ent)
	if not IsValid(ent) then return end
	if not ent.MapCreationID or ent:MapCreationID() <= 0 then return end
	-- Ignore worldspawn itself or players/NPCs
	if ent:IsPlayer() or ent:IsNPC() then return end
	ent.DimensionGlobal = true
	ensureCustomCollision(ent)
	updateTransmitForEntity(ent)
	propagateGlobalToChildren(ent, true)
	-- Also mark any constrained parts
	if constraint and constraint.GetAllConstrainedEntities then
		local constrained = constraint.GetAllConstrainedEntities(ent)
		if constrained then
			for cEnt, _ in pairs(constrained) do
				if IsValid(cEnt) then
					cEnt.DimensionGlobal = true
					ensureCustomCollision(cEnt)
					updateTransmitForEntity(cEnt)
				end
			end
		end
	end
end

-- Helper: ensure weapons eventually inherit their owner's dimension, even if owner is set later
local function ensureWeaponOwnerSync(wep, attempts)
	dprint("ensureWeaponOwnerSync", wep, attempts)
	if not IsValid(wep) then return end
	attempts = attempts or 0
	local owner = wep.GetOwner and wep:GetOwner() or nil
	if IsValid(owner) then
		wep.DimensionID = getEntityDimension(owner)
		updateTransmitForEntity(wep)
		propagateDimensionToChildren(wep, wep.DimensionID, true)
		return
	end
	if attempts < 12 then
		timer.Simple(0, function()
			ensureWeaponOwnerSync(wep, attempts + 1)
		end)
	end
end

-- Helper: projectiles that should mirror shooter dimension
local projectileClassSet = {
	prop_combine_ball = true,
	grenade_ar2 = true,
	rpg_missile = true,
	crossbow_bolt = true,
	npc_grenade_frag = true,
	npc_grenade_bugbait = true,
	manhack = true,
	-- Add more as needed
}

local function ensureProjectileOwnerSync(ent, attempts)
	dprint("ensureProjectileOwnerSync", ent, attempts)
	if not IsValid(ent) then return end
	attempts = attempts or 0
	local owner = ent.GetOwner and ent:GetOwner() or nil
	if not IsValid(owner) and ent.GetPhysicsAttacker then
		owner = ent:GetPhysicsAttacker()
	end
	if IsValid(owner) then
		ent.DimensionID = getEntityDimension(owner)
		updateTransmitForEntity(ent)
		propagateDimensionToChildren(ent, ent.DimensionID, true)
		return
	end
	if attempts < 15 then
		timer.Simple(0, function()
			ensureProjectileOwnerSync(ent, attempts + 1)
		end)
	end
end

-- Core: Update a single entity's transmit state toward a specific player
local function updateEntityTransmitToPlayer(ent, ply)
	dprint("updateEntityTransmitToPlayer", ent, ply)
	if not IsValid(ent) or not IsValid(ply) or not ply:IsPlayer() then return end
	-- Always allow a player to see self
	if ent == ply then
		ent:SetPreventTransmit(ply, false)
		return
	end
	-- Ensure a player always receives their own owned or parented entities (weapons, hands, viewmodel children)
	local owner = ent.GetOwner and ent:GetOwner() or nil
	if IsValid(owner) and owner == ply then
		ent:SetPreventTransmit(ply, false)
		return
	end
	if isDescendantOf(ent, ply) then
		ent:SetPreventTransmit(ply, false)
		return
	end
	local shouldHide = not entitiesShareDimension(ent, ply)
	dprint("\tSetPreventTransmit", ent, "->", ply, "hide=", shouldHide)
	ent:SetPreventTransmit(ply, shouldHide)
end

-- Core: Update transmit for all entities relative to one player
local function updateTransmitForPlayer(ply)
	dprint("updateTransmitForPlayer", ply)
	if not IsValid(ply) then return end
	for _, ent in ipairs(ents.GetAll()) do
		updateEntityTransmitToPlayer(ent, ply)
	end
end

-- Core: Update transmit for one entity relative to all players
function updateTransmitForEntity(ent)
	dprint("updateTransmitForEntity", ent)
	if not IsValid(ent) then return end
	for _, ply in ipairs(player.GetAll()) do
		updateEntityTransmitToPlayer(ent, ply)
	end
end

-- Extend Entity metatable with Get/SetDimension
local entityMeta = FindMetaTable("Entity")
if entityMeta then
	function entityMeta:GetDimension()
		dprint("Entity:GetDimension", self)
		return getEntityDimension(self)
	end

	function entityMeta:SetDimension(id)
		dprint("Entity:SetDimension", self, id)
		id = tonumber(id)
		if id == nil then id = DEFAULT_DIMENSION end
		local previous = self.DimensionID or DEFAULT_DIMENSION
		if previous == id then
			-- No change
			return
		end
		self.DimensionID = id
		ensureCustomCollision(self)

		-- Replicate to client for HUD when this is a player
		if self:IsPlayer() then
			self:SetNWInt("DimensionID", id)
			-- Clear decals clientside when switching dimension
			net.Start("dim_clear_decals")
			net.Send(self)
			-- Stop sounds on dimension change to avoid audio bleed
			net.Start("dim_stop_sound")
			net.Send(self)
		end

		-- Update visibility relationships
		if self:IsPlayer() then
			-- Propagate dimension to owned weapons so they stay visible/interactive
			for _, wep in ipairs(self:GetWeapons()) do
				if IsValid(wep) then
					wep.DimensionID = id
					ensureCustomCollision(wep)
					updateTransmitForEntity(wep)
				end
			end
			-- Also propagate to children (hands, viewmodel-attached entities)
			propagateDimensionToChildren(self, id, true)
			-- If the player is in a vehicle, sync the vehicle and its parts
			if self:InVehicle() then
				local veh = self:GetVehicle()
				if IsValid(veh) then
					veh.DimensionID = id
					ensureCustomCollision(veh)
					updateTransmitForEntity(veh)
					propagateDimensionToChildren(veh, id, true)
					propagateDimensionToConstrained(veh, id)
				end
			end
			updateTransmitForPlayer(self)
		end
		updateTransmitForEntity(self)

		-- Notify player of change (optional)
		if self:IsPlayer() then
			self:ChatPrint("Dimension changed to " .. tostring(id))
		end

		-- Fire a global hook for other addons
		hook.Run("Dimensions_EntityDimensionChanged", self, previous, id)
	end
end

-- Initialize default dimensions for new entities
hook.Add("OnEntityCreated", "Dim_InitEntityDimension", function(ent)
	if not IsValid(ent) then return end
	-- Delay to ensure the entity is fully initialized
	timer.Simple(0, function()
		if not IsValid(ent) then return end
		if ent.DimensionID == nil then
			ent.DimensionID = DEFAULT_DIMENSION
		end
		ensureCustomCollision(ent)
		-- Mark map props as global
		markGlobalIfMapProp(ent)
		-- If this entity has a valid owner (player or entity), inherit owner's dimension
		local owner = ent.GetOwner and ent:GetOwner() or nil
		if IsValid(owner) then
			ent.DimensionID = getEntityDimension(owner)
		end
		-- For weapons where owner may be assigned later, retry syncing a few times
		if ent:IsWeapon() then
			ensureWeaponOwnerSync(ent, 0)
		end
		-- For known projectile classes, ensure owner sync (handles ricochet/collisions across dimensions)
		local cls = ent:GetClass()
		if projectileClassSet[cls] then
			ensureProjectileOwnerSync(ent, 0)
		end
		-- For vehicles that spawn with separate wheels/constraints after a few ticks, resync a few times
		if ent:IsVehicle() then
			local retries = 0
			local function resyncVeh()
				if not IsValid(ent) then return end
				propagateDimensionToChildren(ent, getEntityDimension(ent), true)
				propagateDimensionToConstrained(ent, getEntityDimension(ent))
				ensureCustomCollision(ent)
				retries = retries + 1
				if retries < 8 then
					timer.Simple(0, resyncVeh)
				end
			end
			timer.Simple(0, resyncVeh)
		end
		-- Ensure correct initial visibility relative to all players
		updateTransmitForEntity(ent)
	end)
end)

-- Initialize players on join
hook.Add("PlayerInitialSpawn", "Dim_PlayerInitialSpawn", function(ply)
	if not IsValid(ply) then return end
	ply.DimensionID = DEFAULT_DIMENSION
	ensureCustomCollision(ply)
	ply:SetNWInt("DimensionID", ply.DimensionID)
	sendHudConfig(ply)
	-- Sync weapons to player's dimension
	for _, wep in ipairs(ply:GetWeapons()) do
		if IsValid(wep) then
			wep.DimensionID = ply.DimensionID
			ensureCustomCollision(wep)
			updateTransmitForEntity(wep)
		end
	end
	-- Sync children to player's dimension (hands etc.)
	propagateDimensionToChildren(ply, ply.DimensionID, true)
	-- Ensure visibility both ways
	updateTransmitForPlayer(ply)
	updateTransmitForEntity(ply)
end)

-- On spawn, re-run visibility sync so returning to a dimension shows its occupants
hook.Add("PlayerSpawn", "Dim_PlayerSpawnResync", function(ply)
	if not IsValid(ply) then return end
	ensureCustomCollision(ply)
	-- Re-apply transmit states relative to this player
	updateTransmitForPlayer(ply)
	-- And ensure other entities also update relative to this player
	for _, ent in ipairs(ents.GetAll()) do
		updateEntityTransmitToPlayer(ent, ply)
	end
	-- Ensure hands/viewmodel children match player's dimension
	propagateDimensionToChildren(ply, getEntityDimension(ply), true)
end)

-- Vehicles: sync vehicle dimension to driver on enter; update on passenger enter as well
hook.Add("PlayerEnteredVehicle", "Dim_PlayerEnteredVehicle", function(ply, veh, role)
	if not IsValid(ply) or not IsValid(veh) then return end
	local id = getEntityDimension(ply)
	veh.DimensionID = id
	ensureCustomCollision(veh)
	updateTransmitForEntity(veh)
	propagateDimensionToChildren(veh, id, true)
	propagateDimensionToConstrained(veh, id)
end)

hook.Add("CanPlayerEnterVehicle", "Dim_BlockCrossDimVehicleEnter", function(ply, veh, role)
	if not IsValid(ply) or not IsValid(veh) then return end
	if not entitiesShareDimension(ply, veh) then return false end
end)

hook.Add("CanDrive", "Dim_BlockCanDrive", function(ply, ent)
	if not IsValid(ply) or not IsValid(ent) then return end
	if not entitiesShareDimension(ply, ent) then return false end
end)

-- After loadout, make sure all given weapons match the player's dimension
hook.Add("PlayerLoadout", "Dim_PlayerLoadoutSync", function(ply)
	if not IsValid(ply) then return end
	local id = getEntityDimension(ply)
	for _, wep in ipairs(ply:GetWeapons()) do
		if IsValid(wep) then
			wep.DimensionID = id
			updateTransmitForEntity(wep)
			propagateDimensionToChildren(wep, id, true)
		end
	end
	-- Also ensure the active weapon is visible to the player
	local active = ply:GetActiveWeapon()
	if IsValid(active) then
		updateEntityTransmitToPlayer(active, ply)
	end
end)

-- When switching weapons, keep dimensions synced and force transmit for the owner
hook.Add("PlayerSwitchWeapon", "Dim_SwitchWeaponSync", function(ply, oldWep, newWep)
	if IsValid(newWep) then
		newWep.DimensionID = getEntityDimension(ply)
		updateTransmitForEntity(newWep)
		propagateDimensionToChildren(newWep, newWep.DimensionID, true)
		updateEntityTransmitToPlayer(newWep, ply)
	end
	if IsValid(oldWep) then
		updateTransmitForEntity(oldWep)
		updateEntityTransmitToPlayer(oldWep, ply)
	end
end)

-- When a weapon is equipped, inherit owner's dimension and update visibility
hook.Add("WeaponEquip", "Dim_WeaponEquip", function(wep, owner)
	if not IsValid(wep) then return end
	local ply = owner
	if not IsValid(ply) then
		ply = wep:GetOwner()
	end
	if IsValid(ply) then
		wep.DimensionID = getEntityDimension(ply)
		updateTransmitForEntity(wep)
		-- Update any children of the weapon as well
		propagateDimensionToChildren(wep, wep.DimensionID, true)
	end
end)

-- Enforce interaction limits: only allow using entities in same dimension
hook.Add("PlayerUse", "Dim_PlayerUseLimit", function(ply, ent)
	if not IsValid(ply) or not IsValid(ent) then return end
	local same = entitiesShareDimension(ply, ent)
	dprint("PlayerUse decision", ply, ent, "same=", same)
	if not same then return false end
	-- else fall through (allow default)
end)

-- Block toolgun across dimensions
hook.Add("CanTool", "Dim_CanTool", function(ply, tr, tool)
	if not IsValid(ply) then return end
	local ent = IsValid(tr) and tr.Entity or nil
	local same = not IsValid(ent) or entitiesShareDimension(ply, ent)
	dprint("CanTool decision", ply, ent, tool, "same=", same)
	if not same then return false end
end)

-- Block physgun across dimensions
hook.Add("PhysgunPickup", "Dim_PhysgunPickup", function(ply, ent)
	if not IsValid(ply) or not IsValid(ent) then return end
	local same = entitiesShareDimension(ply, ent)
	dprint("PhysgunPickup decision", ply, ent, "same=", same)
	if not same then return false end
end)

-- Block gravgun pickup across dimensions
hook.Add("GravGunPickupAllowed", "Dim_GravgunPickup", function(ply, ent)
	if not IsValid(ply) or not IsValid(ent) then return end
	local same = entitiesShareDimension(ply, ent)
	dprint("GravGunPickupAllowed decision", ply, ent, "same=", same)
	if not same then return false end
end)

-- Block damage across dimensions
hook.Add("EntityTakeDamage", "Dim_BlockCrossDimDamage", function(target, dmginfo)
    if not (istable(DimensionsConfig) and DimensionsConfig.DamageFilter) then return end
	if not IsValid(target) or not dmginfo then return end
	local attacker = dmginfo:GetAttacker()
	local inflictor = dmginfo:GetInflictor()
	dprint("EntityTakeDamage pre", "target=", target, "attacker=", attacker, "inflictor=", inflictor, "dmg=", dmginfo:GetDamage())

	-- Resolve attacker to controlling player/entity
	if IsValid(inflictor) and inflictor ~= attacker then
		local io = inflictor.GetOwner and inflictor:GetOwner() or nil
		if IsValid(io) then attacker = io end
	end
	if IsValid(attacker) and attacker:IsWeapon() then
		local ow = attacker:GetOwner()
		if IsValid(ow) then attacker = ow end
	end
	if (not IsValid(attacker)) and IsValid(target) and target.GetPhysicsAttacker then
		local pa = target:GetPhysicsAttacker()
		if IsValid(pa) then attacker = pa end
	end

	-- If either is global, allow
	if target.DimensionGlobal or (IsValid(attacker) and attacker.DimensionGlobal) then
		dprint("EntityTakeDamage allow: global")
		return
	end

	-- If attacker invalid, allow
	if not IsValid(attacker) then
		dprint("EntityTakeDamage allow: no attacker")
		return
	end

	-- Allow same-dimension damage explicitly
	local tdim = getEntityDimension(target)
	local adim = getEntityDimension(attacker)
	if tdim == adim then
		dprint("EntityTakeDamage allow: same dim", tdim)
		return
	end

	-- Different dimensions: block
	dprint("EntityTakeDamage block: cross dim", tdim, adim)
	return true
end)

-- Player damage fast-path: allow same-dimension damage, block cross-dimension
hook.Add("PlayerShouldTakeDamage", "Dim_PlayerDamage", function(ply, attacker)
	if not IsValid(ply) then return end
	if not IsValid(attacker) then dprint("PlayerShouldTakeDamage allow: no attacker"); return true end
	-- Resolve to owner if attacker is a weapon/entity with owner
	local ow = attacker.GetOwner and attacker:GetOwner() or nil
	if IsValid(ow) then attacker = ow end
	if attacker == ply then dprint("PlayerShouldTakeDamage allow: self"); return true end
	local same = entitiesShareDimension(ply, attacker)
	dprint("PlayerShouldTakeDamage decision", ply, attacker, "same=", same)
	return same
end)

	-- Prevent hitscan bullets from imparting force across dimensions
hook.Add("EntityFireBullets", "Dim_FilterBullets", function(shooter, data)
    if not (istable(DimensionsConfig) and DimensionsConfig.BulletFilter) then return end
    if not IsValid(shooter) then return end
    -- Resolve source to player/NPC owner if available (weapons set shooter to weapon)
    local src = shooter
    if shooter.GetOwner then
        local ow = shooter:GetOwner()
        if IsValid(ow) then src = ow end
    end
    local original = data.Callback
    data.Callback = function(attacker, tr, dmginfo)
        local hit = tr and tr.Entity or nil
        if IsValid(hit) then
            local same = entitiesShareDimension(src, hit)
            if not same then
                if dmginfo then
                    dmginfo:SetDamage(0)
                    dmginfo:SetDamageForce(Vector(0, 0, 0))
                    dmginfo:SetDamagePosition(tr.HitPos or (IsValid(attacker) and attacker:GetPos()) or vector_origin)
                end
                dprint("EntityFireBullets suppress", src, "->", hit)
                return true
            end
        end
        if original then
            return original(attacker, tr, dmginfo)
        end
    end
    return false
end)

-- Hide effects and sounds across dimensions by tagging effects with owner/shooter dim
hook.Add("OnEntityCreated", "Dim_TagEffectsDimension", function(ent)
	if not IsValid(ent) then return end
	-- Some effects/entities for explosions or particles are clientside-only; for serverside FX entities, tag dimension
	timer.Simple(0, function()
		if not IsValid(ent) then return end
		-- Inherit from owner if present
		local owner = ent.GetOwner and ent:GetOwner() or nil
		if IsValid(owner) then
			ent.DimensionID = getEntityDimension(owner)
			updateTransmitForEntity(ent)
		end
	end)
end)

-- Enforce collision limits: only collide within the same dimension
hook.Add("ShouldCollide", "Dim_ShouldCollide", function(ent1, ent2)
	if not IsValid(ent1) or not IsValid(ent2) then return end
	local d1 = getEntityDimension(ent1)
	local d2 = getEntityDimension(ent2)
	local same = d1 == d2
	dprint("ShouldCollide decision", ent1, ent2, "same=", same)
	if not same then return false end
	-- else fall through to default behavior
end)

-- Console command: changedim <id>
concommand.Add("changedim", function(ply, cmd, args, argStr)
		local callerIsPlayer = IsValid(ply) and ply:IsPlayer()
		local idArg = args and args[1]
		local targetArg = args and args[2]
		local id = tonumber(idArg)
		if id == nil then
			if callerIsPlayer then
				ply:ChatPrint("Usage: changedim <id> [target]")
			else
				print("[Dimensions] Usage: changedim <id> [target]")
			end
			return
		end

		-- Determine target(s): default self if player; allow specifying others only if superadmin or server console
		if targetArg and targetArg ~= "" then
			if callerIsPlayer and not ply:IsSuperAdmin() then
				ply:ChatPrint("You must be superadmin to change another player's dimension.")
				return
			end
			local ok = forEachTarget(targetArg, function(t)
				if IsValid(t) and t:IsPlayer() then t:SetDimension(id) end
			end)
			if not ok then
				if callerIsPlayer then ply:ChatPrint("Target player not found.") else print("[Dimensions] Target player not found.") end
				return
			end
			if callerIsPlayer then ply:ChatPrint("Set dimension of target(s) to " .. tostring(id)) end
		else
			if callerIsPlayer then
				if not IsValid(ply) or not ply:IsPlayer() then return end
				if not ply:IsSuperAdmin() then
					ply:ChatPrint("Superadmin only.")
					return
				end
				ply:SetDimension(id)
			else
				print("[Dimensions] Server console must specify a target: changedim <id> <target>")
				return
			end
		end
end, ac_Changedim, "Change your dimension, or (superadmin) another player's. Usage: changedim <id> [target]")

-- Aliases so 'dim_' prefix shows up in console suggestions
concommand.Add("dim_change", function(ply, cmd, args, argStr)
	-- Forward to changedim
	concommand.Run(ply, "changedim", args or {})
end, ac_Changedim, "Alias of changedim: dim_change <id> [target]")

concommand.Add("dim_changedim", function(ply, cmd, args, argStr)
	concommand.Run(ply, "changedim", args or {})
end, ac_Changedim, "Alias of changedim: dim_changedim <id> [target]")

-- Dimension allocation helper
local NEXT_DIM_ID = 1
local function allocateNewDimension()
	-- Ensure NEXT_DIM_ID is greater than any current player dimension
	for _, p in ipairs(player.GetAll()) do
		local id = getEntityDimension(p)
		if id >= NEXT_DIM_ID then
			NEXT_DIM_ID = id + 1
		end
	end
	local newId = NEXT_DIM_ID
	NEXT_DIM_ID = NEXT_DIM_ID + 1
	return newId
end

-- Bind allocator into public API now that it's defined
-- API module
_G.Dimensions = _G.Dimensions or {}
local API = _G.Dimensions
API.Version = 1

-- Basic queries
function API.GetDimension(ent)
	return getEntityDimension(ent)
end

function API.EntitiesShareDimension(a, b)
	return entitiesShareDimension(a, b)
end

function API.IsGlobal(ent)
	return IsValid(ent) and ent.DimensionGlobal == true
end

-- Mutations
function API.SetDimension(ent, id)
	if not IsValid(ent) then return false end
	if ent.SetDimension then ent:SetDimension(id); return true end
	ent.DimensionID = tonumber(id) or ent.DimensionID or 0
	ensureCustomCollision(ent)
	updateTransmitForEntity(ent)
	return true
end

function API.SetGlobal(ent, makeGlobal)
	if not IsValid(ent) then return false end
	if makeGlobal then
		ent.DimensionGlobal = true
		propagateGlobalToChildren(ent, true)
	else
		ent.DimensionGlobal = nil
	end
	ensureCustomCollision(ent)
	updateTransmitForEntity(ent)
	return true
end

-- Visibility resync
function API.Resync(target)
	if IsValid(target) and target:IsPlayer() then
		updateTransmitForPlayer(target)
		return true
	end
	if IsValid(target) then
		updateTransmitForEntity(target)
		return true
	end
	for _, p in ipairs(player.GetAll()) do updateTransmitForPlayer(p) end
	return true
end

-- Allocation helpers will be bound after allocator is defined
function API.AllocateNewDimension()
	-- Placeholder; will be replaced after allocator definition
	return 0
end

function API.PairInNewDimension(ply, target)
	local newId = (API.AllocateNewDimension and API.AllocateNewDimension()) or 0
	if IsValid(ply) then ply:SetDimension(newId) end
	if IsValid(target) then target:SetDimension(newId) end
	return newId
end

-- dim_tp <target>: Put someone in your dimension and teleport them to you (superadmin only)
concommand.Add("dim_tp", function(ply, cmd, args)
		if not IsValid(ply) or not ply:IsPlayer() then return end
		if not ply:IsSuperAdmin() then ply:ChatPrint("Superadmin only.") return end
		local arg = args and args[1]
		if not arg or arg == "" then ply:ChatPrint("Usage: dim_tp <target>") return end
		local count = 0
		forEachTarget(arg, function(target)
			if not IsValid(target) then return end
			local plyDim = getEntityDimension(ply)
			target:SetDimension(plyDim)
			local dest = IsValid(ply) and (ply:GetPos() + ply:GetForward() * 40) or target:GetPos()
			if IsValid(target) and target.InVehicle and target:InVehicle() then target:ExitVehicle() end
			target:SetPos(dest)
			target:SetEyeAngles(IsValid(ply) and ply:EyeAngles() or target:EyeAngles())
			count = count + 1
		end)
		ply:ChatPrint("Teleported " .. tostring(count) .. " target(s) to you and set dimension.")
end, function(cmd, args) return ac_Players(cmd, args) end, "Bring target(s) to your position and dimension. Usage: dim_tp <target|*>")

-- dim_bubble [radius]: Move you and nearby players into a new dimension (superadmin only)
concommand.Add("dim_bubble", function(ply, cmd, args)
		if not IsValid(ply) or not ply:IsPlayer() then return end
		if not ply:IsSuperAdmin() then ply:ChatPrint("Superadmin only.") return end
		local radius = tonumber(args and args[1]) or 250
		local rSqr = radius * radius
		local newId = allocateNewDimension()
		local origin = ply:GetPos()
		for _, p in ipairs(player.GetAll()) do
			if IsValid(p) then
				local pos = p:GetPos()
				if pos and origin and pos:DistToSqr(origin) <= rSqr then
					p:SetDimension(newId)
				end
			end
		end
		ply:ChatPrint("Moved you and nearby players (" .. tostring(radius) .. "u) to dimension " .. tostring(newId))
end, function(cmd, args)
		local out = {cmd .. " 200", cmd .. " 300", cmd .. " 500"}
		return out
end, "Move you and nearby players to a new dimension. Usage: dim_bubble [radius]")

-- dim_pair_newdim <target>: Put you and target into a new dimension (superadmin only)
concommand.Add("dim_pair_newdim", function(ply, cmd, args)
	if not IsValid(ply) or not ply:IsPlayer() then return end
	if not ply:IsSuperAdmin() then ply:ChatPrint("Superadmin only.") return end
	local arg = args and args[1]
	if not arg or arg == "" then ply:ChatPrint("Usage: dim_pair_newdim <target>") return end
	local newId = allocateNewDimension()
	local count = 0
	if IsValid(ply) then ply:SetDimension(newId) count = count + 1 end
	forEachTarget(arg, function(target)
		if IsValid(target) then
			target:SetDimension(newId)
			count = count + 1
			-- Teleport target to caller
			local dest = ply:GetPos() + ply:GetForward() * 40
			if target:InVehicle() then target:ExitVehicle() end
			target:SetPos(dest)
			target:SetEyeAngles(ply:EyeAngles())
		end
	end)
	ply:ChatPrint("Moved " .. tostring(count) .. " player(s) to new dimension " .. tostring(newId) .. " and teleported them to you")
end, function(cmd, args) return ac_Players(cmd, args) end, "Put you and target(s) in a new dimension. Usage: dim_pair_newdim <target|*>")

-- Chat command support for dim_ commands
hook.Add("PlayerSay", "Dim_ChatCommands", function(ply, text)
	if not IsValid(ply) or not ply:IsPlayer() then return end
	text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then return end
	local parts = {}
	for token in string.gmatch(text, "[^%s]+") do parts[#parts + 1] = token end
	local cmd = string.lower(parts[1] or "")
	local args = {}
	for i = 2, #parts do args[#args + 1] = parts[i] end

	local function run(cmdName, ...)
		concommand.Run(ply, cmdName, { ... })
		return ""
	end

	if cmd == "!dim_change" and args[1] then
		return run("changedim", args[1])
	end
	if not ply:IsSuperAdmin() then return end
	if cmd == "!dim_tp" and args[1] then
		return run("dim_tp", args[1])
	end
	if cmd == "!dim_bubble" then
		return run("dim_bubble", args[1] or "250")
	end
	if cmd == "!dim_pair_newdim" and args[1] then
		return run("dim_pair_newdim", args[1])
	end
end)

-- Superadmin overview data provider
net.Receive("dim_overview_request", function(len, ply)
	if not IsValid(ply) or not ply:IsSuperAdmin() then return end
	-- Gather per-dimension stats
	local byDim = {}
	for _, p in ipairs(player.GetAll()) do
		local id = getEntityDimension(p)
		local bucket = byDim[id]
		if not bucket then bucket = { players = {}, props = 0, npcs = 0, ents = 0 } byDim[id] = bucket end
		bucket.players[#bucket.players + 1] = p:Nick()
	end
	for _, e in ipairs(ents.GetAll()) do
		local id = getEntityDimension(e)
		local bucket = byDim[id]
		if not bucket then bucket = { players = {}, props = 0, npcs = 0, ents = 0 } byDim[id] = bucket end
		if e:IsPlayer() then
			-- already counted above
		else
			bucket.ents = bucket.ents + 1
			if e:GetClass() == "prop_physics" or e:GetClass() == "prop_physics_multiplayer" then
				bucket.props = bucket.props + 1
			end
			if e:IsNPC() then
				bucket.npcs = bucket.npcs + 1
			end
		end
	end
	-- Send compacted data
	local keys = {}
	for id, _ in pairs(byDim) do keys[#keys + 1] = id end
	table.sort(keys, function(a,b) return a < b end)
	net.Start("dim_overview_data")
	net.WriteUInt(#keys, 16)
	for _, id in ipairs(keys) do
		local b = byDim[id]
		net.WriteInt(id, 32)
		net.WriteUInt(#b.players, 16)
		net.WriteUInt(b.props, 16)
		net.WriteUInt(b.npcs, 16)
		net.WriteUInt(b.ents, 16)
		net.WriteString(table.concat(b.players, ", "))
	end
	net.Send(ply)
end)

-- Manual resync command to rebuild visibility (useful if something got out of sync)
concommand.Add("dim_resync", function(ply)
	if IsValid(ply) and ply:IsPlayer() and not ply:IsSuperAdmin() then
		ply:ChatPrint("Superadmin only.")
		return
	end
	local function resyncPlayer(p)
		if not IsValid(p) then return end
		updateTransmitForPlayer(p)
		updateTransmitForEntity(p)
	end
	dprint("CMD dim_resync run", ply)
	-- Server console or superadmin: resync all players
	for _, p in ipairs(player.GetAll()) do
		resyncPlayer(p)
	end
	if IsValid(ply) and ply:IsPlayer() then
		ply:ChatPrint("Dimension visibility resynced for all players.")
	else
		print("[Dimensions] Resynced visibility for all players.")
	end
end, nil, "Resync dimension visibility. Superadmins affect all; others affect self.")

-- Ensure spawned entities inherit the spawning player's dimension
local function setSpawnedEntityDimension(ply, ent)
	if not IsValid(ply) or not IsValid(ent) then return end
	local id = getEntityDimension(ply)
	ent.DimensionID = id
	updateTransmitForEntity(ent)
	propagateDimensionToChildren(ent, id, true)
end

hook.Add("PlayerSpawnedProp", "Dim_SpawnProp", function(ply, model, ent)
	setSpawnedEntityDimension(ply, ent)
end)

hook.Add("PlayerSpawnedRagdoll", "Dim_SpawnRagdoll", function(ply, model, ent)
	setSpawnedEntityDimension(ply, ent)
end)

hook.Add("PlayerSpawnedSENT", "Dim_SpawnSENT", function(ply, ent)
	setSpawnedEntityDimension(ply, ent)
end)

hook.Add("PlayerSpawnedEffect", "Dim_SpawnEffect", function(ply, model, ent)
	setSpawnedEntityDimension(ply, ent)
end)

hook.Add("PlayerSpawnedNPC", "Dim_SpawnNPC", function(ply, ent)
	setSpawnedEntityDimension(ply, ent)
end)

hook.Add("PlayerSpawnedVehicle", "Dim_SpawnVehicle", function(ply, ent)
	setSpawnedEntityDimension(ply, ent)
end)
