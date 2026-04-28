-- BearChad: TBC druid bear tank helper.
-- Rotation priority, debuff/stack/CD trackers, rage cap & clearcast cues.

local ADDON = "BearChad"
local _, class = UnitClass("player")
if class ~= "DRUID" then return end

----------------------------------------------------------------------
-- Spell IDs / names. TBC uses localized names for most APIs, so we
-- keep names; IDs are kept for reference / SpellID-based events.
----------------------------------------------------------------------
local S = {
    Mangle      = GetSpellInfo(33878) or "Mangle (Bear)",
    Lacerate    = GetSpellInfo(33745) or "Lacerate",
    Maul        = GetSpellInfo(6807)  or "Maul",
    Swipe       = GetSpellInfo(779)   or "Swipe (Bear)",
    FFF         = GetSpellInfo(16857) or "Faerie Fire (Feral)",
    DemoRoar    = GetSpellInfo(99)    or "Demoralizing Roar",
    Enrage      = GetSpellInfo(5229)  or "Enrage",
    Barkskin    = GetSpellInfo(22812) or "Barkskin",
    FrenziedReg = GetSpellInfo(22842) or "Frenzied Regeneration",
    Growl       = GetSpellInfo(6795)  or "Growl",
    Bash        = GetSpellInfo(8983)  or "Bash",
    ChalRoar    = GetSpellInfo(5209)  or "Challenging Roar",
    BearForm    = GetSpellInfo(9634)  or "Dire Bear Form",
    Clearcast   = GetSpellInfo(16870) or "Clearcasting",
    MotW        = GetSpellInfo(26990) or "Mark of the Wild",
    Thorns      = GetSpellInfo(26992) or "Thorns",
    OoC         = GetSpellInfo(16864) or "Omen of Clarity",
}

local LACERATE_DURATION = 15  -- seconds
local LACERATE_REFRESH  = 4   -- refresh when <=4s left
local MANGLE_REFRESH    = 2   -- pre-cast inside last 2s
local FFF_REFRESH       = 3   -- refresh FFF debuff (40s) when <=3s left
local RAGE_MAUL_ST      = 50  -- queue Maul in ST when rage >= this
local RAGE_MAUL_AOE     = 70  -- higher in AoE (Swipe + Mangle eat rage)
local RAGE_CAP_WARN     = 85  -- flash bar above this

-- AoE detection (hybrid nameplate + combat-log + threat filter, async hysteresis)
local AOE_THRESHOLD     = 3    -- enemies engaged with player to flip into AoE
local AOE_CL_WINDOW     = 5.0  -- combat-log GUID retention (s)
local AOE_UP_DEBOUNCE   = 0.5  -- ST -> AoE: count must hold for this long
local AOE_DOWN_DEBOUNCE = 2.5  -- AoE -> ST: count must drop for this long
local DEMO_REFRESH      = 5    -- refresh Demo Roar when <= this many seconds left
local BUFF_WARN         = 60   -- buff countdown appears when <= this many seconds
local BUFF_FLASH        = 30   -- pulse red border when <= this many seconds

-- Visual constants
local BAR_TEX           = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill"
local TEXT_FONT         = STANDARD_TEXT_FONT
local TEXT_SIZE         = 11
local TEXT_FLAGS        = "OUTLINE"

local function styleText(fs)
    fs:SetFont(TEXT_FONT, TEXT_SIZE, TEXT_FLAGS)
    fs:SetTextColor(1, 1, 1)
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function spellCD(name)
    local start, dur = GetSpellCooldown(name)
    if not start or start == 0 then return 0 end
    local rem = start + dur - GetTime()
    return rem > 0 and rem or 0
end

-- Aura cache. Refreshed on UNIT_AURA / PLAYER_TARGET_CHANGED events instead of
-- walking 40 slots per OnUpdate tick. Only tracked names are cached; everything
-- else is ignored to keep the rebuild cheap.
local TRACKED_TARGET_DEBUFFS = { S.Mangle, S.Lacerate, S.FFF, S.DemoRoar }
local TRACKED_PLAYER_BUFFS   = { S.Clearcast, S.MotW, S.Thorns, S.OoC }

local trackedTargetSet, trackedBuffSet = {}, {}
for _, n in ipairs(TRACKED_TARGET_DEBUFFS) do trackedTargetSet[n] = true end
for _, n in ipairs(TRACKED_PLAYER_BUFFS)   do trackedBuffSet[n]   = true end

local targetAuras = {}  -- [name] = { count, dur, expires }
local playerAuras = {}  -- [name] = { dur, expires }

local function rebuildTargetAuras()
    wipe(targetAuras)
    if not UnitExists("target") then return end
    for i = 1, 40 do
        local n, _, count, _, dur, expires, source = UnitAura("target", i, "HARMFUL")
        if not n then break end
        if source == "player" and trackedTargetSet[n] then
            targetAuras[n] = { count = count or 0, dur = dur or 0, expires = expires or 0 }
        end
    end
end

local function rebuildPlayerAuras()
    wipe(playerAuras)
    for i = 1, 40 do
        local n, _, _, _, dur, expires = UnitAura("player", i, "HELPFUL")
        if not n then break end
        if trackedBuffSet[n] then
            playerAuras[n] = { dur = dur or 0, expires = expires or 0 }
        end
    end
end

local function targetDebuffByPlayer(name)
    local e = targetAuras[name]
    if not e then return 0, 0, 0 end
    return e.count, e.dur, e.expires
end

local function playerBuff(name)
    return playerAuras[name] ~= nil
end

local function playerBuffInfo(name)
    local e = playerAuras[name]
    if not e then return nil end
    return e.dur, e.expires
end

local function inBearForm()
    -- Form index: 1 = Bear/Dire Bear in TBC for druids with Dire Bear talent.
    local form = GetShapeshiftForm()
    return form == 1
end

local function hasValidTarget()
    return UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDead("target")
end

local function debuffLeft(spellName)
    if not hasValidTarget() then return 0 end
    local _, _, e = targetDebuffByPlayer(spellName)
    return (e and e > 0) and (e - GetTime()) or 0
end

----------------------------------------------------------------------
-- AoE detection: nameplate scan ∪ combat-log GUID pool, threat-filtered.
----------------------------------------------------------------------
local clSeen = {}             -- [guid] = lastSeenTime (mobs trading blows w/ player)
local autoIsAoE = false       -- latched auto-mode result, after debouncing
local aboveSince, belowSince = nil, nil
local lastEnemyCount = 0

local clog = CreateFrame("Frame")
clog:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
clog:RegisterEvent("PLAYER_REGEN_ENABLED")
clog:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        wipe(clSeen)
        autoIsAoE = false
        aboveSince, belowSince = nil, nil
        return
    end
    local _, sub, _, srcGUID, _, _, _, dstGUID = CombatLogGetCurrentEventInfo()
    if not srcGUID or not dstGUID then return end
    local pGUID = UnitGUID("player")
    local now = GetTime()
    if dstGUID == pGUID and srcGUID ~= pGUID and srcGUID:sub(1, 7) ~= "Player-" then
        clSeen[srcGUID] = now
    elseif srcGUID == pGUID and dstGUID ~= pGUID and dstGUID:sub(1, 7) ~= "Player-" then
        clSeen[dstGUID] = now
    end
    if sub == "UNIT_DIED" or sub == "PARTY_KILL" then
        clSeen[dstGUID] = nil
    end
