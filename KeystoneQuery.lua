local addon = LibStub("AceAddon-3.0"):NewAddon("KeystoneQuery", "AceBucket-3.0", "AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
local ldb = LibStub:GetLibrary("LibDataBroker-1.1")
local libCompress = LibStub:GetLibrary("LibCompress")

local debugMode = false

local MYTHIC_KEYSTONE_ID = 138019
local BROADCAST_RATE = (debugMode and 1 or 15) * 60 -- seconds
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

function addon:setMyKeystone(seekBag)
	self:log("Scanning for player's keystone")
	-- GetItemInfo() returns generic info, not info about the player's particular keystone
	-- name, link, quality, iLevel, reqLevel, class, subclass, maxStack, equipSlot, texture, vendorPrice = GetItemInfo(MYTHIC_KEYSTONE_ID)
	
	-- The best way I could find was to scan the player's bags until a keystone is found, and then rip the info out of the item link
	-- The bag to scan is provided by the ITEM_PUSH event; otherwise we scan all of them
	local firstBag = seekBag or 0
	local lastBag = seekBag and seekBag + 1 or NUM_BAG_SLOTS
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
				
				local name = nameWithRealm(UnitName('player'))
				local rtn = {dungeonID = dungeonID, keystoneLevel = keystoneLevel, affixIDs = affixIDs, lootEligible = lootEligible, upgradeTypeID = upgradeTypeID}
				
				-- Detecting if the weekly reset has happened is surprisingly hard (even pinning down the day it happens on each realm is hard)
				-- If the player's keystone is in myKeystones already and the level has decreased, it's probably the result of the reset; clear the whole table in that case
				local oldKeystone = self.myKeystones[name]
				if oldKeystone and oldKeystone.hasKeystone and oldKeystone.keystoneLevel > keystoneLevel then
					-- self.myKeystones is an alias for a field in self.db, so we can't just do self.myKeystones = {}
					for k, _ in pairs(self.myKeystones) do
						self.myKeystones[k] = nil
					end
				end
				
				self.myKeystones[name] = rtn
				return rtn
			end
		end
	end
	-- If we scanned all bags and didn't find a keystone, clear the (potential) existing myKeystones entry
	if not seekBag then
		self.myKeystones[nameWithRealm(UnitName('player'))] = nil
	end
end

function addon:getMyKeystone()
	local name = nameWithRealm(UnitName('player'))
	local rtn = self.myKeystones[name]
	if not rtn then
		rtn = self:setMyKeystone()
	end
	return rtn
end

function addon:renderKeystoneLink(keystone)
	local dungeonName = C_ChallengeMode.GetMapInfo(keystone.dungeonID)
	local numAffixes = #keystone.affixIDs
	local linkColor = LINK_COLORS[numAffixes]
	if not keystone.lootEligible then
		linkColor = '999999'
	end
	-- v1 messages don't include the upgradeTypeID; just hardcode it for now (we were making bad links before, and will continue to do so for most levels)
	keystone.upgradeTypeID = keystone.upgradeTypeID or 45872520
	local link = format("|TInterface\\Icons\\Achievement_PVP_A_%02d:16|t |cff%s|Hitem:%d::::::::110:0:%d:::%d:%d:%s:%d:::|h[%s +%d]|r", keystone.keystoneLevel, linkColor, MYTHIC_KEYSTONE_ID, keystone.upgradeTypeID, keystone.dungeonID, keystone.keystoneLevel, table.concat(keystone.affixIDs, ':'), keystone.lootEligible and '1' or '0', dungeonName, keystone.keystoneLevel)
	if numAffixes > 0 then
		local affixNames = {}
		for i, id in pairs(keystone.affixIDs) do
			affixName, affixDesc = C_ChallengeMode.GetAffixInfo(id)
			tinsert(affixNames, strlower(affixName))
		end
		link = format("%s (%s)", link, table.concat(affixNames, '/'))
	end
	if keystone.lootEligible then
		link = format("%s (%d/%d)", link, LOOT_ILVLS[keystone.keystoneLevel * 2], LOOT_ILVLS[keystone.keystoneLevel * 2 + 1])
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
	local keystone = self.keystones[seek]
	if keystone and keystone.isAlt then
		return 'alt'
	end

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
	local sections = type and {type} or {'party', 'friend', 'guild', 'alt'}
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
						printf("%s has %s", playerLink(name), self:renderKeystoneLink(keystone))
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

function addon:sendKeystones(type, target)
	for name, keystone in pairs(self.myKeystones) do
		SendAddonMessage(ADDON_PREFIX, 'keystone4:' .. self:networkEncode({name = name, keystone = keystone}), type, target)
	end
end

function addon:onAddonMsg(event, prefix, msg, channel, sender)
	if prefix ~= ADDON_PREFIX then return end
	
	-- Addon message format:
	-- v1: keystone1:dungeonID:keystoneLevel:affixID,affixID,affixID:lootEligible
	-- v2: keystone2:(Table serialized/compressed/encoded with Ace3)
	--   Table keys: dungeonID, keystoneLevel, affixIDs, lootEligible, upgradeTypeID
	-- v3: keystone3:(Table mapping player-realm name to v2 keystone table)

	-- A request for this user's keystone info

	if msg == 'keystone1?' then
		self:log('Received keystone v1 request from ' .. sender)
		local keystone = self:getMyKeystone()
		SendAddonMessage(ADDON_PREFIX, format("keystone1:%d:%d:%s:%d", keystone and keystone.dungeonID or 0, keystone and keystone.keystoneLevel or 0, keystone and table.concat(keystone.affixIDs, ',') or '', (keystone and keystone.lootEligible) and 1 or 0), "WHISPER", sender)
		return
	end
	
	-- No released version ever requested v2 keystones, so this shouldn't be necessary
	--[[
	if msg == 'keystone2?' then
		self:log('Received keystone v2 request from ' .. sender)
		SendAddonMessage(ADDON_PREFIX, 'keystone2:' .. self:encodeMyKeystone(), "WHISPER", sender)
		return
	end
	]]

	-- v3 encodings are broken, but don't want to remove them in case a client requests them. Instead return empty data
	if msg == 'keystone3?' then
		self:log('Received keystone v3 request from ' .. sender)
		SendAddonMessage(ADDON_PREFIX, 'keystone3:' .. self:networkEncode(nil), "WHISPER", sender)
		return
	end
	
	if msg == 'keystone4?' or (string.starts(msg, 'keystone') and string.ends(msg, '?')) then
		self:log('Received keystone v4 request from ' .. sender)
		self:sendKeystones('WHISPER', sender)
	end
	
	-- Another user's keystone info (which we may or may not have asked for, but print either way)
	local prefix = 'keystone1:'
	if string.starts(msg, prefix) then
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

	-- No released version ever sent v2 keystones, so this shouldn't be necessary
	--[[
	prefix = 'keystone2:'
	if string.starts(msg, prefix) then
		self:log('Received keystone v2 response from ' .. sender)
		local data = self:networkDecode(strsub(msg, strlen(prefix) + 1))
		self.keystones[sender] = data
		self.keystones[sender].hasKeystone = true
		return
	end
	]]

	prefix = 'keystone3:'
	if string.starts(msg, prefix) then
		self:log('Received keystone v3 response from ' .. sender)
		self:log('Ignoring')
		--[[
		local data = self:networkDecode(strsub(msg, strlen(prefix) + 1))
		for name, keystone in pairs(data) do
			--TODO Is there any way to determine if 'name' is actually a character controlled by 'sender'?
			self.keystones[name] = keystone
			self.keystones[name].hasKeystone = true
			self.keystones[name].isAlt = (name ~= sender)
			self.keystones[name].recordTime = time()
		end
		]]
		return
	end

	prefix = 'keystone4:'
	if string.starts(msg, prefix) then
		self:log('Received keystone v4 response from ' .. sender)
		local data = self:networkDecode(strsub(msg, strlen(prefix) + 1))
		local name = data.name
		self:log('  Keystone data for ' .. name)
		--TODO Is there any way to determine if 'name' is actually a character controlled by 'sender'?
		self.keystones[name] = data.keystone
		self.keystones[name].hasKeystone = true
		self.keystones[name].isAlt = (name ~= sender)
		self.keystones[name].recordTime = time()
	end
		
	if not self.showedOutOfDateMessage then
		self.showedOutOfDateMessage = true
		print('Keystone Query: Unrecognized message received from another user. Is this version out of date?')
	end
end

function addon:onItemPush(eventName, bag, icon)
	-- 'bag' doesn't appear to be the bag number like I thought, so just scanning them all
	self:setMyKeystone()
end

function addon:startTimers()
	if self.broadcastTimer ~= nil then
		self:CancelTimer(self.broadcastTimer)
	end
	self.broadcastTimer = self:ScheduleRepeatingTimer('broadcast', BROADCAST_RATE)
	self:broadcast()
end

function addon:refresh()
	self:log("Refreshing keystone list")
	self.keystones = {}
	SendAddonMessage(ADDON_PREFIX, 'keystone4?', 'PARTY')
	SendAddonMessage(ADDON_PREFIX, 'keystone4?', 'GUILD')
	--TODO Send to friends

	-- Update the LDB text
	if self:getMyKeystone() then
		ldbSource.text = ' ' .. self:renderKeystoneLink(self:getMyKeystone())
	else
		ldbSource.text = ' (none)'
	end
	
	-- Purge old keystone entries
	-- (at the moment we clear the whole list every time, so this isn't needed)
	--[[
	for name, keystone in pairs(self.keystones) do
		if keystone.recordTime > BROADCAST_RATE * 2 then
			self.keystones[name] = nil
		end
	end
	]]
end

function addon:broadcast()
	self:sendKeystones('PARTY')
	self:sendKeystones('GUILD')
	--TODO Send to friends
end

function addon:OnInitialize()
	self.keystones = {}
	self.broadcastTimer = nil
	self.showedOutOfDateMessage = false
	
	local dbDefaults = {
		keystones = {}
	}
	self.db = LibStub('AceDB-3.0'):New('KeystoneQueryDB', {factionrealm = dbDefaults}, true).factionrealm
	self.myKeystones = self.db.keystones

	self:RegisterEvent('CHAT_MSG_ADDON', 'onAddonMsg')
	self:RegisterBucketEvent('ITEM_PUSH', 2, 'onItemPush')
	--TODO Call setMyKeystone(nil) when item is destroyed; not sure which event that is
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
		elseif cmd == 'refresh' then
			addon:refresh()
		elseif cmd == 'dump' then
			print("KeystoneQuery table dump:")
			for name, keystone in table.pairsByKeys(self.keystones) do
				printf(name)
				printf("  section: %s", self:getPlayerSection(name))
				if not keystone.hasKeystone then
					printf("  (no keystone)")
				else
					printf("  dungeonID: %d", keystone.dungeonID)
					printf("  keystoneLevel: %d", keystone.keystoneLevel)
					printf("  affixIDs: %s", table.concat(keystone.affixIDs, '/'))
					printf("  lootEligible: %s", keystone.lootEligible and 'true' or 'false')
					printf("  upgradeTypeID: %d", keystone.upgradeTypeID)
					printf("  isAlt: %s", keystone.isAlt and 'true' or 'false')
					printf("  recordTime: %d", keystone.recordTime)
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
	self:startTimers()
end

function addon:OnDisable()
	self:CancelTimer(self.broadcastTimer)
	self.broadcastTimer = nil
end

ldbSource.OnTooltipShow = function(tooltip)
	tooltip:SetText('Mythic Keystones', HIGHLIGHT_FONT_COLOR:GetRGB())
	
	local sections = {party = 'Party', friend = 'Friends', guild = 'Guild', alt = 'Alts'}
	for section, label in pairs(sections) do
		local labelShown = false
		for name, keystone in table.pairsByKeys(addon.keystones) do
			if addon:getPlayerSection(name) == section then
				if keystone and keystone.hasKeystone then
					if not labelShown then
						tooltip:AddLine(' ')
						-- For some reason I cannot figure out, this results in red text in the tooltip
						-- tooltip:AddLine(gsub(section, '^%l', string.upper))
						tooltip:AddLine(label)
						labelShown = true
					end
					tooltip:AddDoubleLine(addon:renderKeystoneLink(keystone), playerLink(name))
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
