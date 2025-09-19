---@diagnostic disable: undefined-global
-- Multi-Dimension System (Client)
-- Client HUD, decal clearing, and superadmin menu.

local CONFIG = {
	showHUD = true,
}

local DEBUG = istable(DimensionsConfig) and DimensionsConfig.Debug == true
local function dprint(...)
	if not DEBUG then return end
	MsgC(Color(120,180,255), "[Dimensions:CL] ") print(...)
end

net.Receive("dim_config_update", function()
	dprint("NET dim_config_update")
	local show = net.ReadBool()
	CONFIG.showHUD = show
end)

net.Receive("dim_clear_decals", function()
	dprint("NET dim_clear_decals")
	RunConsoleCommand("r_cleardecals")
end)

net.Receive("dim_stop_sound", function()
	dprint("NET dim_stop_sound")
	-- Stop playing sounds when switching dimension to avoid audio bleed
	RunConsoleCommand("stopsound")
end)

-- Fonts
surface.CreateFont("DimHUD.Title", { font = "Roboto", size = 22, weight = 600, antialias = true })
surface.CreateFont("DimHUD.Value", { font = "Roboto", size = 20, weight = 500, antialias = true })

-- Styled HUD panel (top-right)
hook.Add("HUDPaint", "Dim_HUD", function()
	dprint("HUDPaint")
	if not CONFIG.showHUD then return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local dim = ply:GetNWInt("DimensionID", 0)

	local pad = 10
	local w, h = 168, 50
	local x, y = ScrW() - w - 20, 20
	draw.RoundedBox(8, x, y, w, h, Color(12, 14, 18, 210))
	draw.SimpleText("Dimension", "DimHUD.Title", x + pad, y + 14, Color(220, 230, 240), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	draw.SimpleText(tostring(dim), "DimHUD.Value", x + pad, y + h - 14, Color(120, 200, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
end)

local function buildOverviewPanel()
	dprint("buildOverviewPanel")
	local frame = vgui.Create("DFrame")
	frame:SetSize(820, 520)
	frame:Center()
	frame:SetTitle("")
	frame:MakePopup()
	frame:DockPadding(16, 56, 16, 16)
	function frame:Paint(w, h)
		draw.RoundedBox(8, 0, 0, w, h, Color(10, 12, 16, 245))
		draw.SimpleText("Dimensions", "DimHUD.Title", 16, 24, Color(230, 235, 240), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	end

	local container = vgui.Create("DPanel", frame)
	container:Dock(FILL)
	container:DockPadding(0, 0, 0, 0)
	container.Paint = nil

	local list = vgui.Create("DListView", container)
	list:Dock(LEFT)
	list:SetWide(520)
	list:SetHeaderHeight(26)
	list:SetDataHeight(20)
	local colDim = list:AddColumn("Dimension"); colDim:SetFixedWidth(100)
	local colPlayers = list:AddColumn("Players"); colPlayers:SetFixedWidth(80)
	local colProps = list:AddColumn("Props"); colProps:SetFixedWidth(80)
	local colNPCs = list:AddColumn("NPCs"); colNPCs:SetFixedWidth(80)
	local colEnts = list:AddColumn("Entities"); colEnts:SetFixedWidth(90)
	local colNames = list:AddColumn("Player Names")
	function list:Paint(w, h)
		draw.RoundedBox(6, 0, 0, w, h, Color(16, 18, 22, 235))
	end

	-- Style headers: blue text for numeric columns, white for names
	local function styleHeader(col, isBlue)
		if not IsValid(col) or not IsValid(col.Header) then return end
		col.Header:SetTextColor(isBlue and Color(120, 190, 255) or Color(230, 235, 240))
		col.Header:SetFont("DimHUD.Title")
		col.Header.Paint = function(self, w, h)
			draw.RoundedBox(0, 0, 0, w, h, Color(20, 24, 30, 255))
		end
	end
	styleHeader(colDim, true)
	styleHeader(colPlayers, true)
	styleHeader(colProps, true)
	styleHeader(colNPCs, true)
	styleHeader(colEnts, true)
	styleHeader(colNames, false)
	-- Note: DListView doesn't expose GetHeaderSize consistently; omit zebra overlay for compatibility

	-- Actions panel
	local actions = vgui.Create("DPanel", container)
	actions:Dock(FILL)
	actions:DockMargin(12, 0, 0, 0)
	function actions:Paint(w, h)
		draw.RoundedBox(6, 0, 0, w, h, Color(16, 18, 22, 235))
	end

	local title = vgui.Create("DLabel", actions)
	title:Dock(TOP)
	title:DockMargin(8, 8, 8, 4)
	title:SetFont("DimHUD.Title")
	title:SetText("Player actions")
	title:SetTextColor(Color(230, 235, 240))

	local targetCombo = vgui.Create("DComboBox", actions)
	targetCombo:Dock(TOP)
	targetCombo:DockMargin(8, 4, 8, 8)
	targetCombo:SetTall(24)
	targetCombo:SetSortItems(false)
	targetCombo:SetValue("Select player or * (all)")

	local function populateTargets()
		targetCombo:Clear()
		targetCombo:AddChoice("* (all)", "*")
		for _, p in ipairs(player.GetAll()) do
			targetCombo:AddChoice(p:Nick(), tostring(p:UserID()))
		end
	end
	populateTargets()

	local dimEntry = vgui.Create("DTextEntry", actions)
	dimEntry:Dock(TOP)
	dimEntry:DockMargin(8, 0, 8, 8)
	dimEntry:SetTall(24)
	dimEntry:SetPlaceholderText("Dimension id (e.g. 1)")

	local function selectedTarget()
		local _, data = targetCombo:GetSelected()
		if not data then return nil end
		return tostring(data)
	end

	local btnSetDim = vgui.Create("DButton", actions)
	btnSetDim:Dock(TOP)
	btnSetDim:DockMargin(8, 0, 8, 6)
	btnSetDim:SetTall(28)
	btnSetDim:SetText("Set target(s) to dimension")
	btnSetDim:SetTextColor(Color(230, 235, 240))
	function btnSetDim:Paint(w, h) draw.RoundedBox(6, 0, 0, w, h, Color(36, 110, 190, 230)) end
	btnSetDim.DoClick = function()
		local t = selectedTarget()
		local id = tonumber(dimEntry:GetText() or "")
		if not t or not id then return end
		RunConsoleCommand("changedim", tostring(id), t)
		surface.PlaySound("buttons/button15.wav")
	end

	local btnPairNew = vgui.Create("DButton", actions)
	btnPairNew:Dock(TOP)
	btnPairNew:DockMargin(8, 0, 8, 6)
	btnPairNew:SetTall(28)
	btnPairNew:SetText("Pair with ME in NEW dimension")
	btnPairNew:SetTextColor(Color(230, 235, 240))
	function btnPairNew:Paint(w, h) draw.RoundedBox(6, 0, 0, w, h, Color(36, 110, 190, 230)) end
	btnPairNew.DoClick = function()
		local t = selectedTarget()
		if not t then return end
		RunConsoleCommand("dim_pair_newdim", t)
		surface.PlaySound("buttons/button15.wav")
	end

	local btnTP = vgui.Create("DButton", actions)
	btnTP:Dock(TOP)
	btnTP:DockMargin(8, 0, 8, 6)
	btnTP:SetTall(28)
	btnTP:SetText("Teleport target(s) to ME")
	btnTP:SetTextColor(Color(230, 235, 240))
	function btnTP:Paint(w, h) draw.RoundedBox(6, 0, 0, w, h, Color(36, 110, 190, 230)) end
	btnTP.DoClick = function()
		local t = selectedTarget()
		if not t then return end
		RunConsoleCommand("dim_tp", t)
		surface.PlaySound("buttons/button15.wav")
	end

	net.Receive("dim_overview_data", function()
		dprint("NET dim_overview_data")

		if not IsValid(list) then return end
		list:Clear()
		local count = net.ReadUInt(16)
		for i = 1, count do
			local dim = net.ReadInt(32)
			local numPlayers = net.ReadUInt(16)
			local numProps = net.ReadUInt(16)
			local numNPCs = net.ReadUInt(16)
			local numEnts = net.ReadUInt(16)
			local names = net.ReadString()
			local line = list:AddLine(dim, numPlayers, numProps, numNPCs, numEnts, names)
			if IsValid(line) and istable(line.Columns) then
				for i, lbl in ipairs(line.Columns) do
					if IsValid(lbl) and lbl.SetTextColor then
						if i <= 5 then
							lbl:SetTextColor(Color(120, 190, 255))
						else
							lbl:SetTextColor(Color(235, 240, 245))
						end
					end
				end
			end
		end
	end)

	net.Start("dim_overview_request")
	net.SendToServer()

	local refresh = vgui.Create("DButton", frame)
	refresh:Dock(BOTTOM)
	refresh:SetTall(32)
	refresh:SetText("Refresh")
	refresh:SetTextColor(Color(230, 235, 240))
	function refresh:Paint(w, h)
		draw.RoundedBox(6, 0, 0, w, h, Color(36, 110, 190, 230))
	end
	refresh.DoClick = function()
		if not net then return end
		net.Start("dim_overview_request")
		net.SendToServer()
	end
end

concommand.Add("dim_menu", function()
	dprint("CMD dim_menu")
	if not LocalPlayer():IsSuperAdmin() then return end
	buildOverviewPanel()
end, nil, "Open the Dimensions superadmin menu")

-- Note: Do not register client stubs for server commands.
-- Client-side concommand.Add with the same name will shadow server commands
-- and prevent them from running. We keep only dim_menu on client.

-- Context menu: Put you and him in a new dimension (superadmin only)
properties.Add("dim_pair_newdim", {
	MenuLabel = "Dimensions: Pair in New Dimension",
	Order = 999,
	MenuIcon = "icon16/world_add.png",

	Filter = function(self, ent, ply)
		return IsValid(ent) and ent:IsPlayer() and IsValid(ply) and ply:IsPlayer() and ply:IsSuperAdmin()
	end,

	Action = function(self, ent)
		if not (IsValid(ent) and ent:IsPlayer()) then return end
		runConsoleCommand = RunConsoleCommand
		runConsoleCommand("dim_pair_newdim", ent:UserID())
		surface.PlaySound("buttons/button15.wav")
	end,

	Receive = function(self, len, ply)
		-- server-side not needed
	end
})