end)

local function countEngagedEnemies()
    local seen, n = {}, 0
    local now = GetTime()

    if C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
            local u = plate.namePlateUnitToken
            if u and UnitExists(u) and UnitCanAttack("player", u)
               and not UnitIsDead(u)
               and UnitThreatSituation("player", u) ~= nil then
                local g = UnitGUID(u)
                if g and not seen[g] then
                    seen[g] = true
                    n = n + 1
                end
            end
        end
    end

    for g, t in pairs(clSeen) do
        if now - t > AOE_CL_WINDOW then
            clSeen[g] = nil
        elseif not seen[g] then
            seen[g] = true
            n = n + 1
        end
    end
    return n
end

local function updateAoEDetection()
    if not UnitAffectingCombat("player") then
        autoIsAoE = false
        aboveSince, belowSince = nil, nil
        lastEnemyCount = 0
        return
    end
    local count = countEngagedEnemies()
    lastEnemyCount = count
    local now = GetTime()
    if count >= AOE_THRESHOLD then
        belowSince = nil
        aboveSince = aboveSince or now
        if not autoIsAoE and (now - aboveSince) >= AOE_UP_DEBOUNCE then
            autoIsAoE = true
        end
    else
        aboveSince = nil
        belowSince = belowSince or now
        if autoIsAoE and (now - belowSince) >= AOE_DOWN_DEBOUNCE then
            autoIsAoE = false
        end
    end
end

local function aoeMode()
    return (BearChadDB and BearChadDB.aoeMode) or "auto"
end

local function isAoEActive()
    local m = aoeMode()
    if m == "on" then return true end
    if m == "off" then return false end
    return autoIsAoE
end

----------------------------------------------------------------------
-- UI: anchor frame
----------------------------------------------------------------------
local PAD = 8
local FRAME_W = 350
local SUG_SIZE = 64
local BAR_GAP = 10
local FULL_BAR_W = FRAME_W - 2 * PAD
local SIDE_BAR_W = FRAME_W - 2 * PAD - SUG_SIZE - BAR_GAP
local BAR_H = 14

local root = CreateFrame("Frame", "BearChadFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
root:SetSize(FRAME_W, 150)
root:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
root:SetBackdropColor(0.05, 0.05, 0.07, 0.85)
root:SetBackdropBorderColor(0, 0, 0, 1)
root:SetPoint("CENTER", 0, -200)
root:SetMovable(true)
root:EnableMouse(true)
root:RegisterForDrag("LeftButton")
root:SetScript("OnDragStart", function(self)
    if IsShiftKeyDown() then
        self:StartMoving()
    end
end)
root:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    BearChadDB = BearChadDB or {}
    BearChadDB.pos = { p, rp, x, y }
end)

-- Resize grip (bottom-right). Drag to scale.
local grip = CreateFrame("Frame", nil, root)
grip:SetSize(14, 14)
grip:SetPoint("BOTTOMRIGHT", -2, 2)
grip:EnableMouse(true)
grip:SetFrameLevel(root:GetFrameLevel() + 5)
local gripTex = grip:CreateTexture(nil, "OVERLAY")
gripTex:SetAllPoints()
gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Shift+drag to resize  |  /bc scale 1.2")
    GameTooltip:Show()
end)
grip:SetScript("OnLeave", GameTooltip_Hide)
grip:SetScript("OnMouseDown", function(self)
    if not IsShiftKeyDown() then return end
    self.startX = select(1, GetCursorPosition())
    self.startScale = root:GetScale()
    self:SetScript("OnUpdate", function()
        local x = select(1, GetCursorPosition())
        local dx = x - self.startX
        local s = self.startScale + dx * 0.0025
        if s < 0.5 then s = 0.5 elseif s > 2.5 then s = 2.5 end
        root:SetScale(s)
    end)
end)
grip:SetScript("OnMouseUp", function(self)
    self:SetScript("OnUpdate", nil)
    BearChadDB = BearChadDB or {}
    BearChadDB.scale = root:GetScale()
end)

-- Rage bar (top, full width, text inside)
local rage = CreateFrame("StatusBar", nil, root)
rage:SetPoint("TOPLEFT", root, "TOPLEFT", PAD, -PAD)
rage:SetSize(FULL_BAR_W, BAR_H)
rage:SetMinMaxValues(0, 100)
rage:SetStatusBarTexture(BAR_TEX)
rage:SetStatusBarColor(0.9, 0.15, 0.15)
local rageBg = rage:CreateTexture(nil, "BACKGROUND")
rageBg:SetAllPoints()
rageBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)
rage.text = rage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
rage.text:SetPoint("CENTER")
styleText(rage.text)

-- HP bar (full width, below rage)
local hp = CreateFrame("StatusBar", nil, root)
hp:SetPoint("TOPLEFT", rage, "BOTTOMLEFT", 0, -2)
hp:SetSize(FULL_BAR_W, BAR_H)
hp:SetMinMaxValues(0, 1)
hp:SetStatusBarTexture(BAR_TEX)
hp:SetStatusBarColor(0.2, 0.8, 0.2)
local hpBg = hp:CreateTexture(nil, "BACKGROUND")
hpBg:SetAllPoints()
hpBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)
hp.text = hp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
hp.text:SetPoint("CENTER")
styleText(hp.text)

-- Suggester (next-ability icon, left side under bars)
local sug = CreateFrame("Frame", nil, root)
sug:SetSize(SUG_SIZE, SUG_SIZE)
sug:SetPoint("TOPLEFT", hp, "BOTTOMLEFT", 0, -8)
sug.border = CreateFrame("Frame", nil, sug, BackdropTemplateMixin and "BackdropTemplate" or nil)
sug.border:SetPoint("TOPLEFT", -2, 2)
sug.border:SetPoint("BOTTOMRIGHT", 2, -2)
sug.border:SetBackdrop({
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
sug.border:SetBackdropBorderColor(1, 0.82, 0, 1)
sug.border:SetFrameLevel(sug:GetFrameLevel() - 1)
sug.icon = sug:CreateTexture(nil, "ARTWORK")
sug.icon:SetAllPoints()
sug.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
sug.label = sug:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sug.label:SetPoint("TOPLEFT", sug, "BOTTOMLEFT", 0, -6)
sug.label:SetJustifyH("LEFT")
sug.label:SetText("")
sug.mode = sug:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sug.mode:SetPoint("TOPRIGHT", sug, "TOPRIGHT", -2, -2)
sug.mode:SetText("ST")

-- Mangle debuff timer (right of suggester, top)
local mangle = CreateFrame("StatusBar", nil, root)
mangle:SetPoint("TOPLEFT", sug, "TOPRIGHT", BAR_GAP, 0)
mangle:SetSize(SIDE_BAR_W, BAR_H)
mangle:SetMinMaxValues(0, 12)
mangle:SetStatusBarTexture(BAR_TEX)
mangle:SetStatusBarColor(0.85, 0.4, 0.85)
local mBg = mangle:CreateTexture(nil, "BACKGROUND")
mBg:SetAllPoints()
mBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)
mangle.text = mangle:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
mangle.text:SetPoint("CENTER")
styleText(mangle.text)
mangle.text:SetText("Mangle: --")

-- Lacerate stacks + timer (right of suggester, below mangle)
local lac = CreateFrame("StatusBar", nil, root)
lac:SetPoint("TOPLEFT", mangle, "BOTTOMLEFT", 0, -4)
lac:SetSize(SIDE_BAR_W, BAR_H)
lac:SetMinMaxValues(0, LACERATE_DURATION)
lac:SetStatusBarTexture(BAR_TEX)
lac:SetStatusBarColor(0.4, 0.7, 0.2)
local lBg = lac:CreateTexture(nil, "BACKGROUND")
lBg:SetAllPoints()
lBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)
lac.text = lac:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
lac.text:SetPoint("CENTER")
styleText(lac.text)
lac.text:SetText("Lacerate: 0/5")

