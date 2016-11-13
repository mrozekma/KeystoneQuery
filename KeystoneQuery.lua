local myAddon = LibStub("AceAddon-3.0"):NewAddon("KeystoneQuery", "AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
local libCompress = LibStub:GetLibrary("LibCompress")

local MYTHIC_KEYSTONE_ID = 138019
local REFRESH_RATE = 10 * 60 -- seconds
local ICON = 'Interface\\Icons\\INV_Relics_Hourglass'
local ADDON_PREFIX = 'KeystoneQueryDev'

local debugMode = false
local function log(fmt, ...)
	if(debugMode) then
		printf("KeystoneQuery: " .. fmt, ...)
	end
end

local keystones = {}
local updateTimer = nil


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
	linkColor = ({[0] = '00ff00', [1] = 'ffff00', [2] = 'ff0000', [3] = 'a335ee'})[numAffixes]
	if not lootEligible then
		linkColor = '999999'
	end
	originalLinkSubstring = strsub(originalLink, 11, strfind(originalLink, '|h') - 1)
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

local function showPartyKeystones()
	party = GetHomePartyInfo()
	if party then
		party = table.flip(party)
		for name, _ in table.pairsByKeys(party) do
			keystone = keystones[name]
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

local function showGuildKeystones()
	-- This doesn't actually check for people in the guild, it just shows all known keystones from people not in the party
	party = table.flip(GetHomePartyInfo() or {})
	for name, keystone in table.pairsByKeys(keystones) do
		if keystone.hasKeystone and party[name] == nil then
			printf("%s has %s", playerLink(name), renderKeystoneLink(keystone.dungeonID, keystone.keystoneLevel, keystone.affixIDs, keystone.lootEligible, keystone.upgradeTypeID))
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
		dungeonID, keystoneLevel, affixIDs, lootEligible, upgradeTypeID = getMyKeystone()
		-- Ideally we would reconstruct the link on the other end without the need for upgradeTypeID, but I can't figure it out in all cases yet, I'm producing bad links for high-level keystones
		data = self:networkEncode({dungeonID = dungeonID, keystoneLevel = keystoneLevel, affixIDs = affixIDs, lootEligible = lootEligible, upgradeTypeID = upgradeTypeID})
		SendAddonMessage(ADDON_PREFIX, 'keystone2:' .. data, "WHISPER", sender)
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
	
	print('Keystone Query: Unrecognized message received from another user. Is this version out of date?')
end

function myAddon:startTimer()
	if updateTimer ~= nil then
		self:CancelTimer(updateTimer)
	end
	updateTimer = self:ScheduleRepeatingTimer('refresh', REFRESH_RATE)
	self:refresh()
end

function myAddon:refresh()
	log("Refreshing keystone list")
	keystones = {}
	SendAddonMessage(ADDON_PREFIX, 'keystone2?', 'PARTY')
	SendAddonMessage(ADDON_PREFIX, 'keystone2?', 'GUILD')
end

function myAddon:OnInitialize()
	self:RegisterEvent('CHAT_MSG_ADDON', 'onAddonMsg')
	RegisterAddonMessagePrefix(ADDON_PREFIX)

	SLASH_KeystoneQuery1 = '/keystone?'
	SLASH_KeystoneQuery2 = '/key?'
	SlashCmdList['KeystoneQuery'] = function(cmd)
		-- Default looks up party if in one, else guild
		icon = '|TInterface\\Icons\\INV_Misc_Key_14:16|t'
		if cmd == 'party' or cmd == 'p' or (cmd == '' and UnitInParty('player')) then
			printf("|T%s:16|t Keystones in party:", ICON)
			showPartyKeystones()
		elseif cmd == 'guild' or cmd == 'g' or cmd == '' then
			printf("|T%s:16|t Keystones in guild:", ICON)
			showGuildKeystones()
		else
			--TODO
		end
	end
end

function myAddon:OnEnable()
	self:startTimer()
end

function myAddon:OnDisable()
	self:CancelTimer(updateTimer)
	updateTimer = nil
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
