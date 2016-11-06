local function getMyKeystone()
	-- GetItemInfo() returns generic info, not info about the player's particular keystone
	-- name, link, quality, iLevel, reqLevel, class, subclass, maxStack, equipSlot, texture, vendorPrice = GetItemInfo(138019)
	
	-- The best way I could find was to scan the player's bags until a keystone is found, and then rip the info out of the item link
	for bag = 0, NUM_BAG_SLOTS do
		for slot = 1, GetContainerNumSlots(bag) do
			if(GetContainerItemID(bag, slot) == 138019) then
				originalLink = GetContainerItemLink(bag, slot)
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
				numAffixes = ({[4587520] = 0, [5111808] = 1, [6160384] = 2, [4063232] = 3})[upgradeTypeID]
				dungeonID = tonumber(parts[15])
				keystoneLevel = tonumber(parts[16])
				affixIDs = {}
				for i = 0, numAffixes - 1 do
					tinsert(affixIDs, tonumber(parts[17 + i]))
				end
				lootEligible = (tonumber(parts[17 + numAffixes]) == 1)
				return dungeonID, keystoneLevel, affixIDs, lootEligible
			end
		end
	end
end

local function renderKeystoneLink(dungeonID, keystoneLevel, affixIDs, lootEligible)
	dungeonName = C_ChallengeMode.GetMapInfo(dungeonID)
	numAffixes = #affixIDs
	linkColor = ({[0] = '00ff00', [1] = 'ffff00', [2] = 'ff0000', [3] = 'a335ee'})[numAffixes]
	if not lootEligible then
		linkColor = '999999'
	end
	originalLinkSubstring = strsub(originalLink, 11, strfind(originalLink, '|h') - 1)
	link = format("|TInterface\\Icons\\Achievement_PVP_A_%02d:16|t |cff%s%s|h[%s +%d]|r", keystoneLevel, linkColor, originalLinkSubstring, dungeonName, keystoneLevel)
	if numAffixes > 0 then
		affixNames = {}
		for i, id in ipairs(affixIDs) do
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

local function eventHandler(self, event, prefix, msg, channel, sender)
	-- Keystone data going over the network is encoded as: dungeonID:keystoneLevel:affixID,affixID,affixID:lootEligible

	if event == 'CHAT_MSG_ADDON' and prefix == 'KeystoneQuery' then
		-- A request for this user's keystone info
		if msg == 'keystone1?' then
			dungeonID, keystoneLevel, affixIDs, lootEligible = getMyKeystone()
			SendAddonMessage("KeystoneQuery", format("keystone1:%d:%d:%s:%d", dungeonID or 0, keystoneLevel or 0, table.concat(affixIDs or {}, ','), lootEligible and 1 or 0), "WHISPER", sender)
			return
		end

		-- Another user's keystone info (which we may or may not have asked for, but print either way)
		prefix = 'keystone1:'
		if strsub(msg, 1, strlen(prefix)) == prefix then
			_, dungeonID, keystoneLevel, affixIDs, lootEligible = strsplit(':', msg)
			playerLink = format('|Hplayer:%s:0|h%s|h', sender, gsub(sender, format("-%s$", GetRealmName()), ''))
			if tonumber(dungeonID) == 0 then
				print(playerLink .. " doesn't have a keystone")
			else
				affixIDs = { strsplit(',', affixIDs) }
				for k, v in ipairs(affixIDs) do
					affixIDs[k] = tonumber(v)
				end
				print(playerLink .. ' has ' .. renderKeystoneLink(tonumber(dungeonID), tonumber(keystoneLevel), affixIDs, (lootEligible == '1')))
			end
			return
		end

		print('Keystone Query: Unrecognized message received from another user. Is this version out of date?')
	end
end

local keystoneQueryFrame = CreateFrame('Frame', 'KeystoneQueryFrame')
keystoneQueryFrame:RegisterEvent('CHAT_MSG_ADDON')
keystoneQueryFrame:SetScript('OnEvent', eventHandler)
RegisterAddonMessagePrefix('KeystoneQuery')

SLASH_KeystoneQuery1 = '/keystone?'
SLASH_KeystoneQuery2 = '/key?'
SlashCmdList['KeystoneQuery'] = function(who)
	-- Default sends to party if in one, else guild
	icon = '|TInterface\\Icons\\INV_Misc_Key_14:16|t'
	if who == 'party' or who == 'p' or (who == '' and UnitInParty('player')) then
		print(icon .. ' Keystones in party:')
		SendAddonMessage('KeystoneQuery', 'keystone1?', 'PARTY')
	elseif who == 'guild' or who == 'g' or who == '' then
		print(icon .. ' Keystones in guild:')
		SendAddonMessage('KeystoneQuery', 'keystone1?', 'GUILD')
	elseif tonumber(who) then
		_, channelName, _ = GetChannelName(who)
		print(icon .. ' Keystones in #' .. channelName .. ':')
		SendAddonMessage('KeystoneQuery', 'keystone1?', 'CHANNEL', who)
	elseif strsub(who, 1, 1) == '#' then
		-- This function is very poorly named
		channelID, channelName, _ = GetChannelName(strsub(who, 2))
		print(icon .. ' Keystones in #' .. channelName .. ':')
		SendAddonMessage('KeystoneQuery', 'keystone1?', 'CHANNEL', channelID)
	else
		print(icon .. ' ' .. who .. "'s keystone:")
		SendAddonMessage('KeystoneQuery', 'keystone1?', 'WHISPER', who)
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
