local addon = LibStub("AceAddon-3.0"):NewAddon("KeystoneQuery", "AceBucket-3.0", "AceComm-3.0", "AceEvent-3.0", "AceSerializer-3.0", "AceTimer-3.0")
local ldb = LibStub:GetLibrary("LibDataBroker-1.1")
local libCompress = LibStub:GetLibrary("LibCompress")
local AceGUI = LibStub:GetLibrary("AceGUI-3.0")

local version = GetAddOnMetadata('KeystoneQuery', 'Version')
local debugMode = false

local MYTHIC_KEYSTONE_ID = 138019
local BROADCAST_RATE = (debugMode and 1 or 15) * 60 -- seconds
local KEY_REQUEST_DELAY = 5 -- seconds
local ICON = 'Interface\\Icons\\INV_Relics_Hourglass'
local ADDON_PREFIX = 'KeystoneQuery2'
local LINK_COLORS = {'00ff00', 'ffff00', 'ff0000', 'a335ee'} -- Index is number of affixes + 1 on the keystone (thanks Lua for your brilliant 1-indexing)

-- http://www.wowhead.com/mythic-keystones-and-dungeons-guide#loot
local LOOT_ILVLS = {
   nil, -- LOOT_ILVLS[keystoneLevel * 2] is dungeon chest. LOOT_ILVLS[keystoneLevel * 2 + 1] is class hall chest

-- Dungeon Chest  Class Hall Chest  Keystone Level
        865,             nil,            -- 1
        870,             875,            -- 2
        870,             880,            -- 3
        875,             885,            -- 4
        875,             890,            -- 5
        880,             890,            -- 6
        880,             895,            -- 7
        885,             895,            -- 8
        885,             900,            -- 9
        890,             905,            -- 10
        890,             905,            -- 11
        890,             905,            -- 12
}

local ldbSource = LibStub("LibDataBroker-1.1"):NewDataObject("KeystoneQuery", {
	type = "data source",
	icon = ICON,
	label = "Keystone",
	title = "Keystone",
})

if LibDebug and debugMode then
	-- LibDebug replaces print(), which I don't want
	local realPrint = print
	LibDebug()
	getfenv(1).print = realPrint
end

function addon:log(fmt, ...)
	if debugMode then
		local txt = format(fmt, ...)
		if self.logFrame and self.logFrame:IsShown() then
			self:logFrameAppend(txt)
		else
			print("KeystoneQuery: " .. txt)
		end
	end
end

function addon:debug(fmt, ...)
	self:log("|TInterface\\Icons\\INV_Bijou_Red:16|t %s", format(fmt, ...))
end

function addon:setMyKeystone()
	self:log("Scanning for player's keystone")
	local name = nameWithRealm(UnitName('player'))

	local setLDBText = function(keystone)
		if keystone then
			ldbSource.text = ' ' .. self:renderKeystoneLink(keystone, true, self.settings.ldbText.showAffixes, self.settings.ldbText.showLootLvls)
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
				local originalLink = GetContainerItemLink(bag, slot)
				self:log("Player's keystone: %s -- %s", originalLink, gsub(originalLink, '|', '!'))
				local parts = { strsplit(':', originalLink) }

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

				NEW FORMAT:
				-- |cffa335ee|Hkeystone:209:7:1:6:3:0|h[Keystone: The Arcway]|h|r
				1: Color & ItemClass
				2: DungeonID
				3: Keystone Level
				4: NotDepleted
				5... Affixes

				|cffa335ee|Hkeystone:198:7:11:14:0!h[Keystone: Darkheart Thicket]|h|r
				1: Color & ItemClass
				2: DungeonID
				3: Keystone Level
				4... Affixes
				]]				

				local dungeonID = tonumber(parts[2])
				local keystoneLevel = tonumber(parts[3])
				local numAffixes = keystoneLevel < 4 and 0 or keystoneLevel < 7 and 1 or keystoneLevel < 10 and 2 or 3
				local affixIDs = {}
				for i = 0, numAffixes - 1 do
					tinsert(affixIDs, tonumber(parts[4 + i]))
				end
				local lootEligible = true

				local newKeystone = {dungeonID = dungeonID, keystoneLevel = keystoneLevel, affixIDs = affixIDs, lootEligible = lootEligible}
				local oldKeystone = self.myKeystones[name]
				local changed = (oldKeystone == nil or oldKeystone.keystoneLevel ~= newKeystone.keystoneLevel)

				self:log("%s", tostring(changed))

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
		wipe(self.myKeystones)
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