-- Cooldown row (FFF, Demo Roar, Enrage, Barkskin, Frenzied Regen, Growl)
-- Sits under Lacerate in the right column.
local cdRow = CreateFrame("Frame", nil, root)
cdRow:SetPoint("TOPLEFT", lac, "BOTTOMLEFT", 0, -4)
cdRow:SetSize(SIDE_BAR_W, 28)
local cdSpells = { S.Mangle, S.Growl, S.Bash, S.Enrage, S.DemoRoar, S.ChalRoar, S.FrenziedReg, S.Barkskin }
local cdIcons = {}
local _CD_ICON, _CD_N = 28, #cdSpells
local _CD_STRIDE = (SIDE_BAR_W - _CD_ICON) / (_CD_N - 1)
for i, name in ipairs(cdSpells) do
    local b = CreateFrame("Frame", nil, cdRow)
    b:SetSize(_CD_ICON, _CD_ICON)
    if i == _CD_N then
        b:SetPoint("RIGHT", cdRow, "RIGHT", 0, 0)
    else
        b:SetPoint("LEFT", cdRow, "LEFT", (i - 1) * _CD_STRIDE, 0)
    end
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local _, _, tex = GetSpellInfo(name)
    if tex then b.icon:SetTexture(tex) end
    b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cd:SetAllPoints()
    b.spell = name
    cdIcons[i] = b
end

-- Buff status row (MotW, Thorns, OoC). Bright when up, dim+red border when down.
-- Right-aligned under the cooldown row.
local buffRow = CreateFrame("Frame", nil, root)
local _BUFF_COUNT, _BUFF_SIZE, _BUFF_GAP = 3, 22, 4
buffRow:SetPoint("TOPRIGHT", cdRow, "BOTTOMRIGHT", 0, -4)
buffRow:SetSize(_BUFF_COUNT * _BUFF_SIZE + (_BUFF_COUNT - 1) * _BUFF_GAP, _BUFF_SIZE)
local buffSpells = { S.MotW, S.Thorns, S.OoC }
local buffIcons = {}
for i, name in ipairs(buffSpells) do
    local b = CreateFrame("Frame", nil, buffRow)
    b:SetSize(_BUFF_SIZE, _BUFF_SIZE)
    b:SetPoint("LEFT", (i - 1) * (_BUFF_SIZE + _BUFF_GAP), 0)
    b.border = CreateFrame("Frame", nil, b, BackdropTemplateMixin and "BackdropTemplate" or nil)
    b.border:SetPoint("TOPLEFT", -1, 1)
    b.border:SetPoint("BOTTOMRIGHT", 1, -1)
    b.border:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    b.border:SetBackdropBorderColor(0.85, 0.15, 0.15, 1)
    b.border:SetFrameLevel(b:GetFrameLevel() - 1)
    b.border:Hide()
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local _, _, tex = GetSpellInfo(name)
    if tex then b.icon:SetTexture(tex) end
    b.text = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.text:SetPoint("CENTER")
    b.spell = name
    buffIcons[i] = b
end

-- Maul-queued indicator (small overlay near the rage bar; off-GCD so unobtrusive).
local maul = root:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
maul:SetPoint("RIGHT", rage, "RIGHT", -6, 0)
maul:SetText("")
maul:SetTextColor(1, 0.6, 0.1)

-- Form warning (large, anchored over the suggester icon — most critical alert).
local formWarn = root:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
formWarn:SetPoint("CENTER", sug, "CENTER", 0, 0)
formWarn:SetText("")
formWarn:SetTextColor(1, 0.2, 0.2)

