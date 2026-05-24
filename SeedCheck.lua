local ADDON = "SeedCheck"
local CONSECRATION = "Consecration" -- matches all ranks by name
local SEED_OF_CORRUPTION = "Seed of Corruption"

local f = CreateFrame("Frame")

-- State
local tankPallyGUIDs = {}   -- [guid] = true
local warlockGUIDs   = {}   -- [guid] = true
local engagedMobs    = {}   -- [guid] = name (alive, in this pull)
local mobOrder       = {}   -- ordered list of GUIDs, for stable row display
local deadGUIDs      = {}   -- [guid] = true, to ignore lagged events after death
local calledOutSeed  = {}   -- [warlockGUID] = true, suppress duplicate callouts per pull
local pendingCallout = {}   -- [warlockGUID] = name, we plan to send unless preempted

local COMM_PREFIX = "SeedCheck"
local tickCount      = {}   -- [guid] = N
local mobsReady      = 0    -- count of engaged mobs that have hit threshold
local mobsTotal      = 0    -- size of engagedMobs
local announced      = false
local inCombat       = false

-- Defaults
local defaults = {
    threshold = 3,
    mobFontSize = 14,
    announceFontSize = 28,
    announceText = "Warlocks: SEED NOW",
    locked = true,
    sound = "default",
    callOutEarlySeed = true,
    enableSound = true,
    enableAnnounceText = true,
    groupByName = true,
}

local SOUNDS = {
    { key = "default",            label = "Default (Raid Warning)" },
    { key = "JurassicParkTheme",  label = "Jurassic Park Theme",  file = "Interface\\AddOns\\SeedCheck\\sound\\JurassicParkTheme.ogg" },
    { key = "Leeroy",             label = "Leeroy",               file = "Interface\\AddOns\\SeedCheck\\sound\\Leeroy.ogg" },
    { key = "YesYesBison",        label = "Yes Yes Bison",        file = "Interface\\AddOns\\SeedCheck\\sound\\YesYesBison.ogg" },
}

local function playSelectedSound()
    local key = (SeedCheckDB and SeedCheckDB.sound) or "default"
    for _, s in ipairs(SOUNDS) do
        if s.key == key then
            if s.file then
                local ok, handle = PlaySoundFile(s.file, "Master")
                if DEBUG then
                    DEFAULT_CHAT_FRAME:AddMessage(("|cffff7777[SC]|r PlaySoundFile path=%s ok=%s handle=%s"):format(s.file, tostring(ok), tostring(handle)))
                end
            else
                PlaySound(8959)
            end
            return
        end
    end
    PlaySound(8959)
end

local function getThreshold()
    return (SeedCheckDB and SeedCheckDB.threshold) or defaults.threshold
end

local raidMemberGUIDs = {} -- [guid] = true, rebuilt on roster refresh

local function isRaidUnit(guid)
    return guid and raidMemberGUIDs[guid] or false
end

local function isPlayerGUID(guid)
    if not guid then return false end
    return guid:sub(1, 7) == "Player-"
end

local function isMobGUID(guid)
    if not guid then return false end
    return guid:sub(1, 9) == "Creature-"
end

