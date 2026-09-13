-- PartyProbe v2 — reconnaissance for the "bigger party" idea. Solasta II (Brimstone), UE4SS Lua.
--
-- Nothing here touches the disk. Everything it changes lives in memory until the game restarts.
--
-- Finding (from the disassembly of UPartyCreationManagerComponent::InitEditionActors, CL-112340):
--   the number of characters offered by character creation = the number of actors in the
--   party-creation level that carry the actor tag stored in the manager's SpawnAvatarTransformTag
--   (found with UGameplayStatics::GetAllActorsOfClassWithTag). One edition character is created per
--   tagged actor, standing at that actor's transform; SpecterTags[i] names the placeholder for slot i.
--   There is no literal "4" — the four spawn markers are level content.
--
-- Hotkeys:
--   Ctrl+Shift+Backspace   report (read-only): settings, campaign defs, creation manager, session VM, party
--   Ctrl+Shift+Tab         arm "6 slots": the next time InitEditionActors runs, two extra actors in the
--                          creation level get the spawn tag first. Back out to the main menu and start a
--                          new campaign after arming. Press again to disarm. Restart the game to undo fully.
--
-- NOTE: InitEditionActors is called directly from C++, so a UE4SS RegisterHook on it never fires
-- (RegisterHook only sees ProcessEvent calls). The arming therefore happens when the creation level's
-- PartyCreationManagerComponent is constructed (NotifyOnNewObject) — the level's actors are already
-- loaded then and the init runs later — with PlayerController:ClientRestart as a second chance.
-- A delayed check logs EditionCharacters / CharacterSlots a few seconds after arming.

local UEHelpers = require("UEHelpers")
local TAG = "[PartyProbe] "
local WANT_SLOTS = nil          -- nil = disarmed; set by Ctrl+Shift+Tab

local function Out(fmt, ...)
    print(TAG .. string.format(fmt, ...) .. "\n")
end

