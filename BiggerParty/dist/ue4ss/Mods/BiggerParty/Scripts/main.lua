-- BiggerParty — Lua half. Solasta II (Brimstone), UE4SS.
--
-- The native half (version.dll next to the game exe) patches the three hard-coded party-size literals.
-- This half does the things that are level content or UI:
--   * spawns extra PartyAvatarSpawn markers in the character-creation level (host only),
--   * shrinks the character cards so all slots fit, widens the creation camera,
--   * adds "5".."N" to the players radio group on the multiplayer host screen,
--   * owns the on/off toggle: it rewrites BiggerParty.ini and the DLL's watcher follows within a second.
--
-- Config (Brimstone\Binaries\Win64\BiggerParty.ini, shared with the DLL):
--   [BiggerParty]
--   Enabled=1
--   PartySize=6
--   CameraFovMultiplier=1.35     (optional; default grows with PartySize)
--
-- Hotkeys:
--   Ctrl+Shift+Tab         toggle Enabled on/off (takes effect for the next new campaign / lobby)
--   Ctrl+Shift+End         re-apply card layout + camera on the current creation screen
--   Ctrl+Shift+Backspace   status report to the UE4SS log (config, DLL log tail, party/slot counts)

local UEHelpers = require("UEHelpers")
local TAG = "[BiggerParty] "