local function refreshRoster()
    wipe(tankPallyGUIDs)
    wipe(warlockGUIDs)
    wipe(raidMemberGUIDs)

    if IsInRaid() then
        local n = GetNumGroupMembers()
        local allPallies, mtPallies = {}, {}
        for i = 1, n do
            local _, _, _, _, _, fileName, _, _, _, role = GetRaidRosterInfo(i)
            local unit = "raid"..i
            local guid = UnitGUID(unit)
            if guid then
                raidMemberGUIDs[guid] = true
                if fileName == "PALADIN" then
                    allPallies[guid] = true
                    if role == "MAINTANK" then mtPallies[guid] = true end
                end
                if fileName == "WARLOCK" then
                    warlockGUIDs[guid] = true
                end
            end
        end
        -- Prefer MT-flagged pallies; if none flagged, fall back to all
        local source = next(mtPallies) and mtPallies or allPallies
        for g in pairs(source) do tankPallyGUIDs[g] = true end
    else
        local units = { "player" }
        local n = GetNumGroupMembers()
        for i = 1, n - 1 do units[#units+1] = "party"..i end
        for _, unit in ipairs(units) do
            local _, class = UnitClass(unit)
            local guid = UnitGUID(unit)
            if guid then
                raidMemberGUIDs[guid] = true
                if class == "WARLOCK" then warlockGUIDs[guid] = true end
                -- No MT flag in party — treat any paladin as a tank pally
                if class == "PALADIN" then tankPallyGUIDs[guid] = true end
            end
        end
    end
end

-- Custom announce frame (forward-declared; built below)
local announceFrame, announceFS, announceAnim
local function announce(msg)
    if SeedCheckDB.enableAnnounceText ~= false then
        if announceFS then
            announceFS:SetText(msg)
            announceFrame:Show()
            announceFrame:SetAlpha(1)
            if announceAnim then announceAnim:Stop(); announceAnim:Play() end
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[SeedCheck]|r "..msg)
        end
    end
    if SeedCheckDB.enableSound ~= false then
        playSelectedSound()
    end
end

-- forward decls for UI funcs
local UI_Refresh, UI_Show, UI_Hide

local function resetPull()
    wipe(engagedMobs)
    wipe(mobOrder)
    wipe(tickCount)
    wipe(deadGUIDs)
    wipe(calledOutSeed)
    wipe(pendingCallout)
    mobsReady = 0
    mobsTotal = 0
    announced = false
    if UI_Refresh then UI_Refresh() end
end

local function markEngaged(guid, name)
    if not guid then return end
    if isPlayerGUID(guid) then return end
    if deadGUIDs[guid] then return end
    if engagedMobs[guid] then return end
    engagedMobs[guid] = name or UNKNOWN or "Unknown"
    table.insert(mobOrder, guid)
    mobsTotal = mobsTotal + 1
    tickCount[guid] = tickCount[guid] or 0
    if UI_Refresh then UI_Refresh() end
end

local function checkAnnounce()
    if announced then return end
    if mobsTotal == 0 then return end
    if mobsReady >= mobsTotal then
        announced = true
        announce("Warlocks: SEED NOW")
    end
end

local DEBUG = false
local function dprint(...)
    if DEBUG then DEFAULT_CHAT_FRAME:AddMessage("|cffff7777[SC]|r "..table.concat({tostringall(...)}, " ")) end
end

local HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE or 0x00000040

local function onCLEU(_, event, _, sourceGUID, sourceName, sourceFlags, _, destGUID, destName, destFlags, _, ...)
    if not inCombat then return end
    if DEBUG and event:match("DAMAGE") then
        dprint(event, "src=", tostring(sourceName), "dst=", tostring(destName), "srcRaid=", tostring(isRaidUnit(sourceGUID)), "dstRaid=", tostring(isRaidUnit(destGUID)))
    end

    if event == "UNIT_DIED" or event == "UNIT_DESTROYED" or event == "PARTY_KILL" then
        if engagedMobs[destGUID] then
            engagedMobs[destGUID] = nil
            mobsTotal = mobsTotal - 1
            if tickCount[destGUID] and tickCount[destGUID] >= getThreshold() then
                mobsReady = mobsReady - 1
            end
            tickCount[destGUID] = nil
            for i, g in ipairs(mobOrder) do
                if g == destGUID then table.remove(mobOrder, i); break end
            end
            deadGUIDs[destGUID] = true
            if UI_Refresh then UI_Refresh() end
            checkAnnounce()
        end
        return
    end

    -- Engagement detection: raid hits mob, or mob hits raid
    local srcIsRaid = isRaidUnit(sourceGUID)
    local dstIsRaid = isRaidUnit(destGUID)

    local destHostile = destFlags and bit.band(destFlags, HOSTILE) ~= 0
    local srcHostile  = sourceFlags and bit.band(sourceFlags, HOSTILE) ~= 0

    if srcIsRaid and isMobGUID(destGUID) and destName and destHostile then
        markEngaged(destGUID, destName)
    elseif dstIsRaid and isMobGUID(sourceGUID) and sourceName and srcHostile then
        markEngaged(sourceGUID, sourceName)
    end

    -- Warlock cast Seed: if not all mobs are ready, call them out
    if event == "SPELL_CAST_SUCCESS" and warlockGUIDs[sourceGUID] then
        local spellId, spellName = ...
        if spellName == SEED_OF_CORRUPTION
           and not announced
           and SeedCheckDB.callOutEarlySeed
           and not calledOutSeed[sourceGUID]
        then
            calledOutSeed[sourceGUID] = true
            local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
            if channel then
                local msg = ("%s cast Seed early (%d/%d mobs ready)"):format(
                    sourceName or "Someone", mobsReady, mobsTotal)
                pendingCallout[sourceGUID] = msg
                -- Tell other installed clients we're handling this one
                local send = C_ChatInfo and C_ChatInfo.SendAddonMessage or SendAddonMessage
                send(COMM_PREFIX, "CLAIM:"..sourceGUID, channel)
                -- Small random delay so the lowest-latency client's CLAIM lands first;
                -- anyone whose CLAIM was preempted will have cleared pendingCallout.
                local delay = 0.2 + math.random() * 0.4
                C_Timer.After(delay, function()
                    if pendingCallout[sourceGUID] then
                        SendChatMessage(pendingCallout[sourceGUID], channel)
                        pendingCallout[sourceGUID] = nil
                    end
                end)
            end
        end
    end

    -- Consecration tick from a tank paladin
    if (event == "SPELL_PERIODIC_DAMAGE" or event == "SPELL_DAMAGE") and tankPallyGUIDs[sourceGUID] then
        local spellId, spellName = ...
        if spellName == CONSECRATION and engagedMobs[destGUID] then
            local threshold = getThreshold()
            local cur = tickCount[destGUID] or 0
            if cur < threshold then
                cur = cur + 1
                tickCount[destGUID] = cur
                if cur == threshold then
                    mobsReady = mobsReady + 1
                    checkAnnounce()
                end
                if UI_Refresh then UI_Refresh() end
            end
        end
    end
end

-----------------------------------------------------------
-- UI: backgroundless list of engaged mobs and their ticks
-----------------------------------------------------------
local ui = CreateFrame("Frame", "SeedCheckUI", UIParent)
ui:SetSize(220, 20)
ui:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
ui:SetMovable(true)
ui:EnableMouse(true)
ui:RegisterForDrag("LeftButton")
ui:SetScript("OnDragStart", ui.StartMoving)
ui:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    SeedCheckDB = SeedCheckDB or {}
    SeedCheckDB.pos = { point = point, relPoint = relPoint, x = x, y = y }
end)
ui:Hide()

