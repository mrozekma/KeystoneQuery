local addon = LibStub("AceAddon-3.0"):NewAddon("KeystoneQuery", "AceBucket-3.0", "AceComm-3.0", "AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
local ldb = LibStub:GetLibrary("LibDataBroker-1.1")
local libCompress = LibStub:GetLibrary("LibCompress")

local version = GetAddOnMetadata('KeystoneQuery', 'Version')
local debugMode = false

local MYTHIC_KEYSTONE_ID = 138019
local BROADCAST_RATE = (debugMode and 1 or 15) * 60 -- seconds
local ICON = 'Interface\\Icons\\INV_Relics_Hourglass'
local ADDON_PREFIX = 'KeystoneQuery'
local LINK_COLORS = {'00ff00', 'ffff00', 'ff0000', 'a335ee'} -- Index is number of affixes + 1 on the keystone (thanks Lua for your brilliant 1-indexing)

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

function addon:setMyKeystone()
	self:log("Scanning for player's keystone")
	local name = nameWithRealm(UnitName('player'))

	local setLDBText = function(keystone)
		if keystone then
			ldbSource.text = ' ' .. self:renderKeystoneLink(keystone)
		else
			ldbSource.text = ' (none)'
		end
	end
	
	
	-- We also try and set the player's GUID here because it's not always available when OnInitialize runs
	if not self.myGuids[name] then
		local guid = UnitGUID('player')
		if guid then
			self.myGuids[name] = guid
			self.guids[name] = guid
		end
	end
	
	-- GetItemInfo() returns generic info, not info about the player's particular keystone
	-- name, link, quality, iLevel, reqLevel, class, subclass, maxStack, equipSlot, texture, vendorPrice = GetItemInfo(MYTHIC_KEYSTONE_ID)
	
	-- The best way I could find was to scan the player's bags until a keystone is found, and then rip the info out of the item link
	-- The bag to scan is provided by the ITEM_PUSH event; otherwise we scan all of them
	for bag = 0, NUM_BAG_SLOTS do
		local numSlots = GetContainerNumSlots(bag)
		if numSlots == 0 then
			return nil, nil
		end
		for slot = 1, numSlots do
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
				
				local newKeystone = {dungeonID = dungeonID, keystoneLevel = keystoneLevel, affixIDs = affixIDs, lootEligible = lootEligible, upgradeTypeID = upgradeTypeID}
				local oldKeystone = self.myKeystones[name]
				local changed = (oldKeystone == nil or oldKeystone.keystoneLevel ~= newKeystone.keystoneLevel)
				self.myKeystones[name] = newKeystone
				self.myKeystoneOriginalLink = originalLink
				setLDBText(newKeystone)
				return newKeystone, changed
			end
		end
	end
	
	self:log('No keystone found')
	
	-- Detecting if the weekly reset has happened is surprisingly hard (even pinning down the day it happens on each realm is hard)
	-- If we had a keystone but don't anymore, assume it was the reset and wipe myKeystones.
	local oldKeystone = self.myKeystones[name]
	if oldKeystone then
		self:log('Expected a keystone -- assuming weekly reset and clearing alt keystone list')
		-- self.myKeystones is an alias for a field in self.db, so we can't just do self.myKeystones = {}
		for k, _ in pairs(self.myKeystones) do
			self.myKeystones[k] = nil
		end
	else
		self.myKeystones[nameWithRealm(UnitName('player'))] = nil
	end
	self.myKeystoneOriginalLink = nil
	setLDBText(nil)
end

function addon:getMyKeystone()
	local name = nameWithRealm(UnitName('player'))
	local rtn = self.myKeystones[name]
	if not rtn then
		rtn, _ = self:setMyKeystone()
	end
	return rtn
end

function addon:renderKeystoneLink(keystone, formatted)
	formatted = (formatted ~= false) -- Default to true
	local dungeonName = C_ChallengeMode.GetMapInfo(keystone.dungeonID)
	local numAffixes = #keystone.affixIDs
	-- v1 messages don't include the upgradeTypeID; just hardcode it for now (we were making bad links before, and will continue to do so for most levels)
	keystone.upgradeTypeID = keystone.upgradeTypeID or 45872520
	local link
	if formatted then
		local linkColor = keystone.lootEligible and LINK_COLORS[numAffixes + 1] or '999999'
		link = format("|TInterface\\Icons\\Achievement_PVP_A_%02d:16|t |cff%s|Hitem:%d::::::::110:0:%d:::%d:%d:%s:%d:::|h[%s +%d]|r", keystone.keystoneLevel, linkColor, MYTHIC_KEYSTONE_ID, keystone.upgradeTypeID, keystone.dungeonID, keystone.keystoneLevel, table.concat(keystone.affixIDs, ':'), keystone.lootEligible and '1' or '0', dungeonName, keystone.keystoneLevel)
	else
		link = format("%s +%d", dungeonName, keystone.keystoneLevel)
	end
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
		rtn[i] = format("|cff%s%s|r - %s", LINK_COLORS[i + 1], name, desc)
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

function addon:showKeystones(type, showNones)
	local sections = type and {type} or {'party', 'friend', 'guild'}
	for _, section in ipairs(sections) do
		local labelShown = false
		for name, keystone in table.pairsByKeys(self.keystones) do
			if self:getPlayerSection(name) == section then
				if not keystone.isAlt then
					-- If not showNones, this player needs to either have a keystone or have an alt with a keystone
					local printThis = showNones
					if keystone and keystone.hasKeystone then
						printThis = true
					else
						for alt, _ in table.pairsByKeys(self.alts[name]) do
							local altKeystone = self.keystones[alt]
							if altKeystone and altKeystone.hasKeystone then
								printThis = true
							end
						end
					end
					if printThis then
						if not labelShown then
							printf("|T%s:16|t %s keystones:", ICON, gsub(section, '^%l', string.upper))
							labelShown = true
						end
						if keystone == nil then
							printf("%s's keystone is unknown", self:playerLink(name))
						elseif not keystone.hasKeystone then
							printf("%s has no keystone", self:playerLink(name))
						else
							printf("%s has %s", self:playerLink(name), self:renderKeystoneLink(keystone))
						end
						
						if self.alts[name] then
							for alt, _ in table.pairsByKeys(self.alts[name]) do
								if self.keystones[alt] and self.keystones[alt].hasKeystone then
									printf("    %s has %s", self:playerLink(alt), self:renderKeystoneLink(self.keystones[alt]))
								end
							end
						end
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
	local originalData = data
	local data = libCompress:GetAddonEncodeTable():Decode(data)
	local data, err = libCompress:Decompress(data)
	if not data then
		print("Keystone Query: Failed to decompress network data: " .. err)
		self:log(originalData)
		return
	end
	local success, data = self:Deserialize(data)
	if not success then
		print("Keystone Query: Failed to deserialize network data")
		self:log(originalData)
		return
	end
	return data
end

function addon:sendKeystones(type, target)
	for name, keystone in pairs(self.myKeystones) do
		SendAddonMessage(ADDON_PREFIX, 'keystone4:' .. self:networkEncode({name = name, keystone = keystone, v5support = true}), type, target)
	end
	self:SendCommMessage(ADDON_PREFIX .. '2', 'keystone5:' .. self:networkEncode({version = version, guids = self.myGuids, keystones = self.myKeystones}), type, target)
end

function addon:onAddonMsg(event, prefix, msg, channel, sender)
	if prefix == ADDON_PREFIX  then
		self:receiveMessage(msg, channel, sender)
	end
end

function addon:onAceCommMsg(prefix, msg, channel, sender)
	if prefix == ADDON_PREFIX .. '2' then
		self:receiveMessage(msg, channel, sender)
	end
end

function addon:receiveMessage(msg, channel, sender)
	-- Addon message format:
	-- v1: keystone1:dungeonID:keystoneLevel:affixID,affixID,affixID:lootEligible
	-- v2: keystone2:(Table serialized/compressed/encoded with Ace3)
	--   Table keys: dungeonID, keystoneLevel, affixIDs, lootEligible, upgradeTypeID
	-- v3: keystone3:(Table mapping player-realm name to v2 keystone table)
	-- v4: Went back to v2
	-- v5: keystone5:(Table serialized/compressed/encoded with Ace3, sent via AceComm)
	--   Table: 'guid' -> {name -> guid}, 'keystones' -> {name -> keystone}, keystone is the same as v2

	sender = nameWithRealm(sender)
	
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
	
	if msg == 'keystone4?' or msg == 'keystone5?' or (string.starts(msg, 'keystone') and string.ends(msg, '?')) then
		self:log('Received keystone v%s request from %s', strsub(msg, 9, 9), sender)
		self:sendKeystones('WHISPER', sender)
		return
	end
	
	-- Another user's keystone info (which we may or may not have asked for, but print either way)
	local prefix = 'keystone1:'
	if string.starts(msg, prefix) then
		self:log('Received keystone v1 response from ' .. sender)
		self.versions[sender] = '? (v1)'
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
		self.versions[sender] = '? (v2)'
		local data = self:networkDecode(strsub(msg, strlen(prefix) + 1))
		self.keystones[sender] = data
		self.keystones[sender].hasKeystone = true
		return
	end
	]]

	prefix = 'keystone3:'
	if string.starts(msg, prefix) then
		self:log('Received keystone v3 response from ' .. sender)
		self.versions[sender] = '? (v3)'
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
		self.versions[sender] = '? (v4)'
		local data = self:networkDecode(strsub(msg, strlen(prefix) + 1))
		if not data then
			return
		end
		local name = data.name
		if data.v5support then
			self:log('  Sender supports v5, ignoring the v4 message')
			return
		end
		self:log('  Keystone data for ' .. name)
		--TODO Is there any way to determine if 'name' is actually a character controlled by 'sender'?
		self:onNewKeystone(name, data.keystone)
		self.keystones[name] = data.keystone
		self.keystones[name].hasKeystone = true
		self.keystones[name].isAlt = (name ~= sender)
		self.keystones[name].recordTime = time()
		if self.keystones[name].isAlt then
			if not self.keystones[sender] then
				self.keystones[sender] = {hasKeystone = false}
			end
			if not self.alts[sender] then
				self.alts[sender] = {}
			end
			self.alts[sender][name] = true
			self.alts[name] = nil -- If the user was logged into this alt before
		end
		return
	end
	
	prefix = 'keystone5:'
	if string.starts(msg, prefix) then
		self:log('Received keystone v5 response from ' .. sender)
		self.versions[sender] = '? (v5)'
		local data = self:networkDecode(strsub(msg, strlen(prefix) + 1))
		if not data then
			return
		end
		--TODO Is there any way to determine if 'name' is actually a character controlled by 'sender'?
		if data.version then
			self.versions[sender] = data.version .. ' (v5)'
		end
		for name, guid in pairs(data.guids) do
			self.guids[name] = guid
			GetPlayerInfoByGUID(guid)
		end
		for name, keystone in pairs(data.keystones) do
			self:onNewKeystone(name, keystone)
			self.keystones[name] = keystone
			self.keystones[name].hasKeystone = true
			self.keystones[name].isAlt = (name ~= sender)
			self.keystones[name].recordTime = time()
			if self.keystones[name].isAlt then
				if not self.keystones[sender] then
					self.keystones[sender] = {hasKeystone = false}
				end
				if not self.alts[sender] then
					self.alts[sender] = {}
				end
				self.alts[sender][name] = true
				self.alts[name] = nil -- If the user was logged into this alt before
			end
		end
		return
	end
		
	if not self.showedOutOfDateMessage then
		self.showedOutOfDateMessage = true
		print('Keystone Query: Unrecognized message received from another user. Is this version out of date?')
		self:log("From %s: %s", sender, msg)
	end
