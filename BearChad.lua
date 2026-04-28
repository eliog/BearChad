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
    ChalRoar    = GetSpellInfo(5209)  or "Challenging Roar",
    BearForm    = GetSpellInfo(9634)  or "Dire Bear Form",
    Clearcast   = GetSpellInfo(16870) or "Clearcasting",
}

local LACERATE_DURATION = 15  -- seconds
local LACERATE_REFRESH  = 4   -- refresh when <=4s left
local MANGLE_REFRESH    = 2   -- pre-cast inside last 2s
local RAGE_MAUL         = 30  -- queue Maul above this rage
local RAGE_CAP_WARN     = 85  -- flash bar above this

-- AoE detection (hybrid nameplate + combat-log + threat filter, async hysteresis)
local AOE_THRESHOLD     = 3    -- enemies engaged with player to flip into AoE
local AOE_CL_WINDOW     = 5.0  -- combat-log GUID retention (s)
local AOE_UP_DEBOUNCE   = 0.5  -- ST -> AoE: count must hold for this long
local AOE_DOWN_DEBOUNCE = 2.5  -- AoE -> ST: count must drop for this long
local DEMO_REFRESH      = 5    -- refresh Demo Roar when <= this many seconds left

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function spellCD(name)
    local start, dur = GetSpellCooldown(name)
    if not start or start == 0 then return 0 end
    local rem = start + dur - GetTime()
    return rem > 0 and rem or 0
end

local function spellUsable(name)
    local start, dur = GetSpellCooldown(name)
    if not start then return false end
    local gcd = (dur or 0) <= 1.5  -- treat GCD as usable
    return (start == 0) or gcd
end

local function findAura(unit, name, filter)
    for i = 1, 40 do
        local n, _, count, _, dur, expires, source = UnitAura(unit, i, filter)
        if not n then return nil end
        if n == name and (filter ~= "HARMFUL|PLAYER" or source == "player") then
            return count or 0, dur or 0, expires or 0, source
        end
    end
end

local function targetDebuffByPlayer(name)
    -- Walk debuffs and pick the one applied by the player.
    for i = 1, 40 do
        local n, _, count, _, dur, expires, source = UnitAura("target", i, "HARMFUL")
        if not n then return nil end
        if n == name and source == "player" then
            return (count or 0), (dur or 0), (expires or 0)
        end
    end
end

local function playerBuff(name)
    for i = 1, 40 do
        local n = UnitAura("player", i, "HELPFUL")
        if not n then return false end
        if n == name then return true end
    end
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
local root = CreateFrame("Frame", "BearChadFrame", UIParent)
root:SetSize(330, 120)
root:SetPoint("CENTER", 0, -200)
root:SetMovable(true)
root:EnableMouse(true)
root:RegisterForDrag("LeftButton")
root:SetScript("OnDragStart", root.StartMoving)
root:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    BearChadDB = BearChadDB or {}
    BearChadDB.pos = { p, rp, x, y }
end)

local bg = root:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints()
bg:SetColorTexture(0, 0, 0, 0.35)

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
    GameTooltip:SetText("Drag to resize  |  /bc scale 1.2")
    GameTooltip:Show()
end)
grip:SetScript("OnLeave", GameTooltip_Hide)
grip:SetScript("OnMouseDown", function(self)
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

-- Suggester (next-ability icon)
local sug = CreateFrame("Frame", nil, root)
sug:SetSize(64, 64)
sug:SetPoint("LEFT", 6, 12)
sug.border = sug:CreateTexture(nil, "BACKGROUND")
sug.border:SetPoint("TOPLEFT", -2, 2)
sug.border:SetPoint("BOTTOMRIGHT", 2, -2)
sug.border:SetColorTexture(1, 0.82, 0, 0.9)
sug.icon = sug:CreateTexture(nil, "ARTWORK")
sug.icon:SetAllPoints()
sug.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
sug.label = sug:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
sug.label:SetPoint("TOP", sug, "BOTTOM", 0, -2)
sug.label:SetText("")
sug.mode = sug:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
sug.mode:SetPoint("TOPRIGHT", sug, "TOPRIGHT", -2, -2)
sug.mode:SetText("ST")

-- Rage bar
local rage = CreateFrame("StatusBar", nil, root)
rage:SetPoint("TOPLEFT", sug, "TOPRIGHT", 12, -2)
rage:SetSize(240, 14)
rage:SetMinMaxValues(0, 100)
rage:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
rage:SetStatusBarColor(0.9, 0.15, 0.15)
local rageBg = rage:CreateTexture(nil, "BACKGROUND")
rageBg:SetAllPoints()
rageBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)
rage.text = rage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
rage.text:SetPoint("CENTER")