local header = ui:CreateFontString(nil, "OVERLAY", "GameFontNormal")
header:SetPoint("TOPLEFT", ui, "TOPLEFT", 0, 0)
header:SetText("SeedCheck")
header:SetTextColor(0.8, 0.8, 0.8)

local rows = {}
local function getRow(i)
    if rows[i] then return rows[i] end
    local fs = ui:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", ui, "TOPLEFT", 0, -16 * i)
    fs:SetJustifyH("LEFT")
    rows[i] = fs
    return fs
end

UI_Show = function() ui:Show() end
UI_Hide = function() ui:Hide() end

UI_Refresh = function()
    if mobsTotal == 0 then
        for _, fs in ipairs(rows) do fs:SetText("") end
        ui:SetHeight(20)
        return
    end
    local threshold = getThreshold()
    local n = 0

    if SeedCheckDB and SeedCheckDB.groupByName ~= false then
        -- Group by name: one row per unique name, show min tick count and (count)
        local order, groups = {}, {} -- order: array of names; groups[name] = { count, minTick }
        for _, guid in ipairs(mobOrder) do
            local name = engagedMobs[guid] or "?"
            local cur = tickCount[guid] or 0
            local g = groups[name]
            if not g then
                g = { count = 0, minTick = cur }
                groups[name] = g
                order[#order+1] = name
            end
            g.count = g.count + 1
            if cur < g.minTick then g.minTick = cur end
        end
        for i, name in ipairs(order) do
            local g = groups[name]
            local fs = getRow(i)
            if g.count > 1 then
                fs:SetText(("%s (%d)  %d/%d"):format(name, g.count, g.minTick, threshold))
            else
                fs:SetText(("%s  %d/%d"):format(name, g.minTick, threshold))
            end
            if g.minTick >= threshold then
                fs:SetTextColor(0.2, 1.0, 0.2)
            else
                fs:SetTextColor(1.0, 0.82, 0.0)
            end
            n = i
        end
    else
        for i, guid in ipairs(mobOrder) do
            local name = engagedMobs[guid] or "?"
            local cur = tickCount[guid] or 0
            local fs = getRow(i)
            fs:SetText(("%s  %d/%d"):format(name, cur, threshold))
            if cur >= threshold then
                fs:SetTextColor(0.2, 1.0, 0.2)
            else
                fs:SetTextColor(1.0, 0.82, 0.0)
            end
            n = i
        end
    end

    for i = n + 1, #rows do rows[i]:SetText("") end
    ui:SetHeight(20 + n * 16)
end

local function restorePos()
    local p = SeedCheckDB and SeedCheckDB.pos
    if p then
        ui:ClearAllPoints()
        ui:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
    end
    local a = SeedCheckDB and SeedCheckDB.announcePos
    if a and announceFrame then
        announceFrame:ClearAllPoints()
        announceFrame:SetPoint(a.point, UIParent, a.relPoint, a.x, a.y)
    end
end

-----------------------------------------------------------
-- Announcement frame
-----------------------------------------------------------
announceFrame = CreateFrame("Frame", "SeedCheckAnnounce", UIParent)
announceFrame:SetSize(500, 60)
announceFrame:SetPoint("TOP", UIParent, "TOP", 0, -200)
announceFrame:SetMovable(true)
announceFrame:RegisterForDrag("LeftButton")
announceFrame:SetScript("OnDragStart", announceFrame.StartMoving)
announceFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    SeedCheckDB.announcePos = { point = point, relPoint = relPoint, x = x, y = y }
end)
announceFrame:Hide()