local function Out(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end
local function Try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end; return nil end
local function Count(arr) if arr == nil then return -1 end; local ok, n = pcall(function() return #arr end); return ok and n or -1 end
local function ShortName(full) return full:match("([^%.:]+)$") or full end
local function IsInstance(o) return o and o:IsValid() and not o:GetFullName():find("Default__", 1, true) end
local function Instances(className)
    local out = {}
    local ok, found = pcall(FindAllOf, className)
    for _, o in ipairs((ok and found) or {}) do if IsInstance(o) then out[#out + 1] = o end end
    return out
end
local function NameOf(v)
    if v == nil then return "nil" end
    local ok, s = pcall(function() return v.TagName:ToString() end); if ok then return s end
    ok, s = pcall(function() return v:ToString() end); if ok then return s end
    return tostring(v)
end
local function ClassName(o) local ok, s = pcall(function() return o:GetClass():GetFullName() end); return ok and (s:match("([^%.]+)$") or s) or "?" end

--------------------------------------------------------------------------------------------------
-- Config (shared ini)
--------------------------------------------------------------------------------------------------
local INI_NAME = "BiggerParty.ini"
local iniPath = nil

-- Unreal FString/FText values come back as userdata; turn them into Lua strings.
local function Str(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and s or nil
end

local function FindIniPath()
    if iniPath then return iniPath end
    local candidates = {}
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local proj = Str(Try(function() return ksl:GetProjectDirectory() end))
    if proj and #proj > 0 then
        local bpl = StaticFindObject("/Script/Engine.Default__BlueprintPathsLibrary")
        local full = Str(Try(function() return bpl:ConvertRelativePathToFull(proj, "") end))
        candidates[#candidates + 1] = (full or proj) .. "Binaries/Win64/" .. INI_NAME
        candidates[#candidates + 1] = proj .. "Binaries/Win64/" .. INI_NAME
    end
    candidates[#candidates + 1] = INI_NAME
    candidates[#candidates + 1] = "../../../Brimstone/Binaries/Win64/" .. INI_NAME
    for _, c in ipairs(candidates) do
        local f = io.open(c, "r")
        if f then f:close(); iniPath = c; return c end
    end
    return nil
end

local CFG = { Enabled = true, PartySize = 6, CameraFovMultiplier = nil }

local function ReadConfig()
    local p = FindIniPath()
    if not p then Out("config: %s not found next to the game exe — using defaults", INI_NAME) return end
    for line in io.lines(p) do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*([%w%.%-]+)")
        if k then
            if k:lower() == "enabled" then CFG.Enabled = (v ~= "0")
            elseif k:lower() == "partysize" then CFG.PartySize = tonumber(v) or 6
            elseif k:lower() == "camerafovmultiplier" then CFG.CameraFovMultiplier = tonumber(v) end
        end
    end
    if CFG.PartySize < 1 then CFG.PartySize = 1 end
    if CFG.PartySize > 8 then CFG.PartySize = 8 end
end

local function WriteEnabled(enabled)
    local p = FindIniPath()
    if not p then Out("config: cannot toggle — %s not found", INI_NAME) return false end
    local lines, seen = {}, false
    for line in io.lines(p) do
        if line:match("^%s*[Ee]nabled%s*=") then lines[#lines + 1] = "Enabled=" .. (enabled and "1" or "0"); seen = true
        else lines[#lines + 1] = line end
    end
    if not seen then lines[#lines + 1] = "Enabled=" .. (enabled and "1" or "0") end
    local f = io.open(p, "w")
    if not f then Out("config: cannot write %s", p) return false end
    f:write(table.concat(lines, "\n"), "\n"); f:close()
    return true
end

local function Active() return CFG.Enabled and CFG.PartySize > 4 end
local function FovMult() return CFG.CameraFovMultiplier or (1 + (CFG.PartySize - 4) * 0.175) end

--------------------------------------------------------------------------------------------------
-- Creation level: extra spawn markers
--------------------------------------------------------------------------------------------------
local function ActorHasTag(actor, tagName)
    local tags = Try(function() return actor.Tags end)
    for i = 1, Count(tags) do if NameOf(tags[i]) == tagName then return true end end
    return false
end
local function LevelOf(obj) local outer = Try(function() return obj:GetOuter() end); return (outer and outer:IsValid()) and outer:GetFullName() or "?" end
local function TaggedActorsInLevelOf(owner, tagName)
    local level, tagged = LevelOf(owner), {}
    for _, a in ipairs(Instances("Actor")) do
        if LevelOf(a) == level and ActorHasTag(a, tagName) then tagged[#tagged + 1] = a end
    end
    return tagged
end
local function Vec(v) return { X = v.X, Y = v.Y, Z = v.Z } end
local function Rot(r) return { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } end

local function SpawnMarkers(worldContext, markers, count, spawnTag)
    if count <= 0 or #markers < 2 then return 0 end
    local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local tpClass = StaticFindObject("/Script/Engine.TargetPoint")
    if not (statics and statics:IsValid() and tpClass and tpClass:IsValid()) then Out("markers: GameplayStatics/TargetPoint missing") return 0 end
    local locs, rots = {}, {}
    for i, m in ipairs(markers) do
        local okl, l = pcall(function() return m:K2_GetActorLocation() end)
        local okr, r = pcall(function() return m:K2_GetActorRotation() end)
        if not (okl and okr) then Out("markers: cannot read marker %d: %s", i, tostring(l)) return 0 end
        locs[i] = Vec(l); rots[i] = Rot(r)
    end
    local n = #markers
    local stepR = { X = locs[n].X - locs[n-1].X, Y = locs[n].Y - locs[n-1].Y, Z = locs[n].Z - locs[n-1].Z }
    local stepL = { X = locs[1].X - locs[2].X, Y = locs[1].Y - locs[2].Y, Z = locs[1].Z - locs[2].Z }
    local spawned, r, l = 0, 0, 0
    for i = 1, count do
        local loc, rot
        if i % 2 == 1 then r = r + 1; loc = { X = locs[n].X + stepR.X * r, Y = locs[n].Y + stepR.Y * r, Z = locs[n].Z + stepR.Z * r }; rot = rots[n]
        else l = l + 1; loc = { X = locs[1].X + stepL.X * l, Y = locs[1].Y + stepL.Y * l, Z = locs[1].Z + stepL.Z * l }; rot = rots[1] end
        local ok, err = pcall(function()
            local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = loc, Scale3D = { X = 1, Y = 1, Z = 1 } }
            local actor = statics:BeginDeferredActorSpawnFromClass(worldContext, tpClass, xf, 1, nil, 0)
            if not (actor and actor:IsValid()) then error("spawn returned nothing") end
            statics:FinishSpawningActor(actor, xf, 0)
            actor:K2_TeleportTo(loc, rot)
            local tags = actor.Tags
            tags[#tags + 1] = FName(spawnTag)
            if NameOf(tags[#tags]) ~= spawnTag then error("tag did not stick") end
        end)
        if ok then spawned = spawned + 1 else Out("markers: spawn %d failed: %s", i, tostring(err)) end
    end
    return spawned
end

local function EnsureMarkers(pcm)
    local owner = Try(function() return pcm:GetOwner() end)
    if not (owner and owner:IsValid()) then owner = Try(function() return pcm:GetOuter() end) end
    if not (owner and owner:IsValid()) then Out("markers: creation manager has no owner") return end
    if not owner:HasAuthority() then Out("markers: not the host — skipping (host places the markers)") return end
    local spawnTag = NameOf(Try(function() return pcm.SpawnAvatarTransformTag end))
    if spawnTag == "nil" or spawnTag == "None" then Out("markers: SpawnAvatarTransformTag unreadable") return end
    local tagged = TaggedActorsInLevelOf(owner, spawnTag)
    if #tagged >= CFG.PartySize then Out("markers: %d already present", #tagged) return end
    local added = SpawnMarkers(owner, tagged, CFG.PartySize - #tagged, spawnTag)
    Out("markers: %d existing + %d spawned = %d character slots in creation", #tagged, added, #tagged + added)
end

--------------------------------------------------------------------------------------------------
-- Creation screen: card layout + camera
--------------------------------------------------------------------------------------------------
local function ForEachWidget(w, fn, depth)
    depth = depth or 0
    if not (w and w:IsValid()) or depth > 40 then return end
    fn(w)
    local tree = Try(function() return w.WidgetTree end)
    if tree and tree:IsValid() then ForEachWidget(Try(function() return tree.RootWidget end), fn, depth + 1) return end
    local n = Try(function() return w:GetChildrenCount() end)
    if n and n > 0 then for k = 0, n - 1 do ForEachWidget(Try(function() return w:GetChildAt(k) end), fn, depth + 1) end end
end

local ADJUSTED = {}
local function FixLayout()
    local f = 4 / CFG.PartySize
    local sizeBoxClass = StaticFindObject("/Script/UMG.SizeBox")
    local hSlotClass = StaticFindObject("/Script/UMG.HorizontalBoxSlot")
    for _, screen in ipairs(Instances("PartySetupScreen")) do
        local tbl = Try(function() return screen.CharacterSlotsTable end)
        if not (tbl and tbl:IsValid()) then return end
        local nCards = Try(function() return tbl:GetChildrenCount() end) or 0
        local boxes = 0
        for k = 0, nCards - 1 do
            local card = Try(function() return tbl:GetChildAt(k) end)
            if card and card:IsValid() then
                local slot = Try(function() return card.Slot end)
                if slot and slot:IsValid() and slot:IsA(hSlotClass) and not ADJUSTED[slot:GetAddress()] then
                    local pad = Try(function() return slot.Padding end)
                    if pad and pcall(function() slot:SetPadding({ Left = pad.Left * f, Top = pad.Top, Right = pad.Right * f, Bottom = pad.Bottom }) end) then ADJUSTED[slot:GetAddress()] = true end
                end
                ForEachWidget(card, function(w)
                    if w:IsA(sizeBoxClass) and not ADJUSTED[w:GetAddress()] then
                        local over = Try(function() return w.bOverride_WidthOverride end)
                        local width = Try(function() return w.WidthOverride end) or 0
                        if over and width > 0 and pcall(function() w:SetWidthOverride(width * f) end) then boxes = boxes + 1; ADJUSTED[w:GetAddress()] = true end
                        local minOver = Try(function() return w.bOverride_MinDesiredWidth end)
                        local minW = Try(function() return w.MinDesiredWidth end) or 0
                        if minOver and minW > 0 then pcall(function() w:SetMinDesiredWidth(minW * f) end) end
                    end
                end)
            end
        end
        if boxes > 0 then Out("layout: %d cards, shrank %d width overrides by %.2f", nCards, boxes, f) end
    end
end

local CAMERA_DONE = {}
local function WidenCamera()
    local pc = UEHelpers.GetPlayerController()
    if not (pc and pc:IsValid()) then return end
    local vt = Try(function() return pc:GetViewTarget() end)
    if not (vt and vt:IsValid()) or CAMERA_DONE[vt:GetAddress()] then return end
    local cam = Try(function() return vt:GetComponentByClass(StaticFindObject("/Script/Engine.CameraComponent")) end)
    if not (cam and cam:IsValid()) then return end
    local fov = Try(function() return cam.FieldOfView end) or 0
    if fov > 0 and fov < 120 then
        local mult = FovMult()
        if pcall(function() cam:SetFieldOfView(fov * mult) end) then
            CAMERA_DONE[vt:GetAddress()] = true
            Out("camera: %s FOV %.1f -> %.1f", ShortName(vt:GetFullName()), fov, fov * mult)
        end
    end
end

local function ApplyCreationScreenTweaks(label)
    for _, ms in ipairs({ 2500, 6000 }) do
        ExecuteWithDelay(ms, function()
            if not Active() then return end
            pcall(FixLayout); pcall(WidenCamera)
        end)
    end
end

--------------------------------------------------------------------------------------------------
-- Session / lobby screens: the player tiles live in a 2-column grid sized for 4. Re-flow them into
-- 3 columns (4 columns for 7-8) and shrink the tiles' fixed widths so two rows still fit.
--------------------------------------------------------------------------------------------------
local TILES_DONE = {}
local function FixPlayerTiles(screen)
    if not Active() then return end
    local cont = Try(function() return screen.PlayerSlotsContainer end)
    if not (cont and cont:IsValid()) then return end
    local n = Try(function() return cont:GetChildrenCount() end) or 0
    if n <= 4 then return end
    local cols = n > 6 and 4 or 3
    local f = 2 / cols
    local gridSlotClass = StaticFindObject("/Script/UMG.UniformGridSlot")
    local gridSlotClass2 = StaticFindObject("/Script/UMG.GridSlot")
    local sizeBoxClass = StaticFindObject("/Script/UMG.SizeBox")
    local moved, boxes = 0, 0
    for k = 0, n - 1 do
        local tile = Try(function() return cont:GetChildAt(k) end)
        if tile and tile:IsValid() then
            local slot = Try(function() return tile.Slot end)
            if slot and slot:IsValid() and (slot:IsA(gridSlotClass) or slot:IsA(gridSlotClass2)) then
                local row, col = math.floor(k / cols), k % cols
                if Try(function() return slot.Row end) ~= row or Try(function() return slot.Column end) ~= col then
                    if pcall(function() slot:SetRow(row); slot:SetColumn(col) end) then moved = moved + 1 end
                end
            end
            ForEachWidget(tile, function(w)
                if w:IsA(sizeBoxClass) and not TILES_DONE[w:GetAddress()] then
                    local over = Try(function() return w.bOverride_WidthOverride end)
                    local width = Try(function() return w.WidthOverride end) or 0
                    if over and width > 0 and pcall(function() w:SetWidthOverride(width * f) end) then boxes = boxes + 1; TILES_DONE[w:GetAddress()] = true end
                    local hOver = Try(function() return w.bOverride_HeightOverride end)
                    local height = Try(function() return w.HeightOverride end) or 0
                    if hOver and height > 0 and cols > 3 and pcall(function() w:SetHeightOverride(height * 0.85) end) then TILES_DONE[w:GetAddress()] = true end
                end
            end)
        end
    end
    if moved > 0 or boxes > 0 then Out("lobby: %d player tiles -> %d columns (%d moved, %d widths shrunk)", n, cols, moved, boxes) end
end

local function WatchSessionScreen(screen)
    -- tiles are (re)built when players join/leave; re-check every 2 s while the screen lives
    local stop = false
    LoopAsync(2000, function()
        if stop then return true end
        ExecuteInGameThread(function()             -- UObjects must only be touched on the game thread
            if not screen:IsValid() then stop = true return end
            pcall(FixPlayerTiles, screen)
        end)
        return false
    end)
    ExecuteWithDelay(300, function() if screen:IsValid() then pcall(FixPlayerTiles, screen) end end)
end

--------------------------------------------------------------------------------------------------
-- Multiplayer host screen: players radio group 2/3/4 -> 2..PartySize
--------------------------------------------------------------------------------------------------
local RADIO_DONE = {}
local function ExtendPlayersRadio(screen)
    if not Active() then return end
    local rg = Try(function() return screen.SettingPlayersNumber end)
    if not (rg and rg:IsValid()) or RADIO_DONE[rg:GetAddress()] then return end
    local opts = Try(function() return rg.RadioOptions end)
    local n = Count(opts)
    if n < 1 then Out("host screen: RadioOptions unreadable") return end
    local labels = {}
    for i = 1, n do labels[i] = Try(function() return opts[i]:ToString() end) or "?" end
    local wantCount = CFG.PartySize - 1          -- options are 2..PartySize
    if n >= wantCount then RADIO_DONE[rg:GetAddress()] = true return end
    local ok, err = pcall(function()
        for v = n + 2, CFG.PartySize do
            opts[#opts + 1] = FText(tostring(v))
        end
        rg:SetRadioOptions(opts)
    end)
    if ok then
        RADIO_DONE[rg:GetAddress()] = true
        Out("host screen: players options were [%s], now 2..%d", table.concat(labels, ", "), CFG.PartySize)
    else
        Out("host screen: could not extend players options: %s", tostring(err))
    end
end

--------------------------------------------------------------------------------------------------
-- Status report
--------------------------------------------------------------------------------------------------
local function Report()
    ReadConfig()
    Out("config: Enabled=%s PartySize=%d FovMult=%.2f (%s)", tostring(CFG.Enabled), CFG.PartySize, FovMult(), iniPath or "ini not found")
    local p = FindIniPath()
    if p then
        local logp = p:gsub(INI_NAME .. "$", "BiggerParty.log")
        local f = io.open(logp, "r")
        if f then
            local lines = {}
            for line in f:lines() do lines[#lines + 1] = line end
            f:close()
            Out("dll log (%s):", logp)
            for i = math.max(1, #lines - 8), #lines do Out("   %s", lines[i]) end
        else
            Out("dll log not found (%s) — is version.dll installed next to the game exe?", logp)
        end
    end
    for _, pcm in ipairs(Instances("PartyCreationManagerComponent")) do
        Out("creation: EditionCharacters=%d", Count(Try(function() return pcm.EditionCharacters end)))
    end
    for _, vm in ipairs(Instances("GameSessionViewModel")) do
        Out("session: CharacterSlots=%d PlayerSlots=%d IsMultiplayer=%s AmIHost=%s",
            Count(Try(function() return vm.CharacterSlots end)), Count(Try(function() return vm.PlayerSlots end)),
            tostring(Try(function() return vm.IsMultiplayer end)), tostring(Try(function() return vm.AmIHost end)))
    end
    for _, pc in ipairs(Instances("PartyComponent")) do
        Out("party: %d members", Count(Try(function() return pc.Party end)))
    end
end

--------------------------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------------------------
ReadConfig()

local okA, errA = pcall(function()
    NotifyOnNewObject("/Script/Brimstone.PartyCreationManagerComponent", function(obj)
        ReadConfig()
        if not Active() then return end
        local ok, err = pcall(EnsureMarkers, obj)
        if not ok then Out("markers error: %s", tostring(err)) end
        ApplyCreationScreenTweaks("creation")
    end)
end)
if not okA then Out("FAIL NotifyOnNewObject PartyCreationManagerComponent: %s", tostring(errA)) end

local okB, errB = pcall(function()
    NotifyOnNewObject("/Script/Brimstone.MultiplayerOptionsScreen", function(obj)
        ReadConfig()
        if not Active() then return end
        ExecuteWithDelay(500, function()
            if obj:IsValid() then local ok, err = pcall(ExtendPlayersRadio, obj); if not ok then Out("host screen error: %s", tostring(err)) end end
        end)
    end)
end)
if not okB then Out("FAIL NotifyOnNewObject MultiplayerOptionsScreen: %s", tostring(errB)) end

for _, cls in ipairs({ "/Script/Brimstone.SessionSetupScreen", "/Script/Brimstone.MultiplayerSettingsScreen" }) do
    local okC, errC = pcall(function()
        NotifyOnNewObject(cls, function(obj)
            ReadConfig()
            if Active() then WatchSessionScreen(obj) end
        end)
    end)
    if not okC then Out("FAIL NotifyOnNewObject %s: %s", cls, tostring(errC)) end
end

RegisterKeyBind(Key.TAB, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    ReadConfig()
    local newState = not CFG.Enabled
    if WriteEnabled(newState) then
        CFG.Enabled = newState
        Out("%s — applies to the next new campaign / lobby (party size %d)", newState and "ENABLED" or "DISABLED", CFG.PartySize)
    end
end)

RegisterKeyBind(Key.END, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    ExecuteInGameThread(function()
        ReadConfig()
        if not Active() then Out("disabled — nothing to apply") return end
        pcall(FixLayout); pcall(WidenCamera)
        for _, s in ipairs(Instances("MultiplayerOptionsScreen")) do pcall(ExtendPlayersRadio, s) end
        for _, s in ipairs(Instances("SessionSetupScreen")) do pcall(FixPlayerTiles, s) end
        for _, s in ipairs(Instances("MultiplayerSettingsScreen")) do pcall(FixPlayerTiles, s) end
        Out("re-applied layout/camera/host-screen tweaks")
    end)
end)

RegisterKeyBind(Key.BACKSPACE, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    ExecuteInGameThread(function() local ok, err = pcall(Report); if not ok then Out("report failed: %s", tostring(err)) end end)
end)

Out("loaded — Enabled=%s PartySize=%d (%s). Ctrl+Shift+Tab toggle, Ctrl+Shift+End re-apply, Ctrl+Shift+Backspace status",
    tostring(CFG.Enabled), CFG.PartySize, iniPath or "ini not found: using defaults")