end

function addon:onNewKeystone(name, newKeystone)
	if self:getPlayerSection(name) == 'party' then
		local oldKeystone = self.keystones[name]
		if not oldKeystone or not oldKeystone.hasKeystone then
			oldKeystone = self.oldKeystones[name]
		end
		if not oldKeystone or not oldKeystone.hasKeystone or oldKeystone.keystoneLevel ~= newKeystone.keystoneLevel then
			printf("%s has a new keystone: %s", self:playerLink(name), self:renderKeystoneLink(newKeystone))
		end
	end
end

function addon:onBagUpdate()
	self:log('onBagUpdate')
	local _, changed = self:setMyKeystone()
	if changed then
		self:log('Broadcast new keystone')
		self:broadcast()
	end
end

function addon:startTimers()
	if self.broadcastTimer ~= nil then
		self:CancelTimer(self.broadcastTimer)
	end
	self.broadcastTimer = self:ScheduleRepeatingTimer('broadcast', BROADCAST_RATE)
	self:broadcast()
end

function addon:playerLink(player)
	local guid = self.guids[nameWithRealm(player)]
	local rendered = gsub(player, format("-%s$", GetRealmName()), '')
	if guid then
		local _, class, _, _, _, _, _ = GetPlayerInfoByGUID(guid)
		if class then
			local color = RAID_CLASS_COLORS[class]
			if color then
				rendered = format("|c%s%s|r", color.colorStr, rendered)
			end
		end
	end
	return format('|Hplayer:%s:0|h%s|h', player, rendered)