announceFS = announceFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
announceFS:SetAllPoints()
announceFS:SetJustifyH("CENTER")
announceFS:SetTextColor(1, 0.2, 0.2)

announceAnim = announceFrame:CreateAnimationGroup()
local fade = announceAnim:CreateAnimation("Alpha")
fade:SetFromAlpha(1); fade:SetToAlpha(0); fade:SetDuration(1); fade:SetStartDelay(3)
announceAnim:SetScript("OnFinished", function() announceFrame:Hide() end)

-----------------------------------------------------------
-- Apply font sizes + lock/unlock
-----------------------------------------------------------
local function applyFonts()
    local mobSize = (SeedCheckDB and SeedCheckDB.mobFontSize) or defaults.mobFontSize
    local annSize = (SeedCheckDB and SeedCheckDB.announceFontSize) or defaults.announceFontSize
    local fontPath = GameFontNormal:GetFont()
    for _, fs in ipairs(rows) do
        fs:SetFont(fontPath, mobSize, "OUTLINE")
    end
    header:SetFont(fontPath, mobSize - 2, "OUTLINE")
    announceFS:SetFont(fontPath, annSize, "OUTLINE")
    ui:SetWidth(math.max(220, mobSize * 14))
    announceFrame:SetWidth(math.max(400, annSize * 16))
end

local lockTex
local function setLocked(locked)
    SeedCheckDB.locked = locked
    if locked then
        ui:EnableMouse(false)
        announceFrame:EnableMouse(false)
        if lockTex then lockTex:Hide() end
        if announceFrame:IsShown() and announceFS:GetText() == defaults.announceText.." (preview)" then
            announceFrame:Hide()
        end
    else
        ui:EnableMouse(true)
        announceFrame:EnableMouse(true)
        if not lockTex then
            lockTex = ui:CreateTexture(nil, "BACKGROUND")
            lockTex:SetAllPoints()
            lockTex:SetColorTexture(0, 1, 0, 0.15)
            local lockTex2 = announceFrame:CreateTexture(nil, "BACKGROUND")
            lockTex2:SetAllPoints()
            lockTex2:SetColorTexture(0, 1, 0, 0.15)
            lockTex.other = lockTex2
        end
        lockTex:Show(); if lockTex.other then lockTex.other:Show() end
        -- preview content so user sees what they're dragging
        if mobsTotal == 0 then
            UI_Show()
            getRow(1):SetText("Mob A  3/3"); rows[1]:SetTextColor(0.2, 1, 0.2)
            getRow(2):SetText("Mob B  1/3"); rows[2]:SetTextColor(1, 0.82, 0)
            ui:SetHeight(20 + 2 * 16)
        end
        announceFS:SetText(defaults.announceText.." (preview)")
        announceFrame:Show()
        announceFrame:SetAlpha(1)
    end