local function Try(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

local function Count(arr)
    if arr == nil then return -1 end
    local ok, n = pcall(function() return #arr end)
    return ok and n or -1
end

local function ShortName(fullName)
    return fullName:match("([^%.:]+)$") or fullName
end

local function IsInstance(o)
    return o and o:IsValid() and not o:GetFullName():find("Default__", 1, true)
end

local function Instances(className)
    local out = {}
    local ok, found = pcall(FindAllOf, className)
    for _, o in ipairs((ok and found) or {}) do
        if IsInstance(o) then table.insert(out, o) end
    end
    return out
end

-- FName or FGameplayTag -> string
local function NameOf(v)
    if v == nil then return "nil" end
    local ok, s = pcall(function() return v.TagName:ToString() end)
    if ok then return s end
    ok, s = pcall(function() return v:ToString() end)
    if ok then return s end
    return tostring(v)
end

local function NameListToString(arr)
    local names = {}
    for i = 1, Count(arr) do names[#names + 1] = NameOf(arr[i]) end
    return table.concat(names, ", ")
end

local function TagListToString(tags)
    local names = {}
    for i = 1, Count(tags) do
        local ok, s = pcall(function() return tags[i].TagName:ToString() end)
        names[#names + 1] = ok and s or "?"
    end
    return table.concat(names, ", ")
end

local function ActorHasTag(actor, tagName)
    local tags = Try(function() return actor.Tags end)
    for i = 1, Count(tags) do
        if NameOf(tags[i]) == tagName then return true end
    end
    return false
end

local function ClassName(o)
    local ok, s = pcall(function() return o:GetClass():GetFullName() end)
    return ok and (s:match("([^%.]+)$") or s) or "?"
end

local function LevelOf(obj)
    -- actors live directly in a ULevel; compare that outer to group actors by level
    local outer = Try(function() return obj:GetOuter() end)
    return (outer and outer:IsValid()) and outer:GetFullName() or "?"
end

-- All actors in the same level as `owner` (the creation manager's owner), plus which carry `tagName`.
local function ActorsInLevelOf(owner, tagName)
    local level = LevelOf(owner)
    local same, tagged = {}, {}
    for _, a in ipairs(Instances("Actor")) do
        if LevelOf(a) == level then
            same[#same + 1] = a
            if tagName and ActorHasTag(a, tagName) then tagged[#tagged + 1] = a end
        end
    end
    return same, tagged, level
end

--------------------------------------------------------------------------------------------------
local function DescribeCreationManager(pcm)
    local owner = pcm:GetOwner()
    local spawnTag = NameOf(Try(function() return pcm.SpawnAvatarTransformTag end))
    Out("%s  owner=%s", ShortName(pcm:GetFullName()), owner:IsValid() and ShortName(owner:GetFullName()) or "?")
    Out("   EditionCharacters=%d  CurrentCharacterIndex=%s  CharactersReadiness=%d",
        Count(Try(function() return pcm.EditionCharacters end)),
        tostring(Try(function() return pcm.CurrentCharacterIndex end)),
        Count(Try(function() return pcm.CharactersReadiness end)))
    Out("   SpawnAvatarTransformTag=%s", spawnTag)
    Out("   SpecterTags=[%s]", NameListToString(Try(function() return pcm.SpecterTags end)))
    Out("   LightingSnapTags=[%s]", NameListToString(Try(function() return pcm.LightingSnapTags end)))
    if owner:IsValid() then
        local same, tagged, level = ActorsInLevelOf(owner, spawnTag)
        Out("   level %s: %d actors, %d carry the spawn tag:", ShortName(level), #same, #tagged)
        for i, a in ipairs(tagged) do
            Out("     [%d] %s  (%s)  tags=[%s]", i, ShortName(a:GetFullName()), ClassName(a),
                NameListToString(Try(function() return a.Tags end)))
        end
    end
end

local function Report()
    Out("---- settings ----")
    local s = StaticFindObject("/Script/Brimstone.Default__BrimstoneSettings")
    if s and s:IsValid() then
        local tags = Try(function() return s.DefaultHeroes.GameplayTags end)
        Out("BrimstoneSettings.DefaultHeroes (%d): %s   (not used by character creation)", Count(tags), tags and TagListToString(tags) or "?")
    end

    Out("---- campaign definitions ----")
    for _, cd in ipairs(Instances("CampaignDefinition")) do
        Out("%s  DefaultHeroes=%d  bDefaultCampaign=%s  StartingLevel=%s",
            ShortName(cd:GetFullName()), Count(Try(function() return cd.DefaultHeroes end)),
            tostring(Try(function() return cd.bDefaultCampaign end)),
            tostring(Try(function() return cd.StartingLevel end)))
    end

    Out("---- party creation (armed for %s slots) ----", tostring(WANT_SLOTS))
    local pcms = Instances("PartyCreationManagerComponent")
    if #pcms == 0 then Out("no PartyCreationManagerComponent alive (only exists in character creation / lobby)") end
    for _, pcm in ipairs(pcms) do
        local ok, err = pcall(DescribeCreationManager, pcm)
        if not ok then Out("describe failed: %s", tostring(err)) end
    end

    Out("---- session view models ----")
    for _, vm in ipairs(Instances("GameSessionViewModel")) do
        Out("%s  HeroSlots=%d  CharacterSlots=%d  PlayerSlots=%d  NpcSlots=%d  IsMultiplayer=%s  AmIHost=%s  IsInPartyCreation=%s",
            ShortName(vm:GetFullName()),
            Count(Try(function() return vm.HeroSlots end)),
            Count(Try(function() return vm.CharacterSlots end)),
            Count(Try(function() return vm.PlayerSlots end)),
            Count(Try(function() return vm.NpcSlots end)),
            tostring(Try(function() return vm.IsMultiplayer end)),
            tostring(Try(function() return vm.AmIHost end)),
            tostring(Try(function() return vm.IsInPartyCreation end)))
        Out("   IsCurrentAssignmentValid=%s  IsReadyToCreateParty=%s  UnassignedCharacters=%s  CanFillWithMoreCharacters=%s  Warning='%s'",
            tostring(Try(function() return vm.IsCurrentAssignmentValid end)),
            tostring(Try(function() return vm:GetIsReadyToCreateParty() end)),
            tostring(Try(function() return vm:GetUnassignedCharactersNum() end)),
            tostring(Try(function() return vm:GetCanFillWithMoreCharacters() end)),
            tostring(Try(function() return vm.PartySetupWarningText:ToString() end)))
        local players = Try(function() return vm.PlayerSlots end)
        for i = 1, Count(players) do
            local ps = players[i]
            Out("   PlayerSlot[%d] %s controlled=%d ready=%s", i, ShortName(ps:GetFullName()),
                Count(Try(function() return ps.ControlledCharacters end)), tostring(Try(function() return ps.IsReady end)))
        end
    end

    Out("---- party ----")
    local pcs = Instances("PartyComponent")
    if #pcs == 0 then Out("no PartyComponent alive (load into a game)") end
    for _, pc in ipairs(pcs) do
        local party = Try(function() return pc.Party end)
        Out("%s  Party=%d  PartySubgroups=%d", ShortName(pc:GetFullName()), Count(party), Count(Try(function() return pc.PartySubgroups end)))
        for i = 1, Count(party) do
            local m = party[i]
            local name = (m and m:IsValid()) and ShortName(m:GetFullName()) or "invalid"
            Out("   [%d] %-28s hero=%s guest=%s", i, name,
                tostring(Try(function() return pc:IsHero(m) end)),
                tostring(Try(function() return pc:IsGuest(m) end)))
        end
    end
    Out("---- end of report ----")
end

--------------------------------------------------------------------------------------------------
local function Vec(v) return { X = v.X, Y = v.Y, Z = v.Z } end
local function Rot(r) return { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } end

-- Spawn `count` TargetPoint actors next to the existing markers and give them the spawn tag.
local function SpawnMarkers(worldContext, markers, count, spawnTag)
    if count <= 0 or #markers < 2 then return 0 end
    local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local tpClass = StaticFindObject("/Script/Engine.TargetPoint")
    if not (statics and statics:IsValid() and tpClass and tpClass:IsValid()) then Out("arm: GameplayStatics/TargetPoint not found") return 0 end
    local locs, rots = {}, {}
    for i, m in ipairs(markers) do
        local okl, l = pcall(function() return m:K2_GetActorLocation() end)
        local okr, r = pcall(function() return m:K2_GetActorRotation() end)
        if not (okl and okr) then Out("arm: cannot read marker %d transform: %s", i, tostring(l)) return 0 end
        locs[i] = Vec(l); rots[i] = Rot(r)
    end
    local n = #markers
    -- positions: continue the row past the last marker, then before the first
    local targets = {}
    local step = { X = locs[n].X - locs[n-1].X, Y = locs[n].Y - locs[n-1].Y, Z = locs[n].Z - locs[n-1].Z }
    targets[1] = { loc = { X = locs[n].X + step.X, Y = locs[n].Y + step.Y, Z = locs[n].Z + step.Z }, rot = rots[n] }
    local step0 = { X = locs[1].X - locs[2].X, Y = locs[1].Y - locs[2].Y, Z = locs[1].Z - locs[2].Z }
    targets[2] = { loc = { X = locs[1].X + step0.X, Y = locs[1].Y + step0.Y, Z = locs[1].Z + step0.Z }, rot = rots[1] }
    local spawned = 0
    for k = 1, math.min(count, #targets) do
        local t = targets[k]
        local ok, err = pcall(function()
            local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = t.loc, Scale3D = { X = 1, Y = 1, Z = 1 } }
            local actor = statics:BeginDeferredActorSpawnFromClass(worldContext, tpClass, xf, 1, nil, 0)
            if not (actor and actor:IsValid()) then error("BeginDeferredActorSpawnFromClass returned nothing") end
            statics:FinishSpawningActor(actor, xf, 0)
            actor:K2_TeleportTo(t.loc, t.rot)
            local tags = actor.Tags
            tags[#tags + 1] = FName(spawnTag)
            if NameOf(tags[#tags]) ~= spawnTag then error("tag did not stick") end
            Out("arm: spawned marker %s at (%.0f, %.0f, %.0f)", ShortName(actor:GetFullName()), t.loc.X, t.loc.Y, t.loc.Z)
        end)
        if ok then spawned = spawned + 1 else Out("arm: marker spawn failed: %s", tostring(err)) end
    end
    return spawned
end

-- Give every character slot the host/local player does not control yet to that player, through the
-- game's own ChangeCharacterController (updates player state indexes + signals the command manager).
local function AssignExtraSlots()
    for _, vm in ipairs(Instances("GameSessionViewModel")) do
        local slots = Try(function() return vm.CharacterSlots end)
        local players = Try(function() return vm.PlayerSlots end)
        if Count(players) < 1 then Out("assign: no player slots yet") return end
        local me = players[1]
        for i = 1, Count(slots) do
            local slot = slots[i]
            local ok, err = pcall(function() vm:ChangeCharacterController(slot, me) end)
            Out("assign: slot %d -> player 1: %s", i, ok and "called" or ("failed: " .. tostring(err)))
        end
    end
end

-- Make the UI fit: a render scale on the HorizontalBox only shrinks the picture, its layout size stays
-- six slots wide and pushes the start/back buttons off-screen. Unreal's global ApplicationScale
-- (UserInterfaceSettings) scales the real layout instead, so everything shrinks together.
local function SetUIScale(scale)
    local ui = StaticFindObject("/Script/Engine.Default__UserInterfaceSettings")
    if not (ui and ui:IsValid()) then Out("layout: UserInterfaceSettings not found") return end
    local ok, err = pcall(function() ui.ApplicationScale = scale end)
    Out("layout: ApplicationScale = %.2f: %s", scale, ok and "ok" or tostring(err))
end

-- Walk a widget tree (UserWidget -> WidgetTree.RootWidget, PanelWidget -> children).
local function ForEachWidget(w, fn, depth)
    depth = depth or 0
    if not (w and w:IsValid()) or depth > 40 then return end
    fn(w)
    local tree = Try(function() return w.WidgetTree end)
    if tree and tree:IsValid() then
        ForEachWidget(Try(function() return tree.RootWidget end), fn, depth + 1)
        return
    end
    local n = Try(function() return w:GetChildrenCount() end)
    if n and n > 0 then
        for k = 0, n - 1 do ForEachWidget(Try(function() return w:GetChildAt(k) end), fn, depth + 1) end
    end
end

local ADJUSTED = {}   -- widget address -> true, so repeated FixLayout calls do not shrink twice

-- Shrink the layout width of every card in the slot row: SizeBox width overrides and slot padding.
-- (ApplicationScale had no effect in this game; render scale does not change layout.)
local function FixLayout()
    local f = 4 / (WANT_SLOTS or 4)
    SetUIScale(1.0)
    local sizeBoxClass = StaticFindObject("/Script/UMG.SizeBox")
    local hSlotClass = StaticFindObject("/Script/UMG.HorizontalBoxSlot")
    for _, screen in ipairs(Instances("PartySetupScreen")) do
        local tbl = Try(function() return screen.CharacterSlotsTable end)
        if not (tbl and tbl:IsValid()) then Out("layout: %s has no CharacterSlotsTable", ShortName(screen:GetFullName())) return end
        pcall(function() tbl:SetRenderScale({ X = 1, Y = 1 }) end)
        local nCards = Try(function() return tbl:GetChildrenCount() end) or 0
        local boxes, pads = 0, 0
        for k = 0, nCards - 1 do
            local card = Try(function() return tbl:GetChildAt(k) end)
            if card and card:IsValid() then
                -- padding between cards
                local slot = Try(function() return card.Slot end)
                if slot and slot:IsValid() and slot:IsA(hSlotClass) and not ADJUSTED[slot:GetAddress()] then
                    local pad = Try(function() return slot.Padding end)
                    if pad then
                        local ok = pcall(function() slot:SetPadding({ Left = pad.Left * f, Top = pad.Top, Right = pad.Right * f, Bottom = pad.Bottom }) end)
                        if ok then pads = pads + 1; ADJUSTED[slot:GetAddress()] = true end
                    end
                end
                -- width overrides inside the card
                ForEachWidget(card, function(w)
                    if w:IsA(sizeBoxClass) and not ADJUSTED[w:GetAddress()] then
                        local over = Try(function() return w.bOverride_WidthOverride end)
                        local width = Try(function() return w.WidthOverride end) or 0
                        if over and width > 0 then
                            local ok = pcall(function() w:SetWidthOverride(width * f) end)
                            if ok then boxes = boxes + 1; ADJUSTED[w:GetAddress()] = true end
                        end
                        local minOver = Try(function() return w.bOverride_MinDesiredWidth end)
                        local minW = Try(function() return w.MinDesiredWidth end) or 0
                        if minOver and minW > 0 then pcall(function() w:SetMinDesiredWidth(minW * f) end) end
                    end
                end)
            end
        end
        Out("layout: %s row has %d cards; shrank %d SizeBox width(s) and %d padding(s) by %.2f", ShortName(screen:GetFullName()), nCards, boxes, pads, f)
        if boxes == 0 then
            -- fall back to the visual-only shrink so at least the cards are readable
            pcall(function() tbl:SetRenderScale({ X = f, Y = f }) end)
            Out("layout: no SizeBox width overrides found in the cards — used render scale instead")
        end
    end
end

-- Widen the creation camera so the outer models come into frame.
local CAMERA_FOV_MULT = 1.35
local function WidenCamera()
    local pc = UEHelpers.GetPlayerController()
    if not (pc and pc:IsValid()) then Out("camera: no player controller") return end
    local vt = Try(function() return pc:GetViewTarget() end)
    if not (vt and vt:IsValid()) then Out("camera: no view target") return end
    local camClass = StaticFindObject("/Script/Engine.CameraComponent")
    local cam = Try(function() return vt:GetComponentByClass(camClass) end)
    if not (cam and cam:IsValid()) then Out("camera: view target %s has no CameraComponent", ShortName(vt:GetFullName())) return end
    local fov = Try(function() return cam.FieldOfView end) or 0
    if fov > 0 and fov < 120 then
        local ok, err = pcall(function() cam:SetFieldOfView(fov * CAMERA_FOV_MULT) end)
        Out("camera: %s FOV %.1f -> %.1f: %s", ShortName(vt:GetFullName()), fov, fov * CAMERA_FOV_MULT, ok and "ok" or tostring(err))
    else
        Out("camera: %s FOV=%s (left alone)", ShortName(vt:GetFullName()), tostring(fov))
    end
end

-- Pre-hook: before InitEditionActors gathers the tagged spawn actors, tag extra actors so it finds
-- WANT_SLOTS of them. Extra actors are the specter placeholders of the existing slots when possible
-- (they stand at sensible positions), otherwise any other actor in the same level.
local function AddSpawnTags(pcm)
    if not WANT_SLOTS then return end
    local owner = Try(function() return pcm:GetOwner() end)
    if not (owner and owner:IsValid()) then owner = Try(function() return pcm:GetOuter() end) end
    if not (owner and owner:IsValid()) then Out("arm: manager has no owner/outer yet") return end
    local spawnTag = NameOf(Try(function() return pcm.SpawnAvatarTransformTag end))
    if spawnTag == "nil" or spawnTag == "None" then Out("arm: SpawnAvatarTransformTag unreadable (%s)", spawnTag) return end

    local same, tagged = ActorsInLevelOf(owner, spawnTag)
    Out("arm: level has %d actors, %d already carry '%s'; want %d", #same, #tagged, spawnTag, WANT_SLOTS)
    if #tagged >= WANT_SLOTS then return end

    -- Preferred: spawn fresh TargetPoint markers, placed by extrapolating the existing row of four
    -- (5th beyond marker 4, 6th before marker 1), then tag them. Fallback: borrow other actors.
    local added = 0
    local spawned = SpawnMarkers(owner, tagged, WANT_SLOTS - #tagged, spawnTag)
    added = added + spawned
    if #tagged + added < WANT_SLOTS then
        local candidates = {}
        for _, a in ipairs(same) do
            if not ActorHasTag(a, spawnTag) and ClassName(a) == "Actor" then candidates[#candidates + 1] = a end
        end
        for _, a in ipairs(same) do
            if not ActorHasTag(a, spawnTag) and ClassName(a) ~= "Actor" then candidates[#candidates + 1] = a end
        end
        for _, a in ipairs(candidates) do
            if #tagged + added >= WANT_SLOTS then break end
            local ok, err = pcall(function()
                local tags = a.Tags
                tags[#tags + 1] = FName(spawnTag)
                if NameOf(tags[#tags]) ~= spawnTag then error("tag did not stick") end
            end)
            if ok then added = added + 1; Out("arm: borrowed+tagged %s (%s)", ShortName(a:GetFullName()), ClassName(a))
            else Out("arm: could not tag %s: %s", ShortName(a:GetFullName()), tostring(err)) end
        end
    end
    Out("arm: added %d marker(s); InitEditionActors should now find %d", added, #tagged + added)
end

-- The UI slot list is built by UGameSessionViewModel::SetupDefaultSession with a literal 4
-- (mov r13d,4 at 0x146d69133 in CL-112340): four UCharacterSlotViewModel objects, two native delegate
-- bindings each, appended to CharacterSlots. ReadCharacterEditionSlots later Bind()s slot i to
-- edition actor i. From Lua we can construct and append extra slot view models (no delegate
-- bindings, so readiness notifications for slots 5+ are missing — fine for a visual probe).
local function ExtendCharacterSlots(want)
    local cls = StaticFindObject("/Script/Brimstone.CharacterSlotViewModel")
    local pkg = StaticFindObject("/Engine/Transient")
    if not (cls and cls:IsValid()) then Out("slots: CharacterSlotViewModel class not found") return end
    if not (pkg and pkg:IsValid()) then Out("slots: transient package not found") return end
    for _, vm in ipairs(Instances("GameSessionViewModel")) do
        local slots = Try(function() return vm.CharacterSlots end)
        local before = Count(slots)
        if before < 0 then Out("slots: cannot read CharacterSlots on %s", ShortName(vm:GetFullName())) return end
        local added = 0
        while Count(slots) < want do
            local ok, err = pcall(function()
                local slot = StaticConstructObject(cls, pkg)
                if not (slot and slot:IsValid()) then error("StaticConstructObject returned nothing") end
                local n = #slots
                slots[n + 1] = slot
                if not (slots[n + 1]:IsValid() and slots[n + 1]:GetAddress() == slot:GetAddress()) then error("append verify failed") end
                added = added + 1
            end)
            if not ok then Out("slots: append failed: %s", tostring(err)) break end
        end
        Out("slots: %s CharacterSlots %d -> %d (+%d)", ShortName(vm:GetFullName()), before, Count(slots), added)
    end
end

local function HookBoth(path, pre, post)
    local ok, err = pcall(function()
        RegisterHook(path,
            function(Context)
                if pre then
                    local okp, e = pcall(pre, Context:get())
                    if not okp then Out("pre-hook error: %s", tostring(e)) end
                end
            end,
            function(Context)
                if post then
                    local okq, e = pcall(post, Context:get())
                    if not okq then Out("post-hook error: %s", tostring(e)) end
                end
            end)
    end)
    Out("%s hook %s%s", ok and "OK  " or "FAIL", path, ok and "" or (": " .. tostring(err)))
end

HookBoth("/Script/Brimstone.PartyCreationManagerComponent:InitEditionActors",
    AddSpawnTags,
    function(self) Out("InitEditionActors -> EditionCharacters=%d", Count(self.EditionCharacters)) end)

-- Report what creation ended up with, a little while after arming.
local function DelayedCheck(label)
    for _, ms in ipairs({ 3000, 8000 }) do
        ExecuteWithDelay(ms, function()
            for _, pcm in ipairs(Instances("PartyCreationManagerComponent")) do
                local slots = "?"
                for _, vm in ipairs(Instances("GameSessionViewModel")) do slots = tostring(Count(Try(function() return vm.CharacterSlots end))) end
                Out("%s +%dms: EditionCharacters=%d  CharactersReadiness=%d  CharacterSlots=%s", label, ms,
                    Count(Try(function() return pcm.EditionCharacters end)),
                    Count(Try(function() return pcm.CharactersReadiness end)), slots)
            end
            if WANT_SLOTS then
                pcall(AssignExtraSlots)
                pcall(FixLayout)
                pcall(WidenCamera)
            end
        end)
    end
end

-- Primary arming point: the manager component is constructed when the creation level's GameState spawns.
local okN, errN = pcall(function()
    NotifyOnNewObject("/Script/Brimstone.PartyCreationManagerComponent", function(obj)
        if not WANT_SLOTS then return end
        Out("constructed %s — arming now", obj:GetFullName())
        local ok, err = pcall(AddSpawnTags, obj)
        if not ok then Out("arm (construct) error: %s", tostring(err)) end
        local ok2, err2 = pcall(ExtendCharacterSlots, WANT_SLOTS)
        if not ok2 then Out("arm (slots) error: %s", tostring(err2)) end
        DelayedCheck("after construct")
    end)
end)
Out("%s NotifyOnNewObject PartyCreationManagerComponent%s", okN and "OK  " or "FAIL", okN and "" or (": " .. tostring(errN)))

-- Second chance: the player controller restarts early in every map, including the creation level.
HookBoth("/Script/Engine.PlayerController:ClientRestart", function()
    if not WANT_SLOTS then return end
    for _, pcm in ipairs(Instances("PartyCreationManagerComponent")) do
        if Count(Try(function() return pcm.EditionCharacters end)) == 0 then
            Out("ClientRestart with an uninitialised creation manager — arming")
            local ok, err = pcall(AddSpawnTags, pcm)
            if not ok then Out("arm (ClientRestart) error: %s", tostring(err)) end
            local ok2, err2 = pcall(ExtendCharacterSlots, WANT_SLOTS)
            if not ok2 then Out("arm (slots) error: %s", tostring(err2)) end
            DelayedCheck("after ClientRestart")
        end
    end
end, nil)

HookBoth("/Script/Brimstone.PartyCreationManagerComponent:PushCreatedPartyToCampaign", nil,
    function(self)
        local parts = {}
        for _, pc in ipairs(Instances("PartyComponent")) do
            parts[#parts + 1] = string.format("%s Party=%d", ShortName(pc:GetFullName()), Count(pc.Party))
        end
        Out("PushCreatedPartyToCampaign -> EditionCharacters=%d; %s", Count(self.EditionCharacters), table.concat(parts, "; "))
    end)

HookBoth("/Script/Brimstone.PartyComponent:OnRep_Party", nil,
    function(self) Out("OnRep_Party -> Party=%d", Count(self.Party)) end)

--------------------------------------------------------------------------------------------------
RegisterKeyBind(Key.BACKSPACE, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(Report)
        if not ok then Out("report failed: %s", tostring(err)) end
    end)
end)

RegisterKeyBind(Key.TAB, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    if WANT_SLOTS then
        WANT_SLOTS = nil
        SetUIScale(1.0)
        Out("DISARMED — character creation will be stock again (UI scale restored)")
    else
        WANT_SLOTS = 6
        Out("ARMED for %d slots — now go to the main menu and start a NEW campaign; watch for 'InitEditionActors -> EditionCharacters='", WANT_SLOTS)
    end
end)

RegisterKeyBind(Key.END, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(AssignExtraSlots); if not ok then Out("assign failed: %s", tostring(err)) end
        ok, err = pcall(FixLayout); if not ok then Out("layout failed: %s", tostring(err)) end
        ok, err = pcall(WidenCamera); if not ok then Out("camera failed: %s", tostring(err)) end
    end)
end)

Out("v6 loaded — Ctrl+Shift+Backspace = report, Ctrl+Shift+Tab = arm/disarm 6 slots, Ctrl+Shift+End = assign slots to me + fix layout")
