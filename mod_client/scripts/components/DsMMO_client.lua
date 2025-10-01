local Recipe_display = require "recipe_display"

local DSMMO_ACTIONS = {
	["CHOP"] = {1, 0.6, 0, 1},
	["MINE"] = {1, 1, 0.0, 1},
	["ATTACK"] = {0.7, 0, 0, 1},
	["DIG"] = {0.5, 0.3, 0, 1},
	["PICK"] = {0, 1, 1, 1}
}
local ORDER = {
	"CHOP",
	"MINE",
	"ATTACK",
	"DIG",
	"PICK",
}


local LEVEL_MAX = 10

local SKILLS = {
	attack = {
		name="Explosive touch",
		tree="ATTACK",
		min_level=3,
		description="Every attack you deal, has a chance of doing extra damage (spear-damage)"
	},
	attacked = {
		name="Beetaliation",
		tree="ATTACK",
		min_level=5,
		description="Every time you are attacked, there is a chance that you spawn a bee, which will attack the source that attacked you"
	},
	hungry_attack = {
		name="Hungry fighter",
		tree="ATTACK",
		min_level=7,
		description="When you are hungry, your attack damage is multiplied by your eat-level"
	}
}

-- Show the required exp to lvl up
local function get_max_exp(self, action, lvl)
	--return lvl > 0 and DSMMO_ACTIONS[action] + math.ceil(DSMMO_ACTIONS[action] * math.pow(LEVEL_UP_RATE, lvl)) or DSMMO_ACTIONS[action]
	return self.min_exp[action] + math.ceil(self.min_exp[action] * math.pow(self.storage.level_up_rate, lvl))
end

-- Show the current lvl
local function get_level(self, action, xp)
	if xp < self.min_exp[action] then
		return 0
	else
		for lvl=1, LEVEL_MAX, 1 do
			if get_max_exp(self, action, lvl) > xp then
				return lvl
			end
		end
		return 10 --maybe I'm worng, idk
		--This would be way better for performance. But it leads to rounding errors:
		--return math.floor(math.log((xp-DSMMO_ACTIONS[action]) / DSMMO_ACTIONS[action]) / math.log(LEVEL_UP_RATE)) +1
	end
end

-- Gaining exp?
local function onExpCorrection(player, action)
	local self = player._parent.components.DsMMO_client
	local new_xp = self.storage.net_exp[action]:value()
	local current_xp = self.exp[action]
	
	if not player.components.DsMMO then
		local lvl = get_level(self, action, self.storage.net_exp[action]:value())
		
		self.storage.level[action] = lvl
		self.storage.max_exp[action] = get_max_exp(self, action, lvl)
	end
	
	self.exp[action] = new_xp
	if new_xp < current_xp then
		self:show_badge(action, false, true)
		self:createIndicator(new_xp - current_xp, self.colors[action])
	elseif new_xp > current_xp then
		self:show_badge(action)
	elseif player.bufferedaction and player.bufferedaction.action.id == action then
		--pending client action will be finished after and will count for the next level - so we just prepare for it:
		self.exp[action] = self.exp[action] -1
	end
end

-- setup min exp
local function onMinExp(player, action)
	local self = player._parent.components.DsMMO_client
	
	self.min_exp = {}
	for i,v in ipairs(self.storage.net_min_exp:value()) do
		if i < 6 then
			self.min_exp[ORDER[i]] = v
		end
	end
	
	self:init_communication()
end

local function onPerformaction(player, data)
	local self = player.components.DsMMO_client
	local action = player.bufferedaction or self.bufferedaction
	--local action = self.bufferedaction
	if action then
		local actionId = action.action.id
		self:get_experience(actionId)
		--self.bufferedaction = nil --to make sure it only counts for this actionwa
	end
end

local function onAttacked(player)
	local self = player.components.DsMMO_client
	self:get_experience("ATTACK")
end

local DsMMO_client = Class(function(self, player)
	self.player = player
	self.bufferedaction = nil
	self.ui_elements = {}
	self.colors = DSMMO_ACTIONS
	self.skills = SKILLS

	self._recipe_display = nil

	self:create_netListeners()
	TheNet:SendModRPCToServer("DsMMO", 1)
end)

function DsMMO_client:add_display(ui)
	self.ui_elements = ui
end

function DsMMO_client:create_index(array_in, array_out)
	for k,v in pairs(array_in) do
		if not v._duplicate then
			local action = v.tree
			local lvl = v.min_level
			
			if not array_out[action] then
				array_out[action] = {}
			end
			if not array_out[action][lvl] then
				array_out[action][lvl] = {}
			end
			
			v.key = k
			table.insert(array_out[action][lvl], v)
		end
	end
end

function DsMMO_client:create_netListeners()
	print("[DsMMO client] Enabled")
	local player = self.player
	--if TheWorld.ismastersim then
	if player.components.DsMMO then
		self.storage = player.components.DsMMO
	else
		local guid = player.player_classified.GUID
		self.storage = {}
		
		self.storage.net_level_up_rate = net_ushortint(guid, "DsMMO.level_up_rate", "DsMMO.level_up_rate")
		self.storage.net_min_exp = net_bytearray(guid, "DsMMO.min_exp", "DsMMO.min_exp")
		
		player.player_classified:ListenForEvent("DsMMO.level_up_rate", function(player)
			print("DsMMO.level_up_rate")
			player._parent.components.DsMMO_client.storage.level_up_rate = self.storage.net_level_up_rate:value()/10
			self:init_communication()
		end)
	end
	player.player_classified:ListenForEvent("DsMMO.min_exp", onMinExp)