end

function addon:refresh()
	self:log("Refreshing keystone list")
	for name, keystone in pairs(self.keystones) do
		self.oldKeystones[name] = keystone
	end
	self.keystones = {}
	if UnitInParty('player') then
		SendAddonMessage(ADDON_PREFIX, 'keystone4?', 'PARTY')
	end
	if GetGuildInfo('player') then
		SendAddonMessage(ADDON_PREFIX, 'keystone4?', 'GUILD')
	end
	--TODO Send to friends

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
	if UnitInParty('player') then
		self:sendKeystones('PARTY')
	end
	if GetGuildInfo('player') then
		self:sendKeystones('GUILD')
	end
	--TODO Send to friends
end

function addon:OnInitialize()
	self:log('Initializing')
	
	self.guids = {}
	self.keystones = {}

	self.versions = {}
	self.alts = {}
	self.oldKeystones = {}
	self.myKeystoneOriginalLink = nil

	self.broadcastTimer = nil
	self.showedOutOfDateMessage = false
	
	local dbDefaults = {
		guids = {},
		keystones = {},
	}
	self.db = LibStub('AceDB-3.0'):New('KeystoneQueryDB', {factionrealm = dbDefaults}, true).factionrealm
	self.myGuids = self.db.guids
	self.myKeystones = self.db.keystones

	for name, guid in pairs(self.myGuids) do
		self.guids[name] = guid
	end

	self:RegisterBucketEvent('BAG_UPDATE', 2, 'onBagUpdate')
	--TODO Call setMyKeystone() when item is destroyed; not sure which event that is
	self:RegisterBucketEvent({'GUILD_ROSTER_UPDATE', 'FRIENDLIST_UPDATE', 'GROUP_ROSTER_UPDATE', 'PARTY_MEMBER_ENABLE', 'CHALLENGE_MODE_START', 'CHALLENGE_MODE_RESET', 'CHALLENGE_MODE_COMPLETED'}, 2, 'refresh')
	
	self:RegisterEvent('CHAT_MSG_ADDON', 'onAddonMsg')
	RegisterAddonMessagePrefix(ADDON_PREFIX)
	self:RegisterComm(ADDON_PREFIX .. '2', 'onAceCommMsg')
	
	self:setMyKeystone()
	
	SLASH_KeystoneQuery1 = '/keystone?'
	SLASH_KeystoneQuery2 = '/key?'
	SlashCmdList['KeystoneQuery'] = function(cmd)
		-- Default looks up party (if in one) and guild
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
			if GetGuildInfo('player') then
				self:showKeystones('guild', false)
			else
				print("Not in a guild")
			end
		elseif cmd == 'affix' or cmd == 'affixes' then
			printf("|T%s:16|t Affixes:", ICON)
			for _, text in pairs(self:renderAffixes()) do
				print(text)
			end
		elseif cmd == 'refresh' then
			addon:refresh()
		elseif cmd == 'clear' then
			for _, tbl in ipairs({addon.myGuids, addon.guids, addon.myKeystones, addon.keystones, addon.alts, addon.versions}) do
				for k, _ in pairs(tbl) do
					tbl[k] = nil
				end
			end
			addon:refresh()
		elseif cmd == 'dump' or string.starts(cmd, 'dump ') then
			local groups = {'versions', 'guids', 'keystones', 'alts'}
			local groupFns = {
				versions = function()
					for name, version in table.pairsByKeys(self.versions) do
						printf("    %s: %s", name, version)
					end
				end,
				guids = function()
					for name, guid in table.pairsByKeys(self.guids) do
						printf("    %s: %s", name, guid)
					end
				end,
				keystones = function()
					for name, keystone in table.pairsByKeys(self.keystones) do
						printf("    %s", name)
						printf("      section: %s", self:getPlayerSection(name))
						if not keystone.hasKeystone then
							printf("      (no keystone)")
						else
							printf("      dungeonID: %d", keystone.dungeonID)
							printf("      keystoneLevel: %d", keystone.keystoneLevel)
							printf("      affixIDs: %s", table.concat(keystone.affixIDs, '/'))
							printf("      lootEligible: %s", keystone.lootEligible and 'true' or 'false')
							printf("      upgradeTypeID: %d", keystone.upgradeTypeID)
							printf("      isAlt: %s", keystone.isAlt and 'true' or 'false')
							printf("      recordTime: %d", keystone.recordTime)
						end
					end
				end,
				alts = function()
					for name, alts in table.pairsByKeys(self.alts) do
						local vals = {}
						for alt, _ in pairs(alts) do
							tinsert(vals, alt)
						end
						table.sort(vals)
						printf("    %s: %s", name, table.concat(vals, ', '))
					end
				end
			}
			
			print("KeystoneQuery table dump:")
			local groupName = strsub(cmd, 6)
			if groupName == '' then
				for _, groupName in pairs(groups) do
					printf("  %s:", groupName)
					groupFns[groupName]()
				end
			else
				local fn = groupFns[groupName]
				if fn then
					printf("  %s:", groupName)
					fn()
				else
					printf("KeystoneQuery: Unknown dump group: %s", groupName)
				end
			end
		elseif cmd == 'debug off' then
			debugMode = false
			print("KeystoneQuery: debug mode disabled")
		elseif cmd == 'debug on' then
			debugMode = true
			print("KeystoneQuery: debug mode enabled")
		else
			print("KeystoneQuery: unknown command")
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

	local sections = {
		{key = 'party', label = 'Party'},
		{key = 'friend', label = 'Friends'},
		{key = 'guild', label = 'Guild'},
	}
	for _, section in ipairs(sections) do
		local labelShown = false
		for name, keystone in table.pairsByKeys(addon.keystones) do
			if addon:getPlayerSection(name) == section.key then
				-- Only print if this player or one of their alts has a keystone
				local printThis = (keystone and keystone.hasKeystone)
				if not printThis then
					for alt, _ in table.pairsByKeys(addon.alts[name] or {}) do
						if addon.keystones[alt] and addon.keystones[alt].hasKeystone then
							printThis = true
						end
					end
				end
				if printThis then
					if not labelShown then
						tooltip:AddLine(' ')
						tooltip:AddLine(section.label)
						labelShown = true
					end
					if keystone and keystone.hasKeystone then
						tooltip:AddDoubleLine(addon:renderKeystoneLink(keystone), addon:playerLink(name))
					else
						tooltip:AddDoubleLine('|TInterface\\Icons\\Achievement_PVP_A_A:16|t None', addon:playerLink(name))
					end
					for alt, _ in table.pairsByKeys(addon.alts[name] or {}) do
						local keystone = addon.keystones[alt]
						if keystone and keystone.hasKeystone then
							tooltip:AddDoubleLine('     ' .. addon:renderKeystoneLink(keystone), addon:playerLink(alt))
						end
					end
				end
			end
		end
	end
	
	tooltip:AddLine(' ')
	
	for _, text in pairs(addon:renderAffixes()) do
		tooltip:AddLine(text, nil, nil, nil, true)
	end
