-- BiggerParty — Lua half. Solasta II (Brimstone), UE4SS.
--
-- The native half (version.dll, next to the game exe) patches the four hard-coded party-size literals.
-- This half handles what is level content or UI:
--   * spawns extra PartyAvatarSpawn markers in the character-creation level (host only),
--   * shrinks the character cards so all slots fit, and widens the creation camera,
--   * extends the players selector on the multiplayer host screen to 2..N and re-flows the lobby tiles,
--   * extends the inspection screen's portrait strip (extra portraits, selection ring and click),
--   * fits the per-hero rows on the rest screens,
--   * keeps story dialogues working with more than four heroes (see the dialogue section below),
--   * owns the on/off toggle: it rewrites BiggerParty.ini and the DLL's watcher follows within a second.
--
-- Config (Brimstone\Binaries\Win64\BiggerParty.ini, shared with the DLL):
--   [BiggerParty]
--   Enabled=1
--   PartySize=6
--   MaxPlayers=6                 (human players per hosted session; default = PartySize)
--   CameraFovMultiplier=1.35     (optional; default grows with PartySize)
--   EnemyHitPointsPercent=100    (hostile monsters' maximum hit points, % of their definition; host only)
--   CombatExperienceAsIfFour=1   (combat XP per hero as in a four-hero party; the game splits it by head count; host only)
--
-- Hotkeys:
--   Ctrl+Shift+Tab         toggle Enabled on/off (takes effect for the next new campaign / lobby)
--   Ctrl+Shift+End         re-apply the UI tweaks on the current screen
--   Ctrl+Shift+Backspace   status report to the UE4SS log (config, DLL log tail, party/slot counts, roles)
--   Ctrl+Shift+Up / Down   enemy hit points +10% / -10% (written to the ini, applied to the monsters around)
--   Ctrl+Shift+F           party heal: re-activate the formation manager, restart follower AI, re-select

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
-- Scheduling. Everything the mod does runs on the game thread. UE4SS executes LoopAsync/ExecuteWithDelay
-- callbacks on its own thread and key-bind callbacks on its input thread, without the lock the game-thread
-- paths hold; two threads inside one Lua state corrupt its heap (random crashes, worst while a screen full
-- of widgets is open). So timers use the game-thread variants, and key binds only raise a flag that a
-- game-thread poll picks up.
--------------------------------------------------------------------------------------------------
local function Every(ms, fn)      -- fn runs on the game thread every ms; return true from fn to stop
    if LoopInGameThreadWithDelay then
        local handle
        handle = LoopInGameThreadWithDelay(ms, function()
            local ok, stop = pcall(fn)
            if not ok then Out("timer error: %s", tostring(stop)) end
            if ok and stop and handle and CancelDelayedAction then pcall(CancelDelayedAction, handle) end
        end)
        return handle
    end
    local stopped = false            -- older UE4SS without game-thread timers
    LoopAsync(ms, function()
        if stopped then return true end
        ExecuteInGameThread(function() local ok, stop = pcall(fn); if ok and stop then stopped = true end end)
        return false
    end)
end
local function After(ms, fn)      -- fn runs on the game thread once, after ms
    if ExecuteInGameThreadWithDelay then
        ExecuteInGameThreadWithDelay(ms, function() local ok, err = pcall(fn); if not ok then Out("timer error: %s", tostring(err)) end end)
    else
        ExecuteWithDelay(ms, function() ExecuteInGameThread(function() pcall(fn) end) end)
    end
end
-- key binds only set one of these; the game-thread poll in the wiring section acts on them
local PRESSED = { click = false, toggle = false, reapply = false, report = false, heal = false, hpUp = false, hpDown = false }

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

local CFG = { Enabled = true, PartySize = 6, MaxPlayers = 0, CameraFovMultiplier = nil, EnemyHitPointsPercent = 100, CombatExperienceAsIfFour = true }   -- MaxPlayers 0 = follow PartySize

local function ReadConfig()
    local p = FindIniPath()
    if not p then Out("config: %s not found next to the game exe — using defaults", INI_NAME) return end
    for line in io.lines(p) do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*([%w%.%-]+)")
        if k then
            if k:lower() == "enabled" then CFG.Enabled = (v ~= "0")
            elseif k:lower() == "partysize" then CFG.PartySize = tonumber(v) or 6
            elseif k:lower() == "maxplayers" then CFG.MaxPlayers = tonumber(v) or 0
            elseif k:lower() == "camerafovmultiplier" then CFG.CameraFovMultiplier = tonumber(v)
            elseif k:lower() == "enemyhitpointspercent" then CFG.EnemyHitPointsPercent = tonumber(v) or 100
            elseif k:lower() == "combatexperienceasiffour" then CFG.CombatExperienceAsIfFour = (v ~= "0") end
        end
    end
    if CFG.PartySize < 1 then CFG.PartySize = 1 end
    if CFG.PartySize > 8 then CFG.PartySize = 8 end
    if CFG.MaxPlayers <= 0 then CFG.MaxPlayers = CFG.PartySize end
    if CFG.MaxPlayers > CFG.PartySize then CFG.MaxPlayers = CFG.PartySize end
    CFG.EnemyHitPointsPercent = math.floor((CFG.EnemyHitPointsPercent or 100) + 0.5)
    if CFG.EnemyHitPointsPercent < 50 then CFG.EnemyHitPointsPercent = 50 end
    if CFG.EnemyHitPointsPercent > 500 then CFG.EnemyHitPointsPercent = 500 end
end

-- The Narrator mod (optional) speaks lines appended to its queue file next to the ini: a spoken cue
-- for settings changed on a key, since the log is the only other place the value shows
local ANNOUNCE_SEQ = 0
local function Announce(text)
    local p = FindIniPath()
    if not p then return false end
    local dir = p:gsub("[^/\\]*$", "")
    local exe = io.open(dir .. "Narrator/SolastaNarrator.exe", "rb")
    if not exe then return false end
    exe:close()
    local f = io.open(dir .. "Narrator/queue.txt", "a")
    if not f then return false end
    ANNOUNCE_SEQ = ANNOUNCE_SEQ + 1
    f:write(string.format('{"seq":%d,"kind":"sample","text":"%s"}\n', ANNOUNCE_SEQ, text:gsub('"', "'")))
    f:close()
    return true
end

-- rewrite one key in the ini (kept in place; appended when missing). The DLL's watcher re-reads it within a second.
local function WriteIniValue(key, value)
    local p = FindIniPath()
    if not p then Out("config: cannot write %s — %s not found", key, INI_NAME) return false end
    local lines, seen = {}, false
    local pat = "^%s*" .. key:gsub("%a", function(c) return "[" .. c:upper() .. c:lower() .. "]" end) .. "%s*="
    for line in io.lines(p) do
        if line:match(pat) then lines[#lines + 1] = key .. "=" .. value; seen = true
        else lines[#lines + 1] = line end
    end
    if not seen then lines[#lines + 1] = key .. "=" .. value end
    local f = io.open(p, "w")
    if not f then Out("config: cannot write %s", p) return false end
    f:write(table.concat(lines, "\n"), "\n"); f:close()
    return true
end
local function WriteEnabled(enabled) return WriteIniValue("Enabled", enabled and "1" or "0") end

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
        After(ms, function()
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
    Every(2000, function()
        if not screen:IsValid() then return true end
        pcall(FixPlayerTiles, screen)
    end)
    After(300, function() if screen:IsValid() then pcall(FixPlayerTiles, screen) end end)
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
    local wantCount = CFG.MaxPlayers - 1         -- options are 2..MaxPlayers
    if n >= wantCount then RADIO_DONE[rg:GetAddress()] = true return end
    local ok, err = pcall(function()
        for v = n + 2, CFG.MaxPlayers do
            opts[#opts + 1] = FText(tostring(v))
        end
        rg:SetRadioOptions(opts)
    end)
    if ok then
        RADIO_DONE[rg:GetAddress()] = true
        Out("host screen: players options were [%s], now 2..%d", table.concat(labels, ", "), CFG.MaxPlayers)
    else
        Out("host screen: could not extend players options: %s", tostring(err))
    end
end

--------------------------------------------------------------------------------------------------
-- Inspection screen party strip: UPlayerSelectionGroup builds one CharacterPlateExploration plate per
-- controlled character into CharacterPlatesTable (a HorizontalBox inside the CharacterPlatesSB size
-- box). With six heroes the plates exist but only four show. Fix both likely causes: widen the size
-- box, and un-collapse plates. Tab cycling is handled correctly by the game itself.
--------------------------------------------------------------------------------------------------
local STRIP_DONE = {}

-- Walk up from the plates table: report every ancestor's slot and widen fixed-size containers.
-- UMG's UserWidget class object is not always resolvable by path from Lua; fall back to the class-name chain.
local function IsUserWidget(obj)
    if not (obj and obj:IsValid()) then return false end
    local c = StaticFindObject("/Script/UMG.UserWidget")
    if c and c:IsValid() then local ok, r = pcall(function() return obj:IsA(c) end); if ok then return r end end
    local k = Try(function() return obj:GetClass() end)
    for _ = 1, 8 do
        if not (k and k:IsValid()) then break end
        if (k:GetFullName():match("([^%.]+)$") or "") == "UserWidget" then return true end
        k = Try(function() return k:GetSuperStruct() end)
    end
    return false
end
local ANCESTOR_DONE = {}
local function FixStripAncestors(tbl, factor, verbose)
    local canvasSlotClass = StaticFindObject("/Script/UMG.CanvasPanelSlot")
    local sizeBoxClass = StaticFindObject("/Script/UMG.SizeBox")
    local w = tbl
    for depth = 0, 14 do
        if not (w and w:IsValid()) then break end
        local slot = Try(function() return w.Slot end)
        local info = string.format("%s (%s) clip=%s", ShortName(w:GetFullName()), ClassName(w), tostring(Try(function() return w.Clipping end)))
        if slot and slot:IsValid() then
            info = info .. " slot=" .. ClassName(slot)
            if slot:IsA(canvasSlotClass) then
                local auto = Try(function() return slot:GetAutoSize() end)
                local size = Try(function() return slot:GetSize() end)
                local pos = Try(function() return slot:GetPosition() end)
                info = info .. string.format(" canvas auto=%s size=%s pos=%s", tostring(auto), size and string.format("%.0fx%.0f", size.X, size.Y) or "?", pos and string.format("%.0f,%.0f", pos.X, pos.Y) or "?")
                if not auto and size and size.X > 0 and factor and not ANCESTOR_DONE[slot:GetAddress()] then
                    if pcall(function() slot:SetSize({ X = size.X * factor, Y = size.Y }) end) then
                        ANCESTOR_DONE[slot:GetAddress()] = true
                        info = info .. string.format(" -> width x%.2f", factor)
                    end
                end
            end
        end
        if w:IsA(sizeBoxClass) then
            local over = Try(function() return w.bOverride_WidthOverride end)
            local width = Try(function() return w.WidthOverride end) or 0
            local maxOver = Try(function() return w.bOverride_MaxDesiredWidth end)
            local maxW = Try(function() return w.MaxDesiredWidth end) or 0
            info = info .. string.format(" sizebox w=%s%.0f max=%s%.0f", over and "" or "(off)", width, maxOver and "" or "(off)", maxW)
            if factor and not ANCESTOR_DONE[w:GetAddress()] then
                if over and width > 0 then pcall(function() w:SetWidthOverride(width * factor) end) end
                if maxOver and maxW > 0 then pcall(function() w:SetMaxDesiredWidth(maxW * factor) end) end
                if (over and width > 0) or (maxOver and maxW > 0) then ANCESTOR_DONE[w:GetAddress()] = true; info = info .. string.format(" -> x%.2f", factor) end
            end
        end
        if verbose then Out("   ancestor[%d] %s", depth, info) end
        local parent = Try(function() return w:GetParent() end)
        if not (parent and parent:IsValid()) then
            -- top of this widget's tree: hop to the UserWidget that owns it (root -> WidgetTree -> UserWidget)
            local tree = Try(function() return w:GetOuter() end)
            local owner = tree and tree:IsValid() and Try(function() return tree:GetOuter() end)
            if owner and owner:IsValid() and IsUserWidget(owner) and owner:GetAddress() ~= w:GetAddress() then parent = owner end
        end
        w = parent
    end
end


local function SessionIsMultiplayer()
    for _, vm in ipairs(Instances("GameSessionViewModel")) do
        local mp = Try(function() return vm.IsMultiplayer end)
        if mp ~= nil then return mp end
    end
    return false
end

local function FixPartyStrip(verbose)
    if not Active() then return end
    local sizeBoxClass = StaticFindObject("/Script/UMG.SizeBox")
    -- A hidden plate is only ours to show in single player, and only while fewer plates are visible than
    -- there are heroes. In multiplayer each player's group holds that player's heroes and the game hides
    -- plates on purpose (a dropped player's characters, for one): showing them again duplicated a portrait.
    local heroes = 0
    if not SessionIsMultiplayer() then
        for _, pcmp in ipairs(Instances("PartyComponent")) do heroes = math.max(heroes, Count(Try(function() return pcmp.Party end))) end
    end
    for _, grp in ipairs(Instances("PlayerSelectionGroup")) do
        local visible = Try(function() return grp:IsVisible() end)
        if visible then
            local tbl = Try(function() return grp.CharacterPlatesTable end)
            local sb = Try(function() return grp.CharacterPlatesSB end)
            local n = tbl and tbl:IsValid() and (Try(function() return tbl:GetChildrenCount() end) or 0) or -1
            local shown, changed = 0, 0
            local hidden = {}
            for k = 0, math.max(n, 0) - 1 do
                local plate = Try(function() return tbl:GetChildAt(k) end)
                if plate and plate:IsValid() then
                    local vis = Try(function() return plate:GetVisibility() end)     -- 0 Visible 1 Collapsed 2 Hidden 3 HitTestInvisible 4 SelfHitTestInvisible
                    if vis == 1 or vis == 2 then hidden[#hidden + 1] = plate
                    elseif Try(function() return plate:IsVisible() end) then shown = shown + 1 end
                end
            end
            for _, plate in ipairs(hidden) do
                if shown >= heroes then break end
                if pcall(function() plate:SetVisibility(4) end) then changed = changed + 1; shown = shown + 1 end
            end
            local sbInfo = "no size box"
            if sb and sb:IsValid() and sb:IsA(sizeBoxClass) then
                local over = Try(function() return sb.bOverride_WidthOverride end)
                local width = Try(function() return sb.WidthOverride end) or 0
                local maxOver = Try(function() return sb.bOverride_MaxDesiredWidth end)
                local maxW = Try(function() return sb.MaxDesiredWidth end) or 0
                sbInfo = string.format("size box width=%s%.0f max=%s%.0f", over and "" or "(off)", width, maxOver and "" or "(off)", maxW)
                if n > 4 and not STRIP_DONE[sb:GetAddress()] then
                    local f = n / 4
                    if over and width > 0 then pcall(function() sb:SetWidthOverride(width * f) end) end
                    if maxOver and maxW > 0 then pcall(function() sb:SetMaxDesiredWidth(maxW * f) end) end
                    STRIP_DONE[sb:GetAddress()] = true
                    sbInfo = sbInfo .. string.format(" -> scaled by %.2f", f)
                end
            end
            local first = not STRIP_DONE["logged" .. grp:GetAddress()]
            if verbose or changed > 0 or first then
                STRIP_DONE["logged" .. grp:GetAddress()] = true
                Out("strip: %s plates=%d visible=%d uncollapsed=%d; %s", ShortName(grp:GetFullName()), n, shown, changed, sbInfo)
            end
            if n > 4 and tbl and tbl:IsValid() then pcall(FixStripAncestors, tbl, n / 4, verbose or first) end
        end
    end
end

-- Inspection screen portraits: WBP_InspectionPortrait, _1, _2, _3 are placed by hand in the Blueprint
-- (the merchant and chest screens carry their own copies). Enumerate the Blueprint class's variables and
-- functions through reflection to learn how a portrait is told which hero it shows, and extend only the
-- strip that lives inside the visible inspection screen.
local PORTRAITS_DONE = {}

-- Is this widget inside the given screen (walk parents, hopping through owning UserWidgets)?
local function IsInsideWidget(w, screen)
    for _ = 1, 30 do
        if not (w and w:IsValid()) then return false end
        if w:GetAddress() == screen:GetAddress() then return true end
        local parent = Try(function() return w:GetParent() end)
        if not (parent and parent:IsValid()) then
            local tree = Try(function() return w:GetOuter() end)
            local owner = tree and tree:IsValid() and Try(function() return tree:GetOuter() end)
            if owner and owner:IsValid() and IsUserWidget(owner) and owner:GetAddress() ~= w:GetAddress() then parent = owner end
        end
        w = parent
    end
    return false
end

-- one scan of the user widgets per pass: the screens and the click emulation share it
local UW_CACHE, UW_GEN, UW_CACHE_GEN = nil, 0, -1
local function NewScan() UW_GEN = UW_GEN + 1 end
local function UserWidgets()
    if UW_CACHE_GEN ~= UW_GEN then UW_CACHE = Instances("UserWidget"); UW_CACHE_GEN = UW_GEN end
    return UW_CACHE
end

local function InspectionPortraitsIn(screen)
    local out = {}
    for _, w in ipairs(UserWidgets()) do
        local n = w:IsValid() and ShortName(w:GetFullName()) or ""
        if (n:match("^WBP_InspectionPortrait") or n:match("^WBP_PortraitSmallCircle_WithEncumbrance")) and IsInsideWidget(w, screen) then out[#out + 1] = w end
    end
    table.sort(out, function(a, b) return a:GetFullName() < b:GetFullName() end)
    return out
end

local PORTRAIT_BOUND = {}
PORTRAIT_HERO = {}            -- extra portrait widget address -> 0-based hero index
local PORTRAIT_REC = {}       -- extra portrait widget address -> { w = widget, name = full name } (liveness check)

-- the first original portrait next to ours (same class, not one we created)
local function OriginalFor(widget)
    local parent = Try(function() return widget:GetParent() end)
    if not (parent and parent:IsValid()) then return nil end
    local cls = ClassName(widget)
    local n = Try(function() return parent:GetChildrenCount() end) or 0
    for k = 0, n - 1 do
        local c = Try(function() return parent:GetChildAt(k) end)
        if c and c:IsValid() and ClassName(c) == cls and not PORTRAIT_HERO[c:GetAddress()] then return c end
    end
    return nil
end
local function BindExtraPortrait(widget, heroIndex)      -- heroIndex is 0-based into PartyComponent.Party
    -- portraits are captured asynchronously and the manager can hand back a shared/placeholder texture at
    -- first, so keep re-applying until the same texture has been seen a few times in a row.
    local key = widget:GetAddress()
    if PORTRAIT_BOUND[key] and (PORTRAIT_BOUND["stable" .. key] or 0) >= 3 then return true end
    local party = HeroArray()
    local hero = party[heroIndex + 1]
    if not (hero and hero:IsValid()) then return false end
    local guiClass = StaticFindObject("/Script/Brimstone.GuiRulesetActorComponent")
    local comp = Try(function() return hero:GetComponentByClass(guiClass) end)
    if not (comp and comp:IsValid()) then Out("inspect: %s has no GuiRulesetActorComponent", ShortName(hero:GetFullName())) return false end
    local tex = Try(function() return comp:GetPortraitTexture() end)
    if not (tex and tex:IsValid()) then
        -- portraits are rendered on demand: ask the manager (returns the cached texture, or starts a capture)
        for _, mgr in ipairs(Instances("PortraitManagerComponent")) do
            local t = Try(function() return mgr:RequestPortrait(hero) end)
            if t and t:IsValid() then tex = t break end
        end
    end
    if not (tex and tex:IsValid()) then
        if not PORTRAIT_BOUND["warned" .. widget:GetAddress()] then
            PORTRAIT_BOUND["warned" .. widget:GetAddress()] = true
            Out("inspect: no portrait texture yet for %s (requested; retrying each second)", ShortName(hero:GetFullName()))
        end
        return false
    end
    local img = nil
    ForEachWidget(widget, function(w) if not img and ShortName(w:GetFullName()) == "PortraitImg" then img = w end end)
    if not img then Out("inspect: PortraitImg not found inside %s", ShortName(widget:GetFullName())) return false end

    -- What does an original portrait's image hold? Mirror that: same brush, same image size, and if it
    -- is a dynamic material, a fresh instance of the same parent material with our texture as parameter.
    local origImg = nil
    local firstSibling = OriginalFor(widget)
    if firstSibling and firstSibling:IsValid() then
        ForEachWidget(firstSibling, function(c) if not origImg and ShortName(c:GetFullName()) == "PortraitImg" then origImg = c end end)
    end
    local origRes = origImg and Try(function() return origImg.Brush.ResourceObject end)
    local origSize = origImg and Try(function() return origImg.Brush.ImageSize end)
    local resClass = (origRes and origRes.IsValid and origRes:IsValid()) and ClassName(origRes) or "none"
    if not PORTRAIT_BOUND["brushinfo"] then
        PORTRAIT_BOUND["brushinfo"] = true
        Out("inspect: original PortraitImg brush: resource=%s (%s) size=%s", origRes and origRes.IsValid and origRes:IsValid() and ShortName(origRes:GetFullName()) or "none", resClass,
            origSize and string.format("%.0fx%.0f", origSize.X, origSize.Y) or "?")
    end
    local ok, err
    if resClass == "MaterialInstanceDynamic" or resClass:match("^Material") then
        -- Prefer the extra portrait's OWN dynamic material (the circle widget creates one at construction and
        -- keeps a reference for SetSelected); only create a new one if it has none.
        local mid = Try(function() return img.Brush.ResourceObject end)
        local own = mid and mid.IsValid and mid:IsValid() and ClassName(mid) == "MaterialInstanceDynamic"
        -- a material shared with another portrait would make both show the same face
        if own then
            local addr = mid:GetAddress()
            local holder = PORTRAIT_BOUND["mid" .. addr]
            if holder and holder ~= key then own = false; Out("inspect: portrait %d shares material %s — creating its own", heroIndex + 1, ShortName(mid:GetFullName()))
            else PORTRAIT_BOUND["mid" .. addr] = key end
        end
        if not own then
            local mlib = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
            local parent = Try(function() return origRes.Parent end)
            if not (parent and parent:IsValid()) then parent = origRes end
            mid = Try(function() return mlib:CreateDynamicMaterialInstance(img, parent, FName("None"), 0) end)
            if not (mid and mid:IsValid()) then Out("inspect: could not create a material instance from %s", ShortName(parent:GetFullName())) return false end
            PORTRAIT_BOUND["mid" .. mid:GetAddress()] = key
        end
        -- take the parameter name from an original portrait's material: a MID stores overrides even for
        -- names the material does not have, so a read-back check cannot tell a real parameter from a typo.
        local paramSet = PORTRAIT_BOUND["paramname"]
        if not paramSet then
            local tpv = Try(function() return origRes.TextureParameterValues end)
            for t = 1, Count(tpv) do
                local pname = Try(function() return tpv[t].ParameterInfo.Name:ToString() end)
                local pval = Try(function() return tpv[t].ParameterValue end)
                if pname and pval and pval.IsValid and pval:IsValid() then paramSet = pname break end
            end
            paramSet = paramSet or "PortraitTexture"
            PORTRAIT_BOUND["paramname"] = paramSet
        end
        local okp = pcall(function() mid:SetTextureParameterValue(FName(paramSet), tex) end)
        if not okp then Out("inspect: could not set %s on %s", paramSet, ShortName(parent:GetFullName())) return false end
        if own then ok = true else ok, err = pcall(function() img:SetBrushFromMaterial(mid) end) end
        if ok and not PORTRAIT_BOUND["paraminfo"] then PORTRAIT_BOUND["paraminfo"] = true; Out("inspect: portrait material parameter = %s (%s material)", paramSet, own and "own" or "new") end
    else
        ok, err = pcall(function() img:SetBrushFromTexture(tex, false) end)
    end
    if not ok then Out("inspect: setting the portrait brush failed: %s", tostring(err)) return false end
    if origSize and origSize.X > 0 then pcall(function() img:SetDesiredSizeOverride({ X = origSize.X, Y = origSize.Y }) end) end
    -- mirror the child visibility states of an original portrait (hides the "?" placeholder etc.)
    local original = OriginalFor(widget)
    if original then
        local states = {}
        ForEachWidget(original, function(w) states[ShortName(w:GetFullName())] = Try(function() return w:GetVisibility() end) end)
        local applied = 0
        ForEachWidget(widget, function(w)
            local name = ShortName(w:GetFullName())
            local vis = states[name]
            if vis ~= nil and name ~= "PortraitImg" and Try(function() return w:GetVisibility() end) ~= vis then
                if pcall(function() w:SetVisibility(vis) end) then applied = applied + 1 end
            end
        end)
        if applied > 0 then Out("inspect: mirrored %d child visibility state(s) from the first portrait", applied) end
    end
    local texKey = tex:GetAddress()
    if PORTRAIT_BOUND["tex" .. key] == texKey then
        PORTRAIT_BOUND["stable" .. key] = (PORTRAIT_BOUND["stable" .. key] or 0) + 1
    else
        PORTRAIT_BOUND["tex" .. key] = texKey
        PORTRAIT_BOUND["stable" .. key] = 1
        Out("inspect: portrait %d now shows %s (texture %s)", heroIndex + 1, ShortName(hero:GetFullName()), ShortName(tex:GetFullName()))
    end
    PORTRAIT_BOUND[key] = true
    return true
end

local BIND_FLAG = false   -- the flag the game itself passes to InspectionScreen:Bind on a portrait click

-- Screens that carry the four hand-placed WBP_InspectionPortrait widgets. The inspection screen binds a hero
-- through InspectionScreen:Bind; the chest and merchant screens follow the party selection instead.
local PORTRAIT_SCREENS = {
    { class = "InspectionScreen", kind = "inspection" },
    { class = "ModalChestScreen", kind = "selection" },
    { class = "MerchantScreen",   kind = "selection" },
}

local function PortraitScreens()
    local out = {}
    for _, def in ipairs(PORTRAIT_SCREENS) do
        for _, screen in ipairs(Instances(def.class)) do
            if Try(function() return screen:IsVisible() end) then out[#out + 1] = { screen = screen, kind = def.kind } end
        end
    end
    return out
end

local function PartyComponentOfMine()
    local pc0 = UEHelpers.GetPlayerController()
    local pawn = pc0 and pc0:IsValid() and Try(function() return pc0:K2_GetPawn() end)
    local name = (pawn and pawn:IsValid()) and ShortName(pawn:GetFullName()):gsub("^Character_", "") or nil
    local first = nil
    for _, pcmp in ipairs(Instances("PartyComponent")) do
        local party = Try(function() return pcmp.Party end)
        local n = Count(party)
        if n > 0 then
            first = first or pcmp
            if name then
                for i = 1, n do
                    local m = party[i]
                    if m and m:IsValid() and ShortName(m:GetFullName()) == name then return pcmp end
                end
            end
        end
    end
    return first
end
local function PartyArray()
    local pcmp = PartyComponentOfMine()
    local party = pcmp and Try(function() return pcmp.Party end)
    return (Count(party) > 0) and party or nil
end
-- the heroes of the party in party order (NPC guests travelling with the party are not heroes)
local function HeroArray()
    local pcmp = PartyComponentOfMine()
    local party = pcmp and Try(function() return pcmp.Party end)
    local out = {}
    for i = 1, Count(party) do
        local m = party[i]
        if m and m:IsValid() then
            local isHero = Try(function() return pcmp:IsHero(m) end)
            if isHero == nil then isHero = not Try(function() return pcmp:IsGuest(m) end) end
            if isHero ~= false then out[#out + 1] = m end
        end
    end
    return out
end
local function PartyComponentsText()
    local parts = {}
    for _, pcmp in ipairs(Instances("PartyComponent")) do
        local owner = Try(function() return pcmp:GetOwner() end)
        parts[#parts + 1] = string.format("%s on %s: %d member(s)", ShortName(pcmp:GetFullName()), (owner and owner:IsValid()) and ShortName(owner:GetFullName()) or "?", Count(Try(function() return pcmp.Party end)))
    end
    return table.concat(parts, "; ")
end

-- party index (0-based) of a hero actor, or of the pawn (Character_<Hero>_<id>) that stands for it
local function PartyIndexOf(actor)
    local party = HeroArray()
    if not (party and actor and actor:IsValid()) then return nil end
    local name = ShortName(actor:GetFullName())
    for i = 1, #party do
        local m = party[i]
        if m and m:IsValid() then
            if m:GetAddress() == actor:GetAddress() then return i - 1 end
            local heroName = ShortName(m:GetFullName()):gsub("_%d+$", "")
            if name:gsub("_%d+$", "") == "Character_" .. heroName then return i - 1 end
        end
    end
    return nil
end

local function PawnForHero(hero)
    local base = ShortName(hero:GetFullName()):gsub("_%d+$", "")
    local prefix = "Character_" .. base
    for _, cls in ipairs({ "BrimstoneCharacter", "Character" }) do
        for _, pawn in ipairs(Instances(cls)) do
            local n = ShortName(pawn:GetFullName()):gsub("_%d+$", "")
            if n == prefix then return pawn end
        end
    end
    -- NPC party members (guests) use their own name for the pawn
    for _, pawn in ipairs(Instances("BrimstoneCharacter")) do
        if ShortName(pawn:GetFullName()):gsub("_%d+$", "") == base then return pawn end
    end
    return nil
end

local function LocalSelectionState()
    for _, c in ipairs(Instances("BrimstoneSelectionStateComponent")) do return c end
    return nil
end

-- Multiplayer: each player controls a subset of the party, and each player's followers follow that
-- player's selected hero. The player state lists the ruleset actors a player controls (replicated);
-- only the host runs the followers' AI controllers.
local function LocalPlayerState()
    local pc = UEHelpers.GetPlayerController()
    local ps = pc and pc:IsValid() and Try(function() return pc.PlayerState end)
    return (ps and ps:IsValid()) and ps or nil
end
-- the player state controlling a ruleset actor, by the game state's own lookup
local function OwnerStateOf(hero)
    if not (hero and hero:IsValid()) then return nil end
    for _, gs in ipairs(Instances("BrimstoneGameState")) do
        local ps = Try(function() return gs:FindPlayerStateControllingActor(hero) end)
        if ps and ps.IsValid and ps:IsValid() then return ps end
        return nil
    end
    return nil
end
local function IsMine(hero)      -- hero: ruleset actor
    if not (hero and hero:IsValid()) then return false end
    local mine = LocalPlayerState()
    local owner = OwnerStateOf(hero)
    if owner and mine then return owner:GetAddress() == mine:GetAddress() end
    -- no answer from the game state: ask the session's character slot, else assume single player
    for _, vm in ipairs(Instances("GameSessionViewModel")) do
        local slot = Try(function() return vm:FindCharacterSlotFromRulesetActor(hero) end)
        if slot and slot.IsValid and slot:IsValid() then
            local r = Try(function() return slot:GetIsControlledByMe() end)
            if r ~= nil then return r end
        end
        if Try(function() return vm.IsMultiplayer end) == false then return true end
    end
    return true
end
local function MyHeroSet()      -- address set of the party's ruleset actors the local player controls
    local set, n = {}, 0
    local party = PartyArray()
    for i = 1, Count(party) do
        local m = party[i]
        if m and m:IsValid() and IsMine(m) then set[m:GetAddress()] = true; n = n + 1 end
    end
    return set, n
end
local HOST_CACHE = { at = -100, value = false }
local function IsHost()
    if os.clock() - HOST_CACHE.at < 10 then return HOST_CACHE.value end
    local v = nil
    for _, vm in ipairs(Instances("GameSessionViewModel")) do
        local h = Try(function() return vm.AmIHost end)
        if h ~= nil then v = h break end
    end
    if v == nil then
        local pc = UEHelpers.GetPlayerController()
        v = (pc and pc:IsValid() and Try(function() return pc:HasAuthority() end)) or false
    end
    HOST_CACHE = { at = os.clock(), value = v }
    return v
end
local function OwnerNameOf(hero)  -- the player controlling a hero, for the report
    local ps = OwnerStateOf(hero)
    if not ps then return "nobody" end
    return Str(Try(function() return ps:GetPlayerName() end)) or ShortName(ps:GetFullName())
end

-- 0-based party index of the hero the screen currently shows
local function CurrentHeroIndex(entry)
    if entry.kind == "inspection" then
        local comp = Try(function() return entry.screen:GetGuiRulesetActor() end)
        local owner = comp and comp:IsValid() and Try(function() return comp:GetOwner() end)
        return PartyIndexOf(owner)
    end
    local sel = LocalSelectionState()
    local pc = UEHelpers.GetPlayerController()
    if not (sel and sel:IsValid() and pc and pc:IsValid()) then return nil end
    local pawn = Try(function() return sel:GetSelectedCharacter(pc) end) or Try(function() return sel:GetSelectedCharacter() end)
    if not (pawn and pawn.IsValid and pawn:IsValid()) then pawn = Try(function() return pc:K2_GetPawn() end) end
    return PartyIndexOf(pawn)
end

-- make the screen show this hero (what a click on one of the original portraits does)
local function SelectHeroOn(entry, hero)
    if entry.kind == "inspection" then
        local guiClass = StaticFindObject("/Script/Brimstone.GuiRulesetActorComponent")
        local comp = Try(function() return hero:GetComponentByClass(guiClass) end)
        if not (comp and comp:IsValid()) then return false, "no GuiRulesetActorComponent" end
        return pcall(function() entry.screen:Bind(comp, BIND_FLAG) end)
    end
    local pawn = PawnForHero(hero)
    local sel = LocalSelectionState()
    local pc = UEHelpers.GetPlayerController()
    if not (pawn and sel and sel:IsValid() and pc and pc:IsValid()) then return false, "no pawn / selection state" end
    return pcall(function() sel:SelectCharacter(pawn, pc, true, true) end)
end

-- Blueprint reflection: find a function up the class chain, list its parameters, and call it with the
-- hero / portrait widget matched to the parameter types (the chest screen's own handlers take one of them).
local function FunctionOf(obj, name)
    local found = nil
    local cls = Try(function() return obj:GetClass() end)
    local depth = 0
    while cls and cls:IsValid() and not found and depth < 12 do
        pcall(function() cls:ForEachFunction(function(fn) if not found and ShortName(fn:GetFullName()) == name then found = fn end end) end)
        cls = Try(function() return cls:GetSuperStruct() end)
        depth = depth + 1
    end
    return found
end
local function ParamsOf(fn)
    local out = {}
    local retFlag = EPropertyFlags and EPropertyFlags.CPF_ReturnParm
    local outFlag = EPropertyFlags and EPropertyFlags.CPF_OutParm
    pcall(function()
        fn:ForEachProperty(function(prop)
            local q = {}
            q.name = Try(function() return prop:GetFName():ToString() end) or "?"
            q.type = Try(function() return prop:GetClass():GetFName():ToString() end) or "?"
            if q.type:match("ObjectProperty$") or q.type:match("ClassProperty$") then
                q.class = Try(function() return ShortName(prop:GetPropertyClass():GetFullName()) end)
            end
            q.ret = (retFlag and Try(function() return prop:HasAnyPropertyFlags(retFlag) end)) or q.name == "ReturnValue"
            q.out = (outFlag and Try(function() return prop:HasAnyPropertyFlags(outFlag) end)) or false
            out[#out + 1] = q
        end)
    end)
    return out
end
local function DescribeParams(fn)
    local parts = {}
    for _, q in ipairs(ParamsOf(fn)) do
        parts[#parts + 1] = (q.ret and "-> " or "") .. q.name .. ":" .. q.type .. (q.class and ("<" .. q.class .. ">") or "")
    end
    return table.concat(parts, ", ")
end
local function CallByParams(obj, fnName, hero, widget, index)
    local fn = FunctionOf(obj, fnName)
    if not fn then return false, "no function " .. fnName, "" end
    local args, desc = {}, {}
    for _, q in ipairs(ParamsOf(fn)) do
        if not q.ret then
            local cls, nm = (q.class or ""):lower(), q.name:lower()
            local v
            if q.out then
                return false, "output parameter " .. q.name .. " not handled", DescribeParams(fn)
            elseif q.type == "ObjectProperty" then
                if cls:find("widget") or cls:find("portrait") or nm:find("widget") or nm:find("portrait") then v = widget else v = hero end
            elseif q.type == "BoolProperty" then v = true
            elseif q.type == "IntProperty" or q.type == "ByteProperty" then v = index or 0
            else
                return false, "parameter " .. q.name .. ":" .. q.type .. " not handled", DescribeParams(fn)
            end
            args[#args + 1] = v
            desc[#desc + 1] = q.name .. "=" .. ((v == hero) and "hero" or (v == widget) and "portrait" or tostring(v))
        end
    end
    local ok, err = pcall(function() return obj[fnName](obj, table.unpack(args)) end)
    return ok, err, table.concat(desc, ", ")
end

-- The chest/merchant screens bind their four portraits through the portrait's own BindToGameplay(RulesetActor)
-- (the view model behind the carried-weight gauge hangs off that). Bind ours the same way; a click then goes
-- through the screen's OnPortraitClicked(BoundRulesetActor), which makes that hero the looter.
local GAMEPLAY_BOUND = {}     -- extra widget address -> hero address bound through BindToGameplay
local function BindGameplay(entry, w, orig)
    local key = w:GetAddress()
    local k = PORTRAIT_HERO[key]
    local party = HeroArray()
    local hero = k and party[k + 1]
    if not (hero and hero:IsValid()) then return end
    local current = Try(function() return w:GetBoundActor() end)
    if current and current.IsValid and current:IsValid() and current:GetAddress() == hero:GetAddress() then GAMEPLAY_BOUND[key] = hero:GetAddress() return end
    if GAMEPLAY_BOUND[key] == hero:GetAddress() then return end
    local ok, err, sig = CallByParams(w, "BindToGameplay", hero, w, k)
    Out("inspect: portrait %d BindToGameplay(%s) -> %s", k + 1, sig, ok and "ok" or tostring(err))
    GAMEPLAY_BOUND[key] = hero:GetAddress()   -- success or not, do not retry every second
end

-- originals first (by name), then the extras we created (by hero index)
local function OrderedPortraits(screen)
    local originals, extras, orphans = {}, {}, {}
    for _, w in ipairs(InspectionPortraitsIn(screen)) do
        if PORTRAIT_HERO[w:GetAddress()] then extras[#extras + 1] = w
        elseif ShortName(w:GetFullName()):match("_C_%d+$") then orphans[#orphans + 1] = w   -- ours, from before a script reload
        else originals[#originals + 1] = w end
    end
    if #orphans > 0 then
        -- newer objects carry lower numbers: creation order is descending by the suffix
        table.sort(orphans, function(a, b)
            return tonumber(ShortName(a:GetFullName()):match("(%d+)$")) > tonumber(ShortName(b:GetFullName()):match("(%d+)$"))
        end)
        for i, w in ipairs(orphans) do
            local k = #originals + #extras + i - 1
            PORTRAIT_HERO[w:GetAddress()] = k
            PORTRAIT_REC[w:GetAddress()] = { w = w, name = w:GetFullName() }
            extras[#extras + 1] = w
        end
        Out("inspect: recovered %d portrait(s) created before the script reload on %s", #orphans, ShortName(screen:GetFullName()))
    end
    table.sort(extras, function(a, b) return PORTRAIT_HERO[a:GetAddress()] < PORTRAIT_HERO[b:GetAddress()] end)
    return originals, extras
end

local function CopyPadding(from, to)
    local pad = from and Try(function() return from.Slot.Padding end)
    if pad and to then pcall(function() to.Slot:SetPadding({ Left = pad.Left, Top = pad.Top, Right = pad.Right, Bottom = pad.Bottom }) end) end
end

local function ExtendInspectionPortraits(verbose)
    if not Active() then return end
    local nHeroes = #HeroArray()
    if nHeroes <= 4 then return end
    for _, entry in ipairs(PortraitScreens()) do
        local originals, extras = OrderedPortraits(entry.screen)
        if #originals > 0 then
            local last = originals[#originals]
            local parent = Try(function() return last:GetParent() end)
            if parent and parent:IsValid() then
                for _, w in ipairs(extras) do pcall(BindExtraPortrait, w, PORTRAIT_HERO[w:GetAddress()]) end
                if entry.kind == "selection" then
                    for _, w in ipairs(extras) do
                        local okG, errG = pcall(BindGameplay, entry, w, originals[1])
                        if not okG then Out("inspect: BindGameplay error: %s", tostring(errG)) end
                    end
                end
                local existing = #originals + #extras
                if existing < nHeroes and os.clock() - (PORTRAITS_DONE[parent:GetAddress()] or -100) > 5 then
                    -- whatever sits after the last portrait in the row (weight icon, hints) goes back to the end afterwards
                    local trailing = {}
                    local n = Try(function() return parent:GetChildrenCount() end) or 0
                    local lastIdx = Try(function() return parent:GetChildIndex(last) end) or (n - 1)
                    for k = lastIdx + 1, n - 1 do
                        local c = Try(function() return parent:GetChildAt(k) end)
                        if c and c:IsValid() then trailing[#trailing + 1] = c end
                    end
                    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
                    local pc = UEHelpers.GetPlayerController()
                    local cls = last:GetClass()
                    local added = 0
                    for k = existing, nHeroes - 1 do
                        local ok, err = pcall(function()
                            local w = lib:Create(last, cls, pc)
                            if not (w and w:IsValid()) then error("Create returned nothing") end
                            parent:AddChild(w)
                            CopyPadding(last, w)
                            PORTRAIT_HERO[w:GetAddress()] = k
                            PORTRAIT_REC[w:GetAddress()] = { w = w, name = w:GetFullName() }
                            added = added + 1
                        end)
                        if not ok then Out("inspect: could not add portrait %d: %s", k + 1, tostring(err)) break end
                    end
                    for _, c in ipairs(trailing) do
                        local pad = Try(function() return c.Slot.Padding end)
                        if pcall(function() parent:RemoveChild(c) end) and pcall(function() parent:AddChild(c) end) and pad then
                            pcall(function() c.Slot:SetPadding({ Left = pad.Left, Top = pad.Top, Right = pad.Right, Bottom = pad.Bottom }) end)
                        end
                    end
                    PORTRAITS_DONE[parent:GetAddress()] = os.clock()
                    Out("inspect: portraits %d -> %d on %s", existing, existing + added, ShortName(entry.screen:GetFullName()))
                end
            end
        end
    end
end

-- Selection ring for the extra portraits: the game calls the small circle's SetSelected on its own four.
local EXTRA_SELECTED = {}

-- forget extras whose widget is gone (its screen was destroyed): the address is reused by new objects
local function PruneExtras()
    for addr, rec in pairs(PORTRAIT_REC) do
        local alive = Try(function() return rec.w:IsValid() and rec.w:GetFullName() == rec.name end)
        if not alive then
            PORTRAIT_REC[addr] = nil; PORTRAIT_HERO[addr] = nil; EXTRA_SELECTED[addr] = nil; GAMEPLAY_BOUND[addr] = nil
            PORTRAIT_BOUND[addr] = nil; PORTRAIT_BOUND["stable" .. addr] = nil; PORTRAIT_BOUND["tex" .. addr] = nil; PORTRAIT_BOUND["warned" .. addr] = nil
        end
    end
end
local function UpdateExtraHighlights()
    if not Active() then return end
    for _, entry in ipairs(PortraitScreens()) do
        local idx = CurrentHeroIndex(entry)
        if idx ~= nil then
            local _, extras = OrderedPortraits(entry.screen)
            for _, w in ipairs(extras) do
                local want = (PORTRAIT_HERO[w:GetAddress()] == idx)
                if EXTRA_SELECTED[w:GetAddress()] ~= want then
                    local circle = nil
                    ForEachWidget(w, function(c) if not circle and ClassName(c) == "WBP_PortraitSmallCircle_C" then circle = c end end)
                    if circle then
                        local ok, err = pcall(function() circle:SetSelected(want) end)
                        if ok then EXTRA_SELECTED[w:GetAddress()] = want else Out("inspect: SetSelected failed: %s", tostring(err)) end
                    end
                end
            end
        end
    end
end

-- Emulated click on the extra portraits: on a left click, the hovered extra selects its hero the way the
-- screen's own portraits do.
local function ClickExtraPortraits()
    if not Active() then return end
    for _, entry in ipairs(PortraitScreens()) do
        local _, extras = OrderedPortraits(entry.screen)
        if #extras > 0 then
            local curIdx = CurrentHeroIndex(entry)
            local party = HeroArray()
            for _, w in ipairs(extras) do
                local k = PORTRAIT_HERO[w:GetAddress()]
                if k ~= curIdx and Try(function() return w:IsHovered() end) then
                    local hero = party[k + 1]
                    if hero and hero:IsValid() then
                        local ok, err = SelectHeroOn(entry, hero)
                        if not ok then Out("click: portrait %d select failed: %s", k + 1, tostring(err)) end
                        if ok then pcall(UpdateExtraHighlights) end
                        if entry.kind == "selection" then
                            -- what the screen does when one of its own portraits is clicked (looter, refresh)
                            local okC, errC, sig = CallByParams(entry.screen, "OnPortraitClicked", hero, w, k)
                            if not okC and tostring(errC):match("^no function") then okC, errC, sig = CallByParams(entry.screen, "SetLooter", hero, w, k) end
                            if not okC or not CLICK_LOGGED then
                                CLICK_LOGGED = true
                                Out("click: portrait %d handler(%s) -> %s", k + 1, tostring(sig), okC and "ok" or tostring(errC))
                            end
                        end
                    end
                    return
                end
            end
        end
    end
end

local okM, errM = pcall(function()
    RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function() PRESSED.click = true end)
end)
if not okM then Out("click: could not bind the left mouse button: %s", tostring(errM)) end

--------------------------------------------------------------------------------------------------
-- Per-hero rows on other screens (short/long rest, initiative, assignment, ...): the same designer
-- layout problem as the creation cards — a row built for four heroes overflows with six. Shrink the
-- fixed widths inside each card by 4/N, the fix that worked on the creation screen and the lobby.
--------------------------------------------------------------------------------------------------
local ROW_DONE = {}

-- Containers to fit, as { class = "<UE4SS class name>", fields = { "<container property>", ... } }.
local HERO_ROWS = {
    -- scale = true: shrink the whole row visually (pivot top-left) - the card width on these screens is not
    -- set by a size box, so shrinking boxes inside the cards changes nothing
    { class = "PostRestActionsPanel",     fields = { "CharacterActionRowsTable" }, scale = true },
    { class = "PostRestLostPanel",        fields = { "CharacterLostRowsTable" }, scale = true },
    { class = "PostRestRecoveredPanel",   fields = { "CharacterRecoveredRowsTable" }, scale = true },
    { class = "RestPredictionPanel",      fields = { "CharacterConsumedFoodTable", "CharacterLostEffectsTable", "CharacterRestoredFeaturesTable" }, scale = true },
    { class = "CharacterAssignmentScreen", fields = { "HeroesContainer", "NPCsContainer", "UnassignedCharactersHB", "UnassignedPlayersHB" } },
}

-- Visual fit: scale the row so N cards take the width of 4. Re-applied whenever the game resets the transform.
local function ScaleRow(container, label)
    if not (container and container:IsValid()) then return end
    local n = Try(function() return container:GetChildrenCount() end) or 0
    if n <= 4 then return end
    local f = 4 / n
    local cur = Try(function() return container.RenderTransform.Scale.X end)
    if cur and math.abs(cur - f) < 0.01 then return end
    local ok = pcall(function()
        container:SetRenderTransformPivot({ X = 0, Y = 0 })
        container:SetRenderScale({ X = f, Y = f })
    end)
    Out("rows: %s scaled %d cards by %.2f: %s", label, n, f, ok and "ok" or "failed")
end

-- Shrink every fixed width inside a container's children so N of them occupy the space of 4.
local function FitRow(container, label)
    if not (container and container:IsValid()) then return end
    local n = Try(function() return container:GetChildrenCount() end) or 0
    if n <= 4 then return end
    local key = container:GetAddress()
    if ROW_DONE[key] then return end
    local f = 4 / n
    local sizeBoxClass = StaticFindObject("/Script/UMG.SizeBox")
    local hSlotClass = StaticFindObject("/Script/UMG.HorizontalBoxSlot")
    local boxes, pads = 0, 0
    for k = 0, n - 1 do
        local card = Try(function() return container:GetChildAt(k) end)
        if card and card:IsValid() then
            local slot = Try(function() return card.Slot end)
            if slot and slot:IsValid() and hSlotClass and slot:IsA(hSlotClass) then
                local pad = Try(function() return slot.Padding end)
                if pad and pcall(function() slot:SetPadding({ Left = pad.Left * f, Top = pad.Top, Right = pad.Right * f, Bottom = pad.Bottom }) end) then pads = pads + 1 end
            end
            ForEachWidget(card, function(w)
                if sizeBoxClass and w:IsA(sizeBoxClass) then
                    local over = Try(function() return w.bOverride_WidthOverride end)
                    local width = Try(function() return w.WidthOverride end) or 0
                    if over and width > 0 and pcall(function() w:SetWidthOverride(width * f) end) then boxes = boxes + 1 end
                    local minOver = Try(function() return w.bOverride_MinDesiredWidth end)
                    local minW = Try(function() return w.MinDesiredWidth end) or 0
                    if minOver and minW > 0 then pcall(function() w:SetMinDesiredWidth(minW * f) end) end
                end
            end)
        end
    end
    ROW_DONE[key] = true
    if boxes == 0 and pads == 0 then
        -- nothing fixed-width to shrink: fall back to scaling the row visually
        pcall(function() container:SetRenderScale({ X = f, Y = f }) end)
        Out("rows: %s has %d cards and no fixed widths — scaled the row by %.2f", label, n, f)
    else
        Out("rows: %s fitted %d cards (%d width(s), %d padding(s) by %.2f)", label, n, boxes, pads, f)
    end
end

local function FitHeroRows()
    if not Active() then return end
    for _, entry in ipairs(HERO_ROWS) do
        for _, screen in ipairs(Instances(entry.class)) do
            if Try(function() return screen:IsVisible() end) then
                for _, field in ipairs(entry.fields) do
                    local container = Try(function() return screen[field] end)
                    if entry.scale then pcall(ScaleRow, container, entry.class .. "." .. field)
                    else pcall(FitRow, container, entry.class .. "." .. field) end
                end
            end
        end
    end
end

--------------------------------------------------------------------------------------------------
-- Family roles. The campaign defines exactly four (GoldenKid, Scapegoat, Substitute, TopStudent), one
-- per sibling, and an early story beat asks each hero to take one. With six heroes that step runs out
-- of roles and its screen is never pushed, which locks the scene. Give heroes 5+ a role up front so the
-- step has nothing left to ask; duplicates are accepted by the data (roles are just gameplay tags).
--------------------------------------------------------------------------------------------------
local function PartyMembers()
    for _, pc in ipairs(Instances("PartyComponent")) do
        local party = Try(function() return pc.Party end)
        if Count(party) > 0 then return party end
    end
    return nil
end

local function HeroIdentity(hero)
    local cls = StaticFindObject("/Script/Brimstone.HeroIdentityComponent")
    if not (cls and cls:IsValid()) then return nil end
    return Try(function() return hero:GetComponentByClass(cls) end)
end

local function FamilyRoleOf(hero)
    local ident = HeroIdentity(hero)
    if not (ident and ident:IsValid()) then return nil, nil, "no HeroIdentityComponent" end
    local ok, tag = pcall(function() return ident.IdentityData.FamilyRole.TagName:ToString() end)
    if not ok then return ident, nil, "unreadable: " .. tostring(tag) end
    if tag == nil or tag == "" or tag == "None" then return ident, nil, "none" end
    return ident, tag, nil
end

local function ReportFamilyRoles()
    local party = PartyMembers()
    if not party then Out("roles: no party loaded") return end
    for i = 1, Count(party) do
        local hero = party[i]
        local ident, role, why = FamilyRoleOf(hero)
        Out("roles: [%d] %-28s %s", i, ShortName(hero:GetFullName()), role or ("(" .. (why or "?") .. ")"))
    end
end

--------------------------------------------------------------------------------------------------
-- Experiment: the early "family roles" beat is written for exactly four siblings and never pushes its
-- screen with six heroes. Hide the extras from the conversation by deactivating their participant
-- components, let the scene run with four, then hand them back.
--------------------------------------------------------------------------------------------------

-- Party formation: followers walk to anchors arranged around the leader. Dump where the anchors are and which
-- heroes have a controller; Ctrl+Shift+F re-spawns the anchors (SpawnAnchors(true) reassigns them too).
local function Dist(a, b)
    if not (a and b) then return -1 end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function FormationManager()
    for _, m in ipairs(Instances("PartyFormationManagerComponent")) do return m end
    return nil
end

local function ReportFormation()
    local pc = UEHelpers.GetPlayerController()
    local leader = pc and pc:IsValid() and Try(function() return pc:K2_GetPawn() end)
    local lpos = leader and leader:IsValid() and Try(function() return leader:K2_GetActorLocation() end)
    local mgr = FormationManager()
    Out("formation: %s", SplitTextRef and SplitTextRef() or "")
    Out("formation: party components: %s", PartyComponentsText())
    if DialogueStateTextRef then Out("formation: %s", DialogueStateTextRef()) end
    Out("formation: manager tick=%s active=%s; %s", tostring(mgr and Try(function() return mgr:IsComponentTickEnabled() end)),
        tostring(mgr and Try(function() return mgr:IsActive() end)), TickTextRef and TickTextRef() or "")
    Out("formation: manager=%s leader=%s designAnchors=%s providedDesignAnchors=%s radius=%s spread=%s",
        mgr and mgr:IsValid() and ShortName(mgr:GetFullName()) or "none",
        (leader and leader:IsValid()) and ShortName(leader:GetFullName()) or "none",
        tostring(mgr and Count(Try(function() return mgr.DesignAnchors end))), tostring(mgr and Count(Try(function() return mgr.ProvidedDesignAnchors end))),
        tostring(mgr and Try(function() return mgr.PartyFormationRadius end)), tostring(mgr and Try(function() return mgr.PartyFormationAngleSpread end)))
    local ps = LocalPlayerState()
    local controlled = ps and Try(function() return ps.ControlledActors end)
    local names = {}
    for i = 1, Count(controlled) do
        local a = controlled[i]
        names[#names + 1] = (a and a:IsValid()) and (ShortName(a:GetFullName()) .. " (" .. ClassName(a) .. ")") or "invalid"
    end
    Out("owner: local player state %s (slot %s) controls %d actor(s): %s", ps and ShortName(ps:GetFullName()) or "none",
        tostring(ps and Try(function() return ps.PlayerSlotIndex end)), Count(controlled), table.concat(names, ", "))
    local anchors = Instances("PartyFormationAnchor")
    Out("formation: %d anchor(s)", #anchors)
    for i, a in ipairs(anchors) do
        local pos = Try(function() return a:K2_GetActorLocation() end)
        local following = Try(function() return a.FollowingActor end)
        Out("   anchor %d %s dist-to-leader=%.0f following=%s followsLeader=%s", i, ShortName(a:GetFullName()), Dist(pos, lpos),
            (following and following.IsValid and following:IsValid()) and ShortName(following:GetFullName()) or "none",
            tostring(Try(function() return a.AnchorFollowingPartyLeader end)))
    end
    local party = PartyArray()
    for i = 1, Count(party) do
        local hero = party[i]
        if hero and hero:IsValid() then
            local pawn = PawnForHero(hero)
            local ctrl = pawn and Try(function() return pawn:GetController() end)
            local pos = pawn and Try(function() return pawn:K2_GetActorLocation() end)
            local anchorTo = ctrl and Try(function() return ctrl:GetAnchorToFollow() end)
            local leaderTo = ctrl and Try(function() return ctrl:GetLeaderToFollow() end)
            local brain = ctrl and Try(function() return ctrl.BrainComponent end)
            local brainText = (brain and brain.IsValid and brain:IsValid()) and string.format("brain running=%s paused=%s move=%s",
                tostring(Try(function() return brain:IsRunning() end)), tostring(Try(function() return brain:IsPaused() end)),
                tostring(Try(function() return ctrl:GetMoveStatus() end))) or "no brain"
            if pawn then
                -- gameplay tags on the hero's ability system: the game roots characters through tags
                local tagText = "?"
                pcall(function()
                    local asc = hero.BrimstoneAbilitySystemComponent
                    if asc and asc:IsValid() then
                        local names = {}
                        local okT = pcall(function()
                            local container = {}
                            asc:GetOwnedGameplayTags(container)
                            local arr = container.GameplayTags
                            for t = 1, Count(arr) do
                                local nm = Try(function() return arr[t].TagName:ToString() end)
                                if nm then names[#names + 1] = nm end
                            end
                        end)
                        if not okT or #names == 0 then
                            local rep2 = Try(function() return asc.ReplicatedLooseTags end)
                            local arr = rep2 and Try(function() return rep2.GameplayTags end)
                            for t = 1, Count(arr) do
                                local nm = Try(function() return arr[t].TagName:ToString() end)
                                if nm then names[#names + 1] = nm end
                            end
                        end
                        local keep = {}
                        for _, nm in ipairs(names) do
                            if nm:match("[Mm]ove") or nm:match("[Dd]ialog") or nm:match("[Cc]inematic") or nm:match("[Ll]ock") or nm:match("[Bb]lock") or nm:match("[Rr]oot") or nm:match("[Ss]tun") or nm:match("[Ii]mmobil") or nm:match("[Cc]onversation") or nm:match("[Bb]usy") or nm:match("[Ww]ait") or nm:match("State") or nm:match("Condition") or nm:match("Paralys") or nm:match("Incapac") or nm:match("Restrain") or nm:match("Locomotion") or nm:match("Follow") then
                                keep[#keep + 1] = nm
                            end
                        end
                        tagText = string.format("%d tags; relevant: %s", #names, #keep > 0 and table.concat(keep, " ") or "none")
                    end
                end)
                brainText = brainText .. " tags(" .. tagText .. ")"
                local vel = Try(function() return pawn:GetVelocity() end)
                local speed = vel and math.sqrt((vel.X or 0) ^ 2 + (vel.Y or 0) ^ 2 + (vel.Z or 0) ^ 2) or -1
                local mv = Try(function() return pawn.CharacterMovement end)
                local montage = Try(function() return pawn:GetCurrentMontage() end)
                brainText = brainText .. string.format(" dilation=%s tick=%s vel=%.0f mode=%s walk=%s mvActive=%s mvTick=%s montage=%s", tostring(Try(function() return pawn.CustomTimeDilation end)),
                    tostring(Try(function() return pawn:IsActorTickEnabled() end)), speed,
                    tostring(mv and Try(function() return mv.MovementMode end)), tostring(mv and Try(function() return mv.MaxWalkSpeed end)),
                    tostring(mv and Try(function() return mv:IsActive() end)), tostring(mv and Try(function() return mv:IsComponentTickEnabled() end)),
                    (montage and montage.IsValid and montage:IsValid()) and ShortName(montage:GetFullName()) or "none")
                local pf = ctrl and Try(function() return ctrl:GetPathFollowingComponent() end)
                if not (pf and pf.IsValid and pf:IsValid()) then pf = ctrl and Try(function() return ctrl.PathFollowingComponent end) end
                local pfOk = pf and pf.IsValid and pf:IsValid()
                local pfMv = pfOk and Try(function() return pf.MovementComp end)
                local pfMvOk = pfMv and pfMv.IsValid and pfMv:IsValid()
                local pfOwner = pfMvOk and Try(function() return pfMv:GetOwner() end)
                local pfText
                if not pfOk then pfText = "no path follower"
                elseif not pfMvOk then pfText = "path follower " .. ShortName(pf:GetFullName()) .. " has NO movement component"
                elseif mv and mv:IsValid() and pfMv:GetAddress() == mv:GetAddress() then pfText = "same"
                else pfText = "DIFFERENT: " .. ((pfOwner and pfOwner:IsValid()) and ShortName(pfOwner:GetFullName()) or "?") end
                brainText = brainText .. " pfMove=" .. pfText
                local dest = ctrl and Try(function() return ctrl:GetImmediateMoveDestination() end)
                brainText = brainText .. string.format(" ignoreMove(ctrl=%s pawn=%s) dest=%s partial=%s",
                    tostring(ctrl and Try(function() return ctrl:IsMoveInputIgnored() end)), tostring(Try(function() return pawn:IsMoveInputIgnored() end)),
                    dest and string.format("%.0f away", Dist(dest, pos)) or "none", tostring(ctrl and Try(function() return ctrl:HasPartialPath() end)))
                local mesh = Try(function() return pawn.Mesh end)
                local anim = mesh and mesh:IsValid() and Try(function() return mesh:GetAnimInstance() end)
                brainText = brainText .. string.format(" mesh(pauseAnims=%s noSkel=%s tick=%s vis=%s) anim=%s rootMotion=%s stuck=%s forceMove=%s",
                    tostring(mesh and Try(function() return mesh.bPauseAnims end)), tostring(mesh and Try(function() return mesh.bNoSkeletonUpdate end)),
                    tostring(mesh and Try(function() return mesh:IsComponentTickEnabled() end)), tostring(mesh and Try(function() return mesh:IsVisible() end)),
                    (anim and anim.IsValid and anim:IsValid()) and ClassName(anim) or "none", tostring(anim and anim.IsValid and anim:IsValid() and Try(function() return anim.RootMotionMode end)),
                    tostring(Try(function() return pawn.AnimNotifyStuck end)), tostring(Try(function() return pawn.AnimNotifyForceMoveExecution end)))
            end
            Out("   hero %d %s pawn=%s controller=%s owner=%s mine=%s dist-to-leader=%.0f anchor=%s leader=%s %s", i, ShortName(hero:GetFullName()):gsub("_%d+$", ""),
                pawn and "ok" or "none", (ctrl and ctrl:IsValid()) and ClassName(ctrl) or "NONE", OwnerNameOf(hero), tostring(IsMine(hero)), Dist(pos, lpos),
                (anchorTo and anchorTo.IsValid and anchorTo:IsValid()) and ShortName(anchorTo:GetFullName()) or "none",
                (leaderTo and leaderTo.IsValid and leaderTo:IsValid()) and ShortName(leaderTo:GetFullName()) or "none", brainText)
        end
    end
end

local REPAIR_LOGGED = {}
local LAST_HEAL = 0
-- A raw possession leaves every follower AI with a stale party leader (it then follows anchors arranged around
-- the wrong hero and wanders). Only the game's own selection path refreshes it, so heal by selecting another
-- hero and re-selecting the current one - what pressing Tab twice does. Never during a dialogue.
ANCHOR_LAG_TICKS = 0
local function RepairFormation(verbose, force)
    if not Active() then return 0 end
    local dialogueUp = false
    for _, scr in ipairs(Instances("DialogueScreen")) do if Try(function() return scr:IsVisible() end) then dialogueUp = true break end end
    if dialogueUp then return 0 end
    -- never switch selection during combat (turn order and focus belong to the battle UI there)
    for _, cls in ipairs({ "BattleInitiativePanel", "TurnControlPanel" }) do
        for _, w in ipairs(Instances(cls)) do if Try(function() return w:IsVisible() end) then return 0 end end
    end
    if PRE_DIALOGUE_PAWN then
        -- marker left behind by a scene whose end event never came: hand back after a grace period
        if os.clock() - (PRE_DIALOGUE_SINCE or 0) < 20 then return 0 end
        local p2 = UEHelpers.GetPlayerController()
        local now = p2 and p2:IsValid() and Try(function() return p2:K2_GetPawn() end)
        Out("dialogue: no dialogue screen for 20 s but the pre-dialogue marker is still set; handing back now (possessed %s; %s)",
            (now and now:IsValid()) and ShortName(now:GetFullName()) or "none", DialogueScreensText())
        if ResyncSelectionRef then pcall(ResyncSelectionRef) end
        return 0
    end
    if not IsHost() then return 0 end      -- followers' AI controllers only exist on the host
    local pc = UEHelpers.GetPlayerController()
    local leader = pc and pc:IsValid() and Try(function() return pc:K2_GetPawn() end)
    if not (leader and leader:IsValid() and ShortName(leader:GetFullName()):match("^Character_")) then return 0 end
    local party = PartyArray()
    if Count(party) <= 4 then return 0 end
    local mine = MyHeroSet()               -- other players' followers follow their own leaders
    local stale, other = nil, nil
    for i = 1, Count(party) do
        local hero = party[i]
        local pawn = hero and hero:IsValid() and mine[hero:GetAddress()] and PawnForHero(hero)
        if pawn and pawn:GetAddress() ~= leader:GetAddress() then
            other = other or pawn
            local ctrl = Try(function() return pawn:GetController() end)
            local l = ctrl and ctrl:IsValid() and Try(function() return ctrl:GetLeaderToFollow() end)
            if l and l.IsValid and l:IsValid() and l:GetAddress() ~= leader:GetAddress() then stale = l end
        end
    end
    -- the anchors the followers walk to are kept around the leader by the game's formation manager; when
    -- they sit far behind a leader for three checks in a row, the manager has stalled (followers stand still)
    local lagging = 0
    local radius = Try(function() return FormationManager().PartyFormationRadius end) or 200
    local lpos = Try(function() return leader:K2_GetActorLocation() end)
    for _, a in ipairs(Instances("PartyFormationAnchor")) do
        local f = Try(function() return a.FollowingActor end)
        if f and f.IsValid and f:IsValid() and lpos then
            local d = Dist(Try(function() return a:K2_GetActorLocation() end), lpos)
            if d > radius * 2.5 then lagging = lagging + 1 end
        end
    end
    ANCHOR_LAG_TICKS = lagging > 0 and ANCHOR_LAG_TICKS + 1 or 0
    local why = nil
    if stale then why = "followers thought " .. ShortName(stale:GetFullName()) .. " led"
    elseif force then why = "forced" .. (lagging > 0 and (" (" .. lagging .. " anchor(s) far behind)") or "") end
    -- lagging anchors alone never trigger the automatic heal: with a guest in the party the spare anchors
    -- sit far away for good, and a re-selection every few seconds takes control away from the player
    if not (why and other) then return 0 end
    ANCHOR_LAG_TICKS = 0
    -- not while a screen that follows the selection is open (inventory, chest, merchant): the switch can wait
    for _, cls in ipairs({ "InspectionScreen", "ModalChestScreen", "MerchantScreen" }) do
        for _, w in ipairs(Instances(cls)) do if Try(function() return w:IsVisible() end) then return 0 end end
    end
    local now = os.clock()
    if not force and now - LAST_HEAL < 10 then return 0 end
    LAST_HEAL = now
    local sel = LocalSelectionState()   -- defined with the portrait helpers, above this function
    if not (sel and sel:IsValid()) then return 0 end
    -- two selection changes in one frame gave the HUD a half-updated party once (a crash in the game's
    -- party-by-owner sort): select the other hero now, the leader again a moment later
    Out("formation: %s; re-selecting %s, then %s again", why, ShortName(other:GetFullName()), ShortName(leader:GetFullName()))
    local ok1 = pcall(function() sel:SelectCharacter(other, pc, true, true) end)
    After(300, function()
        if not (leader:IsValid() and pc:IsValid() and sel:IsValid()) then return end
        local ok2 = pcall(function() sel:SelectCharacter(leader, pc, true, true) end)
        Out("formation: leader refreshed (%s/%s)", ok1 and "ok" or "refused", ok2 and "ok" or "refused")
    end)
    return 1
end

Every(2000, function() pcall(RepairFormation, false) end)

local function TickText()
    local parts = {}
    for i, a in ipairs(Instances("PartyFormationAnchor")) do
        parts[#parts + 1] = string.format("a%d tick=%s", i, tostring(Try(function() return a:IsActorTickEnabled() end)))
    end
    local owner = Try(function() return FormationManager():GetOwner() end)
    if owner and owner:IsValid() then parts[#parts + 1] = "manager owner " .. ShortName(owner:GetFullName()) .. " tick=" .. tostring(Try(function() return owner:IsActorTickEnabled() end)) end
    return table.concat(parts, " ")
end
TickTextRef = TickText
local function SplitText()
    for _, pcmp in ipairs(Instances("PartyComponent")) do
        local groups = Try(function() return pcmp.PartySubgroups end)
        local party = Try(function() return pcmp.Party end)
        local split = {}
        for i = 1, Count(party) do
            local m = party[i]
            if m and m:IsValid() and Try(function() return pcmp:IsActorSplitFromParty(m) end) then split[#split + 1] = ShortName(m:GetFullName()):match("^([^_]+)") end
        end
        local gtext = {}
        for g = 1, Count(groups) do
            local leader = Try(function() return groups[g].SubGroupLeader end)
            local members = Try(function() return groups[g].SubgroupMembers end)
            local mn = {}
            for k = 1, Count(members) do local a = members[k]; mn[#mn + 1] = (a and a:IsValid()) and (ShortName(a:GetFullName()):match("^([^_]+)") or "?") or "none" end
            gtext[#gtext + 1] = ((leader and leader.IsValid and leader:IsValid()) and (ShortName(leader:GetFullName()):match("^([^_]+)") or "?") or "none") .. ":{" .. table.concat(mn, ",") .. "}"
        end
        return string.format("subgroups=%d %s split=[%s]", Count(groups), table.concat(gtext, " "), table.concat(split, ", "))
    end
    return "no party component"
end
SplitTextRef = SplitText
local function HealNow()
    LAST_HEAL = 0
    local mgr = FormationManager()
    if mgr then
        if Try(function() return mgr:IsComponentTickEnabled() end) == false then
            local ok = pcall(function() mgr:SetComponentTickEnabled(true) end)
            Out("formation: manager tick was off; enabled: %s", tostring(ok))
        end
        if Try(function() return mgr:IsActive() end) == false then
            local ok = pcall(function() mgr:SetActive(true, false) end)
            Out("formation: manager was inactive; activated: %s", tostring(ok))
        end
        local owner = Try(function() return mgr:GetOwner() end)
        if owner and owner:IsValid() and Try(function() return owner:IsActorTickEnabled() end) == false then
            local ok = pcall(function() owner:SetActorTickEnabled(true) end)
            Out("formation: manager owner tick was off; enabled: %s", tostring(ok))
        end
    end
    for i, a in ipairs(Instances("PartyFormationAnchor")) do
        if Try(function() return a:IsActorTickEnabled() end) == false then
            local ok = pcall(function() a:SetActorTickEnabled(true) end)
            Out("formation: anchor %d tick was off; enabled: %s", i, tostring(ok))
        end
    end
    local fixedBrains = 0
    local party = PartyArray()
    for i = 1, Count(party) do
        local hero = party[i]
        local pawn = hero and hero:IsValid() and IsMine(hero) and PawnForHero(hero)
        local ctrl = pawn and Try(function() return pawn:GetController() end)
        local brain = ctrl and ctrl:IsValid() and ClassName(ctrl):match("AIController") and Try(function() return ctrl.BrainComponent end)
        if brain and brain.IsValid and brain:IsValid() then
            local running, paused = Try(function() return brain:IsRunning() end), Try(function() return brain:IsPaused() end)
            if running == false or paused == true then
                local ok, err = pcall(function() brain:RestartLogic() end)
                fixedBrains = fixedBrains + 1
                Out("formation: %s's AI logic was %s; restarted: %s", ShortName(hero:GetFullName()), running == false and "stopped" or "paused", ok and "ok" or tostring(err))
            end
        end
    end
    -- pawns frozen by a scene: time dilation left at 0, or actor tick off
    local thawed = 0
    for i = 1, Count(party) do
        local hero = party[i]
        local pawn = hero and hero:IsValid() and IsMine(hero) and PawnForHero(hero)
        if pawn then
            local dil = Try(function() return pawn.CustomTimeDilation end)
            if dil ~= nil and dil < 0.99 then
                local ok = pcall(function() pawn.CustomTimeDilation = 1.0 end)
                thawed = thawed + 1
                Out("formation: %s had time dilation %s; reset to 1: %s", ShortName(hero:GetFullName()), tostring(dil), tostring(ok))
            end
            if Try(function() return pawn:IsActorTickEnabled() end) == false then
                local ok = pcall(function() pawn:SetActorTickEnabled(true) end)
                thawed = thawed + 1
                Out("formation: %s's actor tick was off; enabled: %s", ShortName(hero:GetFullName()), tostring(ok))
            end
            local ctrl = Try(function() return pawn:GetController() end)
            -- the path follower steering a movement component that is not this pawn's: re-possess, as a reload does
            local mvMine = Try(function() return pawn.CharacterMovement end)
            local pfC = ctrl and ctrl:IsValid() and Try(function() return ctrl.PathFollowingComponent end)
            local pfMvC = pfC and pfC.IsValid and pfC:IsValid() and Try(function() return pfC.MovementComp end)
            if mvMine and mvMine:IsValid() and pfMvC and pfMvC.IsValid and pfMvC:IsValid() and pfMvC:GetAddress() ~= mvMine:GetAddress() and ClassName(ctrl):match("AIController") then
                local ok1 = pcall(function() ctrl:UnPossess() end)
                local ok2 = pcall(function() ctrl:Possess(pawn) end)
                local pfMvAfter = Try(function() return ctrl.PathFollowingComponent.MovementComp end)
                thawed = thawed + 1
                Out("formation: %s's path follower steered another body; re-possessed (%s/%s), now %s", ShortName(hero:GetFullName()), tostring(ok1), tostring(ok2),
                    (pfMvAfter and pfMvAfter.IsValid and pfMvAfter:IsValid() and pfMvAfter:GetAddress() == mvMine:GetAddress()) and "correct" or "still wrong")
            end
            if ctrl and ctrl:IsValid() and Try(function() return ctrl:IsMoveInputIgnored() end) == true then
                local ok = pcall(function() ctrl:ResetIgnoreMoveInput() end)
                thawed = thawed + 1
                Out("formation: %s's controller was ignoring move input; reset: %s (now %s)", ShortName(hero:GetFullName()), tostring(ok), tostring(Try(function() return ctrl:IsMoveInputIgnored() end)))
            end
            local mesh = Try(function() return pawn.Mesh end)
            if mesh and mesh:IsValid() then
                if Try(function() return mesh.bPauseAnims end) == true then
                    local ok = pcall(function() mesh.bPauseAnims = false end)
                    thawed = thawed + 1
                    Out("formation: %s's animations were paused; resumed: %s", ShortName(hero:GetFullName()), tostring(ok))
                end
                if Try(function() return mesh.bNoSkeletonUpdate end) == true then
                    local ok = pcall(function() mesh.bNoSkeletonUpdate = false end)
                    thawed = thawed + 1
                    Out("formation: %s's skeleton updates were off; enabled: %s", ShortName(hero:GetFullName()), tostring(ok))
                end
                if Try(function() return mesh:IsComponentTickEnabled() end) == false then
                    local ok = pcall(function() mesh:SetComponentTickEnabled(true) end)
                    thawed = thawed + 1
                    Out("formation: %s's mesh tick was off; enabled: %s", ShortName(hero:GetFullName()), tostring(ok))
                end
            end
            local mv = Try(function() return pawn.CharacterMovement end)
            if mv and mv:IsValid() then
                if Try(function() return mv:IsActive() end) == false then
                    local ok = pcall(function() mv:SetActive(true, false) end)
                    thawed = thawed + 1
                    Out("formation: %s's movement component was inactive; activated: %s", ShortName(hero:GetFullName()), tostring(ok))
                end
                if Try(function() return mv:IsComponentTickEnabled() end) == false then
                    local ok = pcall(function() mv:SetComponentTickEnabled(true) end)
                    thawed = thawed + 1
                    Out("formation: %s's movement tick was off; enabled: %s", ShortName(hero:GetFullName()), tostring(ok))
                end
            end
        end
    end
    local n = RepairFormation(true, true)
    Out("formation: heal pass %s, %d AI brain(s) restarted, %d pawn(s) thawed; %s", n > 0 and "re-selected the leader" or "could not re-select (screen open, combat or dialogue?)", fixedBrains, thawed, SplitText())
    pcall(ReportFormation)
end
RegisterKeyBind(Key.F, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.heal = true end)

--------------------------------------------------------------------------------------------------
-- Enemy hit points. A monster gets its maximum hit points from the game's own "init health" gameplay
-- effect (URulesetImplementationSettings.InitHealthClass), applied at creation with the definition's
-- MaxHitPoints as a set-by-caller magnitude (UCharacterBuildingComponent::InitMonsterHitPoints). That
-- effect cannot be re-applied from Lua: UE4SS turns the opaque spec handles into empty tables. So, with
-- EnemyHitPointsPercent in the ini, the host writes the scaled value into the HealthAttributeSet's
-- MaxHitPoints data of every hostile monster whose base still equals its definition's, then hands it to
-- the ability system the way a replicated update arrives (OnRep_MaxHitPoints: aggregator base, change
-- listeners) and marks the property dirty for push-model replication to the other players. Lost hit
-- points are tracked separately, so current hit points follow the maximum.
--------------------------------------------------------------------------------------------------
local HP_DONE = {}          -- ruleset actor address -> { name = full name, value = the base this mod set }
local HP_WARNED = {}

local function HealthSetOf(actor)
    local asc = Try(function() return actor.BrimstoneAbilitySystemComponent end)
    if not (asc and asc:IsValid()) then return nil end
    local sets = Try(function() return asc.SpawnedAttributes end)
    for i = 1, Count(sets) do
        local set = sets[i]
        if set and set:IsValid() and ClassName(set) == "HealthAttributeSet" then return set, asc end
    end
    return nil, asc
end

-- write a new maximum into the attribute data, then let the ability system integrate it as it would a
-- replicated value (aggregator base and change listeners), and mark it dirty for the other players
local function ApplyMaxHitPoints(hs, value)
    local oldBase = Try(function() return hs.MaxHitPoints.BaseValue end)
    local oldCur = Try(function() return hs.MaxHitPoints.CurrentValue end)
    if oldBase == nil or oldCur == nil then return false, "cannot read MaxHitPoints" end
    local ok, err = pcall(function()
        hs.MaxHitPoints.BaseValue = value
        hs.MaxHitPoints.CurrentValue = value + (oldCur - oldBase)     -- keep whatever modifiers add on top
    end)
    if not ok then return false, "write failed: " .. tostring(err) end
    local notes = {}
    local okR, errR = pcall(function() hs:OnRep_MaxHitPoints({ BaseValue = oldBase, CurrentValue = oldCur }) end)
    if not okR then notes[#notes + 1] = "listeners not told: " .. tostring(errR) end
    local helpers = StaticFindObject("/Script/Engine.Default__NetPushModelHelpers")
    if helpers and helpers:IsValid() then
        local okD, errD = pcall(function() helpers:MarkPropertyDirty(hs, FName("MaxHitPoints")) end)
        if not okD then notes[#notes + 1] = "not marked for replication: " .. tostring(errD) end
    else
        notes[#notes + 1] = "NetPushModelHelpers not found (no replication mark)"
    end
    return true, table.concat(notes, "; ")
end

-- ruleset actors built from a monster definition, with their attitude towards the party (2 = hostile)
local HP_ERR_LOGGED = {}
local function HpError(where, err)
    if not HP_ERR_LOGGED[where] then HP_ERR_LOGGED[where] = true; Out("enemy hp: error in %s: %s", where, tostring(err)) end
end
local function Monsters()
    local out = {}
    local okL, list = pcall(Instances, "RulesetActor")
    if not okL then HpError("Instances(RulesetActor)", list) return out end
    for _, actor in ipairs(list) do
        local okA, errA = pcall(function()
            -- the BaseDefinition property is not a plain object reference (no IsValid on it); the getter is
            local def = Try(function() return actor:GetBaseDefinition() end)
            if not (def and type(def) == "userdata" and def.IsValid) then
                local raw = Try(function() return actor.BaseDefinition end)
                if not HP_ERR_LOGGED.basedef then
                    HP_ERR_LOGGED.basedef = true
                    Out("enemy hp: GetBaseDefinition() gave %s; BaseDefinition property is %s", tostring(def), type(raw) == "userdata" and ("userdata " .. tostring(Try(function() return raw:GetFullName() end) or Try(function() return raw:ToString() end) or "?")) or tostring(raw))
                end
                def = (type(raw) == "userdata" and raw.IsValid) and raw or nil
            end
            if def and def:IsValid() and ClassName(def) == "MonsterDefinition" then
                out[#out + 1] = { actor = actor, def = def, attitude = Try(function() return actor:GetTeamAttitudeTowardsParty() end) }
            end
        end)
        if not okA then HpError("Monsters", errA) end
    end
    return out
end

local function ScaleEnemyHitPoints(verbose)
    local pct = CFG.EnemyHitPointsPercent or 100
    if pct == 100 and next(HP_DONE) == nil and not verbose then return 0 end
    local changed = 0
    for _, e in ipairs(Monsters()) do
        local actor, def = e.actor, e.def
        local key = actor:GetAddress()
        local name = ShortName(actor:GetFullName())
        local rec = HP_DONE[key]
        if rec and rec.name ~= name then rec = nil; HP_DONE[key] = nil; HP_WARNED[key] = nil end
        if e.attitude == 2 and Try(function() return actor:HasAuthority() end) then
            local hs, asc = HealthSetOf(actor)
            local defHP = Try(function() return def.MaxHitPoints end)
            local base = hs and Try(function() return hs.MaxHitPoints.BaseValue end)
            if hs and asc and defHP and defHP > 0 and base then
                local target = math.floor(defHP * pct / 100 + 0.5)
                local unscaled = math.abs(base - defHP) < 0.5
                local ours = rec and math.abs(base - rec.value) < 0.5
                if math.abs(base - target) < 0.5 then
                    HP_DONE[key] = { name = name, value = target }
                elseif unscaled or ours then
                    local ok, err = ApplyMaxHitPoints(hs, target)
                    local after = Try(function() return hs.MaxHitPoints.BaseValue end) or -1
                    if ok and math.abs(after - target) < 0.5 then
                        HP_DONE[key] = { name = name, value = target }
                        changed = changed + 1
                        Out("enemy hp: %s %d -> %d (%d%% of %d; current now %s)%s", name, math.floor(base + 0.5), math.floor(after + 0.5), pct, defHP,
                            tostring(Try(function() return hs.MaxHitPoints.CurrentValue end)), (err and err ~= "") and (" [" .. err .. "]") or "")
                    elseif not HP_WARNED[key] then
                        HP_WARNED[key] = true
                        Out("enemy hp: %s: could not set %d -> %d: %s (base now %s)", name, math.floor(base + 0.5), target, ok and "no change" or tostring(err), tostring(after))
                    end
                elseif not HP_WARNED[key] then
                    HP_WARNED[key] = true
                    Out("enemy hp: %s left alone: base %d is neither its definition's %d nor a value this mod set", name, math.floor(base + 0.5), defHP)
                end
            end
        end
    end
    return changed
end

local function AdjustEnemyHitPoints(delta)
    ReadConfig()
    local v = (CFG.EnemyHitPointsPercent or 100) + delta
    if v < 50 then v = 50 elseif v > 500 then v = 500 end
    CFG.EnemyHitPointsPercent = v
    if WriteIniValue("EnemyHitPointsPercent", tostring(v)) then
        local okS, n = pcall(ScaleEnemyHitPoints, false)
        Out("enemy hit points: %d%% of the monster definition (%s; Ctrl+Shift+Up / Down)", v, okS and (tostring(n) .. " monster(s) changed now") or ("error: " .. tostring(n)))
        Announce(string.format("Enemy hit points, %d percent.", v))
    end
end

local function ReportEnemyHitPoints()
    Out("enemy hp: setting %d%% (%d monster(s) set by the mod so far)", CFG.EnemyHitPointsPercent or 100, (function() local n = 0 for _ in pairs(HP_DONE) do n = n + 1 end return n end)())
    local list = Monsters()
    for i = 1, math.min(#list, 16) do
        local e = list[i]
        local okR, errR = pcall(function()
            local hs = HealthSetOf(e.actor)
            local rec = HP_DONE[e.actor:GetAddress()]
            Out("enemy hp:   %s attitude=%s def=%s base=%s current=%s lost=%s%s", ShortName(e.actor:GetFullName()), tostring(e.attitude),
                tostring(Try(function() return e.def.MaxHitPoints end)), tostring(hs and Try(function() return hs.MaxHitPoints.BaseValue end)),
                tostring(hs and Try(function() return hs.MaxHitPoints.CurrentValue end)), tostring(hs and Try(function() return hs.LostHitPoints.CurrentValue end)),
                rec and (" (set to " .. tostring(rec.value) .. " by the mod)") or "")
        end)
        if not okR then Out("enemy hp:   %s: %s", ShortName(e.actor:GetFullName()), tostring(errR)) end
    end
    Out("enemy hp: %d monster(s) in the level", #list)
end

-- What binds a chest-screen portrait to its hero? Dump an original and one of ours: class chain with
-- property values and functions, extensions (view models), and the widget tree with texts.
local function DescribeValue(v)
    if v == nil then return "nil" end
    if type(v) ~= "userdata" then return tostring(v) end
    local ok, out = pcall(function()
        local n = Count(v)
        if n >= 0 then return "array[" .. n .. "]" end
        local s = Try(function() return v:ToString() end)
        if type(s) == "string" then return string.format("%q", s) end
        if Try(function() return v.IsValid ~= nil and v:IsValid() end) then return ShortName(v:GetFullName()) .. " (" .. ClassName(v) .. ")" end
        local x = Try(function() return v.X end)
        if type(x) == "number" then return string.format("{X=%s Y=%s}", tostring(x), tostring(Try(function() return v.Y end))) end
        return "userdata"
    end)
    return ok and out or ("? " .. tostring(out))
end
local function DumpObject(label, obj, stopAt)
    Out("bind: %s = %s", label, obj and ShortName(obj:GetFullName()) or "nil")
    if not obj then return end
    local cls = Try(function() return obj:GetClass() end)
    local depth = 0
    while cls and cls:IsValid() and depth < 8 do
        local cname = ShortName(cls:GetFullName())
        if cname == stopAt then break end
        local props, funcs = {}, {}
        local okP, errP = pcall(function()
            cls:ForEachProperty(function(prop)
                pcall(function()
                    local name = Try(function() return prop:GetFName():ToString() end) or "?"
                    local ptype = Try(function() return prop:GetClass():GetFName():ToString() end) or "?"
                    if ptype:match("Delegate") or ptype:match("^Soft") or ptype:match("^Weak") or ptype:match("^Lazy") or ptype:match("Interface") or ptype:match("FieldPath") or ptype == "MapProperty" or ptype == "SetProperty" then
                        props[#props + 1] = string.format("%s:%s (not read)", name, ptype)
                    else
                        props[#props + 1] = string.format("%s:%s=%s", name, ptype, DescribeValue(Try(function() return obj[name] end)))
                    end
                end)
            end)
        end)
        if not okP then props[#props + 1] = "ForEachProperty failed: " .. tostring(errP) end
        local blueprint = cname:match("_C$") ~= nil
        local okF, errF = pcall(function()
            cls:ForEachFunction(function(fn)
                local fname = ShortName(fn:GetFullName())
                if blueprint and not fname:match("^ExecuteUbergraph") and not fname:match("^SequenceEvent") then
                    funcs[#funcs + 1] = fname .. "(" .. DescribeParams(fn) .. ")"
                else
                    funcs[#funcs + 1] = fname
                end
            end)
        end)
        if not okF then funcs[#funcs + 1] = "ForEachFunction failed: " .. tostring(errF) end
        Out("bind:   class %s: %d properties, %d functions", cname, #props, #funcs)
        for i = 1, #props do Out("bind:     %s", props[i]) end
        if #funcs > 0 then
            if blueprint then for i = 1, #funcs do Out("bind:     fn %s", funcs[i]) end
            else Out("bind:     functions: %s", table.concat(funcs, ", ")) end
        end
        cls = Try(function() return cls:GetSuperStruct() end)
        depth = depth + 1
    end
end
local function DumpTree(label, root)
    ForEachWidget(root, function(c)
        local cname = ClassName(c)
        local extra = ""
        if cname:match("TextBlock") or cname:match("RichText") then extra = " text=" .. DescribeValue(Try(function() return c:GetText() end))
        elseif cname == "Image" then extra = " brush=" .. DescribeValue(Try(function() return c.Brush.ResourceObject end))
        elseif cname == "ProgressBar" then extra = " percent=" .. tostring(Try(function() return c.Percent end)) end
        Out("bind:   %s %s (%s)%s vis=%s", label, ShortName(c:GetFullName()), cname, extra, tostring(Try(function() return c:GetVisibility() end)))
    end)
end
local function ReportPortraitBindings()
    local found = false
    for _, entry in ipairs(PortraitScreens()) do
        found = true
        local originals, extras = OrderedPortraits(entry.screen)
        local orig, ours = originals[1], extras[1]
        Out("bind: %s screen %s: %d original portrait(s), %d extra(s)", entry.kind, ShortName(entry.screen:GetFullName()), #originals, #extras)
        if orig then
            DumpObject("original portrait", orig, "UserWidget")
            DumpTree("original", orig)
            local ext = Try(function() return orig.Extensions end)
            for i = 1, Count(ext) do DumpObject("original extension " .. i, ext[i], "Object") end
        end
        if ours then
            DumpObject("extra portrait", ours, "UserWidget")
            local ext = Try(function() return ours.Extensions end)
            for i = 1, Count(ext) do DumpObject("extra extension " .. i, ext[i], "Object") end
        end
        DumpObject("screen", entry.screen, "UserWidget")
    end
    if not found then Out("bind: no inspection/chest/merchant screen open") end
    -- item operation / transfer / context widgets that are up right now
    for _, w in ipairs(UserWidgets()) do
        local cn = ClassName(w)
        if w:IsValid() and (cn:match("Transfer") or cn:match("ItemOperation") or cn:match("DropdownMenu")) then
            if Try(function() return w:IsVisible() end) then
                DumpObject("visible widget", w, "UserWidget")
                DumpTree("widget", w)
            end
        end
    end
end

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
    pcall(FixPartyStrip, true)
    pcall(ExtendInspectionPortraits, true)
    pcall(FitHeroRows)
    pcall(ReportFamilyRoles)
    pcall(ReportFormation)
    pcall(ReportPortraitBindings)
    pcall(ReportEnemyHitPoints)
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
        After(500, function()
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

-- The inspection screen is created once and reused, so poll while its strip is visible (cheap).
--------------------------------------------------------------------------------------------------
-- Dialogue participant fix. Story scenes bind a fixed number of party participants (the family scene
-- binds Party.A..D = four heroes). The dialogue screen is only pushed by the participant on the hero
-- the player currently has selected, so with six heroes a selected-but-unbound hero leaves the scene
-- with no UI. When a dialogue hands out participant contexts, make sure the selected hero is one of
-- the bound ones — using the game's own selection call.
--------------------------------------------------------------------------------------------------

local function SelectionState()
    for _, c in ipairs(Instances("BrimstoneSelectionStateComponent")) do return c end
    return nil
end


-- the participant lives on the pawn (Character_<Hero>); the party array holds the hero actor
local function HeroForPawn(pawn)
    local name = ShortName(pawn:GetFullName()):gsub("^Character_", "")
    local _, party = (function()
        for _, pc in ipairs(Instances("PartyComponent")) do
            local party = Try(function() return pc.Party end)
            if Count(party) > 0 then return pc, party end
        end
        return nil, nil
    end)()
    if not party then return nil end
    for i = 1, Count(party) do
        local m = party[i]
        if m and m:IsValid() and ShortName(m:GetFullName()) == name then return m end
    end
    return nil
end

local PARTY_SWAP = nil        -- { pc = PartyComponent, a = index of the hero moved to the front, tag = dialogue }

local function PartyComponentAndArray()
    for _, pc in ipairs(Instances("PartyComponent")) do
        local party = Try(function() return pc.Party end)
        if Count(party) > 0 then return pc, party end
    end
    return nil, nil
end

local RestorePartyOrder   -- defined below
local EXIT_TOKEN = 0      -- bumped by every swap and every conversation exit; a pending restore only fires if still current
local function SwapPartyFront(hero, tag)
    if PARTY_SWAP and PARTY_SWAP.tag == tag then return end
    if PARTY_SWAP then RestorePartyOrder() end
    local pc, party = PartyComponentAndArray()
    if not party then return end
    local idx = nil
    for i = 1, Count(party) do
        local m = party[i]
        if m and m:IsValid() and m:GetAddress() == hero:GetAddress() then idx = i break end
    end
    if idx == nil then Out("party: %s is not in the party array", ShortName(hero:GetFullName())) return end
    if idx == 1 then Out("party: %s is already party member #1", ShortName(hero:GetFullName())) return end
    local first = party[1]
    local ok, err = pcall(function()
        local arr = pc.Party
        arr[1] = hero
        arr[idx] = first
    end)
    local check = Try(function() return pc.Party[1] end)
    local swapped = ok and check and check:IsValid() and check:GetAddress() == hero:GetAddress()
    if swapped then PARTY_SWAP = { pc = pc, a = idx, tag = tag }; EXIT_TOKEN = EXIT_TOKEN + 1 end   -- cancels a restore pending from the previous dialogue
    Out("party: moving %s to member #1 (was #%d) for %s: %s", ShortName(hero:GetFullName()), idx, tag,
        swapped and "ok" or ("failed " .. tostring(err)))
end

RestorePartyOrder = function()
    if not PARTY_SWAP then return end
    local sw = PARTY_SWAP
    PARTY_SWAP = nil
    if not (sw.pc and sw.pc:IsValid()) then return end
    local ok, err = pcall(function()
        local arr = sw.pc.Party
        local a, b = arr[1], arr[sw.a]
        arr[1] = b
        arr[sw.a] = a
    end)
    Out("party: order restored after %s: %s", sw.tag, ok and "ok" or tostring(err))
end

local EARLY_DONE = {}         -- dialogue tag -> true once a hero has been possessed for it
PRE_DIALOGUE_PAWN = nil       -- the pawn the player had selected before the mod possessed a participant
DialogueScreensText = function()
    local n, vis = 0, 0
    for _, scr in ipairs(Instances("DialogueScreen")) do n = n + 1; if Try(function() return scr:IsVisible() end) then vis = vis + 1 end end
    return string.format("dialogue screens: %d (%d visible)", n, vis)
end

-- Host side, for the other players: when a scene binds one of a remote player's AI followers while the
-- hero that player has possessed is not in the scene, that player would get no dialogue and no vote. The
-- server can possess the bound hero on their behalf (the possession replicates and the participant on
-- their side readies itself), and gives them their previous hero back when the scene ends.
local REMOTE_HANDBACK = {}     -- remote player state address -> { pc, pawn, name, tag, since }
local DIALOGUE_MGR = nil
local function DialogueManager()
    if DIALOGUE_MGR and DIALOGUE_MGR:IsValid() then return DIALOGUE_MGR end
    DIALOGUE_MGR = nil
    for _, mgr in ipairs(Instances("DialogueManagerComponent")) do DIALOGUE_MGR = mgr break end
    return DIALOGUE_MGR
end
local function DialogueActive()
    local mgr = DialogueManager()
    local inst = mgr and Try(function() return mgr.CurrentDialogueInstance end)
    return (inst and inst.IsValid and inst:IsValid()) and true or false
end
local function SelectionStateFor(pc)
    local first = nil
    for _, c in ipairs(Instances("BrimstoneSelectionStateComponent")) do
        first = first or c
        local owner = Try(function() return c:GetOwner() end)
        if owner and owner:IsValid() and pc and owner:GetAddress() == pc:GetAddress() then return c end
    end
    return first
end
local function HandBackRemotePlayers(reason)
    for key, rec in pairs(REMOTE_HANDBACK) do
        REMOTE_HANDBACK[key] = nil
        local pc, pawn = rec.pc, rec.pawn
        if pc and pc:IsValid() and pawn and pawn:IsValid() then
            local sel = SelectionStateFor(pc)
            local ok = (sel and sel:IsValid() and pcall(function() sel:SelectCharacter(pawn, pc, true, true) end)) or false
            local now = Try(function() return pc:K2_GetPawn() end)
            local how = "selection"
            if not (now and now:IsValid() and now:GetAddress() == pawn:GetAddress()) then
                ok = pcall(function() pc:Possess(pawn) end); how = "possession"
            end
            Out("dialogue: gave %s back to %s after %s (%s, %s)", ShortName(pawn:GetFullName()), rec.name or "a player", reason, how, ok and "ok" or "refused")
        else
            Out("dialogue: could not give %s back to %s after %s: controller or pawn gone", rec.pawnName or "their hero", rec.name or "a player", reason)
        end
    end
end
HandBackRemotePlayersRef = HandBackRemotePlayers

-- Once per dialogue instance, as soon as the manager's bindings are filled: log them, and for every remote
-- player whose possessed hero is not in the scene but who has a hero in it, possess that hero for them.
local HANDLED_INSTANCE = nil
local function WatchDialogueBindings()
    if not IsHost() then return end
    local mgr = DialogueManager()
    if not mgr then return end
    local inst = Try(function() return mgr.CurrentDialogueInstance end)
    if not (inst and inst.IsValid and inst:IsValid()) then HANDLED_INSTANCE = nil return end
    local key = inst:GetAddress()
    if HANDLED_INSTANCE == key then return end
    local arr = Try(function() return mgr.CurrentDialogueBindings end)
    local n = Count(arr)
    if n <= 0 then return end                       -- not filled yet: next tick
    HANDLED_INSTANCE = key
    local tag = Try(function() return mgr.ActiveDialogueTag.TagName:ToString() end) or "?"
    local byPlayer, parts = {}, {}
    for i = 1, n do
        local bnd = arr[i]
        local actor = Try(function() return bnd.Actor end)
        local ptag = Try(function() return bnd.ParticipantTag.TagName:ToString() end) or "?"
        local valid = actor and actor.IsValid and actor:IsValid()
        local name = valid and ShortName(actor:GetFullName()) or "none"
        local who = ""
        if valid and name:match("^Character_") then
            local hero = HeroForPawn(actor)
            local ps = hero and OwnerStateOf(hero)
            if ps then
                local k = ps:GetAddress()
                byPlayer[k] = byPlayer[k] or { ps = ps, pawns = {} }
                byPlayer[k].pawns[#byPlayer[k].pawns + 1] = actor
                who = " [" .. OwnerNameOf(hero) .. (IsMine(hero) and ", mine" or "") .. "]"
            end
        end
        parts[#parts + 1] = ptag:gsub("^Dialogue%.Participant%.", "") .. "=" .. name .. who
    end
    Out("bindings: %s: %s", tag, table.concat(parts, "; "))
    local mine = LocalPlayerState()
    for k, rec in pairs(byPlayer) do
        if not (mine and k == mine:GetAddress()) and not REMOTE_HANDBACK[k] then
            local rpc = Try(function() return rec.ps:GetPlayerController() end)
            local theirs = rpc and rpc:IsValid() and Try(function() return rpc:K2_GetPawn() end)
            if rpc and rpc:IsValid() and theirs and theirs:IsValid() then
                local covered = false
                for _, pw in ipairs(rec.pawns) do if pw:GetAddress() == theirs:GetAddress() then covered = true end end
                if not covered then
                    local target = rec.pawns[1]
                    local pname = Str(Try(function() return rec.ps:GetPlayerName() end)) or "a player"
                    REMOTE_HANDBACK[k] = { pc = rpc, pawn = theirs, pawnName = ShortName(theirs:GetFullName()), name = pname, tag = tag, since = os.clock() }
                    local okP, errP = pcall(function() rpc:Possess(target) end)
                    Out("dialogue: %s - %s's possessed %s is not in the scene; the server gives them %s: %s", tag, pname,
                        ShortName(theirs:GetFullName()), ShortName(target:GetFullName()), okP and "ok" or tostring(errP))
                end
            end
        end
    end
end

-- Item transfers. The item menu lists "Transfer to <hero>" for every other party member, but its handler was
-- written for three receivers (four heroes minus the carrier): entries four and five do nothing. When a
-- transfer entry is clicked and no transfer follows, the mod does it through the item's own view model.
local TRANSFER_SEEN = false
--------------------------------------------------------------------------------------------------
-- Combat experience with more than four heroes. ABattle::ConcludeBattle divides the battle's
-- EncounterXPAmount (every hostile contender's XP reward) by the number of contenders on the party's
-- team and gives each of them that share: six heroes level at two-thirds the pace of four. The host
-- watches the battles and, once one has ended, tops every hero up to a four-hero share through the
-- game's own grant functor (the console shows the extra gain as a second line). Guests fighting on the
-- party's side count in the game's divisor but have no progress component, so they get nothing either way.
--------------------------------------------------------------------------------------------------
local BATTLES = {}                 -- address -> { id, pool, heroes, n, state, done, seen }
local XP_FUNCTOR_CDO = nil
local function PartyTeamId()
    local party = PartyArray()
    for i = 1, Count(party) do
        local m = party[i]
        local id = m and m:IsValid() and Try(function() return m.MyTeamID.TeamID end)
        if id ~= nil then return id end
    end
    return nil
end
local function ContenderRulesetActor(c)
    if not (c and c.IsValid and c:IsValid()) then return nil end
    local ra = Try(function() return c:GetContenderRulesetActor() end)
    if ra and ra.IsValid and ra:IsValid() then return ra end
    if Try(function() return c.RulesetId end) ~= nil then return c end     -- already a ruleset actor
    return Try(function() return HeroForPawn(c) end)
end
local function GrantExperienceTo(hero, amount)
    if not XP_FUNCTOR_CDO then
        XP_FUNCTOR_CDO = StaticFindObject("/Script/Brimstone.Default__FunctorAsync_GrantExperience")
        if not (XP_FUNCTOR_CDO and XP_FUNCTOR_CDO:IsValid()) then XP_FUNCTOR_CDO = nil; return false, "no grant functor" end
    end
    local functor = nil
    local ok, err = pcall(function() functor = XP_FUNCTOR_CDO:Functor_GrantExperienceAmount(hero, amount) end)
    if not ok then return false, tostring(err) end
    if not (functor and functor.IsValid and functor:IsValid()) then return false, "functor not created" end
    ok, err = pcall(function() functor:Activate() end)
    if not ok then return false, tostring(err) end
    return true
end
local function TopUpBattle(rec, why)
    rec.done = true
    if rec.n <= 4 or #rec.heroes == 0 or rec.pool <= 0 then
        Out("combat xp: battle %s %s: pool %.0f, %d party contender(s), nothing to add", rec.id, why, rec.pool, rec.n)
        return
    end
    local extra = math.floor(rec.pool / 4) - math.floor(rec.pool / rec.n)
    if extra <= 0 then return end
    local given, names = 0, {}
    for _, h in ipairs(rec.heroes) do
        if h:IsValid() then
            local ok, err = GrantExperienceTo(h, extra)
            if ok then given = given + 1; names[#names + 1] = HeroLabelRef and HeroLabelRef(h) or ShortName(h:GetFullName())
            else Out("combat xp: could not grant %d to %s: %s", extra, ShortName(h:GetFullName()), tostring(err)) end
        end
    end
    Out("combat xp: battle %s %s: pool %.0f split %d ways by the game (%d each); +%d to %d hero(es) for a four-hero share of %d: %s",
        rec.id, why, rec.pool, rec.n, math.floor(rec.pool / rec.n), extra, given, math.floor(rec.pool / 4), table.concat(names, ", "))
end
local function WatchBattles()
    if not (CFG.Enabled and CFG.CombatExperienceAsIfFour and IsHost()) then return end
    local now = os.clock()
    local alive = {}
    for _, b in ipairs(Instances("Battle")) do
        local key = b:GetAddress()
        alive[key] = true
        local state = Try(function() return b.BattleState end)
        local rec = BATTLES[key]
        if not rec then
            rec = { id = tostring(Try(function() return b.BattleId end) or key), pool = 0, heroes = {}, n = 0, state = state, done = false, seen = now }
            BATTLES[key] = rec
        end
        if not rec.done then
            local pool = Try(function() return b.EncounterXPAmount end)
            if pool then rec.pool = pool end
            -- the party-team contenders: what the game divides by, and who to top up
            local team = PartyTeamId()
            local contenders = Try(function() return b.Contenders end)
            if team ~= nil and contenders then
                local heroes, n = {}, 0
                for i = 1, Count(contenders) do
                    local ra = ContenderRulesetActor(contenders[i])
                    if ra and Try(function() return ra.MyTeamID.TeamID end) == team then
                        n = n + 1
                        if HeroIdentity(ra) then heroes[#heroes + 1] = ra end
                    end
                end
                if n > 0 then rec.heroes, rec.n = heroes, n end
            end
            if rec.state ~= state then
                Out("combat xp: battle %s state %s -> %s (pool %.0f, %d party contender(s))", rec.id, tostring(rec.state), tostring(state), rec.pool, rec.n)
                rec.state = state
            end
            if state == 4 then TopUpBattle(rec, "ended") end       -- EBattleState::Ended: the game has granted its share
        end
    end
    for key, rec in pairs(BATTLES) do
        if not alive[key] then
            if not rec.done and rec.state == 3 then TopUpBattle(rec, "gone") end   -- was Ending (the game had decided it), then destroyed before Ended was seen
            BATTLES[key] = nil
        elseif now - rec.seen > 7200 then
            BATTLES[key] = nil
        end
    end
end

-- A hero's first name from its identity component (replicated: right on every machine). The actor name
-- only carries it on the host; clients see "RulesetActor_<id>"
local function HeroGivenName(hero)
    local ident = HeroIdentity(hero)
    if ident and ident:IsValid() then
        local n = Str(Try(function() return ident:GetFirstName() end))
        if n and n ~= "" and n ~= "None" then return n end
    end
    return (ShortName(hero:GetFullName()):match("^([^_]+)") or "")
end
-- for the log: the name plus the actor id, on clients too
local function HeroLabel(hero)
    local short = ShortName(hero:GetFullName())
    if short:match("^RulesetActor_") then
        local n = HeroGivenName(hero)
        if n ~= "" and n ~= "RulesetActor" then return n .. short:sub(#"RulesetActor" + 1) end
    end
    return short
end
HeroLabelRef = HeroLabel
local function LineText(line)
    local text = nil
    ForEachWidget(line, function(c)
        if not text and ClassName(c):match("TextBlock") then
            local t = Str(Try(function() return c:GetText() end))
            if t and t ~= "" then text = t end
        end
    end)
    return text
end
local function ValidVM(vm) return (vm and vm.IsValid and vm:IsValid()) and vm or nil end
-- The item view model a widget carries: a named getter, else any object property holding one (the grid
-- tile that opened the menu keeps its view model under a name of its own), else the list entry's object
local function ItemVMOfWidget(w)
    local vm = ValidVM(Try(function() return w.CachedItemViewModel end)) or ValidVM(Try(function() return w:GetItemViewModel() end))
    if vm then return vm, "getter" end
    local found = nil
    local cls = Try(function() return w:GetClass() end)
    local depth = 0
    while cls and cls:IsValid() and depth < 6 and not found do
        pcall(function()
            cls:ForEachProperty(function(prop)
                if found then return end
                pcall(function()
                    local ptype = Try(function() return prop:GetClass():GetFName():ToString() end) or "?"
                    if ptype ~= "ObjectProperty" then return end
                    local name = Try(function() return prop:GetFName():ToString() end)
                    local v = name and ValidVM(Try(function() return w[name] end))
                    if v and ClassName(v):match("ItemViewModel$") then found = v end
                end)
            end)
        end)
        cls = Try(function() return cls:GetSuperStruct() end)
        depth = depth + 1
    end
    if found then return found, "property" end
    local lib = StaticFindObject("/Script/UMG.Default__UserObjectListEntryLibrary")
    if lib and lib:IsValid() then
        local v = ValidVM(Try(function() return lib:GetListItemObject(w) end))
        if v and ClassName(v):match("ItemViewModel$") then return v, "list entry" end
    end
    return nil
end
local function ItemViewModelOf(menu)
    local anchor = Try(function() return menu.Anchor end)
    local anchorText = (anchor and anchor.IsValid and anchor:IsValid()) and (ShortName(anchor:GetFullName()) .. " (" .. ClassName(anchor) .. ")") or "none"
    -- the anchor, then up the widget tree; at the top of a tree, over to the user widget that owns it
    local w = anchor
    for _ = 1, 24 do
        if not (w and w.IsValid and w:IsValid()) then break end
        local vm, via = ItemVMOfWidget(w)
        if vm then return vm, anchorText .. "; " .. via .. " of " .. ClassName(w) end
        local parent = Try(function() return w:GetParent() end)
        if not (parent and parent:IsValid()) then
            local tree = Try(function() return w:GetOuter() end)
            local owner = tree and tree:IsValid() and Try(function() return tree:GetOuter() end)
            if owner and owner:IsValid() and IsUserWidget(owner) and owner:GetAddress() ~= w:GetAddress() then parent = owner end
        end
        w = parent
    end
    -- the item the inventory has selected (a right-click selects the tile first)
    -- last resort: the item the inventory has selected. That is the last tile left-clicked, which is not
    -- always the one right-clicked (a worn robe went instead of the scale mail once): say so in the log
    for _, ivm in ipairs(Instances("CharacterInventoryViewModel")) do
        local vm = ValidVM(Try(function() return ivm.SelectedItemViewModel end))
        if vm then return vm, anchorText .. "; via the inventory's SELECTED item (may not be the one right-clicked)" end
    end
    return nil, anchorText
end
local function ItemText(vm)
    for _, getter in ipairs({ "GetDisplayName", "GetName", "GetTitle", "GetItemName" }) do
        local t = Str(Try(function() return vm[getter](vm) end))
        if t and t ~= "" and not t:match("^ItemViewModel") then return t end
    end
    local item = Try(function() return vm.Item end)
    local t = item and item.IsValid and item:IsValid() and Str(Try(function() return item:GetDisplayName() end))
    return (t and t ~= "") and t or ShortName(vm:GetFullName())
end
local function CarrierOf(vm)
    local c = Try(function() return vm.ContextualRulesetActor end)
    if c and c.IsValid and c:IsValid() then return c end
    for _, scr in ipairs(Instances("InspectionScreen")) do
        if Try(function() return scr:IsVisible() end) then
            local gui = Try(function() return scr:GetGuiRulesetActor() end)
            local owner = gui and gui.IsValid and gui:IsValid() and Try(function() return gui:GetOwner() end)
            if owner and owner:IsValid() then return owner end
        end
    end
    return nil
end
local function TransferFallback(menu, text)
    if not (text and Active()) then return end
    local party = PartyArray()
    if Count(party) <= 4 then return end
    local vm, how = ItemViewModelOf(menu)
    if not vm then Out("transfer: fallback: no item view model behind the menu (anchor %s)", tostring(how)) return end
    local carrier = CarrierOf(vm)
    if not carrier then Out("transfer: fallback: no carrier for %q", text) return end
    local receiver = nil
    for i = 1, Count(party) do
        local m = party[i]
        if m and m:IsValid() and m:GetAddress() ~= carrier:GetAddress() then
            local given = HeroGivenName(m)
            if given ~= "" and text:find(given, 1, true) then receiver = m break end
        end
    end
    if not receiver then Out("transfer: fallback: no party member named in %q", text) return end
    local ok, err = pcall(function() vm:TransferItem(carrier, receiver, -1, false) end)
    Out("transfer: fallback %q: %s -> %s: %s; item %s (%s)", text, ShortName(carrier:GetFullName()), ShortName(receiver:GetFullName()), ok and "requested" or tostring(err),
        ItemText(vm), tostring(how))
end
local LAST_MENU_CLICK, LAST_TRANSFER_AT = -10, -10
TRANSFER_SERIAL = 0
local function OnMenuLine(menu, line)
    local text = line and line.IsValid and line:IsValid() and LineText(line)
    if not (text and text:match("^%u%l+ %l+ ") and not text:match("…")) then return end   -- "Transfer to X" (not the quantity entry)
    -- one click raises the line's event twice, and the game's own transfer (entries one to three) can run
    -- before or after this hook: decide once per click, by whether a transfer happened around the click
    local now = os.clock()
    if now - LAST_MENU_CLICK < 0.5 then return end
    LAST_MENU_CLICK = now
    if now - LAST_TRANSFER_AT < 0.5 then return end
    local serial = TRANSFER_SERIAL
    After(200, function()
        local later = os.clock()
        if TRANSFER_SERIAL ~= serial or LAST_TRANSFER_AT >= now - 0.5 then return end
        pcall(TransferFallback, menu, text)
    end)
end
-- The menu's Blueprint class is only loaded when a menu first opens: hook it then (retried from the timer).
local MENU_CLASS = "/Game/UI/Common/Dropdown/WBP_DropdownMenu.WBP_DropdownMenu_C"
local MENU_HOOKED = false
local MENU_TRIES = 0
HookItemMenu = function()
    if MENU_HOOKED then return true end
    if not (StaticFindObject(MENU_CLASS) and StaticFindObject(MENU_CLASS):IsValid()) then
        if LoadAsset then pcall(LoadAsset, MENU_CLASS) end
        if not (StaticFindObject(MENU_CLASS) and StaticFindObject(MENU_CLASS):IsValid()) then return false end
    end
    local all = true
    for _, fn in ipairs({ "OnMouseButtonDownUpward_Event", "OnButtonReleased_Event" }) do
        local okH, errH = pcall(function()
            RegisterHook(MENU_CLASS .. ":" .. fn, function(Context, PLine)
                local menu = Context:get()
                local line = Try(function() return PLine:get() end)
                pcall(OnMenuLine, menu, line)
            end)
        end)
        if not okH then all = false; MENU_TRIES = MENU_TRIES + 1; if MENU_TRIES <= 2 then Out("transfer: item menu hook %s not registered yet: %s", fn, tostring(errH)) end end
    end
    MENU_HOOKED = all
    if all then Out("transfer: item menu hooked (entries beyond the third now transfer)") end
    return all
end
HookItemMenu()

-- Item transfers: what the UI asks for (view model) and what reaches the server (RPC)
local function ActorText(a)
    return (a and a.IsValid and a:IsValid()) and ShortName(a:GetFullName()) or tostring(a)
end
pcall(function()
    RegisterHook("/Script/Brimstone.ItemViewModel:TransferItem", function(Context, PCarrier, PReceiver, PQuantity, PDrag)
        TRANSFER_SEEN = true; LAST_TRANSFER_AT = os.clock(); TRANSFER_SERIAL = TRANSFER_SERIAL + 1
    end)
end)
local SWAP_DONE = {}
local function PossessEarly(self, tag)
    if not Active() then return end
    if not tag or tag == "None" or tag == "" then return end
    local owner = Try(function() return self:GetOwner() end)
    if not (owner and owner:IsValid()) then return end
    if not ShortName(owner:GetFullName()):match("^Character_") then return end
    local hero = HeroForPawn(owner) or owner
    -- the server resolves the choice through party member #1: the host moves the first participant it sees there
    if not SWAP_DONE[tag] and IsHost() then
        SWAP_DONE[tag] = true
        After(5000, function() SWAP_DONE[tag] = nil end)
        pcall(SwapPartyFront, hero, tag)
    end
    if EARLY_DONE[tag] then return end
    -- the dialogue screen is pushed for the possessed pawn: each player possesses its own first participant
    if not IsMine(hero) then
        local c = Try(function() return owner:GetController() end)
        pcall(WatchDialogueBindings)      -- the bindings may be complete by now
        Out("dialogue: %s - participant %s (%s) belongs to another player; leaving it to them", tag, ShortName(owner:GetFullName()),
            (c and c:IsValid()) and ClassName(c) or "no controller")
        return
    end
    EARLY_DONE[tag] = true
    After(5000, function() EARLY_DONE[tag] = nil end)
    local pc = UEHelpers.GetPlayerController()
    if not (pc and pc:IsValid()) then return end
    local current = Try(function() return pc:K2_GetPawn() end)
    if current and current:IsValid() and current:GetAddress() == owner:GetAddress() then
        Out("dialogue: %s - possessed hero %s is the first bound participant, nothing to do", tag, ShortName(owner:GetFullName()))
        return
    end
    if current and current:IsValid() and not PRE_DIALOGUE_PAWN then PRE_DIALOGUE_PAWN = current; PRE_DIALOGUE_SINCE = os.clock() end
    local ok, err = pcall(function() pc:Possess(owner) end)
    local after = Try(function() return pc:K2_GetPawn() end)
    Out("dialogue: %s - possessing own first bound hero %s before the scene binds: %s (pawn now %s)", tag, ShortName(owner:GetFullName()),
        ok and "ok" or tostring(err), (after and after:IsValid()) and ShortName(after:GetFullName()) or "none")
end

local function OnConversationExit()
    if not (PARTY_SWAP or PRE_DIALOGUE_PAWN or (REMOTE_HANDBACK and next(REMOTE_HANDBACK))) then return end
    EXIT_TOKEN = EXIT_TOKEN + 1
    local token = EXIT_TOKEN
    After(1500, function()
        if token == EXIT_TOKEN then
            pcall(RestorePartyOrder)
            if PRE_DIALOGUE_PAWN and ResyncSelectionRef then pcall(ResyncSelectionRef) end
            if HandBackRemotePlayersRef then pcall(HandBackRemotePlayersRef, "the conversation exit") end
        end
    end)
end
for _, mod in ipairs({ "/Script/CommonConversationRuntime.", "/Script/Brimstone." }) do
    local okX = pcall(function()
        RegisterHook(mod .. "ConversationParticipantComponent:ClientExitConversation", function(Context)
            pcall(OnConversationExit)
        end)
    end)
    if okX then break end
end

ResyncSelectionRef = nil
local function ResyncSelection()
    local pc = UEHelpers.GetPlayerController()
    local possessed = pc and pc:IsValid() and Try(function() return pc:K2_GetPawn() end)
    local sel = SelectionState()
    if not (sel and sel:IsValid() and pc and pc:IsValid()) then return end
    local target = PRE_DIALOGUE_PAWN
    PRE_DIALOGUE_PAWN = nil
    if not (target and target.IsValid and target:IsValid() and ShortName(target:GetFullName()):match("^Character_")) then target = possessed end
    if not (target and target:IsValid() and ShortName(target:GetFullName()):match("^Character_")) then return end
    -- run the game's own selection twice: first the possessed participant (so its hand-back is done by the
    -- game), then the hero the player had before the scene
    if possessed and possessed:IsValid() and possessed:GetAddress() ~= target:GetAddress() then
        pcall(function() sel:SelectCharacter(possessed, pc, true, true) end)
    end
    local ok = pcall(function() sel:SelectCharacter(target, pc, true, true) end)
    Out("dialogue: selection handed back to %s after the dialogue: %s", ShortName(target:GetFullName()), ok and "ok" or "refused")
end
ResyncSelectionRef = ResyncSelection
PRE_DIALOGUE_SINCE = 0
for _, mod in ipairs({ "/Script/Brimstone.", "/Script/DialogueSystem.", "/Script/BrimstoneDialogue.", "/Script/TacticalCore." }) do
    local okE = pcall(function()
        RegisterHook(mod .. "DialogueManagerComponent:OnDialogueInstanceEnded", function(Context)
            After(500, function() pcall(RestorePartyOrder); pcall(ResyncSelection); pcall(HandBackRemotePlayers, "the scene ended") end)
        end)
    end)
    if okE then break end
end

for _, mod in ipairs({ "/Script/Brimstone.", "/Script/DialogueSystem.", "/Script/BrimstoneDialogue.", "/Script/TacticalCore." }) do
    local okB = pcall(function()
        RegisterHook(mod .. "DialogueParticipantComponent:ClientInitParticipantContext", function(Context, P1)
            local self = Context:get()
            local ctx = P1 and Try(function() return P1:get() end)
            local tag = ctx and Try(function() return ctx.DialogueTag.TagName:ToString() end)
            pcall(PossessEarly, self, tag)
        end)
    end)
    if okB then break end
end

Every(1000, function()
    if not Active() then return end
    NewScan(); pcall(PruneExtras)
    pcall(FixPartyStrip, false); pcall(ExtendInspectionPortraits, false); pcall(UpdateExtraHighlights); pcall(FitHeroRows)
end)

local function ToggleEnabled()
    ReadConfig()
    local newState = not CFG.Enabled
    if WriteEnabled(newState) then
        CFG.Enabled = newState
        Out("%s — applies to the next new campaign / lobby (party size %d)", newState and "ENABLED" or "DISABLED", CFG.PartySize)
    end
end

local function Reapply()
    ReadConfig()
    if not Active() then Out("disabled — nothing to apply") return end
    pcall(FixLayout); pcall(WidenCamera)
    for _, s in ipairs(Instances("MultiplayerOptionsScreen")) do pcall(ExtendPlayersRadio, s) end
    for _, s in ipairs(Instances("SessionSetupScreen")) do pcall(FixPlayerTiles, s) end
    for _, s in ipairs(Instances("MultiplayerSettingsScreen")) do pcall(FixPlayerTiles, s) end
    NewScan()
    pcall(FixPartyStrip, true)
    pcall(FitHeroRows)
    pcall(ExtendInspectionPortraits, true)
    Out("re-applied layout/camera/host-screen tweaks")
end

-- Ownership watch: the game's grouped party getter assumes every party member has a controlling player
-- state (it reads a field of it without a null check); log when a member loses or regains one, and log
-- possession changes, so a crash there has context in the log.
local OWNER_SEEN, POSSESSED_SEEN = {}, nil
local CONTROLLED_SEEN = nil
local function ControlledText()
    local parts = {}
    for _, ps in ipairs(Instances("BrimstonePlayerState")) do
        local arr = Try(function() return ps.ControlledActors end)
        local names = {}
        for i = 1, Count(arr) do
            local a = arr[i]
            names[#names + 1] = (a and a:IsValid()) and (ShortName(a:GetFullName()):match("^([^_]+)") or "?") or "invalid"
        end
        parts[#parts + 1] = string.format("%s[gate=%s ready=%s]={%s}", ShortName(ps:GetFullName()):gsub("^BP_BrimstonePlayerState_C_", "PS_"),
            tostring(Try(function() return ps.bHasCompletedHotJoinGate end)), tostring(Try(function() return ps.bReadyForHotJoin end)), table.concat(names, ","))
    end
    return table.concat(parts, " ")
end

local MEMBERS_SEEN = nil
local ORPHAN_SINCE = {}
-- The formation manager (the component that moves the anchors the followers walk to) is sometimes left
-- deactivated by the game; followers then stand still. Log the transition with what is on screen, and on
-- the host turn it back on once nothing that legitimately pauses it (a dialogue, combat) is up.
local MANAGER_ACTIVE_SEEN, MANAGER_OFF_SINCE = nil, nil
local function ScreensUpText()
    local names = {}
    for _, w in ipairs(Instances("CommonActivatableWidget")) do
        if Try(function() return w:IsVisible() end) then
            local n = ShortName(w:GetFullName()):gsub("_C_%d+$", ""):gsub("_C$", "")
            if not (n:match("HudScreen") or n:match("GameLayout") or n:match("Notification") or n:match("Tooltip")) then names[#names + 1] = n end
        end
    end
    return #names > 0 and table.concat(names, ", ") or "nothing"
end
-- What this machine looks like ten seconds after a level came up: a player left with a dead screen after
-- zoning can send this line (their pawn, their heroes, any loading or transition widget still showing)
local function PostLoadReport()
    local pc = UEHelpers.GetPlayerController()
    local pawn = pc and pc:IsValid() and Try(function() return pc:K2_GetPawn() end)
    local view = pc and pc:IsValid() and Try(function() return pc.PlayerCameraManager:GetViewTarget() end)
    local mine = {}
    for _, h in ipairs(HeroArray()) do
        if IsMine(h) then mine[#mine + 1] = HeroLabelRef and HeroLabelRef(h) or (ShortName(h:GetFullName()):match("^([^_]+)") or "?") end
    end
    local up = {}
    for _, w in ipairs(Instances("UserWidget")) do
        local n = ClassName(w)
        if (n:match("Loading") or n:match("Transition") or n:match("Travel") or n:match("Fade") or n:match("Splash")) and Try(function() return w:IsVisible() end) then
            up[#up + 1] = n:gsub("_C$", "")
        end
    end
    Out("after load: pawn=%s view=%s my heroes=%s (%d) loading widgets up=%s screens up: %s%s", (pawn and pawn:IsValid()) and ShortName(pawn:GetFullName()) or "NONE",
        (view and view:IsValid()) and ShortName(view:GetFullName()) or "NONE", #mine > 0 and table.concat(mine, ",") or "none", #mine,
        #up > 0 and table.concat(up, ",") or "none", ScreensUpText(), IsHost() and " (host)" or "")
end
DialogueStateTextRef = function()
    local mgr = DialogueManager()
    local inst = mgr and Try(function() return mgr.CurrentDialogueInstance end)
    local nb = mgr and Count(Try(function() return mgr.CurrentDialogueBindings end)) or -1
    local tag = mgr and Try(function() return mgr.ActiveDialogueTag.TagName:ToString() end)
    local queued = mgr and Count(Try(function() return mgr.QueuedDialogues end)) or -1
    local convs = 0
    for _, c in ipairs(Instances("ConversationParticipantComponent")) do if Try(function() return c:IsInActiveConversation() end) then convs = convs + 1 end end
    return string.format("dialogue: instance=%s bindings=%d tag=%s queued=%d participants in conversation=%d; screens up: %s",
        (inst and inst.IsValid and inst:IsValid()) and ShortName(inst:GetFullName()) or "none", nb, tostring(tag), queued, convs, ScreensUpText())
end
local function WatchFormationManager()
    local mgr = FormationManager()
    if not mgr then return end
    local active = Try(function() return mgr:IsActive() end)
    if active == nil then return end
    if MANAGER_ACTIVE_SEEN ~= nil and MANAGER_ACTIVE_SEEN ~= active then
        Out("formation: manager %s (screens up: %s)", active and "reactivated" or "DEACTIVATED", ScreensUpText())
    end
    MANAGER_ACTIVE_SEEN = active
    if active then MANAGER_OFF_SINCE = nil return end
    MANAGER_OFF_SINCE = MANAGER_OFF_SINCE or os.clock()
    if not IsHost() or os.clock() - MANAGER_OFF_SINCE < 2 then return end
    for _, scr in ipairs(Instances("DialogueScreen")) do if Try(function() return scr:IsVisible() end) then return end end
    for _, cls in ipairs({ "BattleInitiativePanel", "TurnControlPanel" }) do
        for _, w in ipairs(Instances(cls)) do if Try(function() return w:IsVisible() end) then return end end
    end
    local ok = pcall(function() mgr:SetActive(true, false) end)
    Out("formation: manager was inactive for %.0f s with no dialogue or combat up; reactivated (%s)", os.clock() - MANAGER_OFF_SINCE, tostring(ok))
    MANAGER_OFF_SINCE = os.clock()
end

local function WatchOwnership()
    local party = PartyArray()
    local names = {}
    for i = 1, Count(party) do
        local m = party[i]
        if m and m:IsValid() then
            local ps = OwnerStateOf(m)
            local key = m:GetAddress()
            local now = ps and ShortName(ps:GetFullName()) or "NONE"
            local name = HeroLabelRef and HeroLabelRef(m) or ShortName(m:GetFullName())
            names[#names + 1] = name .. (ps and "" or " (no owner)")
            if OWNER_SEEN[key] == nil then
                if not ps then Out("owner: party member %s (%s) has no controlling player state", name, ClassName(m)) end
            elseif OWNER_SEEN[key] ~= now then
                Out("owner: %s: controlling player state %s -> %s", name, OWNER_SEEN[key], now)
            end
            OWNER_SEEN[key] = now
            -- host: a member nobody controls (a guest joining a full-slot party) crashes the party-by-owner
            -- sort the HUD runs; give it to the local player after two samples without an owner
            if not ps and IsHost() then
                ORPHAN_SINCE[key] = ORPHAN_SINCE[key] or os.clock()
                if os.clock() - ORPHAN_SINCE[key] > 5 then
                    local mine = LocalPlayerState()
                    local arr = mine and Try(function() return mine.ControlledActors end)
                    if arr then
                        local okA, errA = pcall(function() arr[#arr + 1] = m end)
                        local after = OwnerStateOf(m)
                        Out("owner: %s handed to the local player (%s; owner now %s)", name, okA and "ok" or tostring(errA), after and ShortName(after:GetFullName()) or "still none")
                        if after then ORPHAN_SINCE[key] = nil else ORPHAN_SINCE[key] = os.clock() + 30 end   -- retry in half a minute if it did not take
                    end
                end
            else
                ORPHAN_SINCE[key] = nil
            end
        end
    end
    local list = table.concat(names, ", ")
    if MEMBERS_SEEN ~= nil and MEMBERS_SEEN ~= list then Out("owner: party is now: %s", list) end
    if MEMBERS_SEEN == "" and list ~= "" then After(10000, function() pcall(PostLoadReport) end) end   -- a level just came up
    MEMBERS_SEEN = list
end

Every(2000, function() if not MENU_HOOKED then pcall(HookItemMenu) end end)

Every(250, function()
    if not CFG.Enabled then return end
    local ok, err = pcall(WatchDialogueBindings)
    if not ok then HpError("dialogue watch", err) end
    ok, err = pcall(WatchOwnership)
    if not ok then HpError("ownership watch", err) end
    ok, err = pcall(WatchFormationManager)
    if not ok then HpError("formation manager watch", err) end
end)

Every(250, function()
    local ok, err = pcall(WatchBattles)
    if not ok then HpError("battle watch", err) end
end)

Every(3000, function()
    if not CFG.Enabled then return end
    local ok, err = pcall(ScaleEnemyHitPoints, false)
    if not ok then HpError("sweep", err) end
    -- a remote player's hero handed over for a scene: give it back once no dialogue is running
    if next(REMOTE_HANDBACK) then
        local mgr = DialogueManager()
        local nb = mgr and Count(Try(function() return mgr.CurrentDialogueBindings end)) or -1
        local active = DialogueActive()
        local oldest = math.huge
        for _, rec in pairs(REMOTE_HANDBACK) do oldest = math.min(oldest, rec.since or 0) end
        local age = os.clock() - oldest
        if age > 5 and (not active or nb == 0) then
            pcall(HandBackRemotePlayers, "no scene is running")
        elseif age > 5 and (HP_ERR_LOGGED.handback_wait or 0) < 6 then
            HP_ERR_LOGGED.handback_wait = (HP_ERR_LOGGED.handback_wait or 0) + 1
            Out("dialogue: hand-back pending for %.0f s: instance active=%s bindings=%d tag=%s", age, tostring(active), nb,
                tostring(mgr and Try(function() return mgr.ActiveDialogueTag.TagName:ToString() end)))
        end
    end
end)

RegisterKeyBind(Key.UP_ARROW, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.hpUp = true end)
RegisterKeyBind(Key.DOWN_ARROW, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.hpDown = true end)
RegisterKeyBind(Key.TAB, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.toggle = true end)
RegisterKeyBind(Key.END, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.reapply = true end)
RegisterKeyBind(Key.BACKSPACE, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.report = true end)

-- the game-thread side of the key binds and of the click emulation
Every(50, function()
    if PRESSED.click then PRESSED.click = false; if Active() then NewScan(); pcall(ClickExtraPortraits) end end
    if PRESSED.heal then PRESSED.heal = false; pcall(HealNow) end
    if PRESSED.hpUp then PRESSED.hpUp = false; pcall(AdjustEnemyHitPoints, 10) end
    if PRESSED.hpDown then PRESSED.hpDown = false; pcall(AdjustEnemyHitPoints, -10) end
    if PRESSED.toggle then PRESSED.toggle = false; pcall(ToggleEnabled) end
    if PRESSED.reapply then PRESSED.reapply = false; pcall(Reapply) end
    if PRESSED.report then PRESSED.report = false; NewScan(); local ok, err = pcall(Report); if not ok then Out("report failed: %s", tostring(err)) end end
end)

Out("loaded — Enabled=%s PartySize=%d (%s). Ctrl+Shift+Tab toggle, Ctrl+Shift+End re-apply, Ctrl+Shift+Backspace status",
    tostring(CFG.Enabled), CFG.PartySize, iniPath or "ini not found: using defaults")