end

function DsMMO_client:init_communication()
	if self.min_exp and self.storage.level_up_rate then --check if all data has arrived yet
		print("[DsMMO client] Init Communication")
		local player = self.player
		
		if player.components.DsMMO then
			self.exp = {}
			for k,v in pairs(DSMMO_ACTIONS) do
				self.exp[k] = 0
				player.player_classified:ListenForEvent("DsMMO.exp." ..k, function(player) onExpCorrection(player, k) end)
			end
		else
			local guid = player.player_classified.GUID
			self.storage.recipe = net_string(guid, "DsMMO.recipe", "DsMMO.recipe")
			
			self.storage.net_exp = {}
			self.storage.max_exp = {}
			self.storage.level = {}
			self.exp = {}
			
			for k,v in pairs(DSMMO_ACTIONS) do
				--we have to be prepared for the case that onExpCorrection is called after player does an action
				
				self.storage.level[k] = 0
				self.storage.max_exp[k] = self.min_exp[k]
				
				self.exp[k] = 0
				self.storage.net_exp[k] = net_uint(guid, "DsMMO.exp." ..k, "DsMMO.exp." ..k)
				self.storage.net_exp[k]:set_local(0)
				
				player.player_classified:ListenForEvent("DsMMO.exp." ..k, function(player) onExpCorrection(player, k) end)
			end
		end
		
		TheNet:SendModRPCToServer("DsMMO", 2)
		self:activate()
	end
end

function DsMMO_client:activate()
	print("[DsMMO - client] Creating index")
	self.skills_index = {}
	self:create_index(SKILLS, self.skills_index)
	
	
	print("[DsMMO - client] Placing event listeners")
	local player = self.player
	local old_ClearBufferedAction = player.ClearBufferedAction
	
	local dsmmo = self
	player.ClearBufferedAction = function(...)
		if dsmmo.bufferedaction then
			dsmmo.bufferedaction = nil
		end
		if player.bufferedaction then
			--player.components.DsMMO_client.bufferedaction = player.bufferedaction
			dsmmo.bufferedaction = player.bufferedaction
		end
		old_ClearBufferedAction(...)
	end
	
	player:ListenForEvent("performaction", onPerformaction)
	player:ListenForEvent("attacked", onAttacked)
	--player:ListenForEvent("startstarving", onStartStarving)
	--player:ListenForEvent("stopstarving", onStopStarving)
	
	
	print("[DsMMO - client] Building GUI")
	
	local levelBadge = require "widgets/levelbadge"
	self.ui_elements.badge = self.ui_elements.statusdisplays:AddChild(levelBadge("EAT_level_meter", self))
	self.ui_elements.badge:SetPosition(40, -100, 0)
	self.ui_elements.statusdisplays.moisturemeter:SetPosition(-40, -100, 0)
end

-- probably we can delete it
function DsMMO_client:get_chance(base_r, lvl)
	local chance = base_r * (lvl / LEVEL_MAX)
	
	return chance
end

function DsMMO_client:get_experience(action)
	local xp = self.exp[action]
	
	if self.storage.level[action] < LEVEL_MAX then
		local max_exp = self.storage.max_exp[action]
		
		self.exp[action] = xp+1
		self:createIndicator(max_exp - xp, DSMMO_ACTIONS[action])
	end
	self:show_badge(action)
end

function DsMMO_client:show_badge(action, noPulse, isNegative)
	local lvl = self.storage.level[action]
	
	if lvl < LEVEL_MAX then
	
		local max_exp_before = (lvl>0) and get_max_exp(self, action, lvl-1) or 0
		self.ui_elements.badge:update(
			action,
			self.exp[action] - max_exp_before,
			self.storage.max_exp[action] - max_exp_before,
			noPulse,
			isNegative
		)
	else
		self.ui_elements.badge:update(
			action,
			1,
			1,
			true
		)
	end
end

function DsMMO_client:createIndicator(msg, color)
	local player = self.player
	local label_font_size = 30
	
	local indicator = CreateEntity()
	indicator.persists = true
	indicator.entity:AddTransform()
	indicator.Transform:SetPosition(player.Transform:GetWorldPosition())

	local label = indicator.entity:AddLabel()
	if label ~= nil then
		label:SetFont(NUMBERFONT)
		label:SetFontSize(label_font_size)
		label:SetWorldOffset(0, 0, 0)
		label:SetColour(unpack(color))
		label:SetText(msg)
		label:Enable(true)
	end

	--indicator:MoveToFront()
	--indicator.entity:MoveToFront()
	indicator:StartThread(function()
		local label = indicator.Label
		local dx
		if math.random() < 0.5 then
			dx = -0.03
		else
			dx = 0.03
		end
		
		local y = 0
		local x = 0
		local dy = 0.1 - math.random()*0.1
		local ddy = 0.003


		local t = 1
		while indicator:IsValid() and t > 0 do
			t = t-0.02

			if dy > -0.2 then
				ddy = ddy *1.1
				dy = dy - ddy
			end
			x = x + dx
			y = y + dy

			label:SetWorldOffset(x, y, 10)
			label:SetFontSize(label_font_size - label_font_size * (1 - t))
			Sleep(0.02)
		end

		indicator:Remove()
	end)
end


return DsMMO_client