----------------------------------------------------------------------
-- Stats panel (toggleable via /bc stats). Anchors to the right of root.
----------------------------------------------------------------------
local statsRoot = CreateFrame("Frame", "BearChadStatsFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
statsRoot:SetSize(340, 380)
statsRoot:SetPoint("TOP", UIParent, "TOP", 0, -120)
statsRoot:SetFrameStrata("DIALOG")
statsRoot:SetBackdrop({
    bgFile   = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
statsRoot:SetBackdropColor(0.05, 0.05, 0.07, 0.92)
statsRoot:SetBackdropBorderColor(0, 0, 0, 1)
statsRoot:Hide()

local statsTitle = statsRoot:CreateFontString(nil, "OVERLAY")
statsTitle:SetFont(TEXT_FONT, 13, "OUTLINE")
statsTitle:SetPoint("TOPLEFT", 10, -10)
statsTitle:SetText("BearChad Stats")
statsTitle:SetTextColor(0.95, 0.85, 0.4)

local statsClose = CreateFrame("Button", nil, statsRoot, "UIPanelCloseButton")
statsClose:SetPoint("TOPRIGHT", 2, 2)
statsClose:SetScript("OnClick", function()
    statsRoot:Hide()
    BearChadDB = BearChadDB or {}
    BearChadDB.stats = false
end)

-- Forward declarations: OnClick handlers below reference these.
local updateStats
local refreshChadLine

local function attachTooltip(frame, title, body)
    frame:EnableMouse(true)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 0.95, 0.85, 0.4)
        GameTooltip:AddLine(body, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", GameTooltip_Hide)
end

local statsHelp = statsRoot:CreateFontString(nil, "OVERLAY")
statsHelp:SetFont(TEXT_FONT, 9, "OUTLINE")
statsHelp:SetPoint("TOPLEFT", 10, -28)
statsHelp:SetText("vs lvl 73 boss  •  hover any row for details")
statsHelp:SetTextColor(0.55, 0.55, 0.55)

-- Tier selector: pick the raid tier you want to compare your stats against.
-- Chad's standards. Targets reflect "good bear gear for this tier", not minimum.
local phaseList = { "T3", "T4", "T5", "T6", "SWP" }
local phaseTargets = {
    T3  = { hp = "6-8k",   armor = "11-14k", dodge = "18-22%", ehp = "~15k" },
    T4  = { hp = "13-14k", armor = "21-24k", dodge = "28-31%", ehp = "~33k" },
    T5  = { hp = "15-17k", armor = "25-28k", dodge = "31-35%", ehp = "~45k" },
    T6  = { hp = "18-20k", armor = "29-32k", dodge = "35-38%", ehp = "~58k" },
    SWP = { hp = "22k+",   armor = "34-37k", dodge = "39-44%", ehp = "~75k" },
}

-- Parse a target string ("16-18k", "19k+", "~55k", "32-36%") into low/high numbers.
local function parseRange(s)
    if not s then return 0, math.huge end
    local mult = s:find("k") and 1000 or 1
    local lo, hi = s:match("(%d+)%-(%d+)")
    if lo and hi then return tonumber(lo) * mult, tonumber(hi) * mult end
    local single = s:match("(%d+)")
    if single then
        local n = tonumber(single) * mult
        if s:find("%+") then return n, math.huge end
        return n, n
    end
    return 0, math.huge
end

-- Color hex string for a value compared to a target range.
local function colorFor(value, lo, hi)
    if value < lo then return "ff4040" end       -- below: red
    if value <= hi then return "ffd040" end      -- in range: yellow
    return "20ff20"                              -- above: green
end

-- Chad lines pool — picked when stats panel opens or tier changes.
-- Chad is the guild leader. Lines lean into GM authority: recruitment, /gkick,
-- officer chat, demotion, etc. Above-tier lines reflect Chad noticing you, not
-- Chad losing his job.
local chadLines = {
    below = {
        "Chad'll out-threat you while drinking. Go farm.",
        "Chad's gonna one-shot you if you show up like that.",
        "Chad mailed you his hand-me-downs. From Karazhan.",
        "Even Chad's bank alt has more armor than this.",
        "Chad's bear form is better geared than your bear form.",
        "Chad's grandma raids more than your stats suggest.",
        "Chad sent a sympathy card. With a Wowhead link.",
        "Chad's healers unsubbed when they saw this.",
        "Chad would tank this naked. You won't get in geared.",
        "Chad's parsing 99 in greens. You're parsing cope.",
        "Chad's macro reads /threat-cap. You're not loaded.",
        "Chad's threat output exceeds your stamina pool.",
        "Chad just used your gear as a transmog joke.",
        "Chad's officer chat: 'we sure about this guy?'",
        "Chad's drafting your demotion to social rank.",
        "Chad's recruiting a replacement bear right now.",
        "Chad opened the recruitment thread again. Wonder why.",
        "Chad cancelled your raid invite mid-cast.",
        "Chad's pinning your armory in #regrets.",
        "Chad's hovering on /gkick. Don't make him click.",
        "Chad just /promoted his hunter pet over you.",
        -- druid / bear flavor
        "Chad's bear has more agility than your boomkin alt.",
        "Chad shifted out of bear and still out-tanked you.",
        "Chad's idol came enchanted. Yours came from a quest.",
        "Chad uses Maul as punctuation.",
        "Chad's bear butt has higher armor than your chest.",
        "Chad's been a bear longer than you've been logged in.",
        "Chad's Druid Discord pinned your armory in #regrets.",
        "Chad's Lacerate ticks are out-DPSing your rotation.",
        "Chad's Hibernate hits harder than your Mangle.",
        "Chad shapeshifted to escape secondhand embarrassment.",
        "Chad's growl is the only debuff the boss respects.",
        "Chad's Dire Bear form is taller than the boss.",
        "Chad's swipe just cleared your DPS off the meter.",
        "Chad's eating Heroic flasks for breakfast. You're sipping water.",
        "Chad's threat ceiling is the actual ceiling.",
        "Chad innervated the priest just to flex.",
    },
    close = {
        "Chad's nodding politely. Don't get cocky.",
        "You're almost Chad-tier. ALMOST.",
        "Chad: 'not bad, kid.'",
        "Same room as Chad. Different table.",
        "You're a parse away from making Chad sweat.",
        "Chad's keeping an eye on you. Worry.",
        "Chad sees you. He just doesn't respect you yet.",
        "Chad's spreadsheets say: 'might survive.'",
        "Chad bookmarked your armory. For now.",
        "Chad's officer chat: 'he's getting there.'",
        "Chad pencil-marked you on the loot list.",
        -- druid / bear flavor
        "Chad noticed you spec'd into Mangle. Progress.",
        "Chad's bear is one ring upgrade ahead of yours.",
        "Chad's Druid Discord said: 'we'll see.'",
        "Chad's idol approves. Yours is still doubting.",
        "Chad's Maul is queued. Yours is buffering.",
        "Chad's hunter pet stopped giggling. Almost respect.",
    },
    above = {
        "Chad just whispered you for tips.",
        "Chad approves. Begrudgingly.",
        "Chad's parse just got 99'd. By you.",
        "Chad's looking at your gear and quietly weeping.",
        "Chad's healers want your number.",
        "Chad just /ginvited you to officer chat.",
        "Chad's officer chat: 'we found him.'",
        "Chad's eyeing you for the MT slot.",
        "Chad just made you the recruitment poster.",
        "Chad's about to /promote you twice in one /reload.",
        "Chad's pinning your armory in the announcements.",
        "Chad sliced you a key to the guild bank.",
        -- druid / bear flavor
        "Chad asks where you got that idol.",
        "Chad named his bear cub after you.",
        "Chad's hunter pet lowered its head in respect.",
        "Chad's writing a guide titled 'how this bear does it.'",
        "Chad just rebound Maul to your name.",
        "Chad's bear form bowed when you logged in.",
        "Chad's Druid Discord pinned your armory in #legends.",
        "Chad's officer chat: 'shapeshift him into MT immediately.'",
        "Chad's idol just got a hit-piece on Wowhead. You're cited.",
    },
}

local phaseLabel = statsRoot:CreateFontString(nil, "OVERLAY")
phaseLabel:SetFont(TEXT_FONT, 10, "OUTLINE")
phaseLabel:SetPoint("TOPLEFT", 10, -46)
phaseLabel:SetText("Compare to:")
phaseLabel:SetTextColor(0.85, 0.85, 0.85)

local phaseButtons = {}
local function refreshPhaseHighlight()
    local cur = (BearChadDB and BearChadDB.phase) or "T6"
    for i, b in ipairs(phaseButtons) do
        if phaseList[i] == cur then
            b.bg:SetColorTexture(0.4, 0.6, 0.9, 0.7)
            b.text:SetTextColor(1, 1, 1)
        else
            b.bg:SetColorTexture(0.2, 0.2, 0.25, 0.6)
            b.text:SetTextColor(0.7, 0.7, 0.7)
        end
    end
end

for i, p in ipairs(phaseList) do
    local btn = CreateFrame("Button", nil, statsRoot)
    btn:SetSize(40, 16)
    btn:SetPoint("LEFT", phaseLabel, "RIGHT", 6 + (i - 1) * 44, 0)
    btn.bg = btn:CreateTexture(nil, "BACKGROUND")
    btn.bg:SetAllPoints()
    btn.bg:SetColorTexture(0.2, 0.2, 0.25, 0.6)
    btn.text = btn:CreateFontString(nil, "OVERLAY")
    btn.text:SetFont(TEXT_FONT, 10, "OUTLINE")
    btn.text:SetPoint("CENTER")
    btn.text:SetText(p)
    btn.text:SetTextColor(0.7, 0.7, 0.7)
    btn:SetScript("OnClick", function()
        BearChadDB = BearChadDB or {}
        BearChadDB.phase = p
        refreshPhaseHighlight()
        if statsRoot:IsShown() then
            updateStats()
            refreshChadLine()
        end
    end)
    attachTooltip(btn, "Tier " .. p,
        "Compare your stats against typical raid-buffed bear targets for tier " .. p .. ". Affects the grey hint values on HP, Armor, and Dodge rows.")
    phaseButtons[i] = btn
end

local statsSections = {
    {
        header = "SURVIVAL",
        color  = { 0.4, 0.7, 1 },
        rows = {
            { key = "critR",   label = "Crit Reduction", bar = true,
              tipTitle = "Crit Reduction (cap 5.60%)",
              tipBody  = "Bosses cannot crit you above 5.60%. Combines defense skill (above 350), resilience, and Survival of the Fittest talent. UNCRITTABLE = no boss criticals on you." },
            { key = "defense", label = "Defense",
              tipTitle = "Defense Skill",
              tipBody  = "Each defense skill above 350 = 0.04% crit reduction vs lvl 73 boss. 415 skill alone gives 2.6%. 2.36 rating = 1 skill at level 70." },
            { key = "resil",   label = "Resilience",
              tipTitle = "Resilience",
              tipBody  = "39.4 resilience = 1% crit reduction. Useful only as a fungible substitute for defense to hit the crit cap. Otherwise dead stat for PvE." },
            { key = "hp",      label = "Health / EHP",
              tipTitle = "Health / Effective HP",
              tipBody  = "EHP factors armor mitigation: HP / (1 - armor%). Higher EHP = more physical damage you can absorb before dying." },
            { key = "armor",   label = "Armor",
              tipTitle = "Armor",
              tipBody  = "Reduces physical damage. Cap is 75% reduction at ~35,880 armor vs lvl 73. Formula: armor / (armor + 11960)." },
            { key = "dodge",   label = "Dodge",
              tipTitle = "Dodge",
              tipBody  = "Bear's primary mitigation — bears can't parry/block. ~14.7 Agility per 1% dodge in form. Sunwell Radiance subtracts 20% in P5 (toggle above)." },
        },
    },
    {
        header = "THREAT",
        color  = { 1, 0.7, 0.3 },
        rows = {
            { key = "hit",     label = "Hit", bar = true,
              tipTitle = "Hit % (cap 9% / 6% w/ iFF)",
              tipBody  = "Threat optimization. Cap = 9% (or 6% with Improved Faerie Fire in raid) for special attacks. Below cap, some Mangles/Lacerates miss." },
            { key = "expert",  label = "Expertise", bar = true,
              tipTitle = "Expertise (cap 26 skill)",
              tipBody  = "Threat optimization. Cap = 26 expertise skill (eliminates the 6.5% chance bosses dodge attacks from the front). 3.94 rating = 1 skill." },
            { key = "crit",    label = "Crit Chance",
              tipTitle = "Melee Crit Chance",
              tipBody  = "Your own chance to crit on melee attacks. Bear Mangle/Maul crits scale damage and threat heavily. No cap — more is better. Includes form, talent, and gear contributions." },
        },
    },
    {
        header = "RAW STATS",
        color  = { 0.7, 0.7, 0.7 },
        rows = {
            { key = "raw", label = "Base",
              tipTitle = "Base Stats",
              tipBody  = "Stamina, Agility, and Attack Power. 1 Sta ≈ 17 HP raid-buffed. ~14.7 Agility = 1% dodge in form. AP scales bear threat directly." },
        },
    },
}

local statsRowMap = {}
local statsBarMap = {}
local yPos = -72
local zebraI = 0

for _, section in ipairs(statsSections) do
    local hdr = statsRoot:CreateFontString(nil, "OVERLAY")
    hdr:SetFont(TEXT_FONT, 10, "OUTLINE")
    hdr:SetPoint("TOPLEFT", 10, yPos)
    hdr:SetText(section.header)
    hdr:SetTextColor(unpack(section.color))
    yPos = yPos - 14

    -- Thin divider line under section header
    local div = statsRoot:CreateTexture(nil, "ARTWORK")
    div:SetPoint("TOPLEFT", 10, yPos)
    div:SetPoint("TOPRIGHT", -10, yPos)
    div:SetHeight(1)
    div:SetColorTexture(section.color[1], section.color[2], section.color[3], 0.3)
    yPos = yPos - 3

    for _, r in ipairs(section.rows) do
        zebraI = zebraI + 1
        local rowH = r.bar and 22 or 18

        local rowFrame = CreateFrame("Frame", nil, statsRoot)
        rowFrame:SetPoint("TOPLEFT", statsRoot, "TOPLEFT", 6, yPos)
        rowFrame:SetPoint("TOPRIGHT", statsRoot, "TOPRIGHT", -6, yPos)
        rowFrame:SetHeight(rowH)

        if zebraI % 2 == 0 then
            local zebra = rowFrame:CreateTexture(nil, "BACKGROUND")
            zebra:SetAllPoints()
            zebra:SetColorTexture(1, 1, 1, 0.04)
        end

        local lbl = rowFrame:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(TEXT_FONT, 11, "OUTLINE")
        lbl:SetPoint("TOPLEFT", 4, -2)
        lbl:SetText(r.label)
        lbl:SetTextColor(0.78, 0.78, 0.78)

        local val = rowFrame:CreateFontString(nil, "OVERLAY")
        val:SetFont(TEXT_FONT, 11, "OUTLINE")
        val:SetPoint("TOPRIGHT", -4, -2)
        val:SetText("--")
        val:SetTextColor(1, 1, 1)
        val:SetJustifyH("RIGHT")

        if r.bar then
            local bar = CreateFrame("StatusBar", nil, rowFrame)
            bar:SetPoint("BOTTOMLEFT", 4, 1)
            bar:SetPoint("BOTTOMRIGHT", -4, 1)
            bar:SetHeight(3)
            bar:SetMinMaxValues(0, 1)
            bar:SetStatusBarTexture(BAR_TEX)
            local barBg = bar:CreateTexture(nil, "BACKGROUND")
            barBg:SetAllPoints()
            barBg:SetColorTexture(0.15, 0.15, 0.15, 0.7)
            statsBarMap[r.key] = bar
        end

        attachTooltip(rowFrame, r.tipTitle or r.label, r.tipBody or "")
        statsRowMap[r.key] = val
        yPos = yPos - rowH
    end

    yPos = yPos - 6
end

local function getSotFRank()
    if not GetNumTalents or not GetTalentInfo then return 0 end
    for i = 1, GetNumTalents(2) do
        local n, _, _, _, rank = GetTalentInfo(2, i)
        if n == "Survival of the Fittest" then return rank or 0 end
    end
    return 0
end

local function fmtN(n) return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n) end

-- Hit and expertise rating-per-skill in TBC (level 70).
local HIT_RATING_PER_PCT = 15.77   -- 15.77 melee hit rating = 1% hit
local EXP_RATING_PER_SKILL = 3.94  -- 3.94 expertise rating = 1 expertise skill
local DEF_RATING_PER_SKILL = 2.36  -- 2.36 defense rating = 1 defense skill
local RES_PER_PCT_CRIT_REDUCTION = 39.4  -- 39.4 resilience = 1% crit reduction taken

function updateStats()
    -- Defense skill
    local defBase, defMod = UnitDefense("player")
    local defSkill = (defBase or 0) + (defMod or 0)
    local defRating = GetCombatRating and GetCombatRating(2) or 0

    -- Crit reduction = defense skill + resilience + Survival of the Fittest
    local critFromDef = math.max(0, (defSkill - 350) * 0.04)
    local critFromRes = (GetCombatRatingBonus and GetCombatRatingBonus(15)) or 0
    local sotf = getSotFRank()  -- 1% per rank in TBC
    local critTotal = critFromDef + critFromRes + sotf
    local uncrit = critTotal >= 5.6
    if uncrit then
        statsRowMap.critR:SetText(("|cff20ff20%.2f%%   UNCRITTABLE|r"):format(critTotal))
    else
        statsRowMap.critR:SetText(("|cffff4040%.2f%%   NEED %.2f%%|r"):format(critTotal, 5.6 - critTotal))
    end
    if statsBarMap.critR then
        statsBarMap.critR:SetMinMaxValues(0, 5.6)
        statsBarMap.critR:SetValue(math.min(critTotal, 5.6))
        if uncrit then
            statsBarMap.critR:SetStatusBarColor(0.2, 0.85, 0.2)
        else
            statsBarMap.critR:SetStatusBarColor(0.85, 0.2, 0.2)
        end
    end

    -- Health + EHP (factoring armor mitigation only)
    local hp = UnitHealthMax("player") or 0
    local _, totalArmor = UnitArmor("player")
    totalArmor = totalArmor or 0
    local armorDR = totalArmor / (totalArmor + 11960)
    if armorDR > 0.75 then armorDR = 0.75 end
    local ehp = (1 - armorDR) > 0 and math.floor(hp / (1 - armorDR)) or hp

    local phase = (BearChadDB and BearChadDB.phase) or "T6"
    local tgt = phaseTargets[phase] or {}

    -- HP and EHP color-coded vs the tier target
    local hpLo, hpHi = parseRange(tgt.hp)
    local ehpLo, ehpHi = parseRange(tgt.ehp)
    local hpClr  = colorFor(hp, hpLo, hpHi)
    local ehpClr = colorFor(ehp, ehpLo, ehpHi)
    statsRowMap.hp:SetText(("|cff%s%s|r / |cff%s%s|r   |cffaaaaaa%s: %s / %s|r"):format(
        hpClr, fmtN(hp), ehpClr, fmtN(ehp), phase, tgt.hp or "?", tgt.ehp or "?"))

    -- Armor color-coded vs the tier target
    local arLo, arHi = parseRange(tgt.armor)
    local arClr = colorFor(totalArmor, arLo, arHi)
    statsRowMap.armor:SetText(("|cff%s%s|r   %.1f%%   |cffaaaaaa%s: %s|r"):format(
        arClr, fmtN(totalArmor), armorDR * 100, phase, tgt.armor or "?"))

    -- Dodge: color-coded vs tier target.
    local dodge = GetDodgeChance and GetDodgeChance() or 0
    local doLo, doHi = parseRange(tgt.dodge)
    local doClr = colorFor(dodge, doLo, doHi)
    statsRowMap.dodge:SetText(("|cff%s%.2f%%|r   |cffaaaaaa%s: %s|r"):format(doClr, dodge, phase, tgt.dodge or "?"))

    -- Hit (yellow/specials cap = 9%, or 6% with Improved Faerie Fire toggle).
    local hitPct = (GetCombatRatingBonus and GetCombatRatingBonus(6)) or 0
    local hitRating = GetCombatRating and GetCombatRating(6) or 0
    local hitCap = 9
    if hitPct >= hitCap then
        statsRowMap.hit:SetText(("|cff20ff20%.2f%%   CAPPED|r"):format(hitPct))
    else
        local needRating = math.ceil((hitCap - hitPct) * HIT_RATING_PER_PCT)
        statsRowMap.hit:SetText(("|cffffd040%.2f%%   +%d rating to cap|r"):format(hitPct, needRating))
    end
    if statsBarMap.hit then
        statsBarMap.hit:SetMinMaxValues(0, hitCap)
        statsBarMap.hit:SetValue(math.min(hitPct, hitCap))
        if hitPct >= hitCap then
            statsBarMap.hit:SetStatusBarColor(0.2, 0.85, 0.2)
        else
            statsBarMap.hit:SetStatusBarColor(1, 0.82, 0.2)
        end
    end

    -- Expertise (cap = 26 skill = 6.5% dodge eliminated). Threat-optim.
    local expSkill = GetExpertise and GetExpertise() or 0
    local expRating = GetCombatRating and GetCombatRating(24) or 0
    if expSkill >= 26 then
        statsRowMap.expert:SetText(("|cff20ff2026/26   CAPPED|r"))
    else
        local needRating = math.ceil((26 - expSkill) * EXP_RATING_PER_SKILL)
        statsRowMap.expert:SetText(("|cffffd040%d/26   +%d rating to cap|r"):format(expSkill, needRating))
    end
    if statsBarMap.expert then
        statsBarMap.expert:SetMinMaxValues(0, 26)
        statsBarMap.expert:SetValue(math.min(expSkill, 26))
        if expSkill >= 26 then
            statsBarMap.expert:SetStatusBarColor(0.2, 0.85, 0.2)
        else
            statsBarMap.expert:SetStatusBarColor(1, 0.82, 0.2)
        end
    end

    -- Crit chance (player's own melee crit %, no cap — informational)
    local critChance = GetCritChance and GetCritChance() or 0
    statsRowMap.crit:SetText(("%.2f%%"):format(critChance))

    -- Defense skill (color-coded by uncrit status since defense feeds crit reduction)
    local defColor = uncrit and "ffffff" or "ff4040"
    statsRowMap.defense:SetText(("|cff%s%d skill   |cffaaaaaa(%d rating)|r"):format(defColor, defSkill, defRating))

    -- Resilience (folds into crit reduction; show rating + its contribution)
    local resRating = GetCombatRating and GetCombatRating(15) or 0
    statsRowMap.resil:SetText(("%d rating   |cffaaaaaa(%.2f%% crit red)|r"):format(resRating, critFromRes))

    -- Stam / Agi / AP combined into one row.
    local sta = select(2, UnitStat("player", 3)) or 0
    local agi = select(2, UnitStat("player", 2)) or 0
    local apBase, apPos, apNeg = UnitAttackPower("player")
    local ap = (apBase or 0) + (apPos or 0) - (apNeg or 0)
    statsRowMap.raw:SetText(("STA %s  •  AGI %s  •  AP %s"):format(fmtN(sta), fmtN(agi), fmtN(ap)))
end

-- Chad verdict line at the bottom of the panel.
local chadLine = statsRoot:CreateFontString(nil, "OVERLAY")
chadLine:SetFont(TEXT_FONT, 11, "OUTLINE")
chadLine:SetPoint("BOTTOMLEFT", 10, 10)
chadLine:SetPoint("BOTTOMRIGHT", -10, 10)
chadLine:SetWordWrap(true)
chadLine:SetJustifyH("CENTER")
chadLine:SetText("")

local function pickChadBucket()
    local phase = (BearChadDB and BearChadDB.phase) or "T6"
    local tgt = phaseTargets[phase] or {}
    local hp = UnitHealthMax("player") or 0
    local _, totalArmor = UnitArmor("player")
    totalArmor = totalArmor or 0
    local dodge = GetDodgeChance and GetDodgeChance() or 0

    local below, above = 0, 0
    local function score(v, range)
        local lo, hi = parseRange(range)
        if v < lo then below = below + 1
        elseif v > hi then above = above + 1 end
    end
    score(hp, tgt.hp)
    score(totalArmor, tgt.armor)
    score(dodge, tgt.dodge)

    if below >= 2 then return "below" end
    if above >= 2 then return "above" end
    return "close"
end

function refreshChadLine()
    local bucket = pickChadBucket()
    local pool = chadLines[bucket]
    local pick = pool[math.random(1, #pool)]
    chadLine:SetText(pick)
    if bucket == "below" then
        chadLine:SetTextColor(1, 0.35, 0.35)
    elseif bucket == "above" then
        chadLine:SetTextColor(0.35, 0.95, 0.4)
    else
        chadLine:SetTextColor(1, 0.75, 0.3)
    end
end

statsRoot:SetScript("OnShow", function()
    BearChadDB = BearChadDB or {}
    refreshPhaseHighlight()
    updateStats()
    refreshChadLine()
end)
statsRoot:SetScript("OnUpdate", function(self, elapsed)
    self._t = (self._t or 0) + elapsed
    if self._t < 1 then return end
    self._t = 0
    updateStats()
end)

----------------------------------------------------------------------
-- Rotation logic
----------------------------------------------------------------------
local function maulQueued()
    return IsCurrentSpell and IsCurrentSpell(S.Maul)
end

local function suggestSingleTarget()
    if not hasValidTarget() then
        return S.Mangle, "no target"
    end
    local rageNow  = UnitPower("player") or 0
    local mangleCD = spellCD(S.Mangle)
    local lacCD    = spellCD(S.Lacerate)
    local fffCD    = spellCD(S.FFF)
    local cc       = playerBuff(S.Clearcast)

    local lStacks, _, lExpires = targetDebuffByPlayer(S.Lacerate)
    local lLeft = (lExpires or 0) > 0 and (lExpires - GetTime()) or 0
    lStacks = lStacks or 0

    -- 1. Mangle on CD (highest threat-per-GCD; bleed-bonus debuff for Lacerate).
    if mangleCD <= 0.2 and (cc or rageNow >= 15) then
        return S.Mangle, cc and "Mangle (CC!)" or "Mangle on CD"
    end
    -- 2. Lacerate to 5 stacks.
    if lacCD <= 0.2 and lStacks < 5 and (cc or rageNow >= 13) then
        return S.Lacerate, "stack Lacerate ("..lStacks.."/5)"
    end
    -- 3. Lacerate refresh only when expiring (no filler at full stacks).
    if lacCD <= 0.2 and lStacks == 5 and lLeft <= LACERATE_REFRESH and (cc or rageNow >= 13) then
        return S.Lacerate, "refresh Lacerate"
    end
    -- 4. FFF if missing/expiring.
    local fLeft = debuffLeft(S.FFF)
    if fffCD <= 0.2 and fLeft <= FFF_REFRESH then
        return S.FFF, fLeft <= 0 and "apply FFF" or "refresh FFF"
    end
    -- 5. Idle GCD. Suggest Maul only at safe rage and not already queued;
    --    otherwise show "wait" so we don't burn rage on a Maul that
    --    would starve the next Mangle.
    if rageNow >= RAGE_MAUL_ST and not maulQueued() then
        return S.Maul, "queue Maul (rage dump)"
    end
    return "WAIT", "auto-attack — build rage"
end

local function suggestAoE()
    local rageNow  = UnitPower("player") or 0
    local mangleCD = spellCD(S.Mangle)
    local fffCD    = spellCD(S.FFF)
    local dLeft    = debuffLeft(S.DemoRoar)
    local cc       = playerBuff(S.Clearcast)

    -- 1. Demo Roar refresh (AoE AP debuff + multi-target threat).
    if dLeft <= DEMO_REFRESH and (cc or rageNow >= 10) then
        return S.DemoRoar, "Demo Roar"
    end
    -- 2. Swipe — primary AoE threat engine, hits 4. CC makes it free.
    if cc or rageNow >= 20 then
        return S.Swipe, "Swipe ("..lastEnemyCount.." mobs)"
    end
    -- 3. Mangle on CD on focus (snap single-target threat at low rage).
    if hasValidTarget() and mangleCD <= 0.2 and rageNow >= 15 then
        return S.Mangle, "Mangle on focus"
    end
    -- 4. FFF on focus.
    local fLeft = debuffLeft(S.FFF)
    if hasValidTarget() and fffCD <= 0.2 and fLeft <= FFF_REFRESH then
        return S.FFF, fLeft <= 0 and "apply FFF" or "refresh FFF"
    end
    -- 5. Idle. Maul threshold higher in AoE since Swipe will eat rage soon.
    if rageNow >= RAGE_MAUL_AOE and not maulQueued() then
        return S.Maul, "queue Maul (rage dump)"
    end
    return "WAIT", "auto-attack — build rage"
end

local function suggestNext()
    if not inBearForm() then
        return S.BearForm, "SHIFT INTO BEAR"
    end
    if isAoEActive() then
        return suggestAoE()
    end
    return suggestSingleTarget()
end

----------------------------------------------------------------------
-- Update loop
----------------------------------------------------------------------
local lastUpdate = 0
root:SetScript("OnUpdate", function(self, elapsed)
    lastUpdate = lastUpdate + elapsed
    if lastUpdate < 0.1 then return end
    lastUpdate = 0

    updateAoEDetection()

    -- Rage
    local rageNow = UnitPower("player") or 0
    local rageMax = UnitPowerMax("player") or 100
    rage:SetMinMaxValues(0, rageMax)
    rage:SetValue(rageNow)
    rage.text:SetText(("Rage %d / %d"):format(rageNow, rageMax))
    if rageNow >= RAGE_CAP_WARN then
        rage:SetStatusBarColor(1, 0.85, 0.1)
    else
        rage:SetStatusBarColor(0.9, 0.15, 0.15)
    end

    -- Health
    local hpNow = UnitHealth("player") or 0
    local hpMax = UnitHealthMax("player") or 1
    if hpMax < 1 then hpMax = 1 end
    hp:SetMinMaxValues(0, hpMax)
    hp:SetValue(hpNow)
    hp.text:SetText(("HP %s / %s"):format(BreakUpLargeNumbers(hpNow), BreakUpLargeNumbers(hpMax)))
    local pct = hpNow / hpMax
    if pct > 0.5 then
        hp:SetStatusBarColor(0.2, 0.8, 0.2)
    elseif pct > 0.3 then
        hp:SetStatusBarColor(0.9, 0.85, 0.2)
    else
        hp:SetStatusBarColor(0.9, 0.2, 0.2)
    end

    -- Mangle debuff
    local _, mDur, mExpires = targetDebuffByPlayer(S.Mangle)
    if mExpires and mExpires > GetTime() then
        local left = mExpires - GetTime()
        mangle:SetMinMaxValues(0, mDur > 0 and mDur or 12)
        mangle:SetValue(left)
        mangle.text:SetText(("Mangle: %.1fs"):format(left))
    else
        mangle:SetValue(0)
        mangle.text:SetText("Mangle: --")
    end

    -- Lacerate
    local lStacks, lDur, lExpires = targetDebuffByPlayer(S.Lacerate)
    if lExpires and lExpires > GetTime() then
        local left = lExpires - GetTime()
        lac:SetMinMaxValues(0, lDur > 0 and lDur or LACERATE_DURATION)
        lac:SetValue(left)
        lac.text:SetText(("Lacerate %d/5  %.1fs"):format(lStacks or 0, left))
        if (lStacks or 0) >= 5 then
            -- Full stacks: red bar so you know not to keep stacking.
            lac:SetStatusBarColor(0.85, 0.2, 0.2)
        else
            lac:SetStatusBarColor(0.4, 0.7, 0.2)
        end
    else
        lac:SetValue(0)
        lac.text:SetText("Lacerate: 0/5")
        lac:SetStatusBarColor(0.4, 0.7, 0.2)
    end

    -- Cooldowns row (CooldownFrameTemplate / OmniCC handle the numeric display).
    for _, b in ipairs(cdIcons) do
        local start, dur = GetSpellCooldown(b.spell)
        if start and dur and dur > 1.5 then
            b.cd:SetCooldown(start, dur)
        else
            b.cd:Clear()
        end
    end

    -- Buff status row: bright if up & fresh, yellow countdown when expiring,
    -- red-border flash inside flash window, dim+red-border when missing.
    local pulseOn = (math.floor(GetTime() * 2.5) % 2) == 0
    for _, b in ipairs(buffIcons) do
        local _, expires = playerBuffInfo(b.spell)
        if expires and expires > 0 then
            local left = expires - GetTime()
            if left > BUFF_WARN then
                b.icon:SetVertexColor(1, 1, 1)
                b.border:Hide()
                b.text:SetText("")
            elseif left > BUFF_FLASH then
                -- yellow warning + countdown, no flash
                b.icon:SetVertexColor(1, 0.9, 0.5)
                b.border:Hide()
                b.text:SetText(("%d"):format(math.ceil(left)))
                b.text:SetTextColor(1, 0.9, 0.3)
            else
                -- urgent: pulsing red border + countdown
                b.icon:SetVertexColor(1, 0.55, 0.55)
                b.border:SetShown(pulseOn)
                b.text:SetText(("%d"):format(math.ceil(left)))
                b.text:SetTextColor(1, 0.4, 0.4)
            end
        else
            -- buff missing: steady red border, dim icon
            b.icon:SetVertexColor(0.35, 0.35, 0.35)
            b.border:Show()
            b.text:SetText("")
        end
    end

    -- Maul queued
    if IsCurrentSpell and IsCurrentSpell(S.Maul) then
        maul:SetText("MAUL QUEUED")
    else
        maul:SetText("")
    end

    -- Form warning (only meaningful in combat)
    if UnitAffectingCombat("player") and not inBearForm() then
        formWarn:SetText("!! NOT IN BEAR FORM !!")
    else
        formWarn:SetText("")
    end

    -- Suggester
    local nextSpell, why = suggestNext()
    local cc = playerBuff(S.Clearcast)
    if nextSpell == "WAIT" then
        sug.icon:Hide()
        sug.border:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    else
        sug.icon:Show()
        local _, _, tex = GetSpellInfo(nextSpell)
        if tex then sug.icon:SetTexture(tex) end
        sug.icon:SetDesaturated(false)
        if cc then
            sug.border:SetBackdropBorderColor(0.4, 0.9, 1, 1)
        else
            sug.border:SetBackdropBorderColor(1, 0.82, 0, 1)
        end
    end
    sug.label:SetText(why or "")

    -- Mode label (asterisk indicates manual override)
    local active = isAoEActive() and "AoE" or "ST"
    local suffix = aoeMode() == "auto" and "" or "*"
    sug.mode:SetText(active .. suffix)
    if active == "AoE" then
        sug.mode:SetTextColor(1, 0.55, 0.15)
    else
        sug.mode:SetTextColor(0.7, 0.7, 0.7)
    end
end)

----------------------------------------------------------------------
-- Position restore + slash
----------------------------------------------------------------------
local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self, ev, arg)
    if ev == "ADDON_LOADED" and arg == ADDON then
        BearChadDB = BearChadDB or {}
        if BearChadDB.pos then
            local p, rp, x, y = unpack(BearChadDB.pos)
            root:ClearAllPoints()
            root:SetPoint(p, UIParent, rp, x, y)
        end
        if BearChadDB.scale then
            root:SetScale(BearChadDB.scale)
        end
        if BearChadDB.stats then
            statsRoot:Show()
        end
    elseif ev == "PLAYER_LOGIN" then
        rebuildPlayerAuras()
        rebuildTargetAuras()
    end
end)

-- Aura cache refresh: only fires on real changes, not every OnUpdate tick.
local auraEvents = CreateFrame("Frame")
auraEvents:RegisterEvent("UNIT_AURA")
auraEvents:RegisterEvent("PLAYER_TARGET_CHANGED")
auraEvents:SetScript("OnEvent", function(_, ev, unit)
    if ev == "PLAYER_TARGET_CHANGED" then
        rebuildTargetAuras()
    elseif ev == "UNIT_AURA" then
        if unit == "target" then
            rebuildTargetAuras()
        elseif unit == "player" then
            rebuildPlayerAuras()
        end
    end
end)

SLASH_BEARCHAD1 = "/bearchad"
SLASH_BEARCHAD2 = "/bc"
SlashCmdList.BEARCHAD = function(msg)
    msg = (msg or ""):lower()
    BearChadDB = BearChadDB or {}
    local scaleArg = msg:match("^scale%s+([%d%.]+)$")
    local aoeArg   = msg:match("^aoe%s+(%S+)$") or (msg == "aoe" and "toggle" or nil)
    if msg == "lock" then
        root:EnableMouse(false)
        grip:Hide()
        print("|cff88ccff[BearChad]|r locked.")
    elseif msg == "unlock" then
        root:EnableMouse(true)
        grip:Show()
        print("|cff88ccff[BearChad]|r unlocked. Shift+drag body to move, shift+drag corner to resize.")
    elseif msg == "reset" then
        root:ClearAllPoints()
        root:SetPoint("CENTER", 0, -200)
        root:SetScale(1)
        BearChadDB.pos = nil
        BearChadDB.scale = nil
        print("|cff88ccff[BearChad]|r position and scale reset.")
    elseif scaleArg then
        local n = tonumber(scaleArg)
        if n then
            if n < 0.5 then n = 0.5 elseif n > 2.5 then n = 2.5 end
            root:SetScale(n)
            BearChadDB.scale = n
            print(("|cff88ccff[BearChad]|r scale = %.2f"):format(n))
        end
    elseif aoeArg then
        if aoeArg == "on" or aoeArg == "off" or aoeArg == "auto" then
            BearChadDB.aoeMode = aoeArg
        elseif aoeArg == "toggle" then
            local cur = BearChadDB.aoeMode or "auto"
            BearChadDB.aoeMode = (cur == "auto") and "on" or "auto"
        else
            print("|cff88ccff[BearChad]|r usage: /bc aoe on | off | auto")
            return
        end
        print(("|cff88ccff[BearChad]|r AoE mode: %s"):format(BearChadDB.aoeMode))
    elseif msg == "stats" then
        if statsRoot:IsShown() then
            statsRoot:Hide()
            BearChadDB.stats = false
            print("|cff88ccff[BearChad]|r stats panel hidden.")
        else
            statsRoot:Show()
            BearChadDB.stats = true
            print("|cff88ccff[BearChad]|r stats panel shown.")
        end
    else
        print("|cff88ccff[BearChad]|r /bc lock | unlock | reset | scale <0.5-2.5> | aoe <on|off|auto> | stats")
    end
end

print("|cff88ccff[BearChad]|r loaded. Out-thread Chad.")