-- Mangle debuff timer
local mangle = CreateFrame("StatusBar", nil, root)
mangle:SetPoint("TOPLEFT", rage, "BOTTOMLEFT", 0, -4)
mangle:SetSize(240, 12)
mangle:SetMinMaxValues(0, 12)
mangle:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
mangle:SetStatusBarColor(0.85, 0.4, 0.85)
local mBg = mangle:CreateTexture(nil, "BACKGROUND")
mBg:SetAllPoints()
mBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)
mangle.text = mangle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
mangle.text:SetPoint("CENTER")
mangle.text:SetText("Mangle: --")

-- Lacerate stacks + timer
local lac = CreateFrame("StatusBar", nil, root)
lac:SetPoint("TOPLEFT", mangle, "BOTTOMLEFT", 0, -4)
lac:SetSize(240, 12)
lac:SetMinMaxValues(0, LACERATE_DURATION)
lac:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
lac:SetStatusBarColor(0.4, 0.7, 0.2)
local lBg = lac:CreateTexture(nil, "BACKGROUND")
lBg:SetAllPoints()
lBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)
lac.text = lac:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
lac.text:SetPoint("CENTER")
lac.text:SetText("Lacerate: 0/5")

-- Cooldown row (FFF, Demo Roar, Enrage, Barkskin, Frenzied Regen, Growl)
local cdRow = CreateFrame("Frame", nil, root)
cdRow:SetPoint("TOPLEFT", lac, "BOTTOMLEFT", 0, -8)
cdRow:SetSize(240, 28)
local cdSpells = { S.FFF, S.DemoRoar, S.Enrage, S.Barkskin, S.FrenziedReg, S.Growl }
local cdIcons = {}
for i, name in ipairs(cdSpells) do
    local b = CreateFrame("Frame", nil, cdRow)
    b:SetSize(28, 28)
    b:SetPoint("LEFT", (i - 1) * 32, 0)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local _, _, tex = GetSpellInfo(name)
    if tex then b.icon:SetTexture(tex) end
    b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cd:SetAllPoints()
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint("BOTTOM", 0, -10)
    b.spell = name
    cdIcons[i] = b
end

-- Maul-queued indicator (pulses when Maul is on next swing)
local maul = root:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
maul:SetPoint("TOP", root, "TOP", 0, -2)
maul:SetText("")
maul:SetTextColor(1, 0.6, 0.1)

-- Clearcasting glow
local ccText = root:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
ccText:SetPoint("BOTTOM", sug, "TOP", 0, 4)
ccText:SetText("")
ccText:SetTextColor(0.4, 0.9, 1)

-- Form warning
local formWarn = root:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
formWarn:SetPoint("CENTER", root, "CENTER", 0, 40)
formWarn:SetText("")
formWarn:SetTextColor(1, 0.2, 0.2)

