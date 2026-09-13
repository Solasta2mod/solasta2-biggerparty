-- BiggerParty — Lua half. Solasta II (Brimstone), UE4SS.
--
-- The native half (version.dll, next to the game exe) patches the four hard-coded party-size literals.
-- This half handles what is level content or UI:
--   * spawns extra PartyAvatarSpawn markers in the character-creation level (host only),
--   * shrinks the character cards so all slots fit, and widens the creation camera,
--   * extends the players selector on the multiplayer host screen to 2..N and re-flows the lobby tiles,
--   * extends the inspection screen's portrait strip (extra portraits, selection ring and click),
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
--   Ctrl+Shift+End         re-apply the UI tweaks on the current screen
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


local function FixPartyStrip(verbose)
    if not Active() then return end
    local sizeBoxClass = StaticFindObject("/Script/UMG.SizeBox")
    for _, grp in ipairs(Instances("PlayerSelectionGroup")) do
        local visible = Try(function() return grp:IsVisible() end)
        if visible then
            local tbl = Try(function() return grp.CharacterPlatesTable end)
            local sb = Try(function() return grp.CharacterPlatesSB end)
            local n = tbl and tbl:IsValid() and (Try(function() return tbl:GetChildrenCount() end) or 0) or -1
            local shown, changed = 0, 0
            for k = 0, math.max(n, 0) - 1 do
                local plate = Try(function() return tbl:GetChildAt(k) end)
                if plate and plate:IsValid() then
                    local vis = Try(function() return plate:GetVisibility() end)     -- 0 Visible 1 Collapsed 2 Hidden 3 HitTestInvisible 4 SelfHitTestInvisible
                    if vis == 1 or vis == 2 then
                        if pcall(function() plate:SetVisibility(4) end) then changed = changed + 1 end
                    end
                    if Try(function() return plate:IsVisible() end) then shown = shown + 1 end
                end
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

