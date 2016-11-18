local myAddon = LibStub("AceAddon-3.0"):NewAddon("KeystoneQuery", "AceBucket-3.0", "AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
local ldb = LibStub:GetLibrary("LibDataBroker-1.1")
local libCompress = LibStub:GetLibrary("LibCompress")

local debugMode = false

local MYTHIC_KEYSTONE_ID = 138019
local REFRESH_RATE = (debugMode and 1 or 15) * 60 -- seconds
local ICON = 'Interface\\Icons\\INV_Relics_Hourglass'
local ADDON_PREFIX = 'KeystoneQuery'
local LINK_COLORS = {'00ff00', 'ffff00', 'ff0000', 'a335ee'} -- Index is number of affixes on the keystone

local ldbSource = LibStub("LibDataBroker-1.1"):NewDataObject("KeystoneQuery", {
	type = "data source",
	icon = ICON,
	label = "Keystone",
	title = "Keystone",
})

local function log(fmt, ...)
	if(debugMode) then
		printf("KeystoneQuery: " .. fmt, ...)
	end
end

local keystones = {}
local broadcastTimer = nil
local showedOutOfDateMessage = false

--TODO Remember and share alt keystones
--TODO Switch timer updates to broadcast instead of request
--TODO Detect new keystone on dungeon finish
--TODO Keystone voting

local function getMyKeystone()
	log("Scanning for player's keystone")
	-- GetItemInfo() returns generic info, not info about the player's particular keystone
	-- name, link, quality, iLevel, reqLevel, class, subclass, maxStack, equipSlot, texture, vendorPrice = GetItemInfo(MYTHIC_KEYSTONE_ID)
	
	-- The best way I could find was to scan the player's bags until a keystone is found, and then rip the info out of the item link
	for bag = 0, NUM_BAG_SLOTS do
		for slot = 1, GetContainerNumSlots(bag) do
			if(GetContainerItemID(bag, slot) == MYTHIC_KEYSTONE_ID) then
				originalLink = GetContainerItemLink(bag, slot)
				log("Player's keystone: %s -- %s", originalLink, gsub(originalLink, '|', '!'))
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
				
				upgradeTypeID = tonumber(parts[12])
				-- These don't seem right, but I don't have a pile of keystones to test with. Going to get the number of affixes from the level for now instead
				-- numAffixes = ({[4587520] = 0, [5111808] = 1, [6160384] = 2, [4063232] = 3})[upgradeTypeID]
				dungeonID = tonumber(parts[15])
				keystoneLevel = tonumber(parts[16])
				numAffixes = ({0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 3, 3, 3})[keystoneLevel]
				affixIDs = {}
				for i = 0, numAffixes - 1 do
					tinsert(affixIDs, tonumber(parts[17 + i]))
				end
				lootEligible = (tonumber(parts[17 + numAffixes]) == 1)
				return dungeonID, keystoneLevel, affixIDs, lootEligible, upgradeTypeID
			end
		end
	end
end

local function renderKeystoneLink(dungeonID, keystoneLevel, affixIDs, lootEligible, upgradeTypeID)
	dungeonName = C_ChallengeMode.GetMapInfo(dungeonID)
	numAffixes = #affixIDs
	linkColor = LINK_COLORS[numAffixes]
	if not lootEligible then
		linkColor = '999999'
	end
	-- v1 messages don't include the upgradeTypeID; just hardcode it for now (we were making bad links before, and will continue to do so for most levels)
	upgradeTypeID = upgradeTypeID or 45872520
	link = format("|TInterface\\Icons\\Achievement_PVP_A_%02d:16|t |cff%s|Hitem:%d::::::::110:0:%d:::%d:%d:%s:%d:::|h[%s +%d]|r", keystoneLevel, linkColor, MYTHIC_KEYSTONE_ID, upgradeTypeID, dungeonID, keystoneLevel, table.concat(affixIDs, ':'), lootEligible and '1' or '0', dungeonName, keystoneLevel)
	if numAffixes > 0 then
		affixNames = {}
		for i, id in pairs(affixIDs) do
			affixName, affixDesc = C_ChallengeMode.GetAffixInfo(id)
			tinsert(affixNames, strlower(affixName))
		end
		link = format("%s (%s)", link, table.concat(affixNames, '/'))
	end
	if not lootEligible then
		link = link .. " (depleted)"
	end
	return link
end

local function renderAffixes()
	-- I don't see a way to get the week's affix info from the API, so I just list the affixes on the known keystones
	affixes = {}
	for _, keystone in pairs(keystones) do
		if keystone.hasKeystone then
			for i, affixID in pairs(keystone.affixIDs) do
				affixes[i] = affixID
			end
		end
	end
	
	rtn = {}
	for i, affixID in pairs(affixes) do
		name, desc = C_ChallengeMode.GetAffixInfo(affixID)
		rtn[i] = format("|cff%s%s|r - %s", LINK_COLORS[i], name, desc)
	end
	return rtn
end

local function getPlayerSection(seek)
	party = GetHomePartyInfo()
	if party then
		name = nameWithRealm(UnitName('player'))
		if name == seek then return 'party' end
		for _, name in pairs(party) do
			if nameWithRealm(name) == seek then return 'party' end
		end
	end
	
	--TODO Friends
	
	return 'guild'
end

--TODO Everything assumes the player is in a guild; handle when they're not
local function showKeystones(type, showNones)
	sections = type and {type} or {'party', 'friend', 'guild'}
	for _, section in pairs(sections) do
		labelShown = false
		for name, keystone in table.pairsByKeys(keystones) do
			if getPlayerSection(name) == section then
				keystone = keystones[name]
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
						printf("%s has %s", playerLink(name), renderKeystoneLink(keystone.dungeonID, keystone.keystoneLevel, keystone.affixIDs, keystone.lootEligible, keystone.upgradeTypeID))
					end
				end
			end
		end
	end
end

function myAddon:networkEncode(data)
	return libCompress:GetAddonEncodeTable():Encode(libCompress:CompressHuffman(self:Serialize(data)))
end

function myAddon:networkDecode(data)
	data = libCompress:GetAddonEncodeTable():Decode(data)
	data, err = libCompress:Decompress(data)
	if not data then
		print("Keystone Query: Failed to decompress network data: " .. err)
		return
	end
	success, data = self:Deserialize(data)
	if not success then
		print("Keystone Query: Failed to deserialize network data")
		return
	end
	return data
end

function myAddon:encodeMyKeystone()
	dungeonID, keystoneLevel, affixIDs, lootEligible, upgradeTypeID = getMyKeystone()
	-- Ideally we would reconstruct the link on the other end without the need for upgradeTypeID, but I can't figure it out in all cases yet, I'm producing bad links for high-level keystones
	return self:networkEncode({dungeonID = dungeonID, keystoneLevel = keystoneLevel, affixIDs = affixIDs, lootEligible = lootEligible, upgradeTypeID = upgradeTypeID})
end

function myAddon:onAddonMsg(event, prefix, msg, channel, sender)
	if prefix ~= ADDON_PREFIX then return end
	
	-- Addon message format:
	-- v1: keystone1:dungeonID:keystoneLevel:affixID,affixID,affixID:lootEligible
	-- v2: keystone2:(Table serialized/compressed/encoded with Ace3)
	--   Table keys: dungeonID, keystoneLevel, affixIDs, lootEligible, upgradeTypeID

	-- A request for this user's keystone info
	
	if msg == 'keystone1?' then
		log('Received keystone v1 request from ' .. sender)
		dungeonID, keystoneLevel, affixIDs, lootEligible, _ = getMyKeystone()
		SendAddonMessage(ADDON_PREFIX, format("keystone1:%d:%d:%s:%d", dungeonID or 0, keystoneLevel or 0, table.concat(affixIDs or {}, ','), lootEligible and 1 or 0), "WHISPER", sender)
		return
	end
	
	if msg == 'keystone2?' then
		log('Received keystone v2 request from ' .. sender)
		SendAddonMessage(ADDON_PREFIX, 'keystone2:' .. self:encodeMyKeystone(), "WHISPER", sender)
		return
	end

	-- Another user's keystone info (which we may or may not have asked for, but print either way)
	prefix = 'keystone1:'
	if strsub(msg, 1, strlen(prefix)) == prefix then
		log('Received keystone v1 response from ' .. sender)
		_, dungeonID, keystoneLevel, affixIDs, lootEligible = strsplit(':', msg)
		if tonumber(dungeonID) == 0 then
			keystones[sender] = {hasKeystone = false}
		else
			affixIDs = { strsplit(',', affixIDs) }
			for k, v in pairs(affixIDs) do
				affixIDs[k] = tonumber(v)
			end
			keystones[sender] = {hasKeystone = true, dungeonID = tonumber(dungeonID), keystoneLevel = tonumber(keystoneLevel), affixIDs = affixIDs, lootEligible = (lootEligible == '1')}
		end
		return
	end

	prefix = 'keystone2:'
	if strsub(msg, 1, strlen(prefix)) == prefix then
		log('Received keystone v2 response from ' .. sender)
		data = self:networkDecode(strsub(msg, strlen(prefix) + 1))
		keystones[sender] = data
		keystones[sender].hasKeystone = true
		return
	end

	if not showedOutOfDateMessage then
		showedOutOfDateMessage = true
		print('Keystone Query: Unrecognized message received from another user. Is this version out of date?')
	end
end

function myAddon:startTimer()
	if broadcastTimer ~= nil then
		self:CancelTimer(broadcastTimer)
	end
	broadcastTimer = self:ScheduleRepeatingTimer('refresh', REFRESH_RATE)
	-- In the future, broadcast updates instead of requesting them. While a bunch of people still have v1, don't, since they'll see printouts on every broadcast
	-- self:broadcast()
	self:refresh()
end

function myAddon:refresh()
	log("Refreshing keystone list")
	keystones = {}
	SendAddonMessage(ADDON_PREFIX, 'keystone1?', 'PARTY')
	SendAddonMessage(ADDON_PREFIX, 'keystone1?', 'GUILD')
	--TODO Send to friends
	
	if getMyKeystone() then
		ldbSource.text = ' ' .. renderKeystoneLink(getMyKeystone())
	else
		ldbSource.text = ' (none)'
	end
end

function myAddon:refreshSoon()
	log("Refreshing in a moment")
	self:ScheduleTimer('refresh', 2)
end

function myAddon:broadcast()
	SendAddonMessage(ADDON_PREFIX, 'keystone2:' .. self:encodeMyKeystone(), 'PARTY')
	SendAddonMessage(ADDON_PREFIX, 'keystone2:' .. self:encodeMyKeystone(), 'GUILD')
	--TODO Send to friends
end

function myAddon:OnInitialize()
	self:RegisterEvent('CHAT_MSG_ADDON', 'onAddonMsg')
	self:RegisterBucketEvent({'GUILD_ROSTER_UPDATE', 'FRIENDLIST_UPDATE', 'PARTY_MEMBERS_CHANGED', 'PARTY_MEMBER_ENABLE', 'CHALLENGE_MODE_START', 'CHALLENGE_MODE_RESET', 'CHALLENGE_MODE_COMPLETED'}, 2, 'refreshSoon')
	RegisterAddonMessagePrefix(ADDON_PREFIX)

	SLASH_KeystoneQuery1 = '/keystone?'
	SLASH_KeystoneQuery2 = '/key?'
	SlashCmdList['KeystoneQuery'] = function(cmd)
		-- Default looks up party if in one, else guild
		if cmd == '' then
			showKeystones(nil, false)
		elseif cmd == 'party' or cmd == 'p' then
			if UnitInParty('player') then
				showKeystones('party', true)
			else
				print("Not in a party")
			end
--		elseif cmd == 'friends' or cmd == 'f' then
		elseif cmd == 'guild' or cmd == 'g' or cmd == '' then
			showKeystones('guild', false)
		elseif cmd == 'affix' or cmd == 'affixes' then
			printf("|T%s:16|t Affixes:", ICON)
			for _, text in pairs(renderAffixes()) do
				print(text)
			end
		elseif cmd == 'dump' then
			print("KeystoneQuery table dump:")
			for name, keystone in table.pairsByKeys(keystones) do
				if not keystone.hasKeystone then
					printf("%s (%s) = no keystone", name, getPlayerSection(name))
				else
					printf("%s (%s) = %d, %d, %s, %s, %d (%s)", name, getPlayerSection(name), keystone.dungeonID, keystone.keystoneLevel, table.concat(keystone.affixIDs, '/'), keystone.lootEligible and 'true' or 'false', keystone.upgradeTypeID, renderKeystoneLink(keystone.dungeonID, keystone.keystoneLevel, keystone.affixIDs, keystone.lootEligible, keystone.upgradeTypeID))
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

function myAddon:OnEnable()
	log("OnEnable")
	self:startTimer()
end

function myAddon:OnDisable()
	self:CancelTimer(broadcastTimer)
	broadcastTimer = nil
end

ldbSource.OnTooltipShow = function(tooltip)
	tooltip:SetText('Mythic Keystones', HIGHLIGHT_FONT_COLOR:GetRGB())
	
	sections = {'party', 'friend', 'guild'}
	for _, section in pairs(sections) do
		labelShown = false
		for name, keystone in table.pairsByKeys(keystones) do
			if getPlayerSection(name) == section then
				keystone = keystones[name]
				if keystone and keystone.hasKeystone then
					if not labelShown then
						tooltip:AddLine(' ')
						-- For some reason I cannot figure out, this results in red text in the tooltip
						-- tooltip:AddLine(gsub(section, '^%l', string.upper))
						tooltip:AddLine(string.upper(strsub(section, 1, 1)) .. strsub(section, 2))
						labelShown = true
					end
					tooltip:AddDoubleLine(renderKeystoneLink(keystone.dungeonID, keystone.keystoneLevel, keystone.affixIDs, keystone.lootEligible, keystone.upgradeTypeID), playerLink(name))
				end
			end
		end
	end
	
	tooltip:AddLine(' ')
	
	for _, text in pairs(renderAffixes()) do
		tooltip:AddLine(text, nil, nil, nil, true)
	end
end

-- Turns out SendChatMessage() won't take formatting :(
--[[
local originalSendChatMessage = SendChatMessage
function SendChatMessage(msg, ...)
	if msg == 'keystone' or msg == 'key' then
		msg = renderKeystoneLink(getMyKeystone())
	end
	return originalSendChatMessage(msg, ...)
end
]]
