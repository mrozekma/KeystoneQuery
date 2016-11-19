local addon = LibStub("AceAddon-3.0"):NewAddon("KeystoneQuery", "AceBucket-3.0", "AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
local ldb = LibStub:GetLibrary("LibDataBroker-1.1")
local libCompress = LibStub:GetLibrary("LibCompress")

local debugMode = false

local MYTHIC_KEYSTONE_ID = 138019
local REFRESH_RATE = (debugMode and 1 or 15) * 60 -- seconds
local ICON = 'Interface\\Icons\\INV_Relics_Hourglass'
local ADDON_PREFIX = 'KeystoneQuery'
local LINK_COLORS = {'00ff00', 'ffff00', 'ff0000', 'a335ee'} -- Index is number of affixes on the keystone

-- http://www.wowhead.com/mythic-keystones-and-dungeons-guide#loot
local LOOT_ILVLS = {
   nil, -- LOOT_ILVLS[keystoneLevel * 2] is dungeon chest. LOOT_ILVLS[keystoneLevel * 2 + 1] is class hall chest

-- Dungeon Chest  Class Hall Chest  Keystone Level
        840,             nil,            -- 1
        845,             850,            -- 2
        845,             855,            -- 3
        850,             860,            -- 4
        850,             865,            -- 5
        855,             865,            -- 6
        855,             870,            -- 7
        860,             870,            -- 8
        860,             875,            -- 9
        865,             880,            -- 10
        870,             880,            -- 11
        870,             885,            -- 12
        870,             885,            -- 13
        870,             885,            -- 14
        870,             885,            -- 15
}

local ldbSource = LibStub("LibDataBroker-1.1"):NewDataObject("KeystoneQuery", {
	type = "data source",
	icon = ICON,
	label = "Keystone",
	title = "Keystone",
})

function addon:log(fmt, ...)
	if(debugMode) then
		printf("KeystoneQuery: " .. fmt, ...)
	end
end

--TODO Remember and share alt keystones
--TODO Switch timer updates to broadcast instead of request
--TODO Detect new keystone on dungeon finish
--TODO Keystone voting

function addon:getMyKeystone(bag)
	self:log("Scanning for player's keystone")
	-- GetItemInfo() returns generic info, not info about the player's particular keystone
	-- name, link, quality, iLevel, reqLevel, class, subclass, maxStack, equipSlot, texture, vendorPrice = GetItemInfo(MYTHIC_KEYSTONE_ID)
	
	-- The best way I could find was to scan the player's bags until a keystone is found, and then rip the info out of the item link
	-- The bag to scan is provided by the ITEM_PUSH event; otherwise we scan all of them
	local firstBag = bag or 0
	local lastBag = bag and bag + 1 or NUM_BAG_SLOTS
	for bag = firstBag, lastBag do
		for slot = 1, GetContainerNumSlots(bag) do
			if(GetContainerItemID(bag, slot) == MYTHIC_KEYSTONE_ID) then
				originalLink = GetContainerItemLink(bag, slot)
				self:log("Player's keystone: %s -- %s", originalLink, gsub(originalLink, '|', '!'))
				parts = { strsplit(':', originalLink) }
				
				--[[
				Thanks to http://wow.gamepedia.com/ItemString for the [Mythic Keystone] link format:
				1: color prefix
				2: itemID
				3: enchantID
				4: gemID1
				5: gemID2
				6: gemID3
				7: gemID4
				8: suffixID
				9: uniqueID
				10: playerLevel
				11: specID
				12: upgradeTypeID (maps to numAffixes)
				13: difficultyID
				14: numBonusIDs
				15..X: bonusID
				X..Y: upgradeID (dungeonID, keystoneLevel, affixIDs..., lootEligible)
				Y..: (numRelicIDs, relicIDs, ...)
				]]
				
				local upgradeTypeID = tonumber(parts[12])
				-- These don't seem right, but I don't have a pile of keystones to test with. Going to get the number of affixes from the level for now instead
				-- numAffixes = ({[4587520] = 0, [5111808] = 1, [6160384] = 2, [4063232] = 3})[upgradeTypeID]
				local dungeonID = tonumber(parts[15])
				local keystoneLevel = tonumber(parts[16])
				local numAffixes = ({0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 3, 3, 3})[keystoneLevel]
				local affixIDs = {}
				for i = 0, numAffixes - 1 do
					tinsert(affixIDs, tonumber(parts[17 + i]))
				end
				local lootEligible = (tonumber(parts[17 + numAffixes]) == 1)
				return dungeonID, keystoneLevel, affixIDs, lootEligible, upgradeTypeID
			end
		end
	end
end

function addon:renderKeystoneLink(dungeonID, keystoneLevel, affixIDs, lootEligible, upgradeTypeID)
	local dungeonName = C_ChallengeMode.GetMapInfo(dungeonID)
	local numAffixes = #affixIDs
	local linkColor = LINK_COLORS[numAffixes]
	if not lootEligible then
		linkColor = '999999'
	end
	-- v1 messages don't include the upgradeTypeID; just hardcode it for now (we were making bad links before, and will continue to do so for most levels)
	upgradeTypeID = upgradeTypeID or 45872520
	local link = format("|TInterface\\Icons\\Achievement_PVP_A_%02d:16|t |cff%s|Hitem:%d::::::::110:0:%d:::%d:%d:%s:%d:::|h[%s +%d]|r", keystoneLevel, linkColor, MYTHIC_KEYSTONE_ID, upgradeTypeID, dungeonID, keystoneLevel, table.concat(affixIDs, ':'), lootEligible and '1' or '0', dungeonName, keystoneLevel)
	if numAffixes > 0 then
		local affixNames = {}
		for i, id in pairs(affixIDs) do
			affixName, affixDesc = C_ChallengeMode.GetAffixInfo(id)
			tinsert(affixNames, strlower(affixName))
		end
		link = format("%s (%s)", link, table.concat(affixNames, '/'))
	end
	if lootEligible then
		link = format("%s (%d/%d)", link, LOOT_ILVLS[keystoneLevel * 2], LOOT_ILVLS[keystoneLevel * 2 + 1])
	else
		link = link .. " (depleted)"
	end
	return link
end

function addon:renderAffixes()
	-- I don't see a way to get the week's affix info from the API, so I just list the affixes on the known keystones
	local affixes = {}
	for _, keystone in pairs(self.keystones) do
		if keystone.hasKeystone then
			for i, affixID in pairs(keystone.affixIDs) do
				affixes[i] = affixID
			end
		end
	end
	
	local rtn = {}
	for i, affixID in pairs(affixes) do
		local name, desc = C_ChallengeMode.GetAffixInfo(affixID)
		rtn[i] = format("|cff%s%s|r - %s", LINK_COLORS[i], name, desc)
	end
	return rtn
end

function addon:getPlayerSection(seek)
	local party = GetHomePartyInfo()
	if party then
		local name = nameWithRealm(UnitName('player'))
		if name == seek then return 'party' end
		for _, name in pairs(party) do
			if nameWithRealm(name) == seek then return 'party' end
		end
	end
	
	--TODO Friends
	
	return 'guild'
end

--TODO Everything assumes the player is in a guild; handle when they're not
function addon:showKeystones(type, showNones)
	local sections = type and {type} or {'party', 'friend', 'guild'}
	for _, section in pairs(sections) do
		local labelShown = false
		for name, keystone in table.pairsByKeys(self.keystones) do
			if self:getPlayerSection(name) == section then
				if showNones or (keystone and keystone.hasKeystone) then
					if not labelShown then
						printf("|T%s:16|t %s keystones:", ICON, gsub(section, '^%l', string.upper))
						labelShown = true
					end
					if keystone == nil then
						printf("%s's keystone is unknown", playerLink(name))
					elseif not keystone.hasKeystone then
						printf("%s has no keystone", playerLink(name))
					else
						printf("%s has %s", playerLink(name), self:renderKeystoneLink(keystone.dungeonID, keystone.keystoneLevel, keystone.affixIDs, keystone.lootEligible, keystone.upgradeTypeID))
					end
				end
			end
		end
	end
end

function addon:networkEncode(data)
	return libCompress:GetAddonEncodeTable():Encode(libCompress:CompressHuffman(self:Serialize(data)))
end

function addon:networkDecode(data)
	local data = libCompress:GetAddonEncodeTable():Decode(data)
	local data, err = libCompress:Decompress(data)
	if not data then
		print("Keystone Query: Failed to decompress network data: " .. err)
		return
	end
	local success, data = self:Deserialize(data)
	if not success then
		print("Keystone Query: Failed to deserialize network data")
		return
	end
	return data
end

function addon:encodeMyKeystone()
	local dungeonID, keystoneLevel, affixIDs, lootEligible, upgradeTypeID = self:getMyKeystone()
	-- Ideally we would reconstruct the link on the other end without the need for upgradeTypeID, but I can't figure it out in all cases yet, I'm producing bad links for high-level keystones
	return self:networkEncode({dungeonID = dungeonID, keystoneLevel = keystoneLevel, affixIDs = affixIDs, lootEligible = lootEligible, upgradeTypeID = upgradeTypeID})
end

function addon:onAddonMsg(event, prefix, msg, channel, sender)
	if prefix ~= ADDON_PREFIX then return end
	
	-- Addon message format:
	-- v1: keystone1:dungeonID:keystoneLevel:affixID,affixID,affixID:lootEligible
	-- v2: keystone2:(Table serialized/compressed/encoded with Ace3)
	--   Table keys: dungeonID, keystoneLevel, affixIDs, lootEligible, upgradeTypeID

	-- A request for this user's keystone info
	
	if msg == 'keystone1?' then
		self:log('Received keystone v1 request from ' .. sender)
		local dungeonID, keystoneLevel, affixIDs, lootEligible, _ = self:getMyKeystone()
		SendAddonMessage(ADDON_PREFIX, format("keystone1:%d:%d:%s:%d", dungeonID or 0, keystoneLevel or 0, table.concat(affixIDs or {}, ','), lootEligible and 1 or 0), "WHISPER", sender)
		return
	end
	
	if msg == 'keystone2?' then
		self:log('Received keystone v2 request from ' .. sender)
		SendAddonMessage(ADDON_PREFIX, 'keystone2:' .. self:encodeMyKeystone(), "WHISPER", sender)
		return
	end

	-- Another user's keystone info (which we may or may not have asked for, but print either way)
	local prefix = 'keystone1:'
	if strsub(msg, 1, strlen(prefix)) == prefix then
		self:log('Received keystone v1 response from ' .. sender)
		local _, dungeonID, keystoneLevel, affixIDs, lootEligible = strsplit(':', msg)
		if tonumber(dungeonID) == 0 then
			self.keystones[sender] = {hasKeystone = false}
		else
			local affixIDs = { strsplit(',', affixIDs) }
			for k, v in pairs(affixIDs) do
				affixIDs[k] = tonumber(v)
			end
			self.keystones[sender] = {hasKeystone = true, dungeonID = tonumber(dungeonID), keystoneLevel = tonumber(keystoneLevel), affixIDs = affixIDs, lootEligible = (lootEligible == '1')}
		end
		return
	end

	prefix = 'keystone2:'
	if strsub(msg, 1, strlen(prefix)) == prefix then
		self:log('Received keystone v2 response from ' .. sender)
		local data = self:networkDecode(strsub(msg, strlen(prefix) + 1))
		self.keystones[sender] = data
		self.keystones[sender].hasKeystone = true
		return
	end

	if not self.showedOutOfDateMessage then
		self.showedOutOfDateMessage = true
		print('Keystone Query: Unrecognized message received from another user. Is this version out of date?')
	end
end

function addon:startTimer()
	if self.broadcastTimer ~= nil then
		self:CancelTimer(self.broadcastTimer)
	end
	self.broadcastTimer = self:ScheduleRepeatingTimer('refresh', REFRESH_RATE)
	-- In the future, broadcast updates instead of requesting them. While a bunch of people still have v1, don't, since they'll see printouts on every broadcast
	-- self:broadcast()
	self:refresh()
end

function addon:refresh()
	self:log("Refreshing keystone list")
	self.keystones = {}
	SendAddonMessage(ADDON_PREFIX, 'keystone1?', 'PARTY')
	SendAddonMessage(ADDON_PREFIX, 'keystone1?', 'GUILD')
	--TODO Send to friends
	
	if self:getMyKeystone() then
		ldbSource.text = ' ' .. self:renderKeystoneLink(self:getMyKeystone())
	else
		ldbSource.text = ' (none)'
	end
end

function myAddon:broadcast()
	SendAddonMessage(ADDON_PREFIX, 'keystone2:' .. self:encodeMyKeystone(), 'PARTY')
	SendAddonMessage(ADDON_PREFIX, 'keystone2:' .. self:encodeMyKeystone(), 'GUILD')
	--TODO Send to friends
end

function myAddon:OnInitialize()
	self.keystones = {}
	self.broadcastTimer = nil
	self.showedOutOfDateMessage = false
	
	self:RegisterEvent('CHAT_MSG_ADDON', 'onAddonMsg')
	self:RegisterBucketEvent({'GUILD_ROSTER_UPDATE', 'FRIENDLIST_UPDATE', 'PARTY_MEMBERS_CHANGED', 'PARTY_MEMBER_ENABLE', 'CHALLENGE_MODE_START', 'CHALLENGE_MODE_RESET', 'CHALLENGE_MODE_COMPLETED'}, 2, 'refresh')
	RegisterAddonMessagePrefix(ADDON_PREFIX)

	SLASH_KeystoneQuery1 = '/keystone?'
	SLASH_KeystoneQuery2 = '/key?'
	SlashCmdList['KeystoneQuery'] = function(cmd)
		-- Default looks up party if in one, else guild
		if cmd == '' then
			self:showKeystones(nil, false)
		elseif cmd == 'party' or cmd == 'p' then
			if UnitInParty('player') then
				self:showKeystones('party', true)
			else
				print("Not in a party")
			end
--		elseif cmd == 'friends' or cmd == 'f' then
		elseif cmd == 'guild' or cmd == 'g' or cmd == '' then
			self:showKeystones('guild', false)
		elseif cmd == 'affix' or cmd == 'affixes' then
			printf("|T%s:16|t Affixes:", ICON)
			for _, text in pairs(self:renderAffixes()) do
				print(text)
			end
		elseif cmd == 'dump' then
			print("KeystoneQuery table dump:")
			for name, keystone in table.pairsByKeys(self.keystones) do
				if not keystone.hasKeystone then
					printf("%s (%s) = no keystone", name, self:getPlayerSection(name))
				else
					printf("%s (%s) = %d, %d, %s, %s, %d (%s)", name, self:getPlayerSection(name), keystone.dungeonID, keystone.keystoneLevel, table.concat(keystone.affixIDs, '/'), keystone.lootEligible and 'true' or 'false', keystone.upgradeTypeID, self:renderKeystoneLink(keystone.dungeonID, keystone.keystoneLevel, keystone.affixIDs, keystone.lootEligible, keystone.upgradeTypeID))
				end
			end
		elseif cmd == 'debug off' then
			debugMode = false
			print("KeystoneQuery: debug mode disabled")
		elseif cmd == 'debug on' then
			debugMode = true
			print("KeystoneQuery: debug mode enabled")
		else
			--TODO
		end
	end
end

function addon:OnEnable()
	self:log("OnEnable")
	self:startTimer()
end

function addon:OnDisable()
	self:CancelTimer(self.broadcastTimer)
	self.broadcastTimer = nil
end

ldbSource.OnTooltipShow = function(tooltip)
	tooltip:SetText('Mythic Keystones', HIGHLIGHT_FONT_COLOR:GetRGB())
	
	local sections = {'party', 'friend', 'guild'}
	for _, section in pairs(sections) do
		local labelShown = false
		for name, keystone in table.pairsByKeys(addon.keystones) do
			if addon:getPlayerSection(name) == section then
				if keystone and keystone.hasKeystone then
					if not labelShown then
						tooltip:AddLine(' ')
						-- For some reason I cannot figure out, this results in red text in the tooltip
						-- tooltip:AddLine(gsub(section, '^%l', string.upper))
						tooltip:AddLine(string.upper(strsub(section, 1, 1)) .. strsub(section, 2))
						labelShown = true
					end
					tooltip:AddDoubleLine(addon:renderKeystoneLink(keystone.dungeonID, keystone.keystoneLevel, keystone.affixIDs, keystone.lootEligible, keystone.upgradeTypeID), playerLink(name))
				end
			end
		end
	end
	
	tooltip:AddLine(' ')
	
	for _, text in pairs(addon:renderAffixes()) do
		tooltip:AddLine(text, nil, nil, nil, true)
	end
end

-- Turns out SendChatMessage() won't take formatting :(
--[[
local originalSendChatMessage = SendChatMessage
function SendChatMessage(msg, ...)
	if msg == 'keystone' or msg == 'key' then
		msg = self:renderKeystoneLink(self:getMyKeystone())
	end
	return originalSendChatMessage(msg, ...)
end
]]