local function InspectionPortraitsIn(screen)
    local out = {}
    for _, w in ipairs(Instances("UserWidget")) do
        if ShortName(w:GetFullName()):match("^WBP_InspectionPortrait") and IsInsideWidget(w, screen) then out[#out + 1] = w end
    end
    table.sort(out, function(a, b) return a:GetFullName() < b:GetFullName() end)
    return out
end

local PORTRAIT_BOUND = {}
local function BindExtraPortrait(widget, heroIndex)      -- heroIndex is 0-based into PartyComponent.Party
    -- portraits are captured asynchronously and the manager can hand back a shared/placeholder texture at
    -- first, so keep re-applying until the same texture has been seen a few times in a row.
    local key = widget:GetAddress()
    if PORTRAIT_BOUND[key] and (PORTRAIT_BOUND["stable" .. key] or 0) >= 3 then return true end
    local party = nil
    for _, pc in ipairs(Instances("PartyComponent")) do party = Try(function() return pc.Party end) if party then break end end
    local hero = party and party[heroIndex + 1]
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
    for _, w in ipairs(Instances("UserWidget")) do
        if ShortName(w:GetFullName()) == "WBP_InspectionPortrait" then
            ForEachWidget(w, function(c) if not origImg and ShortName(c:GetFullName()) == "PortraitImg" then origImg = c end end)
            if origImg then break end
        end
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
    local original = nil
    for _, w in ipairs(Instances("UserWidget")) do
        if ShortName(w:GetFullName()) == "WBP_InspectionPortrait" and IsInsideWidget(w, Try(function() return widget:GetParent() end) or widget) then original = w break end
    end
    if not original then
        for _, w in ipairs(Instances("UserWidget")) do if ShortName(w:GetFullName()) == "WBP_InspectionPortrait" then original = w break end end
    end
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

local function ExtendInspectionPortraits(verbose)
    if not Active() then return end
    local nHeroes = 0
    for _, pc in ipairs(Instances("PartyComponent")) do nHeroes = math.max(nHeroes, Count(Try(function() return pc.Party end))) end
    if nHeroes <= 4 then return end
    for _, screen in ipairs(Instances("InspectionScreen")) do
        if Try(function() return screen:IsVisible() end) then
            local portraits = InspectionPortraitsIn(screen)
            if #portraits > 0 then
                local last = portraits[#portraits]
                local parent = Try(function() return last:GetParent() end)
                if parent and parent:IsValid() then
                    local n = Try(function() return parent:GetChildrenCount() end) or 0
                    for k = 4, n - 1 do
                        local w = Try(function() return parent:GetChildAt(k) end)
                        if w and w:IsValid() then pcall(BindExtraPortrait, w, k) end
                    end
                end
                if parent and parent:IsValid() and not PORTRAITS_DONE[parent:GetAddress()] then
                    local existing = Try(function() return parent:GetChildrenCount() end) or #portraits
                    if existing < nHeroes then
                        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
                        local pc = UEHelpers.GetPlayerController()
                        local cls = last:GetClass()
                        local added = 0
                        for k = existing, nHeroes - 1 do
                            local ok, err = pcall(function()
                                local w = lib:Create(last, cls, pc)
                                if not (w and w:IsValid()) then error("Create returned nothing") end
                                parent:AddChild(w)
                                local srcSlot, dstSlot = Try(function() return last.Slot end), Try(function() return w.Slot end)
                                local pad = srcSlot and Try(function() return srcSlot.Padding end)
                                if pad and dstSlot then pcall(function() dstSlot:SetPadding({ Left = pad.Left, Top = pad.Top, Right = pad.Right, Bottom = pad.Bottom }) end) end
                                added = added + 1
                            end)
                            if not ok then Out("inspect: could not add portrait %d: %s", k + 1, tostring(err)) break end
                        end
                        PORTRAITS_DONE[parent:GetAddress()] = true
                        Out("inspect: portraits %d -> %d in %s (%s) — unbound until the Blueprint's bind call is known", existing, existing + added, ShortName(parent:GetFullName()), ClassName(parent))
                    end
                end
            end
        end
    end
end

-- Selection ring for the extra portraits: the game calls WBP_PortraitSmallCircle:SetSelected on its four;
-- do the same for ours from the inspection view model's CurrentInspectionIndex.
local EXTRA_SELECTED = {}
SETSELECTED_ARG = function(want) return want end   -- WBP_PortraitSmallCircle_C:SetSelected(bIsSelected: bool)
local function UpdateExtraHighlights()
    if not Active() then return end
    for _, screen in ipairs(Instances("InspectionScreen")) do
        if Try(function() return screen:IsVisible() end) then
            -- which hero is inspected: the screen's bound GUI component -> its owner -> index in the party
            local comp = Try(function() return screen:GetGuiRulesetActor() end)
            local owner = comp and comp:IsValid() and Try(function() return comp:GetOwner() end)
            local idx = nil
            if owner and owner:IsValid() then
                for _, pc in ipairs(Instances("PartyComponent")) do
                    local party = Try(function() return pc.Party end)
                    for i = 1, Count(party) do
                        local m = party[i]
                        if m and m:IsValid() and m:GetAddress() == owner:GetAddress() then idx = i - 1 break end
                    end
                    if idx then break end
                end
            end
            if idx == nil then return end
            local portraits = InspectionPortraitsIn(screen)
            if #portraits > 4 then
                local parent = Try(function() return portraits[#portraits]:GetParent() end)
                local n = parent and parent:IsValid() and (Try(function() return parent:GetChildrenCount() end) or 0) or 0
                for k = 4, n - 1 do
                    local w = Try(function() return parent:GetChildAt(k) end)
                    if w and w:IsValid() then
                        local want = (k == idx)
                        if EXTRA_SELECTED[w:GetAddress()] ~= want then
                            local circle = nil
                            ForEachWidget(w, function(c) if not circle and ShortName(c:GetFullName()) == "WBP_PortraitSmallCircle" then circle = c end end)
                            if circle and SETSELECTED_ARG then
                                local ok, err = pcall(function() circle:SetSelected(SETSELECTED_ARG(want, w)) end)
                                if ok then EXTRA_SELECTED[w:GetAddress()] = want
                                else Out("inspect: SetSelected failed: %s", tostring(err)) end
                            elseif not circle then Out("inspect: no circle widget inside portrait %d", k + 1) end
                        end
                    end
                end
            end
        end
    end
end
-- Click discovery (light): does the screen override a mouse event, and does a click reach InspectionScreen:Bind?
local BIND_FLAG = false   -- the flag the game itself passes to InspectionScreen:Bind on a portrait click
-- Emulated click on the extra portraits: the game's own portraits end in InspectionScreen:Bind(component, flag);
-- on a left click, if an extra portrait is hovered, make the same call for its hero.
local function ClickExtraPortraits()
    if not Active() then return end
    for _, screen in ipairs(Instances("InspectionScreen")) do
        if Try(function() return screen:IsVisible() end) then
            local portraits = InspectionPortraitsIn(screen)
            if #portraits <= 4 then return end
            -- which hero is currently inspected (its enlarged portrait may still sit under the cursor)
            local curIdx = nil
            local comp0 = Try(function() return screen:GetGuiRulesetActor() end)
            local owner0 = comp0 and comp0:IsValid() and Try(function() return comp0:GetOwner() end)
            local party = nil
            for _, pc in ipairs(Instances("PartyComponent")) do party = Try(function() return pc.Party end) if party then break end end
            if owner0 and owner0:IsValid() and party then
                for i = 1, Count(party) do local m = party[i]; if m and m:IsValid() and m:GetAddress() == owner0:GetAddress() then curIdx = i - 1 break end end
            end
            local parent = Try(function() return portraits[#portraits]:GetParent() end)
            local n = parent and parent:IsValid() and (Try(function() return parent:GetChildrenCount() end) or 0) or 0
            for k = 4, n - 1 do
                local w = Try(function() return parent:GetChildAt(k) end)
                if w and w:IsValid() and k ~= curIdx and Try(function() return w:IsHovered() end) then
                    local hero = party and party[k + 1]
                    if hero and hero:IsValid() then
                        local guiClass = StaticFindObject("/Script/Brimstone.GuiRulesetActorComponent")
                        local comp = Try(function() return hero:GetComponentByClass(guiClass) end)
                        if comp and comp:IsValid() then
                            local ok, err = pcall(function() screen:Bind(comp, BIND_FLAG) end)
                            if not ok then Out("click: portrait %d Bind failed: %s", k + 1, tostring(err)) end
                            if ok then pcall(UpdateExtraHighlights) end
                        end
                    end
                    return
                end
            end
        end
    end
end

local okM, errM = pcall(function()
    RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function()
        ExecuteInGameThread(function() pcall(ClickExtraPortraits) end)
    end)
end)
if not okM then Out("click: could not bind the left mouse button: %s", tostring(errM)) end

local function InspectionDiagnostics()
    for _, pc in ipairs(Instances("PartyComponent")) do
        Out("inspect: Party=%d PartySubgroups=%d", Count(Try(function() return pc.Party end)), Count(Try(function() return pc.PartySubgroups end)))
    end
    for _, grp in ipairs(Instances("PlayerSelectionGroup")) do
        local tbl = Try(function() return grp.CharacterPlatesTable end)
        Out("inspect: %s visible=%s table=%s children=%s", ShortName(grp:GetFullName()), tostring(Try(function() return grp:IsVisible() end)),
            tbl and tbl:IsValid() and ClassName(tbl) or "?", tostring(tbl and tbl:IsValid() and Try(function() return tbl:GetChildrenCount() end)))
        local n = tbl and tbl:IsValid() and (Try(function() return tbl:GetChildrenCount() end) or 0) or 0
        for k = 0, n - 1 do
            local plate = Try(function() return tbl:GetChildAt(k) end)
            if plate and plate:IsValid() then
                local size = Try(function() return plate:GetDesiredSize() end)
                Out("   plate[%d] %s vis=%s isVisible=%s desired=%s", k, ClassName(plate), tostring(Try(function() return plate:GetVisibility() end)),
                    tostring(Try(function() return plate:IsVisible() end)), size and string.format("%.0fx%.0f", size.X, size.Y) or "?")
            end
        end
    end
    pcall(FixPartyStrip, true)
    pcall(ExtendInspectionPortraits, true)
    -- dump the inspection screen's widget tree (class counts + any widget whose name smells like a party strip)
    for _, screen in ipairs(Instances("InspectionScreen")) do
        local classes, interesting, total = {}, {}, 0
        ForEachWidget(screen, function(w)
            total = total + 1
            local c = ClassName(w); classes[c] = (classes[c] or 0) + 1
            local name = ShortName(w:GetFullName())
            if name:match("[Pp]ortrait") or name:match("[Pp]arty") or name:match("[Hh]ero") or name:match("[Tt]ab") or c:match("Portrait") or c:match("Party") or c:match("Plate") or c:match("Selector") then
                local n = Try(function() return w:GetChildrenCount() end)
                interesting[#interesting + 1] = string.format("%s (%s)%s", name, c, n and (" children=" .. n) or "")
            end
        end)
        Out("inspect: %s widget tree: %d widgets", ShortName(screen:GetFullName()), total)
        local list = {}
        for c, n in pairs(classes) do list[#list + 1] = string.format("%s x%d", c, n) end
        table.sort(list)
        Out("   classes: %s", table.concat(list, ", "))
        for _, line in ipairs(interesting) do Out("   %s", line) end
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
    pcall(InspectionDiagnostics)
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

-- The inspection screen is created once and reused, so poll while its strip is visible (cheap).
LoopAsync(1000, function()
    ExecuteInGameThread(function()
        if Active() then pcall(FixPartyStrip, false); pcall(ExtendInspectionPortraits, false); pcall(UpdateExtraHighlights) end
    end)
    return false
end)

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
        pcall(FixPartyStrip, true)
        pcall(ExtendInspectionPortraits, true)
        Out("re-applied layout/camera/host-screen tweaks")
    end)
end)

RegisterKeyBind(Key.BACKSPACE, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    ExecuteInGameThread(function() local ok, err = pcall(Report); if not ok then Out("report failed: %s", tostring(err)) end end)
end)

Out("loaded — Enabled=%s PartySize=%d (%s). Ctrl+Shift+Tab toggle, Ctrl+Shift+End re-apply, Ctrl+Shift+Backspace status",
    tostring(CFG.Enabled), CFG.PartySize, iniPath or "ini not found: using defaults")