end

-----------------------------------------------------------
-- Options panel (Interface > AddOns)
-----------------------------------------------------------
local function buildOptionsPanel()
    local panel = CreateFrame("Frame", "SeedCheckOptionsPanel", UIParent)
    panel.name = "SeedCheck"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("SeedCheck")

    local function makeSlider(label, key, min, max, step, y)
        local s = CreateFrame("Slider", "SeedCheck"..key.."Slider", panel, "OptionsSliderTemplate")
        s:SetPoint("TOPLEFT", 16, y)
        s:SetWidth(220); s:SetMinMaxValues(min, max); s:SetValueStep(step); s:SetObeyStepOnDrag(true)
        _G[s:GetName().."Low"]:SetText(min)
        _G[s:GetName().."High"]:SetText(max)
        _G[s:GetName().."Text"]:SetText(label)
        s:SetValue(SeedCheckDB[key] or defaults[key])
        local val = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        val:SetPoint("LEFT", s, "RIGHT", 12, 0)
        val:SetText(tostring(SeedCheckDB[key] or defaults[key]))
        s:SetScript("OnValueChanged", function(self, v)
            v = math.floor(v + 0.5)
            SeedCheckDB[key] = v
            val:SetText(tostring(v))
            applyFonts()
            UI_Refresh()
        end)
        return s
    end

    makeSlider("Mob list font size", "mobFontSize", 8, 28, 1, -50)
    makeSlider("Announcement font size", "announceFontSize", 14, 60, 1, -90)
    makeSlider("Tick threshold", "threshold", 1, 8, 1, -130)

    local soundLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    soundLabel:SetPoint("TOPLEFT", 16, -170)
    soundLabel:SetText("Announcement sound")

    local dd = CreateFrame("Frame", "SeedCheckSoundDropdown", panel, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", 0, -185)
    local function currentLabel()
        for _, s in ipairs(SOUNDS) do
            if s.key == (SeedCheckDB.sound or "default") then return s.label end
        end
        return SOUNDS[1].label
    end
    UIDropDownMenu_SetWidth(dd, 200)
    UIDropDownMenu_SetText(dd, currentLabel())
    UIDropDownMenu_Initialize(dd, function(self, level)
        for _, s in ipairs(SOUNDS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = s.label
            info.func = function()
                SeedCheckDB.sound = s.key
                UIDropDownMenu_SetText(dd, s.label)
                playSelectedSound()
            end
            info.checked = (SeedCheckDB.sound or "default") == s.key
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    local function makeCheckbox(name, key, label, y)
        local cb = CreateFrame("CheckButton", "SeedCheck"..name.."CB", panel, "InterfaceOptionsCheckButtonTemplate")
        cb:SetPoint("TOPLEFT", 16, y)
        cb.Text:SetText(label)
        cb:SetChecked(SeedCheckDB[key] ~= false)
        cb:SetScript("OnClick", function(self)
            SeedCheckDB[key] = self:GetChecked() and true or false
        end)
        return cb
    end

    makeCheckbox("AnnounceText", "enableAnnounceText", "Show on-screen announcement",          -225)
    makeCheckbox("Sound",        "enableSound",        "Play announcement sound",              -250)
    makeCheckbox("CallOut",      "callOutEarlySeed",   "Announce in raid chat if a warlock casts Seed early", -275)
    local groupCB = makeCheckbox("Group", "groupByName", "Group mobs by name in list",         -300)
    groupCB:HookScript("OnClick", function() UI_Refresh() end)

    local unlockBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    unlockBtn:SetSize(140, 22)
    unlockBtn:SetPoint("TOPLEFT", 16, -335)
    local function refreshBtn()
        unlockBtn:SetText(SeedCheckDB.locked and "Unlock frames" or "Lock frames")
    end
    unlockBtn:SetScript("OnClick", function()
        setLocked(not SeedCheckDB.locked)
        refreshBtn()
    end)
    refreshBtn()

    local testBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    testBtn:SetSize(140, 22)
    testBtn:SetPoint("LEFT", unlockBtn, "RIGHT", 8, 0)
    testBtn:SetText("Test announce")
    testBtn:SetScript("OnClick", function() announce(defaults.announceText.." (test)") end)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, "SeedCheck")
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

f:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON then
            SeedCheckDB = SeedCheckDB or {}
            for k, v in pairs(defaults) do
                if SeedCheckDB[k] == nil then SeedCheckDB[k] = v end
            end
        end
    elseif event == "PLAYER_LOGIN" then
        refreshRoster()
        restorePos()
        applyFonts()
        buildOptionsPanel()
        setLocked(SeedCheckDB.locked ~= false)
    elseif event == "GROUP_ROSTER_UPDATE" then
        refreshRoster()
    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        resetPull()
        refreshRoster()
        UI_Show()
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        resetPull()
        UI_Hide()
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        onCLEU(CombatLogGetCurrentEventInfo())
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, _, sender = ...
        if prefix == COMM_PREFIX and sender ~= (UnitName("player")) then
            local guid = message:match("^CLAIM:(.+)$")
            if guid then
                -- Someone else already claimed this callout — stand down
                pendingCallout[guid] = nil
                calledOutSeed[guid] = true
            end
        end
    end
end)

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
f:RegisterEvent("CHAT_MSG_ADDON")

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(COMM_PREFIX)
elseif RegisterAddonMessagePrefix then
    RegisterAddonMessagePrefix(COMM_PREFIX)
end

SLASH_SEEDCHECK1 = "/seedcheck"
SlashCmdList["SEEDCHECK"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "config" or msg == "options" then
        if Settings and Settings.OpenToCategory then
            Settings.OpenToCategory("SeedCheck")
        elseif InterfaceOptionsFrame_OpenToCategory then
            InterfaceOptionsFrame_OpenToCategory("SeedCheck")
            InterfaceOptionsFrame_OpenToCategory("SeedCheck") -- twice: known Blizzard bug
        end
        return
    end
    if msg == "" or msg == "status" then
        DEFAULT_CHAT_FRAME:AddMessage(("|cff33ff99[SeedCheck]|r threshold=%d, tanks=%d, locks=%d, mobs=%d, ready=%d"):format(
            getThreshold(),
            (function() local c=0; for _ in pairs(tankPallyGUIDs) do c=c+1 end; return c end)(),
            (function() local c=0; for _ in pairs(warlockGUIDs)   do c=c+1 end; return c end)(),
            mobsTotal, mobsReady))
    elseif msg == "test" then
        announce("Warlocks: SEED NOW (test)")
    elseif msg == "show" then
        -- Drop in two fake mobs so you can position the frame
        markEngaged("Creature-0-0-0-0-00001-0000000001", "Dummy A")
        markEngaged("Creature-0-0-0-0-00001-0000000002", "Dummy B")
        tickCount["Creature-0-0-0-0-00001-0000000001"] = getThreshold()
        tickCount["Creature-0-0-0-0-00001-0000000002"] = math.max(0, getThreshold() - 1)
        UI_Show(); UI_Refresh()
    elseif msg == "hide" then
        resetPull(); UI_Hide()
    elseif msg == "debug" then
        DEBUG = not DEBUG
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[SeedCheck]|r debug = "..tostring(DEBUG))
    elseif msg == "pallies" then
        local n = 0
        for g in pairs(tankPallyGUIDs) do
            n = n + 1
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[SeedCheck]|r tank pally: "..g)
        end
        DEFAULT_CHAT_FRAME:AddMessage(("|cff33ff99[SeedCheck]|r %d tank pally GUID(s)"):format(n))
    elseif msg == "roster" then
        DEFAULT_CHAT_FRAME:AddMessage(("|cff33ff99[SeedCheck]|r playerGUID=%s in raidSet=%s"):format(
            tostring(UnitGUID("player")), tostring(raidMemberGUIDs[UnitGUID("player")])))
    elseif msg:match("^%d+$") then
        SeedCheckDB.threshold = tonumber(msg)
        DEFAULT_CHAT_FRAME:AddMessage(("|cff33ff99[SeedCheck]|r threshold set to %d"):format(SeedCheckDB.threshold))
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[SeedCheck]|r usage: /seedcheck [status|test|<N>]")
    end
end