function addon:renderKeystoneLink(keystone, formatted, includeAffixes, includeLootLevel)
	-- Default to true
	formatted = (formatted ~= false)
	includeAffixes = (includeAffixes ~= false)
	includeLootLevel = (includeLootLevel ~= false)

	local dungeonName = C_ChallengeMode.GetMapInfo(keystone.dungeonID)
	local numAffixes = #keystone.affixIDs
	local link
	if formatted then
		local linkColor = keystone.lootEligible and LINK_COLORS[numAffixes + 1] or '999999'
		link = format("|TInterface\\Icons\\Achievement_PVP_A_%02d:16|t |cff%s|Hkeystone:%d:%d:%d:%d:%d:%d|h[%s +%d]|r", min(keystone.keystoneLevel, 15), linkColor, keystone.dungeonID, keystone.keystoneLevel, keystone.lootEligible and '1' or '0', keystone.affixIDs[1] or 0, keystone.affixIDs[2] or 0, keystone.affixIDs[3] or 0, dungeonName, keystone.keystoneLevel)
	else
		link = format("%s +%d", dungeonName, keystone.keystoneLevel)
	end
	if includeAffixes and numAffixes > 0 then
		local affixNames = {}
		for i, id in pairs(keystone.affixIDs) do
			local affixName, affixDesc = C_ChallengeMode.GetAffixInfo(id)
			if affixName ~= nil then
				tinsert(affixNames, strlower(affixName))
			end
		end
		link = format("%s (%s)", link, table.concat(affixNames, '/'))
	end
	if includeLootLevel then
		if keystone.lootEligible then
			link = format("%s (%d/%d)", link, LOOT_ILVLS[min(keystone.keystoneLevel * 2, #LOOT_ILVLS)], LOOT_ILVLS[min(keystone.keystoneLevel * 2 + 1, #LOOT_ILVLS)])
		else
			link = link .. " (depleted)"
		end
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
	-- Seems silly to have a dedicated section just for yourself; we'll say the player is their own friend (or in their own party, if in one)
	local party = GetHomePartyInfo()
	local name = nameWithRealm(UnitName('player'))
	if name == seek then return (party and 'party' or 'friend') end

	local keystone = self.keystones[seek]
	if keystone and keystone.isAlt then
		return 'alt'
	end

	if party then
		for _, name in pairs(party) do
			if nameWithRealm(name) == seek then return 'party' end
		end
	end

	for _, name in pairs(self:getFriendPlayerNames()) do
		if name == seek then return 'friend' end
	end

	return 'guild'
end

function addon:getFriendPlayerNames()
	local rtn = {}

	local selfRealm = GetRealmName()
	for i = 1, GetNumFriends() do
		local name, _, _, _, connected, _, _ = GetFriendInfo(i)
		if name and connected then
			tinsert(rtn, format("%s-%s", name, selfRealm))
			self:log("%s-%s", name, selfRealm)
		end
	end

	local selfFaction = UnitFactionGroup('player')
	for i = 1, BNGetNumFriends() do
		local presenceID, presenceName, battleTag, isBattleTagPresence, toonName, toonID, client, isOnline, lastOnline, isAFK, isDND, messageText, noteText, isRIDFriend, broadcastTime, canSoR = BNGetFriendInfo(i)
		if toonName then
			local unknown, toonName, client, realmName, realmID, faction, race, class, unknown, zoneName, level, gameText, broadcastText, broadcastTime, unknown, presenceID = BNGetGameAccountInfo(toonID)
			if faction == selfFaction and (realmName == selfRealm) then
				tinsert(rtn, format("%s-%s", toonName, realmName))
			end
		end
	end

	return rtn
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
	self:log("Sending keystones to %s %s", type, target or '')
	self:SendCommMessage(ADDON_PREFIX, 'keystone6:' .. self:networkEncode({version = version, guids = self.myGuids, keystones = self.myKeystones}), type, target)
end

function addon:onAceCommMsg(prefix, msg, channel, sender)
	if prefix == ADDON_PREFIX then
		self:receiveMessage(msg, channel, sender)
	end
end

function addon:receiveMessage(msg, channel, sender)
	-- Addon message format (v1-v4 are no longer supported):
	-- v5: keystone5:(Table serialized/compressed/encoded with Ace3, sent via AceComm)
	--   Table: 'guid' -> {name -> guid}, 'keystones' -> {name -> keystone}
	--     Keystone table keys: dungeonID, keystoneLevel, affixIDs, lootEligible, upgradeTypeID
	-- v6: Removed upgradeTypeID. Removed support for v5 since KeystoneQuery pre 2.11 is broken in 7.2 anyway

	sender = nameWithRealm(sender)

	-- A request for this user's keystone info
	if msg == 'keystone5?' then return end
	if msg == 'keystone6?' or (string.starts(msg, 'keystone') and string.ends(msg, '?')) then
		self:log('Received keystone v%s request from %s', strsub(msg, 9, 9), sender)
		if self.replyTimers[sender] then
			self:log('  reply already scheduled')
		else
			self:log('  scheduling reply')
			self.replyTimers[sender] = self:ScheduleTimer(function()
				self.replyTimers[sender] = nil
				self:sendKeystones('WHISPER', sender)
			end, KEY_REQUEST_DELAY)
		end
		return
	end

	-- Another user's keystone info
	local prefix = 'keystone6:'
	if string.starts(msg, prefix) then
		self:log('Received keystone v6 response from ' .. sender)
		self.versions[sender] = '? (v6)'
		local data = self:networkDecode(strsub(msg, strlen(prefix) + 1))
		if not data then
			return
		end
		--TODO Is there any way to determine if 'name' is actually a character controlled by 'sender'?
		if data.version then
			self.versions[sender] = data.version .. ' (v6)'
		end
		for name, guid in pairs(data.guids) do
			self.guids[name] = guid
			GetPlayerInfoByGUID(guid)
		end
		for name, keystone in pairs(data.keystones) do
			self:log('  Keystone for %s', name)
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
	local now = time()

	for name, keystone in pairs(self.keystones) do
		self.oldKeystones[name] = keystone
	end
	if IsInGroup(LE_PARTY_CATEGORY_HOME) then
		self:SendCommMessage(ADDON_PREFIX, 'keystone6?', 'PARTY')
	end
	if GetGuildInfo('player') then
		self:SendCommMessage(ADDON_PREFIX, 'keystone6?', 'GUILD')
	end
	for _, name in pairs(self:getFriendPlayerNames()) do
		self:SendCommMessage(ADDON_PREFIX, 'keystone6?', 'WHISPER', name)
	end

	-- Wait a little while, then purge old keystone entries that haven't received an update
	self:ScheduleTimer(function(refreshTime)
		for name, keystone in pairs(self.keystones) do
			local keep = false
			if keystone.hasKeystone then
				keep = (keystone.recordTime >= refreshTime)
			else
				-- Keep if any alts have a keystone we're going to keep
				for alt, _ in pairs(self.alts[name] or {}) do
					if self.keystones[alt] and self.keystones[alt].hasKeystone and self.keystones[alt].recordTime >= refreshTime then
						keep = true
					end
				end
			end
			if not keep then
				self:log("Purging old keystone (%s, %d < %d)", name, keystone.recordTime, refreshTime)
				self.keystones[name] = nil
			end
		end
	end, KEY_REQUEST_DELAY * 3, now)
end

function addon:broadcast()
	self:log("Broadcasting keystones")

	if IsInGroup(LE_PARTY_CATEGORY_HOME) then
		self:sendKeystones('PARTY')
	end

	if GetGuildInfo('player') then
		self:sendKeystones('GUILD')
	end

	for _, name in pairs(self:getFriendPlayerNames()) do
		self:sendKeystones('WHISPER', name)
	end
end

function addon:OnInitialize()
	self:log('Initializing')
	do
		self.logFrame = AceGUI:Create('Frame')
		self.logFrame.AceGUIWidgetVersion = 0 -- We mess with the frame's internals, so make it impossible for AceGUI to put it back in the object pool (not that we ever intend to release it anyway)
		if not debugMode then
			self.logFrame:Hide()
		end
		self.logFrame:SetTitle('Keystone Query - Debug Log')
		self.logFrame:SetPoint('TOPLEFT', 30, -150)
		self.logFrame:SetLayout('Flow')
		self.logFrame.frame:SetFrameStrata('LOW')
		self.logFrame:SetCallback('OnClose', function() debugMode = false end)

		local scrollContainer = AceGUI:Create('SimpleGroup')
		self.logFrame:AddChild(scrollContainer)
		scrollContainer:SetFullWidth(true)
		scrollContainer:SetFullHeight(true)
		scrollContainer:SetLayout('Fill')

		local logContent = AceGUI:Create('ScrollFrame')
		scrollContainer:AddChild(logContent)
		logContent:SetLayout('Flow')

		-- Get rid of the status bar
		self.logFrame.statustext:GetParent():Hide()

		-- Add buttons next to the close button
		local clearButton = CreateFrame('Button', nil, self.logFrame.frame, 'UIPanelButtonTemplate')
		clearButton:SetText('Clear')
		clearButton:SetScript('OnClick', function()
			logContent:ReleaseChildren()
		end)
		local markButton = CreateFrame('Button', nil, self.logFrame.frame, 'UIPanelButtonTemplate')
		markButton:SetText('Mark')
		markButton:SetScript('OnClick', function()
			local marker = AceGUI:Create('Icon')
			marker:SetImage('Interface\\Icons\\Ability_Hunter_MarkedForDeath')
			marker:SetImageSize(16, 16)
			marker:SetWidth(24)
			marker:SetHeight(24)
			logContent:AddChild(marker)
		end)
		-- The close button is at -27, 17
		local x, y = -27, 17
		for _, button in ipairs({clearButton, markButton}) do
			button:SetHeight(20)
			button:SetWidth(100)
			x = x - button:GetWidth()
			button:SetPoint('BOTTOMRIGHT', x, y)
		end

		self.logFrameAppend = function(_, txt)
			local l = AceGUI:Create('Label')
			l:SetText(format("|cffaaaaaa[%s]|r %s", date('%H:%M:%S'), txt))
			l:SetFullWidth(true)
			logContent:AddChild(l)
		end
	end

	self.guids = {}
	self.keystones = {}

	self.versions = {}
	self.alts = {}
	self.oldKeystones = {}
	self.myKeystoneOriginalLink = nil
	self.replyTimers = {}

	self.broadcastTimer = nil
	self.showedOutOfDateMessage = false

	local dbDefaults = {
		guids = {},
		keystones = {},
		settings = {
			ldbText = {
				showAffixes = true,
				showLootLvls = true,
			},
		},
	}
	self.db = LibStub('AceDB-3.0'):New('KeystoneQueryDB', {faction = dbDefaults}, true).faction
	self.myGuids = self.db.guids
	self.myKeystones = self.db.keystones
	self.settings = self.db.settings

	for name, guid in pairs(self.myGuids) do
		self.guids[name] = guid
	end

	self:RegisterBucketEvent('BAG_UPDATE', 2, 'onBagUpdate')
	--TODO Call setMyKeystone() when item is destroyed; not sure which event that is

	-- Need to special-case GROUP_ROSTER_UPDATE, so can't use RegisterBucketEvent
	--TODO Do I need to call GuildRoster() myself if GUILD_ROSTER_UPDATE hasn't happened in a while?
	-- self:RegisterBucketEvent({'GUILD_ROSTER_UPDATE', 'FRIENDLIST_UPDATE', 'GROUP_ROSTER_UPDATE', 'PARTY_MEMBER_ENABLE', 'CHALLENGE_MODE_START', 'CHALLENGE_MODE_RESET', 'CHALLENGE_MODE_COMPLETED'}, 2, 'refresh')
	do
		local refreshTimer = nil
		local function startRefreshTimer()
			self:log('  started the refresh timer')
			refreshTimer = self:ScheduleTimer(function()
				refreshTimer = nil
				self:refresh()
			end, 2)
		end
		local function updateOnlineList(len, getter, oldList)
			local newList = {}
			local changed = false
			for i = 1, len do
				local name, online = getter(i)
				if online then
					if not oldList[name] then
						self:log('  found new player online: %s', name)
						changed = true
					end
					newList[name] = true
				elseif oldList[name] then
					-- 'name' has signed off. Could just clear their data, but might as well request a refresh. The post-refresh cleanup will remove their entries
					-- Ignore events for the current user (you stay connected long enough to watch yourself sign off, oddly)
					if name ~= nameWithRealm(UnitName('player')) then
						changed = true
					end
				end
			end
			if changed and not refreshTimer then
				startRefreshTimer()
			end
			return newList
		end

		for _, eventName in ipairs({'GROUP_ROSTER_UPDATE', 'PARTY_MEMBER_ENABLE', 'BN_FRIEND_ACCOUNT_ONLINE', 'CHALLENGE_MODE_START', 'CHALLENGE_MODE_RESET', 'CHALLENGE_MODE_COMPLETED'}) do
			self:RegisterEvent(eventName, function()
				self:log('Event: %s', eventName)
				if refreshTimer == nil then
					startRefreshTimer()
				end
			end)
		end
		local guildList = {}
		self:RegisterEvent('GUILD_ROSTER_UPDATE', function()
			self:log('Event: GUILD_ROSTER_UPDATE')
			guildList = updateOnlineList(GetNumGuildMembers(), function(i)
				local name, _, _, _, _, _, _, _, online, _, _, _, _, _, _, _ = GetGuildRosterInfo(i)
				return name, online
			end, guildList)
		end)
		local friendList = {}
		self:RegisterEvent('FRIENDLIST_UPDATE', function()
			self:log('Event: FRIENDLIST_UPDATE')
			friendList = updateOnlineList(GetNumFriends(), function(i)
				local name, _, _, _, connected, _, _, _ = GetFriendInfo(i)
				return name, connected
			end, friendList)
		end)
	end

	self:RegisterComm(ADDON_PREFIX, 'onAceCommMsg')

	self:setMyKeystone()

	_G.SLASH_KeystoneQuery1 = '/keystone?'
	_G.SLASH_KeystoneQuery2 = '/key?'
	SlashCmdList['KeystoneQuery'] = function(cmd)
		-- Default looks up party (if in one) and guild
		if cmd == '' then
			self:showKeystones(nil, false)
		elseif cmd == 'party' or cmd == 'p' then
			if IsInGroup(LE_PARTY_CATEGORY_HOME) then
				self:showKeystones('party', true)
			else
				print("Not in a party")
			end
		elseif cmd == 'friends' or cmd == 'f' then
			self:showKeystones('friend', false)
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
				wipe(tbl)
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
			addon.logFrame:Hide()
			print("KeystoneQuery: debug mode disabled")
		elseif cmd == 'debug on' then
			debugMode = true
			print("KeystoneQuery: debug mode enabled")
		elseif cmd == 'debug log' then
			if addon.logFrame:IsShown() then
				addon.logFrame:Hide()
				debugMode = false
			else
				addon.logFrame:Show()
				debugMode = true
			end
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

local ldbConfigMenu = CreateFrame('Frame', 'KeystoneQueryConfigMenu')
ldbConfigMenu.displayMode = 'MENU'
ldbConfigMenu.initialize = function(self, level)
	local function setSetting(self, k, _, wasChecked)
		addon.settings.ldbText[k] = not wasChecked
		addon:setMyKeystone()
	end
	if level == 1 then
		UIDropDownMenu_AddButton({text = 'Data feed text', isTitle = true}, 1)
		UIDropDownMenu_AddButton({text = 'Show affixes', isNotRadio = true, checked = addon.settings.ldbText.showAffixes, func = setSetting, arg1 = 'showAffixes'}, 1)
		UIDropDownMenu_AddButton({text = 'Show loot ilvls', isNotRadio = true, checked = addon.settings.ldbText.showLootLvls, func = setSetting, arg1 = 'showLootLvls'}, 1)
	end
end

ldbSource.OnClick = function(frame, button)
	if button == 'LeftButton' and IsShiftKeyDown() then
		local editbox = DEFAULT_CHAT_FRAME.editBox
		if editbox then
			local link = renderKeystoneForChat(addon:getMyKeystone())
			editbox:Insert(link)
			-- editbox:Show() -- This doesn't seem to work; editbox:IsShown() is always true and this does nothing if called when the box isn't up
		end
	elseif button == 'RightButton' then
		GameTooltip:Hide()
		ToggleDropDownMenu(1, nil, ldbConfigMenu, frame, 0, 0)
	end
end

hooksecurefunc("ChatEdit_OnTextChanged", function(self, userInput)
	if userInput then
		local msg = self:GetText()
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