----------------------------------------------------------------------
-- Rotation logic
----------------------------------------------------------------------
local function suggestSingleTarget()
    if not hasValidTarget() then
        return S.Mangle, "no target"
    end
    local rageNow = UnitPower("player") or 0
    local mangleCD = spellCD(S.Mangle)
    local lacCD    = spellCD(S.Lacerate)
    local fffCD    = spellCD(S.FFF)

    local _, _, mExpires = targetDebuffByPlayer(S.Mangle)
    local lStacks, _, lExpires = targetDebuffByPlayer(S.Lacerate)
    local mLeft = (mExpires or 0) > 0 and (mExpires - GetTime()) or 0
    local lLeft = (lExpires or 0) > 0 and (lExpires - GetTime()) or 0
    lStacks = lStacks or 0

    if mangleCD <= 0.2 and mLeft <= MANGLE_REFRESH and rageNow >= 15 then
        return S.Mangle, "apply/refresh Mangle"
    end
    if lacCD <= 0.2 and lStacks < 5 and rageNow >= 13 then
        return S.Lacerate, "stack Lacerate ("..lStacks.."/5)"
    end
    if lacCD <= 0.2 and lStacks == 5 and lLeft <= LACERATE_REFRESH and rageNow >= 13 then
        return S.Lacerate, "refresh Lacerate"
    end
    if mangleCD <= 0.2 and rageNow >= 15 then
        return S.Mangle, "Mangle on CD"
    end
    if fffCD <= 0.2 then
        return S.FFF, "FFF"
    end
    if lacCD <= 0.2 and rageNow >= 13 then
        return S.Lacerate, "Lacerate filler"
    end
    return S.Maul, "queue Maul"
end

local function suggestAoE()
    local rageNow = UnitPower("player") or 0
    local mangleCD = spellCD(S.Mangle)
    local fffCD    = spellCD(S.FFF)
    local mLeft    = debuffLeft(S.Mangle)
    local dLeft    = debuffLeft(S.DemoRoar)

    -- 1. Demo Roar if missing or about to fall off (AoE attack-power debuff + threat).
    if dLeft <= DEMO_REFRESH and rageNow >= 10 then
        return S.DemoRoar, "Demo Roar"
    end
    -- 2. Maintain Mangle on focus target (still 30% bleed bonus + snap threat).
    if hasValidTarget() and mangleCD <= 0.2 and mLeft <= MANGLE_REFRESH and rageNow >= 15 then
        return S.Mangle, "Mangle on focus"
    end
    -- 3. Swipe spam.
    if rageNow >= 20 then
        return S.Swipe, "Swipe ("..lastEnemyCount.." mobs)"
    end
    -- 4. Mangle on CD if rage allows.
    if hasValidTarget() and mangleCD <= 0.2 and rageNow >= 15 then
        return S.Mangle, "Mangle on CD"
    end
    -- 5. FFF on CD.
    if hasValidTarget() and fffCD <= 0.2 then
        return S.FFF, "FFF"
    end
    -- 6. Building rage: queue Maul on focus.
    return S.Maul, "queue Maul"
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
    else
        lac:SetValue(0)
        lac.text:SetText("Lacerate: 0/5")
    end

    -- Cooldowns row
    for _, b in ipairs(cdIcons) do
        local start, dur = GetSpellCooldown(b.spell)
        if start and dur and dur > 1.5 then
            b.cd:SetCooldown(start, dur)
            local left = start + dur - GetTime()
            b.text:SetText(left > 0 and ("%.0f"):format(left) or "")
        else
            b.cd:Clear()
            b.text:SetText("")
        end
    end

    -- Maul queued
    if IsCurrentSpell and IsCurrentSpell(S.Maul) then
        maul:SetText("MAUL QUEUED")
    else
        maul:SetText("")
    end

    -- Clearcasting
    ccText:SetText(playerBuff(S.Clearcast) and "CLEARCAST — free GCD" or "")

    -- Form warning (only meaningful in combat)
    if UnitAffectingCombat("player") and not inBearForm() then
        formWarn:SetText("!! NOT IN BEAR FORM !!")
    else
        formWarn:SetText("")
    end

    -- Suggester
    local nextSpell, why = suggestNext()
    local _, _, tex = GetSpellInfo(nextSpell)
    if tex then sug.icon:SetTexture(tex) end
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
        print("|cff88ccff[BearChad]|r unlocked. Drag body to move, corner to resize.")
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
    else
        print("|cff88ccff[BearChad]|r /bc lock | unlock | reset | scale <0.5-2.5> | aoe <on|off|auto>")
    end
end

print("|cff88ccff[BearChad]|r loaded. Out-thread Chad.")