end

local function renderKeystoneForChat(keystone)
	if not keystone then
		return 'no keystone'
	end
	local link = addon:renderKeystoneLink(keystone, false)
	if addon.myKeystoneOriginalLink then
		link = format("%s -- %s", addon.myKeystoneOriginalLink, link)
	end
	return link
end

ldbSource.OnClick = function(frame, button)
	if button == 'LeftButton' and IsShiftKeyDown() then
		local editbox = DEFAULT_CHAT_FRAME.editBox
		if editbox then
			local link = renderKeystoneForChat(addon:getMyKeystone())
			editbox:Insert(link)
			-- editbox:Show() -- This doesn't seem to work; editbox:IsShown() is always true and this does nothing if called when the box isn't up
		end
	end
end

hooksecurefunc("ChatEdit_OnTextChanged", function(self, userInput)
	if userInput then
		msg = self:GetText()
		if strfind(msg, ':key') then
			-- Replace :key: and :keystone: with a semi-detailed version of this player's keystone
			local link = renderKeystoneForChat(addon:getMyKeystone())
			-- Lua's regex support is abysmal. Not sure there's a way to do this in one replace
			-- msg = gsub(msg, ':key(stone)?:', link)
			msg = gsub(msg, ':key:', link)
			msg = gsub(msg, ':keystone:', link)
			
			-- Replace :keys: and :keystones: with a very simple ("Dungeon +level") list of this account's keystones including alts
			local links = {}
			for name, keystone in table.pairsByKeys(addon.myKeystones) do
				local dungeonName = C_ChallengeMode.GetMapInfo(keystone.dungeonID)
				tinsert(links, format("%s has %s +%d", Ambiguate(name, 'short'), dungeonName, keystone.keystoneLevel))
			end
			links = table.concat(links, ', ')
			msg = gsub(msg, ':keys:', links)
			msg = gsub(msg, ':keystones:', links)
			
			self:SetText(msg)
		end
	end
end)
