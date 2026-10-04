-- Kobold: a playable kobold race for Solasta II (installed with BiggerParty; Mod options turns it on and off).
-- The game's hidden Gnome ancestry becomes the Kobold in character creation (its own picture, Draconic Cry and the
-- Kobold Legacy). A kobold hero's own body keeps animating but is not drawn; the game's kobold model rides on it,
-- mirrors its animations and carries its weapons. Cameras and portraits frame the kobold. In cutscenes a kobold
-- hero's lines are spoken in a kobold voice by the Narrator's companion (its add-on pack Narrator/packs/kobold).
-- Only heroes become kobolds: the game draws its Siklas NPCs on the gnome body too.
-- Kobold.ini next to the game exe: Enabled=0 changes nothing (at the next start), VoiceLevel (0.03-1, times the
-- game's master and voice volume; also Ctrl+Shift+, and Ctrl+Shift+.), Lab=1 the developer keys (Ctrl+Shift+J dump,
-- H anatomy, K / L kobold on / off, P portrait distance, U the studio).
local UEHelpers = require("UEHelpers")
local TAG = "[Kobold] "

local function Try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end; return nil end
local function ShortName(full) return full and (full:match("([^%.:]+)$") or full) or "nil" end
local function Str(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and s or nil
end
local function Valid(o) return o ~= nil and Try(function() return o:IsValid() end) == true end
local function Name(o) return Valid(o) and (Try(function() return ShortName(o:GetFullName()) end) or "?") or "nil" end
local function ClassOf(o) return Valid(o) and (Try(function() return ShortName(o:GetClass():GetFullName()) end) or "?") or "?" end
local function Tag(t) return Try(function() return t.TagName:ToString() end) or "?" end

local logPath = nil
-- settings and the game's folder: one table (the main chunk is at Lua's limit of 200 locals)
local KCFG = { version = "1.0.0", Enabled = true, VoiceLevel = 0.30, Lab = false, dir = nil }
function KCFG.Dir()                      -- the folder of the game's exe ("" when it is the working folder)
    if KCFG.dir then return KCFG.dir end
    local f = io.open("BiggerParty.ini", "r")
    if f then f:close(); KCFG.dir = ""; return KCFG.dir end
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local proj = Str(Try(function() return ksl:GetProjectDirectory() end))
    KCFG.dir = (proj and #proj > 0) and (proj .. "Binaries/Win64/") or ""
    return KCFG.dir
end
function KCFG.Read()
    local f = io.open(KCFG.Dir() .. "Kobold.ini", "r")
    if not f then return false end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k == "Enabled" then KCFG.Enabled = v ~= "0"
        elseif k == "VoiceLevel" then local n = tonumber(v); if n then KCFG.VoiceLevel = math.max(0.03, math.min(1.0, n)) end
        elseif k == "Lab" then KCFG.Lab = v == "1" end
    end
    f:close()
    return true
end
function KCFG.Write(key, value)          -- one key of Kobold.ini, the other lines kept
    local path, lines, seen = KCFG.Dir() .. "Kobold.ini", {}, false
    local f = io.open(path, "r")
    if f then
        for line in f:lines() do
            if line:match("^%s*([%w_]+)%s*=") == key then lines[#lines + 1] = key .. "=" .. value; seen = true else lines[#lines + 1] = line end
        end
        f:close()
    else
        lines = { "[Kobold]", "; 0 = the kobold race is off from the next start (Mod options: Kobold race)", "Enabled=1",
            "; the kobold voice, times the game's master and voice volume (Mod options: Kobold voice; Ctrl+Shift+, and .)", "VoiceLevel=0.30",
            "; 1 = the developer keys (dumps, the studio)", "Lab=0" }
        for i, l in ipairs(lines) do if l:match("^" .. key .. "=") then lines[i] = key .. "=" .. value; seen = true end end
    end
    if not seen then lines[#lines + 1] = key .. "=" .. value end
    local w = io.open(path, "w")
    if not w then return false end
    w:write(table.concat(lines, "\n"), "\n"); w:close()
    return true
end
local function Log(fmt, ...)
    local line = string.format(fmt, ...)
    print(TAG .. line .. "\n")
    if logPath == nil then
        logPath = false
        logPath = KCFG.Dir() .. "Kobold.log"
    end
    if logPath then
        local f = io.open(logPath, "a")
        if f then f:write(os.date("[%Y-%m-%d %H:%M:%S] "), line, "\n"); f:close() end
    end
end

local function Every(ms, fn)      -- fn runs on the game thread every ms
    if LoopInGameThreadWithDelay then
        return LoopInGameThreadWithDelay(ms, function()
            local ok, err = pcall(fn)
            if not ok then Log("timer error: %s", tostring(err)) end
        end)
    end
    LoopAsync(ms, function()
        ExecuteInGameThread(function() local ok, err = pcall(fn); if not ok then Log("timer error: %s", tostring(err)) end end)
        return false
    end)
end
if not KCFG.Read() then KCFG.Write("Enabled", "1") end      -- a first start writes the defaults
if not KCFG.Enabled then
    Log("Kobold %s: off (Kobold.ini Enabled=0, Mod options: Kobold race) - nothing in the game is changed", KCFG.version)
    return
end
Log("Kobold %s: on; voice level %.2f%s", KCFG.version, KCFG.VoiceLevel, KCFG.Lab and "; developer keys on" or "")

local function Vec(v)
    local x, y, z = Try(function() return v.X end), Try(function() return v.Y end), Try(function() return v.Z end)
    if type(x) ~= "number" then return "?" end
    return string.format("(%.1f %.1f %.1f)", x, y or 0, z or 0)
end
local function Rot(r)
    local p, y, l = Try(function() return r.Pitch end), Try(function() return r.Yaw end), Try(function() return r.Roll end)
    if type(p) ~= "number" then return "?" end
    return string.format("p%.0f y%.0f r%.0f", p, y or 0, l or 0)
end

local function ParamsText(fn)
    local parts = {}
    pcall(function()
        fn:ForEachProperty(function(prop)
            local n = Try(function() return prop:GetFName():ToString() end) or "?"
            local t = Try(function() return prop:GetClass():GetFName():ToString() end) or "?"
            parts[#parts + 1] = n .. ":" .. t
        end)
    end)
    return table.concat(parts, ", ")
end

--------------------------------------------------------------------------------------------------
-- assets
--------------------------------------------------------------------------------------------------
local PATHS = {
    body = "/Game/Characters/Monsters/Kobold/Body/SK_Character_Monster_Kobold_Body.SK_Character_Monster_Kobold_Body",
    armor = "/Game/Characters/Monsters/Kobold/Armor/SK_Character_Monster_Kobold_Armor.SK_Character_Monster_Kobold_Armor",
    abp = "/Game/Characters/Monsters/Kobold/ABP_Monster_Kobold.ABP_Monster_Kobold_C",
    avatarBP = "/Ruleset_2024/Blueprints/Avatars/BP_Kobold.BP_Kobold_C",
    avatarDef = "/Ruleset_2024/Database/Monsters/Humanoids/Kobold/DA_MON_Kobold_Avatar.DA_MON_Kobold_Avatar",
}
local ANCESTRIES = { "Dragonborn", "Dwarf", "Elf", "Gnome", "HalfOrc", "Halfelf", "Halfling", "Human", "Pavon", "Siklas", "Tiefling" }

local function Load(path, quiet)
    local o = Try(function() return StaticFindObject(path) end)
    if Valid(o) then return o end
    local ok, r = pcall(function() return LoadAsset(path) end)
    if ok and Valid(r) then return r end
    o = Try(function() return StaticFindObject(path) end)
    if Valid(o) then return o end
    if not quiet then Log("could not load %s (%s)", path, ok and "not found" or tostring(r)) end
    return nil
end

local SKC_PATH = "/Script/Engine.SkeletalMeshComponent"
local function SkeletalComponents(pawn)
    local out = {}
    local cls = StaticFindObject(SKC_PATH)
    local arr = cls and Try(function() return pawn:K2_GetComponentsByClass(cls) end)
    local n = arr and (Try(function() return #arr end) or 0) or 0
    for i = 1, n do
        local c = Try(function() return arr[i] end)
        if Valid(c) then out[#out + 1] = c end
    end
    return out
end
local function CompName(c) return Try(function() return c:GetFName():ToString() end) or "?" end
local function MeshOf(c)
    for _, get in ipairs({ function() return c.SkeletalMeshAsset end, function() return c.SkeletalMesh end, function() return c:GetSkeletalMeshAsset() end }) do
        local m = Try(get)
        if Valid(m) then return m end
    end
    return nil
end
local function AvatarOf(pawn)
    local cls = StaticFindObject("/Script/Brimstone.CharacterAvatarComponent")
    local c = cls and Try(function() return pawn:GetComponentByClass(cls) end)
    return Valid(c) and c or nil
end
local AVATAR_MESHES = { "BodySkeletalMeshComponent", "HairSkeletalMeshComponent", "BeardSkeletalMeshComponent",
    "ClothesSkeletalMeshComponent", "HelmetSkeletalMeshComponent", "GlovesSkeletalMeshComponent", "BootsSkeletalMeshComponent",
    "CapeSkeletalMeshComponent", "BeltSkeletalMeshComponent", "BracersSkeletalMeshComponent" }
-- every drawn component of the hero: the avatar's mesh slots, the character's Mesh and everything attached under
-- them (face, eyebrows, wielded weapons), except the names in skip (the kobold puppet and its armour)
local function HeroDrawn(pawn, skip)
    local out, seen = {}, {}
    local function add(c, depth)
        if not Valid(c) or depth > 6 then return end
        local a = Try(function() return c:GetAddress() end)
        if not a or seen[a] then return end
        seen[a] = true
        if skip and skip[CompName(c)] then return end
        local mc = StaticFindObject("/Script/Engine.MeshComponent")
        if mc and Try(function() return c:IsA(mc) end) == true then out[#out + 1] = c end
        local kids = Try(function() return c.AttachChildren end)
        local n = kids and (Try(function() return #kids end) or 0) or 0
        for i = 1, n do add(Try(function() return kids[i] end), depth + 1) end
    end
    local av = AvatarOf(pawn)
    if av then for _, prop in ipairs(AVATAR_MESHES) do add(Try(function() return av[prop] end), 0) end end
    add(Try(function() return pawn.Mesh end), 0)
    for _, c in ipairs(SkeletalComponents(pawn)) do add(c, 0) end
    return out
end
local function CurrentPawn()
    local pc = UEHelpers.GetPlayerController()
    local pawn = Valid(pc) and Try(function() return pc:K2_GetPawn() end)
    if Valid(pawn) and AvatarOf(pawn) then return pawn end
    return nil
end

--------------------------------------------------------------------------------------------------
-- Ctrl+Shift+J: what things are made of
--------------------------------------------------------------------------------------------------
function DumpComponent(c, indent)
    local ai = Try(function() return c:GetAnimInstance() end)
    Log("%s%s [%s] mesh=%s anim=%s visible=%s rel=%s %s scale=%s parent=%s", indent, CompName(c), ClassOf(c), Name(MeshOf(c)),
        Valid(ai) and ClassOf(ai) or "none", tostring(Try(function() return c:IsVisible() end)),
        Vec(Try(function() return c.RelativeLocation end)), Rot(Try(function() return c.RelativeRotation end)),
        Vec(Try(function() return c.RelativeScale3D end)), Name(Try(function() return c:GetAttachParent() end)))
end

function DumpHero(pawn)
    Log("== hero %s [%s]", Name(pawn), ClassOf(pawn))
    local cap = Try(function() return pawn.CapsuleComponent end)
    if Valid(cap) then
        Log("   capsule half height %s radius %s", tostring(Try(function() return cap:GetScaledCapsuleHalfHeight() end)),
            tostring(Try(function() return cap:GetScaledCapsuleRadius() end)))
    end
    local cls = StaticFindObject(SKC_PATH)
    local ok, err = pcall(function() return pawn:K2_GetComponentsByClass(cls) end)
    Log("   K2_GetComponentsByClass: %s, %d skeletal component(s)", ok and "ok" or ("failed: " .. tostring(err)), #SkeletalComponents(pawn))
    for _, c in ipairs(HeroDrawn(pawn)) do
        local owner = Try(function() return c:GetOwner() end)
        DumpComponent(c, (Valid(owner) and owner:GetAddress() ~= pawn:GetAddress()) and ("   [" .. Name(owner) .. "] ") or "   ")
    end
    local av = AvatarOf(pawn)
    if not av then Log("   no CharacterAvatarComponent"); return end
    local t = Try(function() return av.CurrentMeshSelectionTags end)
    if t then
        local parts = {}
        for _, k in ipairs({ "AncestryTag", "HairTag", "BeardTag", "ClothesTag", "HelmetTag", "GlovesTag", "BootsTag", "CapeTag", "BeltTag", "BracersTag" }) do
            parts[#parts + 1] = k:gsub("Tag$", "") .. "=" .. Tag(Try(function() return t[k] end))
        end
        Log("   mesh selection: %s", table.concat(parts, " "))
    end
    Log("   avatar body component %s, anim instance %s, ethereal %s, in story %s",
        Name(Try(function() return av.BodySkeletalMeshComponent end)), Name(Try(function() return av.CurrentAnimInstance end)),
        tostring(Try(function() return av.bIsEthereal end)), tostring(Try(function() return av.bIsInStory end)))
end

function DumpKoboldAvatar()
    local cls = Load(PATHS.avatarBP)
    if not cls then return end
    Log("== %s (parent %s)", Name(cls), Name(Try(function() return cls:GetSuperStruct() end)))
    local cdo = Try(function() return cls:GetCDO() end)
    if Valid(cdo) then
        local mesh = Try(function() return cdo.Mesh end)
        if Valid(mesh) then DumpComponent(mesh, "   default Mesh: ") end
        local cap = Try(function() return cdo.CapsuleComponent end)
        if Valid(cap) then Log("   default capsule half height %s radius %s", tostring(Try(function() return cap.CapsuleHalfHeight end)), tostring(Try(function() return cap.CapsuleRadius end))) end
        local av = Try(function() return cdo:GetComponentByClass(StaticFindObject("/Script/Brimstone.CharacterAvatarComponent")) end)
        Log("   default object has a CharacterAvatarComponent: %s", tostring(Valid(av)))
    end
    local scs = Try(function() return cls.SimpleConstructionScript end)
    local nodes = Valid(scs) and Try(function() return scs.AllNodes end)
    local n = nodes and (Try(function() return #nodes end) or 0) or 0
    for i = 1, n do
        local node = Try(function() return nodes[i] end)
        local tpl = node and Try(function() return node.ComponentTemplate end)
        if Valid(tpl) then
            Log("   added component %s (under %s):", tostring(Try(function() return node.InternalVariableName:ToString() end)),
                tostring(Try(function() return node.ParentComponentOrVariableName:ToString() end)))
            DumpComponent(tpl, "      ")
        end
    end
    local def = Load(PATHS.avatarDef)
    if def then
        Log("   %s: dynamic character %s, right handed %s, capsule override %s, wielded item scale %s", Name(def),
            tostring(Try(function() return def.bIsDynamicCharacter end)), tostring(Try(function() return def.bIsRightHanded end)),
            tostring(Try(function() return def.CapsuleHeightOverride end)), tostring(Try(function() return def.WieldedItemScale end)))
    end
end

function DumpAncestries()
    for _, a in ipairs(ANCESTRIES) do
        Load(string.format("/Ruleset_2024/Database/Ancestries/%s/DA_AN_%s.DA_AN_%s", a, a, a))
    end
    Load("/Ruleset_2024/Database/Ancestries/Human/DA_AN_Fallen.DA_AN_Fallen")
    local list = Try(function() return FindAllOf("AncestryDefinition") end) or {}
    Log("== ancestries (%d)", #list)
    for _, a in ipairs(list) do
        if Valid(a) and not a:GetFullName():find("Default__", 1, true) then
            Log("   %s: %q tag %s offered %s locked %s default %s sort %s size %s wielded scale %s capsule %s", Name(a),
                Str(Try(function() return a.Title end)) or "?", Tag(Try(function() return a.AssetTag end)),
                tostring(Try(function() return a.bEnumerableForUser end)), tostring(Try(function() return a.bLockedForUser end)),
                tostring(Try(function() return a.bDefaultSelection end)), tostring(Try(function() return a.SortOrder end)),
                Tag(Try(function() return a.CreatureSizeTag end)), tostring(Try(function() return a.WieldedItemScale end)),
                tostring(Try(function() return a.CapsuleHeightOverride end)))
        end
    end
    for _, fnName in ipairs({ "GetBodyMesh", "GetAnimClass", "GetAvailableHairMesh", "GetAvailableBeardMesh" }) do
        local fn = Try(function() return StaticFindObject("/Script/Brimstone.AncestryDefinition:" .. fnName) end)
        if Valid(fn) then Log("   AncestryDefinition:%s(%s)", fnName, ParamsText(fn)) end
    end
end

local MAPPINGS = { "Attacks/DA_AM_Dagger_Attack", "Attacks/DA_AM_Scimitar_Attack", "Attacks/DA_AM_Bow_Attack",
    "Attacks/DA_AM_Slash_Attack", "Attacks/DA_AM_Slash_Attack_Shield", "Attacks/DA_AM_Crossbow_Attack", "Attacks/DA_AM_Throw_Attack",
    "Spells/DA_AM_SpellCast_Ranged_Short", "Spells/DA_AM_SpellCast_Benefic", "Power/DA_AM_Power_MeleeAttack",
    "Interaction/DA_AM_Interaction_Chest", "Interaction/DA_AM_Interaction_Default", "Locomotion/DA_AM_Jump", "Locomotion/DA_AM_ClimbUp" }
function DumpMappings()
    Log("== animation mappings (an action's default montage, and the tags that replace it)")
    for _, m in ipairs(MAPPINGS) do
        local leaf = m:match("[^/]+$")
        local d = Load("/Game/Database/Animations/" .. m .. "." .. leaf)
        if d then
            local keys, how = {}, "no Overrides"
            local ov = Try(function() return d.Overrides end)
            if ov ~= nil then
                local ok, err = pcall(function()
                    ov:ForEach(function(k, v)
                        local kk = Try(function() return k:get() end) or k
                        keys[#keys + 1] = Tag(kk)
                    end)
                end)
                how = ok and (#keys .. " override(s)") or ("ForEach failed: " .. tostring(err))
            end
            Log("   %s: %s %s", leaf, how, table.concat(keys, ", "))
        end
    end
    for _, fnName in ipairs({ "FetchMontage", "FindAnimOverrideFromASC" }) do
        local fn = Try(function() return StaticFindObject("/Script/Brimstone.AnimMappingDefinition:" .. fnName) end)
        if Valid(fn) then Log("   AnimMappingDefinition:%s(%s)", fnName, ParamsText(fn)) end
    end
end

local FindByName      -- defined with the kobold puppet below; the dump uses it
local KOBOLD = {}      -- pawn address -> { name, pawn, saved = { [component address] = how to restore }, puppet, armor, items, montage }
local STATE_ANIMS = { "Idle", "Walk", "Jog", "Run", "Death", "Uncouncious", "Fall_Dead", "Death_Flying", "Prone_In", "Prone_Idle",
    "Prone_Out", "Fall_Prone", "HitFront", "Defend_In", "Defend_Loop", "Defend_Out", "Dagger_Idle", "Shortsword_Idle", "Longsword_idle",
    "Shield_Idle", "Bow_Idle", "Crossbow_Idle", "Greataxe_Idle", "Quarterstaff_Idle", "Idle_Sneak", "Flying_Idle" }
function DumpStateAnims(label, ai)
    local parts = {}
    for _, v in ipairs(STATE_ANIMS) do
        local a = Try(function() return ai[v] end)
        parts[#parts + 1] = v .. "=" .. (Valid(a) and Name(a) or "-")
    end
    Log("   %s animations: %s", label, table.concat(parts, " "))
end
local function Dump()
    Log("================ Kobold dump")
    for addr, st in pairs(KOBOLD) do
        local p = st.pawn
        if p and Valid(p) and Name(p) == st.name then
            local puppet = FindByName(p, st.puppet)
            local kAI = Valid(puppet) and Try(function() return puppet:GetAnimInstance() end)
            local av = AvatarOf(p)
            local body = av and Try(function() return av.BodySkeletalMeshComponent end)
            local hAI = Valid(body) and Try(function() return body:GetAnimInstance() end)
            if Valid(kAI) then DumpStateAnims(st.name .. " kobold", kAI) end
            if Valid(hAI) then DumpStateAnims(st.name .. " hero", hAI) end
        end
    end
    local pawn = CurrentPawn()
    if pawn then DumpHero(pawn) else Log("no hero is selected (on the world map?)") end
    pcall(DumpKoboldAvatar)
    pcall(DumpAncestries)
    local ok, err = pcall(DumpMappings)
    if not ok then Log("mappings: %s", tostring(err)) end
end

--------------------------------------------------------------------------------------------------
-- Ctrl+Shift+K / L: the kobold puppet
--------------------------------------------------------------------------------------------------
local CLASSES = {}
local function ClassAt(path)
    local c = CLASSES[path]
    if c == nil then c = Try(function() return StaticFindObject(path) end) or false; CLASSES[path] = c end
    return c or nil
end
local function IsA(c, path)
    local cls = ClassAt(path)
    return cls ~= nil and Try(function() return c:IsA(cls) end) == true
end
local function IsMesh(c) return IsA(c, "/Script/Engine.MeshComponent") end
local function IsSkinned(c) return IsA(c, "/Script/Engine.SkinnedMeshComponent") end
local function SetDrawn(c, flags)
    pcall(function() c:SetRenderInMainPass(flags.main) end)
    pcall(function() c:SetRenderInDepthPass(flags.depth) end)
    pcall(function() c:SetCastShadow(flags.shadow) end)
    pcall(function() c:SetRenderCustomDepth(flags.custom) end)
end
local HIDDEN = { main = false, depth = false, shadow = false, custom = false }
local function FlagsOf(c)
    local function b(name, default) local v = Try(function() return c[name] end); if type(v) == "boolean" then return v end; return default end
    return { main = b("bRenderInMainPass", true), depth = b("bRenderInDepthPass", true), shadow = b("CastShadow", true), custom = b("bRenderCustomDepth", false) }
end
-- skinned meshes stop being drawn but keep animating (the game's actions run on them); static meshes (weapons,
-- Nanite, which ignores the render-pass flags) are hidden outright
local function HideMesh(c)
    if IsSkinned(c) then
        local s = { skinned = true, flags = FlagsOf(c) }
        SetDrawn(c, HIDDEN)
        return s
    end
    local s = { skinned = false, hidden = Try(function() return c.bHiddenInGame end) == true }
    pcall(function() c:SetHiddenInGame(true, false) end)
    return s
end
local function StillHidden(c, s)
    if s.skinned then return Try(function() return c.bRenderInMainPass end) == false end
    return Try(function() return c.bHiddenInGame end) == true
end
local function RestoreMesh(c, s)
    if s.skinned then SetDrawn(c, s.flags) else pcall(function() c:SetHiddenInGame(s.hidden, false) end) end
end
local function MeshesUnder(root, skip)
    local out, seen = {}, {}
    local function add(c, depth)
        if not Valid(c) or depth > 6 then return end
        local a = Try(function() return c:GetAddress() end)
        if not a or seen[a] then return end
        seen[a] = true
        if skip and skip[CompName(c)] then return end
        if IsMesh(c) then out[#out + 1] = c end
        local kids = Try(function() return c.AttachChildren end)
        local n = kids and (Try(function() return #kids end) or 0) or 0
        for i = 1, n do add(Try(function() return kids[i] end), depth + 1) end
    end
    add(root, 0)
    return out
end
-- the roots of item actors (weapons, shield, lantern, potion) hanging on the hero's own components, with their socket
local function HeroItems(pawn, skip)
    local items, seen = {}, {}
    local mine = pawn:GetAddress()
    local function walk(c, depth)
        if not Valid(c) or depth > 6 then return end
        local a = Try(function() return c:GetAddress() end)
        if not a or seen[a] then return end
        seen[a] = true
        if skip and skip[CompName(c)] then return end
        local owner = Try(function() return c:GetOwner() end)
        if Valid(owner) and owner:GetAddress() ~= mine then
            local sock = Try(function() return c:GetAttachSocketName():ToString() end) or "None"
            local parent = Try(function() return c:GetAttachParent() end)
            items[#items + 1] = { root = c, socket = sock, parent = Valid(parent) and CompName(parent) or "?", owner = Name(owner) }
            return
        end
        local kids = Try(function() return c.AttachChildren end)
        local n = kids and (Try(function() return #kids end) or 0) or 0
        for i = 1, n do walk(Try(function() return kids[i] end), depth + 1) end
    end
    local av = AvatarOf(pawn)
    if av then for _, prop in ipairs(AVATAR_MESHES) do walk(Try(function() return av[prop] end), 0) end end
    walk(Try(function() return pawn.Mesh end), 0)
    return items
end
local function Transform()
    return { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
end
local function SetMesh(c, mesh)
    if pcall(function() c:SetSkeletalMeshAsset(mesh) end) then return "SetSkeletalMeshAsset" end
    if pcall(function() c:SetSkeletalMesh(mesh, true) end) then return "SetSkeletalMesh" end
    return "failed"
end
local function AddSkeletal(pawn, parent)
    local cls = StaticFindObject(SKC_PATH)
    local c = Try(function() return pawn:AddComponentByClass(cls, true, Transform(), false) end)
    if not Valid(c) then return nil end
    local ok = Try(function() return c:K2_AttachToComponent(parent, FName("None"), 2, 2, 2, false) end)
    if ok == false then Log("   attaching %s to %s failed", CompName(c), CompName(parent)) end
    return c
end
FindByName = function(pawn, name)
    if not name then return nil end
    local av = AvatarOf(pawn)
    local body = av and Try(function() return av.BodySkeletalMeshComponent end)
    local kids = Valid(body) and Try(function() return body.AttachChildren end)
    local n = kids and (Try(function() return #kids end) or 0) or 0
    for i = 1, n do
        local c = Try(function() return kids[i] end)
        if Valid(c) and CompName(c) == name then return c end
        local sub = Valid(c) and Try(function() return c.AttachChildren end)
        local m = sub and (Try(function() return #sub end) or 0) or 0
        for j = 1, m do local d = Try(function() return sub[j] end); if Valid(d) and CompName(d) == name then return d end end
    end
    return nil
end

-- where an item hangs on the kobold: the same socket if the kobold has it, else its hand for a hand socket
local KOBOLD_ITEM_SCALE = 0.75
-- the kobold (about 1 m) at the hidden gnome body's height (about 1.2 m): the dialogue camera and enemies aim there
KOBOLD_SCALE = 1.15
local function KoboldSocket(puppet, socket)
    local function has(s) return Try(function() return puppet:DoesSocketExist(FName(s)) end) == true end
    if socket ~= "None" and has(socket) then return socket end
    local l = socket:lower()
    local right = l:find("_r$") or l:find("_r_") or l:find("right")
    local left = l:find("_l$") or l:find("_l_") or l:find("left")
    local hand = l:find("hand") or l:find("weapon") or l:find("grip") or l:find("wield")
    if hand and right then for _, s in ipairs({ "hand_r", "Hand_R", "RightHand", "weapon_r" }) do if has(s) then return s end end end
    if hand and left then for _, s in ipairs({ "hand_l", "Hand_L", "LeftHand", "weapon_l", "shield_l" }) do if has(s) then return s end end end
    if l:find("shield") then for _, s in ipairs({ "EQU_BTL_Shield", "EQU_BTL_Weapon_L", "EQU_EXPL_Shield", "hand_l" }) do if has(s) then return s end end end
    return nil
end

-- one pass over a kobold hero: items onto the kobold (or hidden), every other mesh of the hero undrawn (not when
-- itemsOnly: the items are checked every tick, the game moves them between sockets as it draws and sheathes)
local function Settle(pawn, st, puppet, itemsOnly)
    local skip = { [st.puppet] = true }
    if st.armor then skip[st.armor] = true end
    for _, it in ipairs(HeroItems(pawn, skip)) do
        local a = it.root:GetAddress()
        local target = KoboldSocket(puppet, it.socket)
        if target then
            if not st.items[a] then
                local sc = Try(function() return it.root.RelativeScale3D end)
                st.items[a] = { socket = it.socket, parent = it.parent, scale = sc and { X = sc.X, Y = sc.Y, Z = sc.Z } or nil, owner = it.owner }
            end
            local ok = Try(function() return it.root:K2_AttachToComponent(puppet, FName(target), 2, 2, 0, false) end)
            local base = st.items[a].scale or { X = 1, Y = 1, Z = 1 }
            pcall(function() it.root:SetRelativeScale3D({ X = base.X * KOBOLD_ITEM_SCALE, Y = base.Y * KOBOLD_ITEM_SCALE, Z = base.Z * KOBOLD_ITEM_SCALE }) end)
            if not st.items[a].logged then
                st.items[a].logged = true
                Log("%s: %s moved from %s:%s to the kobold's %s (%s)", st.name, it.owner, it.parent, it.socket, target, tostring(ok))
            end
        else
            if not st.items[a] then st.items[a] = { hiddenOnly = true, socket = it.socket, owner = it.owner } end
            st.noplace = st.noplace or {}
            if not st.noplace[it.owner .. "@" .. it.socket] then
                st.noplace[it.owner .. "@" .. it.socket] = true
                Log("%s: %s on %s:%s has no place on the kobold: hidden", st.name, it.owner, it.parent, it.socket)
            end
        end
    end
    if itemsOnly then return end
    local av = AvatarOf(pawn)
    local roots = {}
    if av then for _, prop in ipairs(AVATAR_MESHES) do roots[#roots + 1] = Try(function() return av[prop] end) end end
    roots[#roots + 1] = Try(function() return pawn.Mesh end)
    for _, r in ipairs(roots) do
        for _, c in ipairs(MeshesUnder(r, skip)) do
            local a = c:GetAddress()
            if not st.saved[a] then
                st.saved[a] = HideMesh(c)
                if st.ready then Log("%s: new %s %s (%s) hidden", st.name, ClassOf(c), CompName(c), Name(MeshOf(c))) end
            elseif not StillHidden(c, st.saved[a]) then
                HideMesh(c)
            end
        end
    end
end

-- the kobold's own animations for what the hidden hero does
local KM = "/Game/Characters/Monsters/Kobold/Animations/"
-- plain sequences, not the kobold's montages: a montage holds at sections the game's ability moves on, and its
-- notifies send gameplay events and force moves to the character that owns the mesh (here the hero)
local KOBOLD_ANIMS = {
    dagger = "A_Kobold_Combat_Attack_Dagger", slash = "A_Kobold_Combat_Attack_Scimitar", throw = "A_Kobold_Combat_Attack_ManaPearl",
    spell = "A_Kobold_Combat_Attack_Spellcast", jump = "A_Kobold_Locomotion_Jump", jumpdown = "A_Kobold_Locomotion_Jump_Down",
    climbup = "A_Kobold_Locomotion_Climb_Up", fidget = "A_Kobold_Locomotion_Idle_Acting_01",
}
local function KoboldAnimFor(text)
    local s = (text or ""):lower()
    if s:find("death") or s:find("dying") or s:find("_die") or s:find("prone") or s:find("knock") then return nil end
    if (s:find("_hit") or s:find("hurt") or s:find("react")) and not s:find("attack") then return nil end
    if s:find("dodge") or s:find("defend") or s:find("block") or s:find("parry") then return nil end
    if s:find("jump_down") or s:find("jumpdown") or s:find("drop") then return "jumpdown" end
    if s:find("jump") or s:find("vault") or s:find("leap") then return "jump" end
    if s:find("climb_down") or s:find("climbdown") then return "climbdown" end
    if s:find("climb") then return "climbup" end
    if s:find("spell") or s:find("cast") or s:find("power") or s:find("pray") or s:find("metamagic") then return "spell" end
    if s:find("crossbow") or s:find("bow") or s:find("throw") or s:find("javelin") or s:find("dart") or s:find("sling") then return "throw" end
    if s:find("dagger") or s:find("rapier") or s:find("shortsword") or s:find("fist") or s:find("unarmed") or s:find("punch") then return "dagger" end
    if s:find("attack") or s:find("slash") or s:find("strike") or s:find("bash") or s:find("combat") then return "slash" end
    if s:find("interaction") or s:find("collect") or s:find("loot") or s:find("belt") or s:find("chest") or s:find("lockpick")
        or s:find("inspect") or s:find("disarm") or s:find("place") or s:find("slide") then return "fidget" end
    return nil
end
local function MontageSource(m)
    local tracks = Try(function() return m.SlotAnimTracks end)
    local t1 = tracks and Try(function() return tracks[1] end)
    local segs = t1 and Try(function() return t1.AnimTrack.AnimSegments end)
    local s1 = segs and Try(function() return segs[1] end)
    local ref = s1 and Try(function() return s1.AnimReference end)
    return Valid(ref) and Name(ref) or nil, t1 and Try(function() return t1.SlotName:ToString() end) or nil
end
local KOBOLD_SLOT = nil
-- the loop window of each kobold attack (its montage's LoopStart..LoopEnd), by the sequence the mirror plays
KOBOLD_LOOPS = {}
local MONTAGE_OF = { A_Kobold_Combat_Attack_Scimitar = "AM_Kobold_Combat_Attack_Scimitar", A_Kobold_Combat_Attack_Dagger = "AM_Kobold_Combat_Attack_Dagger",
    A_Kobold_Combat_Attack_ManaPearl = "AM_Kobold_Combat_Attack_ManaPear", A_Kobold_Combat_Attack_Spellcast = "AM_Kobold_Combat_Attack_Spellcast" }
function DumpKoboldMontage()
    for seq, mname in pairs(MONTAGE_OF) do pcall(DumpOneMontage, seq, mname) end
end
function DumpOneMontage(seq, name)
    local asset = Load(KM .. name .. "." .. name)
    if not asset then return end
    local loopStart, loopEnd = nil, nil
    local secs = Try(function() return asset.CompositeSections end)
    local parts = {}
    for i = 1, (secs and (Try(function() return #secs end) or 0) or 0) do
        local sc = Try(function() return secs[i] end)
        local sn = Try(function() return sc.SectionName:ToString() end) or "?"
        local t = tonumber(Try(function() return sc.LinkValue end))
        local nx = Try(function() return sc.NextSectionName:ToString() end) or "?"
        parts[#parts + 1] = string.format("%s@%s->%s", sn, tostring(t), nx)
        if sn == nx and t then loopStart = t end                   -- a section that repeats itself: the hold
        if loopStart and not loopEnd and t and t > loopStart and sn ~= nx then loopEnd = t end
    end
    if loopStart and loopEnd then KOBOLD_LOOPS[seq] = { loopStart, loopEnd } end
    Log("   %s sections: %s", name, table.concat(parts, ", "))
    local notifies = Try(function() return asset.Notifies end)
    local np = {}
    for i = 1, (notifies and (Try(function() return #notifies end) or 0) or 0) do
        local n = Try(function() return notifies[i] end)
        local obj = Try(function() return n.Notify end)
        local st = Try(function() return n.NotifyStateClass end)
        local cls = Valid(obj) and ClassOf(obj) or (Valid(st) and ClassOf(st) or "?")
        np[#np + 1] = string.format("%s@%s(%s)", cls, tostring(Try(function() return n.LinkValue end)), tostring(Try(function() return n.Duration end)))
    end
    Log("   %s notifies: %s", name, table.concat(np, ", "))
end
local function PlayOnPuppet(puppet, key, heroLen)
    local name = KOBOLD_ANIMS[key]
    if not name then return "no animation" end
    local asset = Load(KM .. name .. "." .. name)
    local ai = asset and Try(function() return puppet:GetAnimInstance() end)
    if not Valid(ai) then return "not loaded" end
    if name:sub(1, 3) == "AM_" then
        if not KOBOLD_SLOT then local _, slot = MontageSource(asset); KOBOLD_SLOT = slot; Log("kobold montage slot: %s", tostring(slot)) end
        local kLen = tonumber(Try(function() return asset:GetPlayLength() end))
        local rate = 1.0
        if kLen and heroLen and heroLen > 0.2 then rate = math.max(0.75, math.min(3.0, kLen / heroLen)) end
        local ok, len = pcall(function() return ai:Montage_Play(asset, rate, 0, 0.0, true) end)
        return ok and (string.format("%s (%.1f s at x%.2f", name, kLen or tonumber(len) or 0, rate) .. (heroLen and string.format(" to fit the hero's %.1f s)", heroLen) or ")"))
            or ("Montage_Play failed: " .. tostring(len)), ok and asset or nil
    end
    if not KOBOLD_SLOT then
        local probe = Load(KM .. KOBOLD_ANIMS.slash .. "." .. KOBOLD_ANIMS.slash)
        local _, slot = probe and MontageSource(probe)
        KOBOLD_SLOT = slot or "DefaultSlot"
        Log("kobold montage slot: %s", KOBOLD_SLOT)
    end
    local kLen = tonumber(Try(function() return asset:GetPlayLength() end))
    local rate = 1.0
    if kLen and heroLen and heroLen > 0.2 and not KOBOLD_LOOPS[name] then rate = math.max(0.85, math.min(1.6, kLen / heroLen)) end
    local ok, m = pcall(function() return ai:PlaySlotAnimationAsDynamicMontage(asset, FName(KOBOLD_SLOT), 0.1, 0.2, rate, 1, -1.0, 0.0) end)
    return ok and string.format("%s (%.1f s at x%.2f in slot %s)", name, kLen or 0, rate, KOBOLD_SLOT)
        or ("dynamic montage failed: " .. tostring(m)), (ok and Valid(m)) and m or nil, kLen and (kLen / rate) or nil
end

local function KoboldOn(pawn)
    local addr = pawn:GetAddress()
    if KOBOLD[addr] then
        local st = KOBOLD[addr]
        local puppet = FindByName(pawn, st.puppet)
        if Valid(puppet) then ResetKoboldAnim(st, puppet, "Ctrl+Shift+K") else Log("%s is a kobold already", Name(pawn)) end
        return
    end
    local av = AvatarOf(pawn)
    local body = av and Try(function() return av.BodySkeletalMeshComponent end)
    if not Valid(body) then Log("%s: no body component", Name(pawn)); return end
    local kBody, kArmor, kAbp = Load(PATHS.body), Load(PATHS.armor), Load(PATHS.abp)
    if not (kBody and kAbp) then Log("kobold assets missing: nothing changed"); return end
    -- the body's custom depth (the portrait camera cuts the character out with it; hover outlines use it too),
    -- its stencil value and lighting channels, read before the body is hidden: the kobold takes them over
    local look = {
        custom = Try(function() return body.bRenderCustomDepth end) == true,
        stencil = tonumber(Try(function() return body.CustomDepthStencilValue end)) or 0,
        c0 = Try(function() return body.LightingChannels.bChannel0 end),
        c1 = Try(function() return body.LightingChannels.bChannel1 end),
        c2 = Try(function() return body.LightingChannels.bChannel2 end),
    }
    local puppet = AddSkeletal(pawn, body)
    if not puppet then Log("adding the puppet failed: nothing changed"); return end
    local how = SetMesh(puppet, kBody)
    pcall(function() puppet:SetRelativeScale3D({ X = KOBOLD_SCALE, Y = KOBOLD_SCALE, Z = KOBOLD_SCALE }) end)
    local okAnim = pcall(function() puppet:SetAnimInstanceClass(kAbp) end)
    local armor = nil
    if kArmor then
        armor = AddSkeletal(pawn, puppet)
        if armor then
            SetMesh(armor, kArmor)
            if not pcall(function() armor:SetLeaderPoseComponent(puppet, true, false) end) then Log("   armour: SetLeaderPoseComponent failed") end
        end
    end
    for _, c in ipairs({ puppet, armor }) do
        if Valid(c) then
            pcall(function() c:SetRenderCustomDepth(look.custom) end)
            pcall(function() c:SetCustomDepthStencilValue(look.stencil) end)
            if look.c0 ~= nil then pcall(function() c:SetLightingChannels(look.c0 == true, look.c1 == true, look.c2 == true) end) end
        end
    end
    local st = { name = Name(pawn), pawn = pawn, saved = {}, items = {}, last = {}, puppet = CompName(puppet), armor = armor and CompName(armor) or nil, montage = nil, look = look,
        preview = (ClassOf(pawn):find("EditionAvatar", 1, true) ~= nil) or (ClassOf(pawn):find("PreviewAvatar", 1, true) ~= nil)
            or (ClassOf(pawn):find("InventoryAvatar", 1, true) ~= nil) }   -- the creation screen's model: no character state
    KOBOLD[addr] = st
    local socks = Try(function() return puppet:GetAllSocketNames() end)
    local names = {}
    for i = 1, (socks and (Try(function() return #socks end) or 0) or 0) do
        local e = Try(function() return socks[i] end)
        names[#names + 1] = Try(function() return e:ToString() end) or Try(function() return e:get():ToString() end) or "?"
    end
    for i = 1, #names, 40 do
        Log("kobold sockets %d-%d of %d: %s", i, math.min(i + 39, #names), #names, table.concat(names, ", ", i, math.min(i + 39, #names)))
    end
    Settle(pawn, st, puppet)
    local bl = Try(function() return body.RelativeLocation end)
    st.bodyLoc = { X = tonumber(Try(function() return bl.X end)) or 0, Y = tonumber(Try(function() return bl.Y end)) or 0, Z = tonumber(Try(function() return bl.Z end)) or 0 }
    if st.preview then pcall(SinkHidden, st, pawn, true, "a model") end
    st.ready = true
    st.bornAt = os.clock()
    st.resetAt = { os.clock() + 2, os.clock() + 5 }
    local ai = Try(function() return puppet:GetAnimInstance() end)
    local n = 0; for _ in pairs(st.saved) do n = n + 1 end
    Log("%s is a kobold: puppet %s (mesh %s via %s, anim %s -> %s), armour %s; %d of the hero's meshes hidden; custom depth %s stencil %s lighting %s/%s/%s",
        Name(pawn), CompName(puppet), Name(MeshOf(puppet)), how, tostring(okAnim), Valid(ai) and ClassOf(ai) or "none",
        armor and Name(MeshOf(armor)) or "none", n, tostring(look.custom), tostring(look.stencil), tostring(look.c0), tostring(look.c1), tostring(look.c2))
end

local function KoboldOff(pawn)
    local st = KOBOLD[pawn:GetAddress()]
    if not st then Log("%s is not a kobold", Name(pawn)); return end
    pcall(SinkHidden, st, pawn, false, "the kobold look is undone")
    local av = AvatarOf(pawn)
    local body = av and Try(function() return av.BodySkeletalMeshComponent end)
    local puppet = FindByName(pawn, st.puppet)
    -- items back on the hero's body, at their own sockets and scale
    if Valid(puppet) and Valid(body) then
        local kids = Try(function() return puppet.AttachChildren end)
        local list = {}
        for i = 1, (kids and (Try(function() return #kids end) or 0) or 0) do list[#list + 1] = Try(function() return kids[i] end) end
        for _, c in ipairs(list) do
            local it = Valid(c) and st.items[c:GetAddress()]
            if it and not it.hiddenOnly then
                pcall(function() c:K2_AttachToComponent(body, FName(it.socket), 2, 2, 0, false) end)
                if it.scale then pcall(function() c:SetRelativeScale3D(it.scale) end) end
            end
        end
    end
    -- the hero's meshes drawn again (hidden items included)
    local roots = {}
    if av then for _, prop in ipairs(AVATAR_MESHES) do roots[#roots + 1] = Try(function() return av[prop] end) end end
    roots[#roots + 1] = Try(function() return pawn.Mesh end)
    local skip = { [st.puppet] = true }
    if st.armor then skip[st.armor] = true end
    for _, r in ipairs(roots) do
        for _, c in ipairs(MeshesUnder(r, skip)) do
            local s = st.saved[c:GetAddress()]
            if s then RestoreMesh(c, s) end
        end
    end
    local armor = FindByName(pawn, st.armor)
    for _, c in ipairs({ armor, puppet }) do
        if Valid(c) and not pcall(function() c:K2_DestroyComponent(c) end) then pcall(function() c:SetVisibility(false, true) end) end
    end
    KOBOLD[pawn:GetAddress()] = nil
    Log("%s looks like itself again", Name(pawn))
end

-- the hidden hero's animation state, copied onto the kobold's animation (both derive from ABP_Characters_Template,
-- which the game drives on the hero only): the kobold's own death, unconscious, prone, defend, hit and combat stances
local STATE_VARS = { "bIsInCombat", "bForceIsInCombat", "bCombatTriggered", "bIsDead", "IsDeadCounter", "bIsUnconscious",
    "IsUnconsciousCounter", "bIsProne", "bIsDefending", "bBlocksAttack", "bIsAttackBlocked", "bIsHit", "bIsSneak",
    "bSneakTriggered", "bIsFalling", "bWasFalling", "bIsFlying", "bFlyTriggered", "bIsEthereal",
    "bHasUsedMainAttack", "bAttackLaunched" }
-- the hero's weapon stance (EAnimWieldedWeaponType) as one the kobold has: kobolds hold daggers, scimitars and bows,
-- never a shield or a two-handed weapon (a stance the kobold's animation lacks left it stuck after combat, 4 Oct)
local ATTACK_FLAGS = { bAttackLaunched = true, bHasUsedMainAttack = true, bCombatTriggered = true }
local ATTACK_KEYS = { dagger = true, slash = true, throw = true, spell = true }
local KOBOLD_STANCE = { [0] = 0, [1] = 1, [2] = 2, [3] = 1, [4] = 4, [5] = 4, [6] = 1, [7] = 1, [8] = 1, [9] = 1, [10] = 1, [11] = 1 }
local WATCHED = { bIsInCombat = true, WieldedWeaponType = true, bHasShield = true, bIsDead = true, bIsUnconscious = true, bIsProne = true, bIsDefending = true, bIsSneak = true }
function ResetKoboldAnim(st, puppet, why)
    local abp = Load(PATHS.abp)
    if not abp then return nil end
    pcall(function() puppet:SetAnimInstanceClass(nil) end)
    pcall(function() puppet:SetAnimInstanceClass(abp) end)
    Log("%s: the kobold's animation starts afresh (%s)", st.name, why)
    st.stuckSince = nil
    return Try(function() return puppet:GetAnimInstance() end)
end
local function AssetVar(ai, v)
    local a = Try(function() return ai[v] end)
    return Valid(a) and a or nil
end
local function CopyState(st, heroAI, kAI, puppet)
    if st.hasUnconscious == nil then
        st.hasUnconscious = AssetVar(kAI, "Uncouncious") ~= nil
        Log("%s: the kobold's animation %s unconscious animation%s", st.name, st.hasUnconscious and "has an" or "has no",
            st.hasUnconscious and "" or " (an unconscious hero is shown as a dead kobold)")
    end
    local down = Try(function() return heroAI.bIsUnconscious end) == true or Try(function() return heroAI.bIsDead end) == true
    if st.down and not down then                             -- back on its feet: start the kobold's animation afresh
        local abp = Load(PATHS.abp)
        if abp then
            pcall(function() puppet:SetAnimInstanceClass(nil) end)
            pcall(function() puppet:SetAnimInstanceClass(abp) end)
            Log("%s is back on its feet: the kobold's animation starts afresh", st.name)
            kAI = Try(function() return puppet:GetAnimInstance() end) or kAI
        end
    end
    st.down = down
    local inCombat = Try(function() return heroAI.bIsInCombat end) == true
    if st.combat and not inCombat and not down then
        local abp = Load(PATHS.abp)
        if abp then
            pcall(function() puppet:SetAnimInstanceClass(nil) end)
            pcall(function() puppet:SetAnimInstanceClass(abp) end)
            Log("%s's fight is over: the kobold's animation starts afresh", st.name)
            kAI = Try(function() return puppet:GetAnimInstance() end) or kAI
        end
    end
    st.combat = inCombat
    local inStory = Try(function() return heroAI.bIsInStory end) == true
    if st.story and not inStory then kAI = ResetKoboldAnim(st, puppet, "the story scene is over") or kAI end
    st.story = inStory
    -- an unconscious hero on a kobold without an unconscious animation: the kobold's death state is ours, not copied
    local sub = not st.hasUnconscious and Try(function() return heroAI.bIsUnconscious end) == true
    local SUBBED = { bIsDead = true, IsDeadCounter = true, bIsUnconscious = true, IsUnconsciousCounter = true }
    for _, v in ipairs(STATE_VARS) do
        local val = Try(function() return heroAI[v] end)
        if type(val) ~= "boolean" and type(val) ~= "number" then val = nil end   -- missing: UE4SS hands back a TrivialObject
        if st.attackUntil and os.clock() < st.attackUntil and ATTACK_FLAGS[v] then val = nil end
        if sub and SUBBED[v] then
            if WATCHED[v] and st.last[v] ~= true and v == "bIsUnconscious" then Log("%s: bIsUnconscious %s -> true", st.name, tostring(st.last[v])); st.last[v] = true end
            val = nil
        end
        if val ~= nil then
            if Try(function() return kAI[v] end) ~= val then pcall(function() kAI[v] = val end) end
            if WATCHED[v] and st.last[v] ~= val then
                if st.last[v] ~= nil then Log("%s: %s %s -> %s", st.name, v, tostring(st.last[v]), tostring(val)) end
                st.last[v] = val
            end
        end
    end
    local hd = Try(function() return heroAI.HitDirection end)
    if hd then pcall(function() kAI.HitDirection = { X = hd.X, Y = hd.Y, Z = hd.Z } end) end
    local wt = tonumber(Try(function() return heroAI.WieldedWeaponType end))
    if wt then
        local kt = KOBOLD_STANCE[wt] or 1
        if Try(function() return kAI.WieldedWeaponType end) ~= kt then pcall(function() kAI.WieldedWeaponType = kt end) end
        if st.last.weapon ~= wt then Log("%s: weapon stance %s -> the kobold's %s", st.name, tostring(wt), tostring(kt)); st.last.weapon = wt end
    end
    for _, v in ipairs({ "bHasShield", "bIsWieldingItemWithBothHands", "bHasVersatileWeapon" }) do
        if Try(function() return kAI[v] end) == true then pcall(function() kAI[v] = false end) end
    end
    if sub then
        pcall(function() kAI.bIsUnconscious = false end)
        if Try(function() return kAI.bIsDead end) ~= true then
            pcall(function() kAI.bIsDead = true end)
            pcall(function() kAI.IsDeadCounter = (Try(function() return kAI.IsDeadCounter end) or 0) + 1 end)
            Log("%s is unconscious: the kobold lies dead", st.name)
        end
    end
end

local function Mirror(st, pawn, puppet, heroAI, kAI)
    local m = Try(function() return heroAI:GetCurrentActiveMontage() end)
    local mname = Valid(m) and Name(m) or nil
    if mname ~= st.montage then
        st.montage = mname
        st.montageSrc = nil
        if mname then
            local src = MontageSource(m)
            st.montageSrc = src
            local key = KoboldAnimFor(mname .. " " .. (src or ""))
            local result, asset, dur = "nothing", nil, nil
            if not st.montageDumped then st.montageDumped = true; pcall(DumpKoboldMontage) end
            if key then result, asset, dur = PlayOnPuppet(puppet, key, tonumber(Try(function() return m:GetPlayLength() end))) end
            st.kMontage, st.kSeq, st.heroSection, st.struck, st.wasLooping = asset, key and KOBOLD_ANIMS[key] or nil, nil, false, false
            Log("%s plays %s%s -> kobold %s", st.name, mname, src and (" (" .. src .. ")") or "", result)
            if asset then st.check = { asset = asset, at = os.clock(), name = KOBOLD_ANIMS[key], marks = { 0.2, 0.6, 1.2, 2.0, 3.0 } } end
            if asset and ATTACK_KEYS[key] then
                st.attackUntil = os.clock() + math.max(0.5, math.min(3.0, dur or 1.5))
                for v in pairs(ATTACK_FLAGS) do pcall(function() kAI[v] = true end) end
            end
        end
    end
    -- the hero's montage section, and the kobold's attack held in its loop window while the hero loops
    if Valid(m) then
        local sec = Try(function() return heroAI:Montage_GetCurrentSection(m):ToString() end)
        if sec and sec ~= st.heroSection then
            Log("   hero %s section %s at %s", mname, sec, tostring(Try(function() return heroAI:Montage_GetPosition(m) end)))
            st.heroSection = sec
            if sec == "LoopEnd" and st.montageSrc and st.montageSrc:find("Growl", 1, true) then st.cryCastAt = os.clock() end
        end
        local win = st.kSeq and KOBOLD_LOOPS[st.kSeq]
        if win and Valid(st.kMontage) and sec then
            local l = sec:lower()
            local looping = l:find("loop") and not l:find("end")
            local striking = l:find("end") ~= nil
            local pos = tonumber(Try(function() return kAI:Montage_GetPosition(st.kMontage) end))
            if looping and pos and pos > win[2] then pcall(function() kAI:Montage_SetPosition(st.kMontage, win[1]) end) end
            if striking and not st.struck and pos and pos < win[2] then
                pcall(function() kAI:Montage_SetPosition(st.kMontage, win[2]) end)
                Log("   kobold strikes with the hero (%s): %.2f -> %.2f", sec, pos, win[2])
            end
            if striking then st.struck = true end
            st.wasLooping = looping
        end
    end
    local pawnTD = tonumber(Try(function() return pawn.CustomTimeDilation end))
    if pawnTD and pawnTD ~= st.timeDilation then
        if st.timeDilation then Log("   %s time dilation %s -> %s", st.name, tostring(st.timeDilation), tostring(pawnTD)) end
        -- the game freezes the attacker while it resolves the attack: the kobold waits in its hold pose
        local win = st.kSeq and KOBOLD_LOOPS[st.kSeq]
        if pawnTD == 0 and win and Valid(st.kMontage) and not st.struck then
            local pos = tonumber(Try(function() return kAI:Montage_GetPosition(st.kMontage) end))
            if pos and pos < win[1] then
                pcall(function() kAI:Montage_SetPosition(st.kMontage, win[1]) end)
                Log("   kobold holds while the game resolves the attack: %.2f -> %.2f", pos, win[1])
            end
        end
        st.timeDilation = pawnTD
    end
    if st.check and st.check.marks and #st.check.marks > 1 and os.clock() - st.check.at > st.check.marks[1] then
        Log("   kobold %s at %.1f s: position %s, rate %s, playing %s", st.check.name, os.clock() - st.check.at,
            tostring(Try(function() return kAI:Montage_GetPosition(st.check.asset) end)), tostring(Try(function() return kAI:Montage_GetPlayRate(st.check.asset) end)),
            tostring(Try(function() return kAI:Montage_IsPlaying(st.check.asset) end)))
        table.remove(st.check.marks, 1)
    elseif st.check and os.clock() - st.check.at > (st.check.marks and st.check.marks[1] or 0.4) then       -- is the kobold's animation really playing?
        local playing = Try(function() return kAI:Montage_IsPlaying(st.check.asset) end)
        local pos = Try(function() return kAI:Montage_GetPosition(st.check.asset) end)
        local active = Try(function() return kAI:GetCurrentActiveMontage() end)
        Log("   kobold %s after %.1f s: playing %s, position %s, active montage %s", st.check.name, os.clock() - st.check.at,
            tostring(playing), tostring(pos), Valid(active) and Name(active) or "none")
        local function slotInfo(ai)
            local parts = {}
            for _, fn in ipairs({ "GetSlotNodeGlobalWeight", "GetSlotMontageGlobalWeight", "GetSlotMontageLocalWeight", "IsSlotActive" }) do
                local ok, v = pcall(function() return ai[fn](ai, FName(KOBOLD_SLOT or "DefaultSlot")) end)
                parts[#parts + 1] = fn:gsub("^GetSlot", ""):gsub("GlobalWeight", "G"):gsub("LocalWeight", "L") .. "=" .. (ok and tostring(v) or "n/a")
            end
            for _, v in ipairs({ "bAttackLaunched", "bHasUsedMainAttack", "bCombatTriggered", "bIsInCombat" }) do
                parts[#parts + 1] = v .. "=" .. tostring(Try(function() return ai[v] end))
            end
            parts[#parts + 1] = "LayersBP=" .. Name(Try(function() return ai.LayersBP end))
            return table.concat(parts, " ")
        end
        Log("   kobold: %s", slotInfo(kAI))
        Log("   hero:   %s", slotInfo(heroAI))
        st.check = nil
    end
end

local TICK = 0
Every(100, function()
    if next(KOBOLD) == nil then return end
    TICK = TICK + 1
    if TICK % 10 == 1 then                                    -- once a second: find the kobold heroes' characters again
        local found = {}
        for _, cname in ipairs({ "BrimstoneCharacter", "CharacterEditionAvatar", "BrimstoneInventoryAvatar" }) do
            for _, pawn in ipairs(Try(function() return FindAllOf(cname) end) or {}) do
                local addr = Valid(pawn) and pawn:GetAddress()
                local st = addr and KOBOLD[addr]
                if st and Name(pawn) == st.name then st.pawn = pawn; found[addr] = true end
            end
        end
        for addr, st in pairs(KOBOLD) do
            if not found[addr] then KOBOLD[addr] = nil; Log("%s is gone (level change?): forgotten", st.name) end
        end
    end
    for addr, st in pairs(KOBOLD) do
        local pawn = st.pawn
        if pawn and Valid(pawn) and Name(pawn) == st.name then
            local puppet = FindByName(pawn, st.puppet)
            if Valid(puppet) then
                Settle(pawn, st, puppet, TICK % 5 ~= 0)
                local av = AvatarOf(pawn)
                local body = av and Try(function() return av.BodySkeletalMeshComponent end)
                local heroAI = Valid(body) and Try(function() return body:GetAnimInstance() end)
                local kAI = Try(function() return puppet:GetAnimInstance() end)
                if Valid(heroAI) and Valid(kAI) and not st.preview then
                    CopyState(st, heroAI, kAI, puppet)
                    kAI = Try(function() return puppet:GetAnimInstance() end) or kAI
                    Mirror(st, pawn, puppet, heroAI, kAI)
                    -- fresh starts shortly after the body appears (a load sets the hero up after it), and when the
                    -- kobold's animation has lost its character
                    if st.resetAt and st.resetAt[1] and os.clock() > st.resetAt[1] then
                        table.remove(st.resetAt, 1)
                        kAI = ResetKoboldAnim(st, puppet, "settling after the body appeared") or kAI
                    end
                    if not st.charLogged and os.clock() > (st.charLogAt or 0) then      -- once, for the log: does it know its character?
                        st.charLogAt = os.clock() + 6
                        if not st.resetAt or #st.resetAt == 0 then
                            st.charLogged = true
                            Log("%s: the kobold's animation's character is %s, ground speed %s", st.name, Name(Try(function() return kAI.Character end)),
                                tostring(Try(function() return kAI.GroundSpeed end)))
                        end
                    end
                    -- the hero moves but the kobold's animation sees no ground speed: start it afresh
                    local vel = Try(function() return pawn:GetVelocity() end)
                    local speed = vel and math.sqrt((tonumber(Try(function() return vel.X end)) or 0) ^ 2 + (tonumber(Try(function() return vel.Y end)) or 0) ^ 2) or 0
                    local gs = tonumber(Try(function() return kAI.GroundSpeed end))
                    if speed > 60 and (gs == nil or gs < 1) then
                        st.stuckSince = st.stuckSince or os.clock()
                        if os.clock() - st.stuckSince > 1.0 then
                            ResetKoboldAnim(st, puppet, string.format("moving at %.0f but the kobold's ground speed was %s", speed, tostring(gs)))
                        end
                    else
                        st.stuckSince = nil
                    end
                end
            end
        end
    end
end)

--------------------------------------------------------------------------------------------------
-- Ctrl+Shift+H: the anatomy of ancestries (every reflected field, down through feature sets, choices and powers)
-- and how the selected hero refers to its ancestry. Written to Kobold.log; read only.
--------------------------------------------------------------------------------------------------
local ANATOMY_LINES = 0
local function PropTypeOf(prop) return Try(function() return prop:GetClass():GetFName():ToString() end) or "?" end
local function PropNameOf(prop) return Try(function() return prop:GetFName():ToString() end) or "?" end
local SKIP_TYPES = { SoftObjectProperty = true, SoftClassProperty = true, MapProperty = true, SetProperty = true, DelegateProperty = true,
    MulticastDelegateProperty = true, MulticastInlineDelegateProperty = true, MulticastSparseDelegateProperty = true,
    WeakObjectProperty = true, LazyObjectProperty = true, InterfaceProperty = true, FieldPathProperty = true, OptionalProperty = true }
local DumpDeep            -- forward
local function TagsOf(container)
    local tags = Try(function() return container.GameplayTags end)
    local out = {}
    for i = 1, (tags and (Try(function() return #tags end) or 0) or 0) do
        local t = Try(function() return tags[i] end)
        out[#out + 1] = Try(function() return t.TagName:ToString() end) or "?"
    end
    return "{" .. table.concat(out, ", ") .. "}"
end
local function Simple(v, t)
    if v == nil then return "nil" end
    if t == "TextProperty" or t == "StrProperty" or t == "NameProperty" then
        local s = Str(v)
        if s and #s > 120 then s = s:sub(1, 117) .. "..." end
        return string.format("%q", s or "?")
    end
    return tostring(v)
end
local function StructText(sv, sprop, depth, seen, indent, maxDepth)
    local sname = Try(function() return ShortName(sprop:GetStruct():GetFullName()) end) or "?"
    if sname == "GameplayTag" then return Try(function() return sv.TagName:ToString() end) or "?" end
    if sname == "GameplayTagContainer" then return TagsOf(sv) end
    local parts = {}
    local st = Try(function() return sprop:GetStruct() end)
    pcall(function()
        st:ForEachProperty(function(fp)
            local fn, ft = PropNameOf(fp), PropTypeOf(fp)
            if SKIP_TYPES[ft] then parts[#parts + 1] = fn .. "=(" .. ft .. ")"; return end
            local fv = Try(function() return sv[fn] end)
            if ft == "ObjectProperty" or ft == "ClassProperty" then
                parts[#parts + 1] = fn .. "=" .. (Valid(fv) and (Name(fv) .. " [" .. ClassOf(fv) .. "]") or "nil")
                if ft == "ObjectProperty" and Valid(fv) and depth < maxDepth then
                    seen.later = seen.later or {}
                    seen.later[#seen.later + 1] = { fv, depth + 1, indent .. "      " }
                end
            elseif ft == "StructProperty" then
                parts[#parts + 1] = fn .. "=" .. StructText(fv, fp, depth, seen, indent, maxDepth)
            elseif ft == "ArrayProperty" then
                parts[#parts + 1] = fn .. "=array[" .. tostring(Try(function() return #fv end)) .. "]"
            else
                parts[#parts + 1] = fn .. "=" .. Simple(fv, ft)
            end
        end)
    end)
    return sname .. "{" .. table.concat(parts, " ") .. "}"
end
local function ValueText(obj, prop, depth, seen, indent, maxDepth)
    local name, t = PropNameOf(prop), PropTypeOf(prop)
    if SKIP_TYPES[t] then return name .. " (" .. t .. ", not read)" end
    local v = Try(function() return obj[name] end)
    if t == "ObjectProperty" or t == "ClassProperty" then
        if not Valid(v) then return name .. " = nil" end
        if t == "ObjectProperty" and depth < maxDepth then
            seen.later = seen.later or {}
            seen.later[#seen.later + 1] = { v, depth + 1, indent .. "      " }
        end
        return name .. " = " .. Name(v) .. " [" .. ClassOf(v) .. "]"
    end
    if t == "StructProperty" then return name .. " = " .. StructText(v, prop, depth, seen, indent, maxDepth) end
    if t == "ArrayProperty" then
        local inner = Try(function() return prop:GetInner() end)
        local it = inner and PropTypeOf(inner) or "?"
        local n = v and (Try(function() return #v end) or 0) or 0
        local parts = {}
        for i = 1, math.min(n, 40) do
            local e = Try(function() return v[i] end)
            if it == "ObjectProperty" or it == "ClassProperty" then
                parts[#parts + 1] = Valid(e) and (Name(e) .. " [" .. ClassOf(e) .. "]") or "nil"
                if it == "ObjectProperty" and Valid(e) and depth < maxDepth then
                    seen.later = seen.later or {}
                    seen.later[#seen.later + 1] = { e, depth + 1, indent .. "      " }
                end
            elseif it == "StructProperty" then
                parts[#parts + 1] = StructText(e, inner, depth, seen, indent, maxDepth)
            else
                parts[#parts + 1] = Simple(e, it)
            end
        end
        return string.format("%s = [%d] %s", name, n, table.concat(parts, " | "))
    end
    return name .. " = " .. Simple(v, t)
end
DumpDeep = function(obj, depth, seen, indent, maxDepth)
    if not Valid(obj) or ANATOMY_LINES > 4000 then return end
    local a = obj:GetAddress()
    if seen[a] then Log("%s%s (above)", indent, Name(obj)); return end
    seen[a] = true
    Log("%s%s [%s]", indent, Name(obj), ClassOf(obj))
    ANATOMY_LINES = ANATOMY_LINES + 1
    local cls = Try(function() return obj:GetClass() end)
    local hops = 0
    local mine = {}
    while Valid(cls) and hops < 12 do
        local cname = ShortName(cls:GetFullName())
        if cname == "PrimaryDataAsset" or cname == "DataAsset" or cname == "Object" or cname == "ActorComponent" or cname == "Actor" then break end
        pcall(function()
            cls:ForEachProperty(function(prop)
                local line = ValueText(obj, prop, depth, mine, indent, maxDepth)
                Log("%s   %s", indent, line)
                ANATOMY_LINES = ANATOMY_LINES + 1
            end)
        end)
        cls = Try(function() return cls:GetSuperStruct() end)
        hops = hops + 1
    end
    for _, item in ipairs(mine.later or {}) do DumpDeep(item[1], item[2], seen, item[3], maxDepth) end
end

function Anatomy()
    ANATOMY_LINES = 0
    Log("================ Kobold anatomy")
    local seen = {}
    for _, path in ipairs({ "/Ruleset_2024/Database/Ancestries/Dragonborn/DA_AN_Dragonborn.DA_AN_Dragonborn",
        "/Ruleset_2024/Database/Ancestries/Tiefling/DA_AN_Tiefling.DA_AN_Tiefling",
        "/Ruleset_2024/Database/Ancestries/Elf/DA_SC_HighElf.DA_SC_HighElf" }) do
        local d = Load(path)
        if d then DumpDeep(d, 0, seen, "", 4) end
    end
    -- how a power's ability finds its power: the ability classes' defaults
    for _, path in ipairs({ "/Ruleset_2024/Database/Ancestries/Dragonborn/GA_PowerDraconicAncestrySilverBreath.GA_PowerDraconicAncestrySilverBreath_C",
        "/Ruleset_2024/Database/Ancestries/Dragonborn/GA_RechargeDragonbornBreath.GA_RechargeDragonbornBreath_C" }) do
        local cls = Load(path)
        local cdo = cls and Try(function() return cls:GetCDO() end)
        if Valid(cdo) then DumpDeep(cdo, 0, seen, "", 2) end
    end
    -- how the selected hero holds its ancestry: its ruleset actor's fields that name an ancestry or a definition
    local pawn = CurrentPawn()
    if pawn then
        local name = Name(pawn):gsub("^Character_", "")
        for _, pcmp in ipairs(Try(function() return FindAllOf("PartyComponent") end) or {}) do
            local party = Try(function() return pcmp.Party end)
            for i = 1, (party and (Try(function() return #party end) or 0) or 0) do
                local m = Try(function() return party[i] end)
                if Valid(m) and Name(m) == name then
                    Log("== %s [%s]: every field", Name(m), ClassOf(m))
                    local cls = Try(function() return m:GetClass() end)
                    local hops = 0
                    while Valid(cls) and hops < 12 do
                        pcall(function()
                            cls:ForEachProperty(function(prop)
                                local pn = PropNameOf(prop)
                                Log("   %s", ValueText(m, prop, 9, {}, "", 0))
                            end)
                        end)
                        cls = Try(function() return cls:GetSuperStruct() end)
                        hops = hops + 1
                    end
                    local bd = Try(function() return m:GetBaseDefinition() end)
                    Log("   GetBaseDefinition() = %s [%s]", Name(bd), ClassOf(bd))
                    local comps = {}
                    for _, cname in ipairs({ "CharacterBuildingComponent", "BP_CharacterBuildingComponent_C" }) do
                        local c = Try(function() return m:GetComponentByClass(StaticFindObject("/Script/Brimstone." .. cname)) end)
                        if Valid(c) then comps[#comps + 1] = c end
                    end
                    for _, c in ipairs(comps) do DumpDeep(c, 0, {}, "   ", 1) end
                end
            end
        end
    end
    -- can a script copy a data object, and grow an array? (a throwaway copy of the human's skill choice)
    local skill = Load("/Ruleset_2024/Database/Ancestries/Human/DA_PCH_HumanSkillful.DA_PCH_HumanSkillful")
    if skill then
        local okC, clone = pcall(function()
            return StaticConstructObject(skill:GetClass(), skill:GetOuter(), FName("DA_PCH_KoboldCloneTest"), 0, 0, false, false, skill)
        end)
        Log("clone test: StaticConstructObject %s -> %s [%s]", okC and "ok" or ("failed: " .. tostring(clone)), okC and Name(clone) or "-", okC and ClassOf(clone) or "-")
        if okC and Valid(clone) then
            local okT = pcall(function() clone.Title = FText("Kobold clone test") end)
            Log("clone test: clone title %q (write %s), original title %q, clone tags %d, clone allow any %s", Str(Try(function() return clone.Title end)) or "?",
                tostring(okT), Str(Try(function() return skill.Title end)) or "?", Try(function() return #clone.ChoiceTags end) or -1, tostring(Try(function() return clone.bAllowAny end)))
            local tags = Try(function() return clone.ChoiceTags end)
            local before = tags and (Try(function() return #tags end) or -1) or -1
            local okA, errA = pcall(function() tags[before + 1] = { TagName = FName("Ruleset.Skill.Arcana.Proficiency") } end)
            local after = Try(function() return #clone.ChoiceTags end) or -1
            local last = Try(function() return clone.ChoiceTags[after].TagName:ToString() end) or "?"
            Log("array append test: %d -> %d (%s), last %s; original still %d", before, after, okA and "ok" or ("failed: " .. tostring(errA)), last,
                Try(function() return #skill.ChoiceTags end) or -1)
        end
    end
    Log("================ anatomy done (%d lines)", ANATOMY_LINES)
end

--------------------------------------------------------------------------------------------------
-- Draconic Cry: the Kobold ancestry grants the (unused) Dragonborn breath's ability and its recharge, and that
-- ability now runs a copy of the breath power made into the cry: a bonus action, enemies within 10 ft, Faerie Fire's
-- highlighted condition (attacks against them have advantage) until the start of the kobold's next turn, no save,
-- proficiency-bonus uses recharged by long rests. Built once, at start, before heroes are granted their abilities.
-- Also a probe of the asset manager's DefinitionsMap (find an existing entry; add a throwaway one and fetch it back).
--------------------------------------------------------------------------------------------------
local CRY_DONE = false
KOBOLD_REGISTERED = KOBOLD_REGISTERED or {}
local function CloneObj(template, name, outer)
    local ok, obj = pcall(function()
        return StaticConstructObject(template:GetClass(), outer or template:GetOuter(), FName(name), 0, 0, false, false, template)
    end)
    if ok and Valid(obj) then return obj end
    Log("   clone %s failed: %s", name, tostring(obj))
    return nil
end
local function SetTagName(structv, tag)
    return pcall(function() structv.TagName = FName(tag) end)
end
local CRY_TEXT = "As a bonus action, you let out a draconic cry at the enemies within 10 feet of you. Until the start of your next turn, you and your allies have advantage on attack rolls against them. You can use it a number of times equal to your proficiency bonus, and regain all uses after a long rest."
function BuildDraconicCry(gnome)
    if CRY_DONE then return end
    CRY_DONE = true
    local DB = "/Ruleset_2024/Database/Ancestries/"
    local breath = Load(DB .. "Dragonborn/DA_POW_DraconicAncestrySilverBreath.DA_POW_DraconicAncestrySilverBreath")
    local stone = Load(DB .. "Dwarf/DA_POW_StoneCunning.DA_POW_StoneCunning")
    local gaCls = Load(DB .. "Dragonborn/GA_PowerDraconicAncestrySilverBreath.GA_PowerDraconicAncestrySilverBreath_C")
    local rcCls = Load(DB .. "Dragonborn/GA_RechargeDragonbornBreath.GA_RechargeDragonbornBreath_C")
    local stoneGA = Load(DB .. "Dwarf/GA_PowerStoneCunning.GA_PowerStoneCunning_C")
    local faerie = Load("/Ruleset_2024/Database/Spells/Level1/DA_SPL_FaerieFire.DA_SPL_FaerieFire")
    local growl = Load("/Game/Database/Animations/Power/DA_AM_Power_Growl.DA_AM_Power_Growl")
    if not (breath and stone and gaCls and rcCls and stoneGA and faerie) then Log("Draconic Cry: a piece is missing, not built"); return end
    -- the cry takes over the Silver Dragonborn's breath (its ability, the breaths' recharge, its table entry): only
    -- while no hero can be a Dragonborn
    local dragonborn = Load(DB .. "Dragonborn/DA_AN_Dragonborn.DA_AN_Dragonborn")
    if not dragonborn or Try(function() return dragonborn.bEnumerableForUser end) ~= false then
        Log("Draconic Cry: not built - %s (it would take over the Silver Dragonborn's breath)",
            dragonborn and "the game offers the Dragonborn in character creation" or "the Dragonborn ancestry was not found")
        return
    end
    local steps = {}
    local function step(label, fn) local ok, err = pcall(fn); steps[#steps + 1] = label .. (ok and "" or (" FAILED " .. tostring(err))) end
    local cry = CloneObj(breath, "DA_POW_KoboldDraconicCry")
    if not cry then return end
    step("texts", function() cry.Title = FText("Draconic Cry"); cry.Description = FText(CRY_TEXT); cry.ShortDescription = FText(CRY_TEXT) end)
    step("bonus action", function() assert(SetTagName(cry.ActivationTimeTag, "Ruleset.ActivationTime.Bonus")) end)
    step("10 ft sphere", function()
        assert(SetTagName(cry.TargetTypeTag, "Ruleset.TargetType.Aoe.Sphere"))
        cry.TargetType = 7
        cry.TargetParameter1Scalable.Value = 10.0
    end)
    step("one round", function()
        assert(SetTagName(cry.DurationTypeTag, "Ruleset.DurationType.Round"))
        cry.DurationType = 1
        cry.DurationParameterScalable.Value = 1.0
    end)
    step("no save", function() cry.bHasSavingThrow = false end)
    step("enemies only", function()
        local tg = cry.TeamFilteringTags.GameplayTags
        tg[#tg + 1] = { TagName = FName("Ruleset.Team.Hostile") }
    end)
    step("highlighted condition", function()
        local form = CloneObj(stone.EffectForms[1], "ConditionForm_KoboldDraconicCry", cry)
        assert(form, "no form")
        form.ConditionGE = faerie.EffectForms[1].ConditionGE
        cry.EffectForms[1] = form
    end)
    if growl then step("growl animation", function() cry.AnimMappingDefinition = growl end) end
    step("no breath effects", function()
        for _, c in ipairs({ "PrepareCue", "StartCue", "ActivationCue", "ProjectileCue", "ZoneImpactCue", "TargetImpactCue", "MissedImpactCue" }) do
            SetTagName(cry[c].GameplayCueTag, "None")
        end
    end)
    -- the breath's ability runs the cry, costs a bonus action, is a bonus action
    local gaCDO = Try(function() return gaCls:GetCDO() end)
    local stoneCDO = Try(function() return stoneGA:GetCDO() end)
    step("ability runs the cry", function() gaCDO.SpecificEffectDefinition = cry end)
    step("bonus action cost", function() gaCDO.CostGameplayEffectClass = stoneCDO.CostGameplayEffectClass end)
    step("bonus action tag", function()
        local at = gaCDO.AbilityTags.GameplayTags
        for i = 1, #at do
            if at[i].TagName:ToString() == "Ruleset.ActionType.Main" then at[i].TagName = FName("Ruleset.ActionType.Bonus") end
        end
    end)
    -- recharged by long rests only (the breath also took short rests)
    local rcCDO = Try(function() return rcCls:GetCDO() end)
    step("long rests only", function()
        local tr = rcCDO.AbilityTriggers
        for i = 1, #tr do
            if tr[i].TriggerTag.TagName:ToString() == "AbilityEvent.ShortRest.Executed" then tr[i].TriggerTag.TagName = FName("AbilityEvent.LongRest.Executed") end
        end
    end)
    -- the Kobold ancestry grants both
    step("granted", function()
        local ga = gnome.Features.GrantedGameplayAbilities
        for _, cls in ipairs({ gaCls, rcCls }) do
            local n = #ga + 1
            ga[n] = { Ability = cls, AbilityLevel = 1 }
            if not Valid(Try(function() return ga[n].Ability end)) then pcall(function() ga[n].Ability = cls end) end
            assert(Valid(Try(function() return ga[n].Ability end)), "an ability entry did not keep its ability")
        end
    end)
    -- the action bar finds a power by its tag: the cry takes the breath's entry in the definitions table (only the
    -- unplayed dragonborn used it), so it shows as Draconic Cry there too
    step("listed by tag", function()
        local am = FindFirstOf("BrimstoneAssetManager")
        local tag = cry.AssetTag.TagName:ToString()
        am.DefinitionsMap:Add({ TagName = FName(tag) }, cry)
        KOBOLD_REGISTERED[#KOBOLD_REGISTERED + 1] = { tag, cry }
        local lib = StaticFindObject("/Script/Brimstone.Default__BrimstoneBlueprintLibrary")
        assert(Name(lib:FetchDefinitionFromTag({ TagName = FName(tag) })) == Name(cry), "the table still lists the breath")
    end)
    local granted = {}
    local arr = Try(function() return gnome.Features.GrantedGameplayAbilities end)
    for i = 1, (arr and (Try(function() return #arr end) or 0) or 0) do granted[#granted + 1] = Name(Try(function() return arr[i].Ability end)) end
    Log("Draconic Cry: %s", table.concat(steps, ", "))
    Log("   cry: %q, activation %s, target %s r%s, duration %s x%s, save %s, team %s, condition %s; ability runs %s; kobold grants %s",
        Str(Try(function() return cry.Title end)) or "?", Try(function() return cry.ActivationTimeTag.TagName:ToString() end) or "?",
        Try(function() return cry.TargetTypeTag.TagName:ToString() end) or "?", tostring(Try(function() return cry.TargetParameter1Scalable.Value end)),
        Try(function() return cry.DurationTypeTag.TagName:ToString() end) or "?", tostring(Try(function() return cry.DurationParameterScalable.Value end)),
        tostring(Try(function() return cry.bHasSavingThrow end)), TagsOf(Try(function() return cry.TeamFilteringTags end)),
        Name(Try(function() return cry.EffectForms[1].ConditionGE end)), Name(Try(function() return gaCDO.SpecificEffectDefinition end)), table.concat(granted, " "))
end

-- the definitions table: can a script find in it, and add to it?
local MAP_PROBED = false
function ProbeDefinitionsMap()
    if MAP_PROBED then return end
    MAP_PROBED = true
    local am = Try(function() return FindFirstOf("BrimstoneAssetManager") end)
    if not Valid(am) then Log("definitions table: no asset manager found"); return end
    local map = Try(function() return am.DefinitionsMap end)
    local lib = StaticFindObject("/Script/Brimstone.Default__BrimstoneBlueprintLibrary")
    local okF, found = pcall(function() return map:Find({ TagName = FName("Ruleset.Ancestry.Gnome") }) end)
    local foundObj = okF and (Try(function() return found:get() end) or found) or nil
    local okL, viaLib = pcall(function() return lib:FetchDefinitionFromTag({ TagName = FName("Ruleset.Ancestry.Gnome") }) end)
    Log("definitions table: Find(Gnome) %s -> %s; FetchDefinitionFromTag(Gnome) %s -> %s", okF and "ok" or ("failed: " .. tostring(found)), Name(foundObj),
        okL and "ok" or ("failed: " .. tostring(viaLib)), Name(viaLib))
    if not (okF and Valid(foundObj)) then return end
    local skill = Load("/Ruleset_2024/Database/Ancestries/Human/DA_PCH_HumanSkillful.DA_PCH_HumanSkillful")
    local probe = skill and CloneObj(skill, "DA_PCH_KoboldMapProbe")
    if not probe then return end
    local tag = "Ruleset.Feature.Ancestry.Kobold.MapProbe"
    local okA, errA = pcall(function() map:Add({ TagName = FName(tag) }, probe) end)
    local okB, back = pcall(function() return lib:FetchDefinitionFromTag({ TagName = FName(tag) }) end)
    Log("definitions table: Add %s; fetched back %s -> %s", okA and "ok" or ("failed: " .. tostring(errA)), okB and "ok" or ("failed: " .. tostring(back)), Name(back))
end

--------------------------------------------------------------------------------------------------
-- Kobold Legacy: a choice of one of three, built from copies of the elf's lineage choice, its high elf option, the
-- keen senses skill choice and the high elf cantrip choice, registered in the asset manager's definitions table
-- under kobold tags (the choice finds its options by tag), and added to the Kobold ancestry's choices.
--   Craftiness        proficiency in Arcana, Investigation, Medicine, Sleight of Hand or Survival
--   Defiance          advantage on saves to avoid or end Frightened (the halfling's Brave effect)
--   Draconic Sorcery  one cantrip of the Sorcerer list (cast the way the high elf casts its cantrip)
--------------------------------------------------------------------------------------------------
local LEGACY_DONE = false
KOBOLD_REGISTERED = KOBOLD_REGISTERED or {}       -- { tag, object } entries this mod put in the definitions table
-- the entries must stay (saved kobold heroes look their choices up by tag): re-added if the table lost them
function KeepKoboldDefinitions()
    if #KOBOLD_REGISTERED == 0 then return end
    local am = Try(function() return FindFirstOf("BrimstoneAssetManager") end)
    local map = Valid(am) and Try(function() return am.DefinitionsMap end)
    if not map then return end
    local readded = {}
    for _, e in ipairs(KOBOLD_REGISTERED) do
        local f = Try(function() return map:Find({ TagName = FName(e[1]) }) end)
        local obj = f and (Try(function() return f:get() end) or f)
        if not Valid(obj) and Valid(e[2]) then
            pcall(function() map:Add({ TagName = FName(e[1]) }, e[2]) end)
            readded[#readded + 1] = e[1]
        end
    end
    if #readded > 0 then Log("kobold definitions re-added to the table: %s", table.concat(readded, ", ")) end
end
local TAG_LEGACY = "Ruleset.Choice.Ancestry.Kobold.KoboldLegacy"
local TAG_CRAFT = "Ruleset.Feature.Ancestry.Kobold.KoboldLegacy.Craftiness"
local TAG_DEFIANCE = "Ruleset.Feature.Ancestry.Kobold.KoboldLegacy.Defiance"
local TAG_SORCERY = "Ruleset.Feature.Ancestry.Kobold.KoboldLegacy.DraconicSorcery"
local LEGACY_TEXT = {
    choice = "Your draconic blood shows itself in one of three ways.\n- Craftiness: proficiency in one of Arcana, Investigation, Medicine, Sleight of Hand or Survival.\n- Defiance: advantage on saving throws to avoid or end the Frightened condition.\n- Draconic Sorcery: one cantrip of your choice from the Sorcerer spell list.",
    craft = "You have proficiency in one of these skills of your choice: Arcana, Investigation, Medicine, Sleight of Hand or Survival.",
    defiance = "You have advantage on saving throws you make to avoid or end the Frightened condition.",
    sorcery = "You know one cantrip of your choice from the Sorcerer spell list.",
}
function BuildKoboldLegacy(gnome)
    if LEGACY_DONE then return end
    LEGACY_DONE = true
    local DB = "/Ruleset_2024/Database/Ancestries/"
    local lineage = Load(DB .. "Elf/DA_CH_ElvenLineage.DA_CH_ElvenLineage")
    local highElf = Load(DB .. "Elf/DA_FC_LineageHighElf.DA_FC_LineageHighElf")
    local keen = Load(DB .. "Elf/DA_PCH_ElfKeenSenses.DA_PCH_ElfKeenSenses")
    local cantrip = Load(DB .. "Elf/DA_SCH_HighElfCantrip.DA_SCH_HighElfCantrip")
    local braveCls = Load(DB .. "Halfling/GE_HalflingBrave.GE_HalflingBrave_C")
    local castCls = Load(DB .. "Elf/GE_HighElfCasting.GE_HighElfCasting_C")
    local fsCls = StaticFindObject("/Script/Brimstone.RulesetFeatureSet")
    local am = Try(function() return FindFirstOf("BrimstoneAssetManager") end)
    local map = Valid(am) and Try(function() return am.DefinitionsMap end)
    if not (lineage and highElf and keen and cantrip and braveCls and castCls and Valid(fsCls) and map) then
        Log("Kobold Legacy: a piece is missing, not built"); return
    end
    local steps = {}
    local function step(label, fn) local ok, err = pcall(fn); steps[#steps + 1] = label .. (ok and "" or (" FAILED " .. tostring(err))); return ok end
    local function register(obj, tag) map:Add({ TagName = FName(tag) }, obj); KOBOLD_REGISTERED[#KOBOLD_REGISTERED + 1] = { tag, obj } end
    local function newFS(outer, name)
        local ok, fs = pcall(function() return StaticConstructObject(fsCls, outer, FName(name)) end)
        assert(ok and Valid(fs), "no feature set: " .. tostring(fs))
        return fs
    end
    local function container(name, tag, title, desc, keepInnate)
        local c = CloneObj(highElf, name)
        assert(c, "no container")
        c.Title = FText(title); c.Description = FText(desc)
        assert(SetTagName(c.AssetTag, tag))
        local fs = newFS(c, name .. "_Features")
        c.Features = fs
        if not keepInnate then c.FeatureSets[1] = newFS(c, name .. "_NoSpells") end
        register(c, tag)
        return c, fs
    end
    -- an entry must carry its choice: the game dereferences it unchecked (a null one crashed it on the main menu)
    local function addChoice(fs, choice)
        assert(Valid(choice), "no choice to add")
        local fc = fs.FeatureChoices
        local n = #fc + 1
        fc[n] = { FeatureChoice = choice, bChoiceGrantedWhenContainerIsAcquired = false, ChoiceLevel = 1 }
        if not Valid(Try(function() return fc[n].FeatureChoice end)) then
            pcall(function() fc[n].FeatureChoice = choice end)
            pcall(function() fc[n].ChoiceLevel = 1 end)
        end
        local back = Try(function() return fc[n].FeatureChoice end)
        assert(Valid(back) and back:GetAddress() == choice:GetAddress(), "the entry did not keep its choice (" .. Name(back) .. ")")
    end
    local function contents(fs)
        local parts = {}
        local fc = Try(function() return fs.FeatureChoices end)
        for i = 1, (fc and (Try(function() return #fc end) or 0) or 0) do parts[#parts + 1] = "choice " .. Name(Try(function() return fc[i].FeatureChoice end)) end
        local ge = Try(function() return fs.GrantedGameplayEffects end)
        for i = 1, (ge and (Try(function() return #ge end) or 0) or 0) do parts[#parts + 1] = "effect " .. Name(Try(function() return ge[i].GameplayEffect end)) end
        return #parts > 0 and table.concat(parts, ", ") or "empty"
    end
    local whole = { craft = false, defiance = false, sorcery = false }
    local made = {}
    -- Craftiness
    step("craftiness", function()
        local skills = CloneObj(keen, "DA_PCH_KoboldCraftiness")
        assert(skills, "no skill choice")
        skills.Title = FText("Craftiness"); skills.Description = FText(LEGACY_TEXT.craft)
        assert(SetTagName(skills.AssetTag, "Ruleset.Choice.Ancestry.Kobold.Craftiness"))
        local ct = skills.ChoiceTags
        ct[1].TagName = FName("Ruleset.Skill.Arcana.Proficiency")
        ct[2].TagName = FName("Ruleset.Skill.Investigation.Proficiency")
        ct[3].TagName = FName("Ruleset.Skill.Medicine.Proficiency")
        ct[4] = { TagName = FName("Ruleset.Skill.SleightOfHand.Proficiency") }
        ct[5] = { TagName = FName("Ruleset.Skill.Survival.Proficiency") }
        register(skills, "Ruleset.Choice.Ancestry.Kobold.Craftiness")
        local _, fs = container("DA_FC_KoboldCraftiness", TAG_CRAFT, "Craftiness", LEGACY_TEXT.craft, false)
        addChoice(fs, skills)
        whole.craft, made.craft = true, contents(fs)
    end)
    -- Defiance
    step("defiance", function()
        local _, fs = container("DA_FC_KoboldDefiance", TAG_DEFIANCE, "Defiance", LEGACY_TEXT.defiance, false)
        local ge = fs.GrantedGameplayEffects
        local n = #ge + 1
        ge[n] = { GameplayEffect = braveCls, EffectLevel = 1.0 }
        if not Valid(Try(function() return ge[n].GameplayEffect end)) then pcall(function() ge[n].GameplayEffect = braveCls end) end
        assert(Valid(Try(function() return ge[n].GameplayEffect end)), "the effect entry did not keep its effect")
        whole.defiance, made.defiance = true, contents(fs)
    end)
    -- Draconic Sorcery
    step("draconic sorcery", function()
        local spell = CloneObj(cantrip, "DA_SCH_KoboldDraconicSorcery")
        assert(spell, "no cantrip choice")
        spell.Title = FText("Draconic Sorcery"); spell.Description = FText(LEGACY_TEXT.sorcery)
        assert(SetTagName(spell.SpellListTag, "Ruleset.SpellList.Sorcerer"))
        spell.bExplicitSpellList = false
        assert(SetTagName(spell.AssetTag, "Ruleset.Choice.Ancestry.Kobold.DraconicSorcery.Cantrip"))
        register(spell, "Ruleset.Choice.Ancestry.Kobold.DraconicSorcery.Cantrip")
        local _, fs = container("DA_FC_KoboldDraconicSorcery", TAG_SORCERY, "Draconic Sorcery", LEGACY_TEXT.sorcery, true)
        local ge = fs.GrantedGameplayEffects
        local n = #ge + 1
        ge[n] = { GameplayEffect = castCls, EffectLevel = 1.0 }
        if not Valid(Try(function() return ge[n].GameplayEffect end)) then pcall(function() ge[n].GameplayEffect = castCls end) end
        assert(Valid(Try(function() return ge[n].GameplayEffect end)), "the effect entry did not keep its effect")
        addChoice(fs, spell)
        whole.sorcery, made.sorcery = true, contents(fs)
    end)
    -- the choice of one of the three, on the Kobold ancestry
    step("the choice", function()
        assert(whole.craft and whole.defiance and whole.sorcery, "an option is not whole: the Legacy stays off the ancestry")
        local choice = CloneObj(lineage, "DA_CH_KoboldLegacy")
        assert(choice, "no choice")
        choice.Title = FText("Kobold Legacy"); choice.Description = FText(LEGACY_TEXT.choice)
        assert(SetTagName(choice.AssetTag, TAG_LEGACY))
        local tags = choice.ChoiceTags
        tags[1].TagName = FName(TAG_CRAFT)
        tags[2].TagName = FName(TAG_DEFIANCE)
        tags[3] = { TagName = FName(TAG_SORCERY) }
        register(choice, TAG_LEGACY)
        addChoice(gnome.Features, choice)
    end)
    -- read back
    local lib = StaticFindObject("/Script/Brimstone.Default__BrimstoneBlueprintLibrary")
    local back = {}
    for _, t in ipairs({ TAG_LEGACY, TAG_CRAFT, TAG_DEFIANCE, TAG_SORCERY }) do
        back[#back + 1] = Name(Try(function() return lib:FetchDefinitionFromTag({ TagName = FName(t) }) end))
    end
    local choices = {}
    local fc = Try(function() return gnome.Features.FeatureChoices end)
    for i = 1, (fc and (Try(function() return #fc end) or 0) or 0) do choices[#choices + 1] = Name(Try(function() return fc[i].FeatureChoice end)) end
    Log("Kobold Legacy: %s", table.concat(steps, ", "))
    Log("   options: Craftiness [%s]; Defiance [%s]; Draconic Sorcery [%s]", made.craft or "-", made.defiance or "-", made.sorcery or "-")
    Log("   fetched by tag: %s; kobold choices: %s", table.concat(back, " "), table.concat(choices, " "))
end

--------------------------------------------------------------------------------------------------
-- The Kobold race (first step): the game's unused Gnome ancestry renamed Kobold, offered in character creation,
-- walking 30 ft. Gnome is already Small with darkvision. Applied a few seconds after start and checked every ten
-- seconds (the asset can be reloaded). Read back after writing, so the log says what really changed.
--------------------------------------------------------------------------------------------------
local KOBOLD_TITLE = "Kobold"
local KOBOLD_SHORT = "Small, scaly and quick-witted, kobolds trace their blood to dragons and stand by their own."
local KOBOLD_DESC = "Kobolds are small reptilian folk who claim the blood of dragons; quick, clever and stubbornly loyal to their kin. Kobold traits (mod): Small; speed 30 ft; darkvision; Draconic Cry (a bonus action, proficiency bonus times per long rest: you and your allies have advantage on attacks against the enemies within 10 ft until the start of your next turn); Kobold Legacy (Craftiness, Defiance or Draconic Sorcery)."   -- one paragraph: the ancestry panel wraps it in a <NarrativeLine> tag, and rich text tags do not span lines
local RACE_DONE = false
local function TextIs(v, s) return Str(v) == s end
local function KoboldRace()
    local gnome = Load("/Ruleset_2024/Database/Ancestries/Gnome/DA_AN_Gnome.DA_AN_Gnome", true)
    if not gnome then return end
    if RACE_DONE and TextIs(Try(function() return gnome.Title end), KOBOLD_TITLE) then return end
    local changes = {}
    local function set(field, value, label)
        local ok, err = pcall(function() gnome[field] = value end)
        changes[#changes + 1] = label .. (ok and "" or (" FAILED: " .. tostring(err)))
    end
    set("Title", FText(KOBOLD_TITLE), "title")
    set("ShortDescription", FText(KOBOLD_SHORT), "short description")
    set("Description", FText(KOBOLD_DESC), "description")
    set("bEnumerableForUser", true, "offered in creation")
    set("SortOrder", 65, "sort order 65")
    -- never write a soft object property (LargeTexture) from here: UE4SS copies the object as if it were the
    -- soft pointer and the game crashes (4 Oct, 01:26); the picture is changed on screen instead
    -- walk 30 ft instead of the gnome's 25
    local walk30 = Load("/Ruleset_2024/Database/Ancestries/GE_Walk30.GE_Walk30_C")
    local fs = Try(function() return gnome.Features end)
    local arr = Valid(fs) and Try(function() return fs.GrantedGameplayEffects end)
    local n = arr and (Try(function() return #arr end) or 0) or 0
    for i = 1, n do
        local e = Try(function() return arr[i] end)
        local ge = e and Try(function() return e.GameplayEffect end)
        if Valid(ge) and Name(ge) == "GE_Walk25_C" and walk30 then
            local ok, err = pcall(function() e.GameplayEffect = walk30 end)
            local back = Try(function() return arr[i].GameplayEffect end)
            changes[#changes + 1] = string.format("walk 25 -> 30 (%s; reads back %s)", ok and "written" or ("FAILED: " .. tostring(err)), Name(back))
        end
    end
    RACE_DONE = true
    local okC, errC = pcall(BuildDraconicCry, gnome)
    if not okC then Log("Draconic Cry failed: %s", tostring(errC)) end
    local okL, errL = pcall(BuildKoboldLegacy, gnome)
    if not okL then Log("Kobold Legacy failed: %s", tostring(errL)) end
    local effects = {}
    for i = 1, n do effects[#effects + 1] = Name(Try(function() return arr[i].GameplayEffect end)) end
    Log("Kobold race: %s; now title %q, offered %s, sort %s, effects %s", table.concat(changes, ", "),
        Str(Try(function() return gnome.Title end)) or "?", tostring(Try(function() return gnome.bEnumerableForUser end)),
        tostring(Try(function() return gnome.SortOrder end)), table.concat(effects, " "))
end
-- every character of the Kobold ancestry gets the kobold body; the creation avatar follows the ancestry picked
local KOBOLD_TAG = "Ruleset.Ancestry.Gnome"
local function AncestryOf(actor)
    local av = AvatarOf(actor)
    local t = av and Try(function() return av.CurrentMeshSelectionTags end)
    return t and Try(function() return t.AncestryTag.TagName:ToString() end) or nil
end
-- only heroes: the game draws its Siklas NPCs (Jebfa, the Ka'Umm) on the gnome body, so their look's ancestry is the
-- kobold's (the hidden Gnome) too. A hero's simulation actor owns a HeroIdentityComponent, an NPC's a
-- MonsterIdentityComponent. HEROES.owners: the addresses of every hero identity's owner (refreshed each pass).
local HEROES = { owners = {}, said = {} }
function HEROES.Owners()
    local t = {}
    for _, c in ipairs(Try(function() return FindAllOf("HeroIdentityComponent") end) or {}) do
        local o = Valid(c) and Try(function() return c:GetOwner() end)
        if Valid(o) then t[o:GetAddress()] = true end
    end
    HEROES.owners = t
end
function HEROES.Check(actor, isModel)
    -- true: a hero; false: an NPC (or a model of one); a model whose simulation actor does not exist yet counts as a hero
    if HEROES.owners[actor:GetAddress()] then return true end
    local sim = Try(function() return actor.SimulationActor end)
    if Valid(sim) then return HEROES.owners[sim:GetAddress()] == true end
    return isModel
end
local function AutoKobold()
    HEROES.Owners()
    for _, cname in ipairs({ "BrimstoneCharacter", "CharacterEditionAvatar", "BrimstoneInventoryAvatar" }) do
        for _, actor in ipairs(Try(function() return FindAllOf(cname) end) or {}) do
            if Valid(actor) and not actor:GetFullName():find("Default__", 1, true) then
                local anc = AncestryOf(actor)
                local addr = actor:GetAddress()
                local hero = anc == KOBOLD_TAG and HEROES.Check(actor, cname ~= "BrimstoneCharacter")
                if anc == KOBOLD_TAG and not hero then
                    if KOBOLD[addr] then
                        Log("%s is not a hero (an NPC drawn on the gnome body): own look back", Name(actor))
                        pcall(KoboldOff, actor)
                    elseif not HEROES.said[addr] then
                        HEROES.said[addr] = true
                        Log("%s has the gnome body but is not a hero (a Siklas NPC?): left as it is", Name(actor))
                    end
                elseif anc == KOBOLD_TAG and not KOBOLD[addr] then
                    Log("%s is of the Kobold ancestry: kobold body", Name(actor))
                    local ok, err = pcall(KoboldOn, actor)
                    if not ok then Log("kobold failed: %s", tostring(err)) end
                elseif anc and anc ~= KOBOLD_TAG and KOBOLD[addr] and KOBOLD[addr].auto and cname ~= "BrimstoneCharacter" then
                    Log("%s is now %s: own look back", Name(actor), anc)
                    pcall(KoboldOff, actor)
                end
                if KOBOLD[addr] and anc == KOBOLD_TAG then KOBOLD[addr].auto = true end
            end
        end
    end
end
-- cameras: the game's camera rigs aim at bones of the character's body (the portrait camera at the right eye,
-- dialogue cameras at the head). A kobold hero's own body is hidden and taller (the gnome's), so the hidden body is
-- lowered by the gap between its eyes and the kobold's (the kobold raised by the same, so it stays on the ground):
-- every such camera then frames the kobold. A squash in height did the same for the eyes but distorted the eye
-- bone's transform, and the portrait came out as a close-up of the neck. Models are lowered for good; heroes only
-- during story scenes and dialogue. Never read the cameras' soft actor references: UE4SS copies them wrongly.
local EYE = "cc_base_r_eye"
local function VecZ(v) return tonumber(Try(function() return v.Z end)) end
local function SetRel(c, v) return pcall(function() c:K2_SetRelativeLocation(v, false, {}, true) end) end
-- how far the hidden body's eyes sit above the kobold's: each eye's height over its own body's origin, so the
-- lowering already applied (or undone by the game) does not count
local function EyeGap(st, body, puppet)
    local bz = VecZ(Try(function() return body:K2_GetComponentLocation() end))
    local pz = VecZ(Try(function() return puppet:K2_GetComponentLocation() end))
    local gz = VecZ(Try(function() return body:GetSocketLocation(FName(EYE)) end))
    local kz = VecZ(Try(function() return puppet:GetSocketLocation(FName(EYE)) end))
    if not (bz and pz and gz and kz) then return nil end
    return (gz - bz) - (kz - pz)
end
local function RelZ(c) return tonumber(Try(function() return c.RelativeLocation.Z end)) end
-- the places kept: the game sometimes puts a model's body back (it re-applies its own setup)
function KeepSunk(st, pawn)
    if not st.sink then return end
    local av = AvatarOf(pawn)
    local body = av and Try(function() return av.BodySkeletalMeshComponent end)
    local puppet = FindByName(pawn, st.puppet)
    if not (Valid(body) and Valid(puppet)) then return end
    local base = st.bodyLoc or { X = 0, Y = 0, Z = 0 }
    local bzr, pzr = RelZ(body), RelZ(puppet)
    if not (bzr and pzr) then return end
    if math.abs(bzr - (base.Z - st.sink)) > 1 or math.abs(pzr - st.sink) > 1 then
        SetRel(body, { X = base.X, Y = base.Y, Z = base.Z - st.sink })
        SetRel(puppet, { X = 0, Y = 0, Z = st.sink })
        st.replaced = (st.replaced or 0) + 1
        if st.replaced <= 3 then Log("%s: the hidden body or the kobold was moved back (body at %.0f, kobold at %.0f): placed again", st.name, bzr, pzr) end
    end
end
function SinkHidden(st, pawn, on, why, gap)
    local av = AvatarOf(pawn)
    local body = av and Try(function() return av.BodySkeletalMeshComponent end)
    local puppet = FindByName(pawn, st.puppet)
    if not (Valid(body) and Valid(puppet)) then return end
    local base = st.bodyLoc or { X = 0, Y = 0, Z = 0 }
    if not on then
        if not st.sink then return end
        SetRel(body, { X = base.X, Y = base.Y, Z = base.Z })
        SetRel(puppet, { X = 0, Y = 0, Z = 0 })
        if st.baseOffset then pcall(function() pawn.BaseTranslationOffset.Z = st.baseOffset end) end
        st.sink = nil
        Log("%s: the hidden body back in place (%s)", st.name, why)
        return
    end
    gap = gap or EyeGap(st, body, puppet)
    if not gap then return end
    if gap < 5 or gap > 90 then
        if not st.sinkOdd then st.sinkOdd = true; Log("%s: the eye gap looks wrong (%.0f cm): the hidden body stays", st.name, gap) end
        return
    end
    if st.sink and math.abs(gap - st.sink) < 3 then return end
    local okB = SetRel(body, { X = base.X, Y = base.Y, Z = base.Z - gap })
    local okP = SetRel(puppet, { X = 0, Y = 0, Z = gap })
    local bto = tonumber(Try(function() return pawn.BaseTranslationOffset.Z end))
    if bto and not st.preview then
        if st.baseOffset == nil then st.baseOffset = bto end
        pcall(function() pawn.BaseTranslationOffset.Z = st.baseOffset - gap end)
    end
    local was = st.sink
    st.sink = gap
    Log("%s: the hidden body %s %.0f cm, the kobold raised as much (%s)%s", st.name, was and "lowered again," or "lowered", gap, why,
        (okB and okP) and "" or " - a move FAILED")
end
-- the gap measured in quiet moments of normal play (standing, no action), for the next scene
local function SampleGap(st, pawn)
    if st.sink or st.combat or st.down or st.montage then return end
    if st.gapAt and os.clock() - st.gapAt < 3 then return end
    st.gapAt = os.clock()
    local vel = Try(function() return pawn:GetVelocity() end)
    local speed = vel and math.sqrt((tonumber(Try(function() return vel.X end)) or 0) ^ 2 + (tonumber(Try(function() return vel.Y end)) or 0) ^ 2) or 0
    if speed > 5 then return end
    local av = AvatarOf(pawn)
    local body = av and Try(function() return av.BodySkeletalMeshComponent end)
    local puppet = FindByName(pawn, st.puppet)
    local gap = Valid(body) and Valid(puppet) and EyeGap(st, body, puppet)
    if not gap or gap < 10 or gap > 80 then return end
    st.gaps = st.gaps or {}
    table.insert(st.gaps, gap)
    if #st.gaps > 7 then table.remove(st.gaps, 1) end
    local sorted = {}
    for i, v in ipairs(st.gaps) do sorted[i] = v end
    table.sort(sorted)
    local was = st.refGap
    st.refGap = sorted[math.floor((#sorted + 1) / 2)]
    if not was then Log("%s: eye gap in quiet play %.0f cm (used when a scene starts)", st.name, st.refGap) end
end
-- heroes: lowered while a story scene runs or the view is a dialogue or cutscene camera; models: always
local VIEW = { name = nil }
local STORY_VIEWS = { "BlackEye", "BES_", "BEC_", "CameraActor", "CineCamera", "Sequence" }
function SinkUpkeep()
    if next(KOBOLD) == nil then return end
    local pc = UEHelpers.GetPlayerController()
    local vt = Valid(pc) and Try(function() return pc:GetViewTarget() end)
    local cls = Valid(vt) and ClassOf(vt) or "?"
    local name = Valid(vt) and (Name(vt) .. " [" .. cls .. "]") or "none"
    if name ~= VIEW.name then VIEW.name = name; Log("cameras: the view is %s", name) end
    local story = false
    for _, k in ipairs(STORY_VIEWS) do if cls:find(k, 1, true) then story = true end end
    for _, st in pairs(KOBOLD) do
        local pawn = st.pawn
        if pawn and Valid(pawn) and Name(pawn) == st.name then
            if st.preview then
                if not st.sinkSettled and st.bornAt and os.clock() - st.bornAt > 1.5 then
                    st.sinkSettled = true
                    SinkHidden(st, pawn, true, "a model, settled")
                end
                KeepSunk(st, pawn)
            elseif story or st.story then
                if not st.sink then SinkHidden(st, pawn, true, st.story and "a story scene" or ("the view is " .. cls), st.refGap)
                else KeepSunk(st, pawn) end
            else
                if st.sink then SinkHidden(st, pawn, false, "the game's camera is back") end
                SampleGap(st, pawn)
            end
            if not st.preview then
                local okC, errC = pcall(CryUpkeep, st, pawn)
                if not okC and not st.cryError then st.cryError = true; Log("%s: cry check failed: %s", st.name, tostring(errC)) end
            end
        end
    end
end
Every(100, function()
    local ok, err = pcall(SinkUpkeep)
    if not ok and not SINK_ERROR then SINK_ERROR = true; Log("lowering failed: %s", tostring(err)) end
end)
-- Draconic Cry: with no enemy within 10 ft the game asks whether to use it anyway, and the use is already spent by
-- then. A spent use whose cry never reaches its release (the growl's LoopEnd) is given back once the ability is over.
local CRY_COST = "Ruleset.Cost.Dragonbornbreath"
local ASL = nil
local function AscOf(pawn)
    ASL = ASL or Try(function() return StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary") end)
    return Valid(ASL) and Try(function() return ASL:GetAbilitySystemComponent(pawn) end) or nil
end
local function TagCount(asc, tag) return tonumber(Try(function() return asc:GetGameplayTagCount({ TagName = FName(tag) }) end)) end
function CryUpkeep(st, pawn)
    local asc = AscOf(pawn)
    if not Valid(asc) then return end
    local n = TagCount(asc, CRY_COST)
    if not n then return end
    if st.cryUses and n < st.cryUses then
        st.crySpend = { from = st.cryUses, at = os.clock() }
        Log("%s: a Draconic Cry use is spent (%d -> %d)", st.name, st.cryUses, n)
    end
    local p = st.crySpend
    if p then
        local busy = (TagCount(asc, "Status.InRunEffectDefinitionAction") or 0) > 0
        if st.cryCastAt and st.cryCastAt >= p.at - 1.0 then
            Log("%s: Draconic Cry cast (%d left)", st.name, n)
            st.crySpend = nil
        elseif not busy and os.clock() - p.at > 1.5 then
            local ok = pcall(function() asc:SetLooseGameplayTagCount({ TagName = FName(CRY_COST) }, p.from, true) end)
            local back = TagCount(asc, CRY_COST)
            Log("%s: Draconic Cry was not cast: the use is given back (%d -> %s%s)", st.name, n, tostring(back), ok and "" or ", FAILED")
            st.crySpend = nil
            n = back or n
        end
    end
    st.cryUses = n
end
-- the kobold's own voice in cutscenes: when a kobold hero speaks a line that has a kobold recording, the hero's own
-- voice is muted and the narrator companion plays the recording (a "sample" of the line's exact text). The line
-- being spoken comes from the game's VoiceLineSubsystem (its SoundWave, a soft reference, is never read).
local VOICE = { lines = nil, linesAt = 0, last = nil, muted = nil, vls = nil, vlsAt = 0, secs = {} }
local function GameFile(rel) return KCFG.Dir() .. rel end
local function NormText(t)
    local n = (t or ""):lower():gsub("[^a-z0-9]+", " ")
    n = n:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return n
end
local function KoboldLines()
    if VOICE.lines and os.clock() - VOICE.linesAt < 30 then return VOICE.lines end
    VOICE.linesAt = os.clock()
    local set, n = {}, 0
    local f = io.open(GameFile("Narrator/packs/kobold/lines.txt"), "r")
    if f then
        for raw in f:lines() do
            local l = raw:gsub("%s+$", "")
            local norm, key, secs = l:match("^(.-) | (%S+) | ([%d%.]+)$")
            if not norm then norm, key = l:match("^(.-) | (%S+)$") end
            if norm and secs then VOICE.secs[key] = tonumber(secs) end
            if norm and norm ~= "" then set[norm] = key; n = n + 1
            elseif l ~= "" then set[l] = true; n = n + 1 end
        end
        f:close()
    end
    if not VOICE.lines then Log("kobold voice: %d recorded line(s) in Narrator/packs/kobold", n) end
    VOICE.lines = set
    return set
end
local function JsonStr(str)                 -- a JSON string (the backslash made with string.char: no escapes here)
    local bs = string.char(92)
    local body = str:gsub('[%c"' .. bs .. ']', function(c)
        if c == '"' then return bs .. '"' elseif c == bs then return bs .. bs end
        return string.format(bs .. "u%04x", c:byte())
    end)
    return '"' .. body .. '"'
end
local function Narrate(json)
    local f = io.open(GameFile("Narrator/queue.txt"), "a")
    if not f then return false end
    f:write(json, "\n"); f:close()
    return true
end
-- the kobold's lines play at the game's voice volume (master x voice) x the kobold voice level (Ctrl+Shift+, and .,
-- VoiceLevel in Kobold.ini, read again every 3 s: Mod options changes it while the game runs); one table: the
-- main chunk is at Lua's limit of 200 locals. 0.30 by default: the level of the game's own voices, measured.
local KVOL = { level = KCFG.VoiceLevel, readAt = -100, settings = nil, settingsAt = -100 }
function KVOL.Dec3(x)                       -- "0.350": digits only, whatever the C locale's decimal point
    local m = math.floor((tonumber(x) or 0) * 1000 + 0.5)
    return string.format("%d.%03d", m // 1000, m % 1000)
end
function KVOL.Load()
    if os.clock() - KVOL.readAt < 3 then return false end
    KVOL.readAt = os.clock()
    KCFG.Read()
    local changed = math.abs(KCFG.VoiceLevel - KVOL.level) > 0.0005
    KVOL.level = KCFG.VoiceLevel
    return changed
end
function KVOL.GameVolume()
    if not Valid(KVOL.settings) or os.clock() - KVOL.settingsAt > 10 then
        KVOL.settingsAt = os.clock()
        KVOL.settings = Try(function() return FindFirstOf("BrimstoneSettingsLocal") end)
    end
    local st = KVOL.settings
    local o = Valid(st) and tonumber(Try(function() return st.OverallVolume end)) or 1.0
    local v = Valid(st) and tonumber(Try(function() return st.VoiceVolume end)) or 1.0
    o, v = math.max(0, math.min(1, o)), math.max(0, math.min(1, v))
    return o * v, o, v
end
function KVOL.Gain()
    KVOL.Load()
    return math.max(0.0, math.min(1.0, KVOL.GameVolume() * KVOL.level))
end
function KVOL.Sample(text)
    return '{"kind":"sample","text":' .. JsonStr(text) .. ',"gain":' .. KVOL.Dec3(KVOL.Gain()) .. '}'
end
function KoboldGainStep(up)
    KVOL.Load()
    if up ~= nil then
        KVOL.level = math.max(0.03, math.min(1.0, KVOL.level * (up and 1.1885 or 1 / 1.1885)))     -- 1.5 dB a step
        KCFG.VoiceLevel = KVOL.level
        KCFG.Write("VoiceLevel", KVOL.Dec3(KVOL.level))
    end
    local _, o, v = KVOL.GameVolume()
    Log("kobold voice level %s x the game's master %s x voice %s = %s", KVOL.Dec3(KVOL.level), KVOL.Dec3(o), KVOL.Dec3(v), KVOL.Dec3(KVOL.Gain()))
    local best, bestS = nil, 99                                -- a short kobold line at the new level
    local lines = KoboldLines()
    for key, sec in pairs(VOICE.secs) do if sec > 0.5 and sec < bestS then best, bestS = key, sec end end
    for norm, key in pairs(lines) do
        if key == best then Narrate('{"kind":"stop"}'); Narrate(KVOL.Sample(norm)); break end
    end
end
local function VoiceComp(char)
    local cls = Try(function() return StaticFindObject("/Script/Brimstone.CharacterEffectsComponent") end)
    local fx = Valid(cls) and Try(function() return char:GetComponentByClass(cls) end)
    local vac = Valid(fx) and Try(function() return fx.VoiceAudioComponent end)
    return Valid(vac) and vac or nil
end
function KoboldVoiceUpkeep()
    if next(KOBOLD) == nil then return end
    if not Valid(VOICE.vls) then
        if os.clock() - VOICE.vlsAt < 5 then return end
        VOICE.vlsAt = os.clock()
        VOICE.vls = Try(function() return FindFirstOf("VoiceLineSubsystem") end)
        if not Valid(VOICE.vls) then return end
    end
    local cur = Try(function() return VOICE.vls.CurrentVoiceLine end)
    if not cur then return end
    local char = Try(function() return cur.Character end)
    local text = Valid(char) and (Str(Try(function() return cur.LocalizationKey end)) or "") or ""
    local id = (Valid(char) and tostring(char:GetAddress()) or "-") .. "|" .. text
    if id ~= VOICE.last then
        if VOICE.muted then                                   -- the line before is over: its speaker's voice back
            pcall(function() VOICE.muted.vac:SetVolumeMultiplier(VOICE.muted.vol) end)
            pcall(function() VOICE.muted.vac:AdjustVolume(0.0, 1.0, 0) end)
            VOICE.muted = nil
        end
        VOICE.last = id
        if Valid(char) and text ~= "" then
            local st = KOBOLD[char:GetAddress()]
            local kob = st and not st.preview
            local have = kob and KoboldLines()[NormText(text)]
            Log("voice line: %s%s says %q (%s)%s", Name(char), kob and " (a kobold)" or "", text:sub(1, 90), tostring(Str(Try(function() return cur.StringTableId end))),
                kob and (have and ": the kobold's recording plays" or ": no kobold recording yet") or "")
            if have then
                local vac = VoiceComp(char)
                if vac then
                    local vol = tonumber(Try(function() return vac.VolumeMultiplier end)) or 1.0
                    pcall(function() vac:SetVolumeMultiplier(0.0) end)
                    pcall(function() vac:AdjustVolume(0.0, 0.001, 0) end)
                    VOICE.muted = { vac = vac, vol = vol }
                else
                    Log("kobold voice: %s's own voice was not found to mute", Name(char))
                end
                if not (Narrate('{"kind":"stop"}') and Narrate(KVOL.Sample(text))) then
                    Log("kobold voice: the narrator's queue could not be written (%s)", GameFile("Narrator/queue.txt"))
                end
            end
        end
    elseif VOICE.muted then
        pcall(function() VOICE.muted.vac:SetVolumeMultiplier(0.0) end)       -- kept quiet while the line lasts
        pcall(function() VOICE.muted.vac:AdjustVolume(0.0, 0.001, 0) end)
    end
end
Every(1000, function()
    if KVOL.Load() then
        local ok, err = pcall(KoboldGainStep, nil)
        if not ok then Log("kobold voice level failed: %s", tostring(err)) end
    end
end)
Every(100, function()
    local ok, err = pcall(KoboldVoiceUpkeep)
    if not ok and not VOICE.error then VOICE.error = true; Log("kobold voice failed: %s", tostring(err)) end
end)
-- cutscene lines: a cutscene plays its own recording of each line (SW_<key>_<voice>) from its sequence, never
-- through the VoiceLineSubsystem. Every line reaches the conversation's participants as a message (LastMessage:
-- the text, the speaker's tag, the participants with their actors). A kobold hero's recorded line: the companion
-- plays the kobold's take and the game's own take is turned down until the next line.
local CONV = { comps = nil, at = 0, last = nil, search = nil, muted = {} }
local function ConvComps()
    if CONV.comps and os.clock() - CONV.at < 3 then return CONV.comps end
    CONV.at = os.clock()
    local out = {}
    for _, c in ipairs(Try(function() return FindAllOf("ConversationParticipantComponent") end) or {}) do
        if Valid(c) and not c:GetFullName():find("Default__", 1, true) then out[#out + 1] = c end
    end
    CONV.comps = out
    return out
end
local function RestoreConvMutes()
    for _, m in ipairs(CONV.muted) do
        if Valid(m.comp) then pcall(function() m.comp:SetVolumeMultiplier(m.vol) end) end
    end
    CONV.muted = {}
end
local function MuteTake(key)
    local n = 0
    local prefix = "SW_" .. key .. "_"
    for _, a in ipairs(Try(function() return FindAllOf("AudioComponent") end) or {}) do
        local snd = Valid(a) and Try(function() return a.Sound end)
        local nm = Valid(snd) and Name(snd) or ""
        if nm:sub(1, #prefix) == prefix then
            local vol = tonumber(Try(function() return a.VolumeMultiplier end)) or 1.0
            pcall(function() a:SetVolumeMultiplier(0.0) end)
            CONV.muted[#CONV.muted + 1] = { comp = a, vol = vol }
            n = n + 1
            Log("kobold voice: the game's take %s turned down", nm)
        end
    end
    return n
end
function ConversationUpkeep()
    local active = false
    for _, st in pairs(KOBOLD) do if not st.preview and (st.story or st.sink) then active = true end end
    if not active then
        if CONV.last or CONV.search then RestoreConvMutes(); CONV.last = nil; CONV.search = nil end
        return
    end
    for _, c in ipairs(ConvComps()) do
        local msg = Valid(c) and Try(function() return c.LastMessage end)
        local text = msg and (Str(Try(function() return msg.Message.Text end)) or "") or ""
        if text ~= "" then
            local spk = Try(function() return msg.Message.SpeakerID.TagName:ToString() end) or "?"
            local id = spk .. "|" .. text
            if id ~= CONV.last then
                CONV.last = id
                RestoreConvMutes()
                CONV.search = nil
                local actor = nil
                local list = Try(function() return msg.Participants.List end)
                for i = 1, (list and (Try(function() return #list end) or 0) or 0) do
                    local e = Try(function() return list[i] end)
                    if e and Try(function() return e.ParticipantID.TagName:ToString() end) == spk then actor = Try(function() return e.Actor end) end
                end
                local st = Valid(actor) and KOBOLD[actor:GetAddress()]
                local kob = st and not st.preview
                local key = kob and KoboldLines()[NormText(text)]
                if key == true then key = nil end
                Log("dialogue line: %s (%s, %s)%s says %q%s", tostring(Str(Try(function() return msg.Message.ParticipantDisplayName end))), spk, Name(actor),
                    kob and " (a kobold)" or "", text:sub(1, 90), kob and (key and ": the kobold's recording plays" or ": no kobold recording yet") or "")
                if key then
                    if not (Narrate('{"kind":"stop"}') and Narrate(KVOL.Sample(text))) then
                        Log("kobold voice: the narrator's queue could not be written")
                    end
                    CONV.search = { key = key, untilT = os.clock() + 4, found = 0 }
                end
            end
            break
        end
    end
    -- the game's own take of the kobold's line, turned down as soon as the cutscene starts it
    local sr = CONV.search
    if sr then
        if sr.found > 0 then
            for _, m in ipairs(CONV.muted) do if Valid(m.comp) then pcall(function() m.comp:SetVolumeMultiplier(0.0) end) end end
        elseif os.clock() < sr.untilT then
            if not sr.at or os.clock() - sr.at > 0.25 then sr.at = os.clock(); sr.found = MuteTake(sr.key) end
        else
            Log("kobold voice: the game's take of %s was not found to turn down", sr.key)
            CONV.search = nil
        end
    end
end
Every(100, function()
    local ok, err = pcall(ConversationUpkeep)
    if not ok and not CONV.error then CONV.error = true; Log("dialogue lines failed: %s", tostring(err)) end
end)
-- cutscene takes by their sound: SW_<dialogue>_<n>_<F1|F2|M1|M2> is a hero's take of line <dialogue>_<n>
local TAKES = { comps = {}, seeded = false, sound = {}, active = false, muted = {}, convLogged = false, keyText = nil,
    say = { key = nil, untilT = nil } }       -- say: the kobold line the companion is playing, and when it ends
local function NoteAudio(a)
    local ok, addr = pcall(function() return a:GetAddress() end)
    if ok and addr and not TAKES.comps[addr] then TAKES.comps[addr] = a end
end
local okN, errN = pcall(function() NotifyOnNewObject("/Script/Engine.AudioComponent", function(a) pcall(NoteAudio, a) end) end)
if not okN then Log("cutscene takes: new audio components not noted (%s)", tostring(errN)) end
local function KeyTexts()
    if TAKES.keyText and os.clock() - (TAKES.keyAt or 0) < 30 then return TAKES.keyText end
    TAKES.keyAt = os.clock()
    local m = {}
    for norm, key in pairs(KoboldLines()) do if type(key) == "string" then m[key] = norm end end
    TAKES.keyText = m
    return m
end
local function OwnerText(a)
    local o = Try(function() return a:GetOwner() end)
    local p = Try(function() return a:GetAttachParent() end)
    local po = Valid(p) and Try(function() return p:GetOwner() end)
    return o, p, po
end
-- who speaks a take: a dialogue hands each line to a role (Dialogue.Participant.Party.A-D) and fills the roles from
-- the party (by archetype, family role, class, or its own default pick), so a hero's seat and family role decide
-- which lines it says. The take's role: the cutscene's voice track that holds it (its RoleTag), else the shipped
-- roles.txt. The speaker: the dialogue manager's current bindings (role -> actor), else the kobold hero's own
-- participant context.
local SPEAK = { roles = nil, rolesAt = 0, dlg = nil }
local function Len(arr)
    if arr == nil then return 0 end
    return tonumber(Try(function() return arr:GetArrayNum() end)) or tonumber(Try(function() return #arr end)) or 0
end
local function Same(a, b)
    return Valid(a) and Valid(b) and Try(function() return a:GetAddress() == b:GetAddress() end) == true
end
local function Short(tag) return (tostring(tag or "?"):gsub("^Dialogue%.Participant%.", "")) end
local function RolesTable()
    if SPEAK.roles and os.clock() - SPEAK.rolesAt < 60 then return SPEAK.roles end
    SPEAK.rolesAt = os.clock()
    local t, n = {}, 0
    local f = io.open(GameFile("Narrator/packs/kobold/roles.txt"), "r")
    if f then
        for raw in f:lines() do
            local key, role = raw:match("^(%S+)%s+(%S+)")
            if key then t[key] = role; n = n + 1 end
        end
        f:close()
    end
    if not SPEAK.roles then Log("cutscene takes: %d line roles in Narrator/packs/kobold/roles.txt", n) end
    SPEAK.roles = t
    return t
end
local function TrackRole(nm, key)
    -- the cutscene's voice track whose section plays this take (or another take of the same line)
    local prefix = "SW_" .. key .. "_"
    local found = nil
    for _, t in ipairs(Try(function() return FindAllOf("MovieSceneVoiceTrack") end) or {}) do
        if Valid(t) then
            local secs = Try(function() return t.AudioSections end)
            for i = 1, Len(secs) do
                local sec = Try(function() return secs[i] end)
                local snd = Valid(sec) and Try(function() return sec.Sound end)
                local sn = Valid(snd) and Name(snd) or ""
                if sn == nm or sn:sub(1, #prefix) == prefix then
                    local hit = { role = Tag(Try(function() return t.RoleTag end)), voice = Tag(Try(function() return t.VoiceTag end)),
                        pitch = tonumber(Try(function() return t.VoicePitchMultiplier end)) }
                    if hit.role == "?" or hit.role == "None" then hit.role = nil end
                    if sn == nm and hit.role then return hit end
                    if not found or (hit.role and not found.role) then found = hit end
                end
            end
        end
    end
    return found
end
local function Bindings()
    -- the current dialogue: its roles { [role tag] = actor } and its tag
    local out, m = {}, nil
    for _, c in ipairs(Try(function() return FindAllOf("DialogueManagerComponent") end) or {}) do
        if Valid(c) and not c:GetFullName():find("Default__", 1, true) then m = c; break end
    end
    local list = Valid(m) and Try(function() return m.CurrentDialogueBindings end)
    for i = 1, Len(list) do
        local b = Try(function() return list[i] end)
        local role = b and Tag(Try(function() return b.ParticipantTag end))
        local a = b and Try(function() return b.Actor end)
        if role and role ~= "?" and Valid(a) then out[role] = a end
    end
    return out, Valid(m) and Tag(Try(function() return m.ActiveDialogueTag end)) or "?"
end
local function KoboldOf(actor)
    -- the kobold hero this actor is (its pawn, or its ruleset actor: the pawn's name without "Character_")
    if not Valid(actor) then return nil end
    local st = KOBOLD[actor:GetAddress()]
    if st then return (not st.preview) and st or nil end
    local nm = Name(actor)
    for _, k in pairs(KOBOLD) do
        if not k.preview and k.name and (k.name == nm or k.name == "Character_" .. nm) then return k end
    end
    return nil
end
local function ContextRole(st)
    -- the role the hero's own dialogue participant component holds in the current dialogue
    for _, c in ipairs(Try(function() return FindAllOf("DialogueParticipantComponent") end) or {}) do
        if Valid(c) and Same(Try(function() return c:GetOwner() end), st.pawn) then
            local r = Tag(Try(function() return c.ParticipantContext.ParticipantID end))
            if r ~= "?" and r ~= "None" then return r end
        end
    end
    return nil
end
local function PartyText()
    -- every seat: its hero, family role, archetypes (the dialogue roles it can be picked for) and voice
    local ids = {}
    for _, c in ipairs(Try(function() return FindAllOf("HeroIdentityComponent") end) or {}) do
        if Valid(c) and not c:GetFullName():find("Default__", 1, true) then
            local o = Try(function() return c:GetOwner() end)
            if Valid(o) then ids[(Name(o):gsub("^Character_", ""))] = c end
        end
    end
    local out, seat = {}, 0
    for _, pcmp in ipairs(Try(function() return FindAllOf("PartyComponent") end) or {}) do
        local party = Try(function() return pcmp.Party end)
        for i = 1, Len(party) do
            local m = Try(function() return party[i] end)
            if Valid(m) then
                seat = seat + 1
                local nm = (Name(m):gsub("^Character_", ""))
                local c = ids[nm]
                local id = c and Try(function() return c.IdentityData end)
                local arch = {}
                local arr = id and Try(function() return id.DialogueRoles end)
                for j = 1, Len(arr) do arch[#arch + 1] = (Tag(Try(function() return arr[j] end)):gsub("^Personality%.Archetype%.", "")) end
                local fam = id and (Tag(Try(function() return id.FamilyRole end)):gsub("^Personality%.FamilyRole%.", "")) or "?"
                out[#out + 1] = string.format("seat %d %s%s: family %s, archetypes %s, voice %s x%s", seat, nm, KoboldOf(m) and " (kobold)" or "",
                    fam, #arch > 0 and table.concat(arch, "/") or "none", id and Tag(Try(function() return id.VoiceTag end)) or "?",
                    tostring(id and Try(function() return id.VoicePitchMultiplier end) or "?"))
            end
        end
    end
    return out
end
function TakesUpkeep()
    local active = false
    for _, st in pairs(KOBOLD) do if not st.preview and (st.story or st.sink) then active = true end end
    if not active then
        if TAKES.active then
            for _, m in ipairs(TAKES.muted) do
                if Valid(m.comp) then pcall(function() m.comp:SetVolumeMultiplier(m.vol) end); pcall(function() m.comp:AdjustVolume(0.0, 1.0, 0) end) end
            end
            TAKES.muted, TAKES.active, TAKES.sound, TAKES.convLogged = {}, false, {}, false
            SPEAK.dlg = nil
        end
        return
    end
    if not TAKES.active then
        TAKES.active = true
        local n = 0
        for _, a in ipairs(Try(function() return FindAllOf("AudioComponent") end) or {}) do if Valid(a) then NoteAudio(a); n = n + 1 end end
        Log("cutscene takes: a scene with a kobold; %d audio components in memory", n)
    end
    if not TAKES.convLogged then                      -- the party's seats, family roles, archetypes and voices (once a scene)
        TAKES.convLogged = true
        local party = PartyText()
        Log("cutscene takes: the party: %s", #party > 0 and table.concat(party, "; ") or "not found")
    end
    local texts = KeyTexts()
    for addr, a in pairs(TAKES.comps) do
        if not Valid(a) then
            TAKES.comps[addr] = nil
        else
            local snd = Try(function() return a.Sound end)
            local nm = Valid(snd) and Name(snd) or ""
            -- a dialogue take: a hero's SW_<key>_<voice>, or anyone's SW_<key> under /Dialogues/
            local line = nm:match("^SW_(.+_%d+)_[FM][12]$")
            if not line then
                line = nm:match("^SW_(.+_%d+)$")
                if line and not (Try(function() return snd:GetFullName() end) or ""):find("/Dialogues/", 1, true) then line = nil end
            end
            local playing = line ~= nil and Try(function() return a:IsPlaying() end) == true
            local was = TAKES.sound[addr]
            local started = playing and (not was or was.nm ~= nm or not was.playing)
            TAKES.sound[addr] = { nm = nm, playing = playing }
            if started then
                local say = TAKES.say
                if say.untilT and os.clock() < say.untilT - 0.05 and line ~= say.key then
                    Narrate('{"kind":"stop"}')
                    Log("kobold voice: cut %.2f s early, the next line started (%s)", say.untilT - os.clock(), nm)
                end
                say.untilT = nil
                local key, voice = nm:match("^SW_(.+_%d+)_([FM][12])$")
                if key then
                    local o, p, po = OwnerText(a)
                    local st = KoboldOf(o) or KoboldOf(po)               -- a take on the speaker's own component
                    local how = st and "its own sound" or nil
                    local hit = TrackRole(nm, key)
                    local role = hit and hit.role
                    local src = role and "voice track" or nil
                    if not role then role = RolesTable()[key]; src = role and "roles.txt" or nil end
                    local binds, dlg = Bindings()
                    if dlg ~= SPEAK.dlg then
                        SPEAK.dlg = dlg
                        local parts = {}
                        for r, actor in pairs(binds) do parts[#parts + 1] = Short(r) .. " = " .. Name(actor) end
                        table.sort(parts)
                        Log("dialogue %s: %s", dlg, #parts > 0 and table.concat(parts, ", ") or "no roles bound")
                    end
                    local who = role and binds[role] or nil
                    if not st and who then st = KoboldOf(who); how = st and "the dialogue's roles" or nil end
                    if not st and role then
                        for _, k in pairs(KOBOLD) do
                            if not k.preview and ContextRole(k) == role then st = k; how = "its own dialogue role" end
                        end
                    end
                    local kob = st ~= nil
                    local norm = texts[key]
                    Log("cutscene take: %s (%s): a line of %s (%s%s), said by %s%s", nm, voice, Short(role), src or "role not found",
                        hit and string.format(", track voice %s x%s", hit.voice, tostring(hit.pitch)) or "",
                        Valid(who) and Name(who) or (kob and st.name) or "?",
                        kob and string.format(": the kobold's (%s) - %s", how, norm and "its recording plays" or "no recording yet") or "")
                    if kob and norm then
                        local vol = tonumber(Try(function() return a.VolumeMultiplier end)) or 1.0
                        pcall(function() a:SetVolumeMultiplier(0.0) end)
                        pcall(function() a:AdjustVolume(0.0, 0.001, 0) end)       -- the sound's own fader: the sequencer leaves it alone
                        TAKES.muted[#TAKES.muted + 1] = { comp = a, vol = vol, until_ = os.clock() + 30 }
                        if not (Narrate('{"kind":"stop"}') and Narrate(KVOL.Sample(norm))) then
                            Log("kobold voice: the narrator's queue could not be written")
                        end
                        TAKES.say.key, TAKES.say.untilT = key, os.clock() + (VOICE.secs[key] or 4.0) + 0.15
                    end
                end
            end
        end
    end
    -- the kobold's takes kept down while they play; a component given another sound gets its volume back
    for i = #TAKES.muted, 1, -1 do
        local m = TAKES.muted[i]
        local nm = Valid(m.comp) and (Name(Try(function() return m.comp.Sound end))) or ""
        if not Valid(m.comp) or not nm:match("^SW_.+_%d+_[FM][12]$") or (TAKES.sound[m.comp:GetAddress()] or {}).nm ~= nm then
            if Valid(m.comp) then
                pcall(function() m.comp:SetVolumeMultiplier(m.vol) end)
                pcall(function() m.comp:AdjustVolume(0.0, 1.0, 0) end)
            end
            table.remove(TAKES.muted, i)
        else
            pcall(function() m.comp:SetVolumeMultiplier(0.0) end)
            pcall(function() m.comp:AdjustVolume(0.0, 0.001, 0) end)
        end
    end
end
Every(100, function()
    local ok, err = pcall(TakesUpkeep)
    if not ok and not TAKES.error then TAKES.error = true; Log("cutscene takes failed: %s", tostring(err)) end
end)
-- the portrait, for the log: where the hidden eye and the kobold's are when the game has set the camera up
local function PortraitEyes(pmc)
    local avatar = Try(function() return pmc.PortraitAvatar end)
    local st = Valid(avatar) and KOBOLD[avatar:GetAddress()]
    if not st then return end
    local av = AvatarOf(avatar)
    local body = av and Try(function() return av.BodySkeletalMeshComponent end)
    local puppet = FindByName(avatar, st.puppet)
    local gz = Valid(body) and VecZ(Try(function() return body:GetSocketLocation(FName(EYE)) end))
    local kz = Valid(puppet) and VecZ(Try(function() return puppet:GetSocketLocation(FName(EYE)) end))
    Log("portrait camera for %s: the hidden eye at %s, the kobold's at %s (lowered %s cm)", Name(avatar),
        tostring(gz and math.floor(gz + 0.5)), tostring(kz and math.floor(kz + 0.5)), tostring(st.sink and math.floor(st.sink + 0.5)))
end
-- Draconic Cry: clicking it and cancelling spent a use (4 Oct). The game's own powers around the user, logged once
-- (read only), to set the cry up like them
local POWER_FIELDS = { "ActivationTimeTag", "RangeTypeTag", "TargetTypeTag", "TargetType", "TargetParameter1Scalable", "TargetParameter2Scalable",
    "RangeParameterScalable", "CanIncludeSourceOfEffect", "TeamFilteringTags", "ActorTypeFilteringTags", "bHideTargetingAreaFeedback", "DurationTypeTag",
    "bSilentPower", "bHasCloseRange" }
local ABILITY_FIELDS = { "CommitTag", "bRequiresConfirmation", "bHasExternalTargetingConfirmation", "bIsContextualAbility", "CostGameplayEffectClass",
    "AdditionalCosts", "AbilityTags", "ActivationOwnedTags", "AbilityTriggers", "SpecificEffectDefinition", "ActivationPolicy" }
local function Fields(obj, wanted)
    local set = {}
    for _, w in ipairs(wanted) do set[w] = true end
    local parts = {}
    local cls = Try(function() return obj:GetClass() end)
    local hops = 0
    while Valid(cls) and hops < 14 do
        pcall(function()
            cls:ForEachProperty(function(prop)
                local n = PropNameOf(prop)
                if set[n] then set[n] = nil; parts[#parts + 1] = ValueText(obj, prop, 0, {}, "", 0) end
            end)
        end)
        cls = Try(function() return cls:GetSuperStruct() end)
        hops = hops + 1
    end
    return table.concat(parts, "; ")
end
local POWERS_LOGGED = false
local DB = "/Ruleset_2024/Database/"
function LogPowerSetups()
    if POWERS_LOGGED then return end
    POWERS_LOGGED = true
    local list = {
        { DB .. "CharacterClasses/Cleric/DA_POW_TurnUndead.DA_POW_TurnUndead", DB .. "CharacterClasses/Cleric/GA_PowerTurnUndead.GA_PowerTurnUndead_C" },
        { DB .. "CharacterClasses/Fighter/Commander/DA_POW_RousingShout.DA_POW_RousingShout", DB .. "CharacterClasses/Fighter/Commander/GA_PowerRousingShout.GA_PowerRousingShout_C" },
        { DB .. "Monsters/Beasts/SandLion/DA_POW_Growl.DA_POW_Growl", DB .. "Monsters/Beasts/SandLion/GA_PowerGrowl.GA_PowerGrowl_C" },
        { nil, "/Ruleset_2024/Database/Ancestries/Dwarf/GA_PowerStoneCunning.GA_PowerStoneCunning_C" },
        { nil, "/Ruleset_2024/Database/Ancestries/Dragonborn/GA_PowerDraconicAncestrySilverBreath.GA_PowerDraconicAncestrySilverBreath_C" },
    }
    for _, e in ipairs(list) do
        local cls = Load(e[2], true)
        local cdo = Valid(cls) and Try(function() return cls:GetCDO() end)
        if Valid(cdo) then
            Log("power setup: %s (parent %s): %s", Name(cls), Name(Try(function() return cls:GetSuperStruct() end)), Fields(cdo, ABILITY_FIELDS))
            local def = e[1] and Load(e[1], true) or Try(function() return cdo.SpecificEffectDefinition end)
            if Valid(def) then Log("power setup:    %s: %s", Name(def), Fields(def, POWER_FIELDS)) end
        else
            Log("power setup: %s not found", e[2])
        end
    end
end
-- portraits: the portrait manager spawns a model of the hero, waits FramesToWaitBeforeCapture frames, captures
local PORTRAIT_HOOKED, PORTRAIT_FRAMES_SET, RETAKEN = false, false, {}
-- the portrait camera (the manager's DefaultPortraitShootingParameters; the ancestry's own are for the character
-- collection only) pulled back during a kobold's capture: a kobold's head with its horns and snout is far bigger
-- than the gnome face the camera is set for. Ctrl+Shift+P cycles the distance and retakes the kobold portraits.
PORTRAIT_ZOOM = 2.0                -- the user's pick (4 Oct, 14:28): the camera 4 m from the eye instead of 1.85
local ZOOMS = { 1.6, 2.0, 2.4, 3.0, 3.6 }
local ZOOMED, ZOOM_LOGGED = nil, false
local function V3(v)
    local x, y, z = tonumber(Try(function() return v.X end)), tonumber(Try(function() return v.Y end)), tonumber(Try(function() return v.Z end))
    if not (x and y and z) then return nil end
    return { X = x, Y = y, Z = z }
end
local function V3Text(v) return v and string.format("(%.1f %.1f %.1f)", v.X, v.Y, v.Z) or "?" end
local function ShotParams(pmc)
    local list = {}
    local d = Try(function() return pmc.DefaultPortraitShootingParameters end)
    if d then list[#list + 1] = { "the manager's", d } end
    local gnome = Load("/Ruleset_2024/Database/Ancestries/Gnome/DA_AN_Gnome.DA_AN_Gnome", true)
    local g = gnome and Try(function() return gnome.CharacterCollectionPortraitShootingParameters end)
    if g then list[#list + 1] = { "the ancestry's", g } end
    return list
end
-- the portrait rig's look-at parts: within 15 m of the portrait model (the portrait scene is far from the rest)
local RIG_SAVED, RIG_LOGGED = {}, false
local function NearLookAts(avatar)
    local out = {}
    local a = V3(Try(function() return avatar:K2_GetActorLocation() end))
    if not a then return out end
    for _, c in ipairs(Try(function() return FindAllOf("LookAtComponent") end) or {}) do
        local o = Valid(c) and not c:GetFullName():find("Default__", 1, true) and Try(function() return c:GetOwner() end)
        local l = Valid(o) and V3(Try(function() return o:K2_GetActorLocation() end))
        if l and math.sqrt((l.X - a.X) ^ 2 + (l.Y - a.Y) ^ 2 + (l.Z - a.Z) ^ 2) < 1500 then out[#out + 1] = { comp = c, rig = o } end
    end
    return out
end
local function RestoreRigs()
    for a, sv in pairs(RIG_SAVED) do
        if Valid(sv.comp) then
            if sv.r then pcall(function() sv.comp.Target_0.BoundingRadius = sv.r end) end
            if sv.size then pcall(function() sv.comp.DesiredTargetViewportSize = sv.size end) end
        end
        RIG_SAVED[a] = nil
    end
end
-- a look-at with a dynamic field of view keeps its target at a set share of the view: the target made bigger
local function ZoomRigs(avatar)
    local found = NearLookAts(avatar)
    local lines = {}
    for _, e in ipairs(found) do
        local c = e.comp
        local a = c:GetAddress()
        local sv = RIG_SAVED[a]
        if not sv then
            sv = { comp = c, r = tonumber(Try(function() return c.Target_0.BoundingRadius end)), auto = Try(function() return c.Target_0.bAutoSize end) == true,
                size = tonumber(Try(function() return c.DesiredTargetViewportSize end)), dyn = Try(function() return c.bDynamicFoV end) }
            RIG_SAVED[a] = sv
        end
        if sv.auto and sv.size and sv.size > 0 then
            pcall(function() c.DesiredTargetViewportSize = sv.size / PORTRAIT_ZOOM end)
        elseif sv.r and sv.r > 0 then
            pcall(function() c.Target_0.BoundingRadius = sv.r * PORTRAIT_ZOOM end)
        end
        if not RIG_LOGGED then
            lines[#lines + 1] = string.format("%s of %s [%s]: dynamic field of view %s (%s..%s), target %s:%s radius %s (auto %s), view share %s, damping %s",
                CompName(c), Name(e.rig), ClassOf(e.rig), tostring(sv.dyn), tostring(Try(function() return c.MinFoV end)), tostring(Try(function() return c.MaxFoV end)),
                tostring(Str(Try(function() return c.Target_0.ComponentName end))), tostring(Str(Try(function() return c.Target_0.BoneName end))),
                tostring(sv.r), tostring(sv.auto), tostring(sv.size), tostring(Try(function() return c.FieldOfViewDamping end)))
        end
    end
    if not RIG_LOGGED then
        RIG_LOGGED = true
        Log("portrait rig: %d look-at part(s) near the portrait model%s", #found, #lines > 0 and (": " .. table.concat(lines, "; ")) or "")
    end
    return #found
end
-- where the portrait camera really is: the rig's follow part and its scene capture (the camera the portrait is shot with)
local CHECKS = {}
local function RotText(r)
    local p, y, l = tonumber(Try(function() return r.Pitch end)), tonumber(Try(function() return r.Yaw end)), tonumber(Try(function() return r.Roll end))
    return p and string.format("p%.0f y%.0f r%.0f", p, y or 0, l or 0) or "?"
end
local function RigParts(rig)
    local fol = nil
    for _, c in ipairs(Try(function() return FindAllOf("FollowComponent") end) or {}) do
        local o = Valid(c) and Try(function() return c:GetOwner() end)
        if Valid(o) and o:GetAddress() == rig:GetAddress() then fol = c end
    end
    local capCls = Try(function() return StaticFindObject("/Script/Engine.SceneCaptureComponent2D") end)
    local cap = Valid(capCls) and Try(function() return rig:GetComponentByClass(capCls) end)
    return fol, Valid(cap) and cap or nil
end
local function DescribeRig(rig, fol, cap, eye, when)
    local cl = cap and V3(Try(function() return cap:K2_GetComponentLocation() end))
    local dist = (cl and eye) and math.sqrt((cl.X - eye.X) ^ 2 + (cl.Y - eye.Y) ^ 2 + (cl.Z - eye.Z) ^ 2) or nil
    Log("portrait rig %s (%s): camera at %s %s, field of view %s, %s cm from the kobold's eye %s; follow offset %s, desired %s, resolved %s, follow part at %s",
        Name(rig), when, V3Text(cl), cap and RotText(Try(function() return cap:K2_GetComponentRotation() end)) or "?",
        tostring(cap and Try(function() return cap.FOVAngle end)), dist and string.format("%.0f", dist) or "?", V3Text(eye),
        V3Text(fol and V3(Try(function() return fol.FollowOffset end))), V3Text(fol and V3(Try(function() return fol.DesiredPosition end))),
        V3Text(fol and V3(Try(function() return fol.TargetResolvedPosition end))), V3Text(fol and V3(Try(function() return fol:K2_GetComponentLocation() end))))
end
local function KoboldEye(avatar)
    local st = KOBOLD[avatar:GetAddress()]
    local puppet = st and FindByName(avatar, st.puppet)
    return Valid(puppet) and V3(Try(function() return puppet:GetSocketLocation(FName("cc_base_r_eye")) end)) or nil
end
local SNAP_LOGGED = false
local function PortraitRigCheck(pmc)
    local avatar = Try(function() return pmc.PortraitAvatar end)
    if not (Valid(avatar) and KOBOLD[avatar:GetAddress()]) then return end
    local eye = KoboldEye(avatar)
    local seen = {}
    for _, e in ipairs(NearLookAts(avatar)) do
        local rig = e.rig
        if not seen[rig:GetAddress()] then
            seen[rig:GetAddress()] = true
            local fol, cap = RigParts(rig)
            DescribeRig(rig, fol, cap, eye, "after the game's setup")
            if not SNAP_LOGGED then
                SNAP_LOGGED = true
                local fn = Try(function() return StaticFindObject("/Script/Black_Eye.BlackEyeCameraRigBase:SnapComponentsToTargetsNow") end)
                Log("portrait rig: SnapComponentsToTargetsNow(%s)", Valid(fn) and ParamsText(fn) or "not found")
            end
            local okS, errS = pcall(function() rig:SnapComponentsToTargetsNow() end)
            if not okS then Log("portrait rig: the snap failed: %s", tostring(errS)) end
            DescribeRig(rig, fol, cap, eye, "after the snap")
            CHECKS[#CHECKS + 1] = { rig = rig, fol = fol, cap = cap, avatar = avatar, at = os.clock() + 0.15, when = "0.15 s later" }
            CHECKS[#CHECKS + 1] = { rig = rig, fol = fol, cap = cap, avatar = avatar, at = os.clock() + 0.5, when = "0.5 s later" }
        end
    end
end
Every(50, function()
    for i = #CHECKS, 1, -1 do
        local c = CHECKS[i]
        if os.clock() >= c.at then
            table.remove(CHECKS, i)
            if Valid(c.rig) and Valid(c.avatar) then pcall(DescribeRig, c.rig, c.fol, c.cap, KoboldEye(c.avatar), c.when) end
        end
    end
end)
-- the game's own follow offsets (read once, before any scaling), and when the scaled ones go back
local ZOOM_BASE, ZOOM_UNTIL = {}, nil
function UnzoomPortrait(why)
    if not ZOOMED then return end
    for _, z in ipairs(ZOOMED) do
        pcall(function() z.p.CameraFollowOffset.X = z.f.X; z.p.CameraFollowOffset.Y = z.f.Y; z.p.CameraFollowOffset.Z = z.f.Z end)
    end
    ZOOMED, ZOOM_UNTIL = nil, nil
    RestoreRigs()
    Log("portrait: the camera settings back to the game's (%s)", why)
end
Every(500, function() if ZOOM_UNTIL and os.clock() > ZOOM_UNTIL then pcall(UnzoomPortrait, "3 s after the kobold's portrait") end end)
local function PortraitZoom(pmc, on)
    if not on then return end                 -- the game applies the settings again before it captures: they stay
    local avatar = Try(function() return pmc.PortraitAvatar end)
    if not (Valid(avatar) and KOBOLD[avatar:GetAddress()]) then pcall(UnzoomPortrait, "a portrait of another hero"); return end
    ZOOMED = {}
    ZOOM_UNTIL = os.clock() + 3
    local parts = {}
    for _, e in ipairs(ShotParams(pmc)) do
        local p = e[2]
        local f = ZOOM_BASE[e[1]] or V3(Try(function() return p.CameraFollowOffset end))
        if f then
            ZOOM_BASE[e[1]] = f
            ZOOMED[#ZOOMED + 1] = { p = p, f = f }
            pcall(function() p.CameraFollowOffset.X = f.X * PORTRAIT_ZOOM; p.CameraFollowOffset.Y = f.Y * PORTRAIT_ZOOM; p.CameraFollowOffset.Z = f.Z * PORTRAIT_ZOOM end)
            if not ZOOM_LOGGED then
                parts[#parts + 1] = string.format("%s: bone %s, follow %s, look-at %s, focal %s, screen %s", e[1], tostring(Str(Try(function() return p.BoneToTrack end))),
                    V3Text(f), V3Text(V3(Try(function() return p.CameraLookAtOffset end))), tostring(Try(function() return p.FocalLength end)),
                    V3Text(V3({ X = Try(function() return p.SubjectScreenPosition.X end), Y = Try(function() return p.SubjectScreenPosition.Y end), Z = 0 })))
            end
        end
    end
    if not ZOOM_LOGGED and #parts > 0 then ZOOM_LOGGED = true; Log("portrait camera settings: %s", table.concat(parts, "; ")) end
    Log("portrait: the camera pulled back x%.1f for %s", PORTRAIT_ZOOM, Name(avatar))
end
local function KoboldPortraitModels(pmc, why)
    local models = { Try(function() return pmc.PortraitAvatar end) }
    local extra = Try(function() return pmc.AdditionalPortraitAvatars end)
    for i = 1, (extra and (Try(function() return #extra end) or 0) or 0) do models[#models + 1] = Try(function() return extra[i] end) end
    for _, m in ipairs(models) do
        if Valid(m) and AncestryOf(m) == KOBOLD_TAG and not KOBOLD[m:GetAddress()] then
            Log("portrait: the kobold goes on the portrait model %s (%s)", Name(m), why)
            local ok, err = pcall(KoboldOn, m)
            if not ok then Log("portrait kobold failed: %s", tostring(err)) end
        end
    end
end
local function HookPortraits()
    if PORTRAIT_HOOKED then return end
    PORTRAIT_HOOKED = true
    local fn = Try(function() return StaticFindObject("/Script/Brimstone.PortraitManagerComponent:OnReadyForCapture") end)
    Log("portrait: OnReadyForCapture(%s); RefreshPortrait(%s)", Valid(fn) and ParamsText(fn) or "not found",
        ParamsText(Try(function() return StaticFindObject("/Script/Brimstone.PortraitManagerComponent:RefreshPortrait") end) or {}))
    local ok, err = pcall(function()
        RegisterHook("/Script/Brimstone.PortraitManagerComponent:OnReadyForCapture", function(Context)
            local pmc = Try(function() return Context:get() end)
            if Valid(pmc) then
                pcall(KoboldPortraitModels, pmc, "ready for capture")
                local okZ, errZ = pcall(PortraitZoom, pmc, true)
                if not okZ then Log("portrait zoom failed: %s", tostring(errZ)) end
            end
        end, function(Context)
            local pmc = Try(function() return Context:get() end)
            if Valid(pmc) then
                pcall(PortraitZoom, pmc, false)
                local okA, errA = pcall(PortraitEyes, pmc)
                if not okA then Log("portrait camera failed: %s", tostring(errA)) end
            end
        end)
    end)
    if not ok then Log("portrait: hook not registered: %s", tostring(err)) end
end
local function PortraitUpkeep()
    local pmc = Try(function() return FindFirstOf("PortraitManagerComponent") end)
    if not Valid(pmc) then return end
    if not PORTRAIT_FRAMES_SET then
        local f = tonumber(Try(function() return pmc.FramesToWaitBeforeCapture end))
        if f and f < 20 then pcall(function() pmc.FramesToWaitBeforeCapture = 20 end) end
        PORTRAIT_FRAMES_SET = true
        Log("portrait: frames before capture %s -> %s", tostring(f), tostring(Try(function() return pmc.FramesToWaitBeforeCapture end)))
    end
    pcall(KoboldPortraitModels, pmc, "seen in passing")
    -- each kobold hero's portrait retaken once, a few seconds after its kobold body appeared
    for addr, st in pairs(KOBOLD) do
        if not st.preview and not RETAKEN[st.name] and st.bornAt and os.clock() - st.bornAt > 4 and st.pawn and Valid(st.pawn) and Name(st.pawn) == st.name then
            RETAKEN[st.name] = true
            local heroName = st.name:gsub("^Character_", "")
            local hero = nil
            for _, pcmp in ipairs(Try(function() return FindAllOf("PartyComponent") end) or {}) do
                local party = Try(function() return pcmp.Party end)
                for i = 1, (party and (Try(function() return #party end) or 0) or 0) do
                    local m = Try(function() return party[i] end)
                    if Valid(m) and Name(m) == heroName then hero = m end
                end
            end
            local okR, errR = false, "no party member " .. heroName
            if hero then okR, errR = pcall(function() pmc:RefreshPortrait(hero) end) end
            Log("portrait: %s retaken (%s)", heroName, okR and "asked" or ("failed: " .. tostring(errR)))
        end
    end
end
local EARLY_START = os.clock()
local earlyDone = false
Every(250, function()
    if earlyDone then return end
    local ok, err = pcall(KoboldRace)
    if not ok then Log("Kobold race failed: %s", tostring(err)) end
    if RACE_DONE then earlyDone = true; Log("Kobold race built %.1f s after the mod loaded", os.clock() - EARLY_START) end
end)
-- the race picture: the ancestry panel's AncestryImage shows the kobold portrait while the Kobold is selected
-- (the gnome's picture is a placeholder of two elves). Widgets are found afresh each time and only touched while
-- visible; nothing about them is kept.
local KOBOLD_PICTURE = "/Game/UI/Ruleset/Monsters/Humanoids/Kobold/T_UI_Kobold.T_UI_Kobold"
local PICTURE_TOP = 0.08          -- where the band shown of a picture taller than its frame starts (the head is high)
local PICTURE_LOGGED, PICTURE_CROP_LOGGED = false, false
local PICTURE = {}                -- by image widget: the game's own brush resource (its material), and whether we cropped
-- the game's picture is a material with the ancestry's texture as a parameter: its parameters, for the log (once)
local function LogPictureMaterial(m)
    local parts = {}
    for _, o in ipairs({ m, Try(function() return m.Parent end) }) do
        if Valid(o) then
            for _, arr in ipairs({ "TextureParameterValues", "ScalarParameterValues", "VectorParameterValues" }) do
                local a = Try(function() return o[arr] end)
                for i = 1, (a and (Try(function() return #a end) or 0) or 0) do
                    local e = Try(function() return a[i] end)
                    local n = e and Str(Try(function() return e.ParameterInfo.Name end)) or "?"
                    local v = e and Try(function() return e.ParameterValue end)
                    parts[#parts + 1] = string.format("%s.%s %s=%s", Name(o), arr:gsub("ParameterValues", ""), n,
                        Valid(v) and Name(v) or (type(v) == "number" and string.format("%.3f", v)) or (v and Vec(v)) or "?")
                end
            end
        end
    end
    Log("race picture: the game's picture is %s [%s]: %s", Name(m), ClassOf(m), #parts > 0 and table.concat(parts, "; ") or "no parameters read")
end
-- the part of the kobold picture shown (horns to collar, as a share of its height) and the bottom fade (a share of it)
local PICTURE_PART = { top = 0.0, bottom = 0.8, fade = 0.2 }
-- the pair: the game's ancestry pictures show two people; two kobold portraits side by side, facing each other
local KOBOLD_UI = "/Game/UI/Ruleset/Monsters/Humanoids/Kobold/"
local PICTURE_PAIR = { { name = "T_UI_Kobold", x = 0.31, mirror = false }, { name = "T_UI_KoboldSpellCaster", x = 0.69, mirror = true } }
local PANEL_COLOR = { R = 0.006, G = 0.007, B = 0.011, A = 1.0 }
local PAIR = { rt = nil, failed = false, logged = false }
local function LockPath() return KCFG.Dir() .. "Kobold_picture.lock" end
local function DrawPair(ownTex)
    local krl = Try(function() return StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary") end)
    local pc = UEHelpers.GetPlayerController()
    if not (Valid(krl) and Valid(pc)) then return nil, "no rendering library or player controller" end
    local textures = {}
    for i, e in ipairs(PICTURE_PAIR) do
        textures[i] = Load(KOBOLD_UI .. e.name .. "." .. e.name, true)
        if not textures[i] then return nil, "no " .. e.name end
    end
    if not PAIR.logged then
        PAIR.logged = true
        for _, f in ipairs({ "/Script/Engine.KismetRenderingLibrary:CreateRenderTarget2D", "/Script/Engine.KismetRenderingLibrary:BeginDrawCanvasToRenderTarget",
            "/Script/Engine.KismetRenderingLibrary:EndDrawCanvasToRenderTarget", "/Script/Engine.Canvas:K2_DrawTexture" }) do
            Log("race picture: %s(%s)", f:match("[^:]+$"), ParamsText(Try(function() return StaticFindObject(f) end) or {}))
        end
    end
    local tw = Valid(ownTex) and tonumber(Try(function() return ownTex:Blueprint_GetSizeX() end)) or 1024
    local th = Valid(ownTex) and tonumber(Try(function() return ownTex:Blueprint_GetSizeY() end)) or 480
    local W = 1024
    local H = math.max(128, math.floor(W * th / tw + 0.5))
    local f = io.open(LockPath(), "w")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S"), " drawing the kobold pair" .. string.char(10)); f:close() end
    Log("race picture: drawing the pair %s + %s into %d x %d (the game's picture is %d x %d)", PICTURE_PAIR[1].name, PICTURE_PAIR[2].name, W, H, tw, th)
    local rt = Try(function() return krl:CreateRenderTarget2D(pc, W, H, 6, PANEL_COLOR, false, false) end)
    if not Valid(rt) then os.remove(LockPath()); return nil, "no render target" end
    local cT, sT, xT = {}, {}, {}
    local okB, errB = pcall(function() krl:BeginDrawCanvasToRenderTarget(pc, rt, cT, sT, xT) end)
    local canvas = cT.Canvas
    local drawn = 0
    if okB and Valid(canvas) then
        for i, e in ipairs(PICTURE_PAIR) do
            local size = H
            local x = e.x * W - size / 2
            local u0, du = 0, 1
            if e.mirror then u0, du = 1, -1 end
            if pcall(function() canvas:K2_DrawTexture(textures[i], { X = x, Y = 0 }, { X = size, Y = size }, { X = u0, Y = 0 }, { X = du, Y = 1 },
                { R = 1, G = 1, B = 1, A = 1 }, 1, 0.0, { X = 0.5, Y = 0.5 }) end) then drawn = drawn + 1 end
        end
    end
    local okE, errE = pcall(function() krl:EndDrawCanvasToRenderTarget(pc, xT) end)
    os.remove(LockPath())
    if not (okB and Valid(canvas) and drawn == #PICTURE_PAIR) then
        return nil, string.format("drawing failed (begin %s, canvas %s, drawn %d, end %s)", okB and "ok" or tostring(errB), Name(canvas), drawn, okE and "ok" or tostring(errE))
    end
    return rt, string.format("drawn %d portraits (size %s x %s, end %s)", drawn, tostring(sT.X), tostring(sT.Y), okE and "ok" or tostring(errE))
end
local function PairPicture(ownTex)
    if PAIR.failed then return nil end
    if Valid(PAIR.rt) then return PAIR.rt end
    local lf = io.open(LockPath(), "r")
    if lf then
        lf:close()
        PAIR.failed = true
        Log("race picture: the last drawing of the pair never finished (the game stopped while drawing?): one kobold is shown instead; delete %s to try again", LockPath())
        return nil
    end
    local rt, how = DrawPair(ownTex)
    Log("race picture: the pair %s", how)
    if not rt then PAIR.failed = true; return nil end
    PAIR.rt = rt
    return rt
end
local function IsMaterial(o) return Valid(o) and ClassOf(o):find("Material", 1, true) ~= nil end
local function MatTex(m) return Try(function() return m:K2_GetTextureParameterValue(FName("PortraitTexture")) end) end
local function MatScalar(m, n) return tonumber(Try(function() return m:K2_GetScalarParameterValue(FName(n)) end)) end
-- the brush's UV region: through the game's material, the part shown at its own shape and centred (the material
-- fades the picture's edges to nothing, so the margins stay clear) with the bottom fade moved up to the part's
-- bottom; on a plain image, a band of the full width (nothing outside the texture may show there)
local function CropPicture(img, tex, mid, ownTex)
    local tw = tonumber(Try(function() return tex:Blueprint_GetSizeX() end))
    local th = tonumber(Try(function() return tex:Blueprint_GetSizeY() end))
    local geo = Try(function() return img:GetCachedGeometry() end)
    local sbl = Try(function() return StaticFindObject("/Script/UMG.Default__SlateBlueprintLibrary") end)
    local size = geo and Valid(sbl) and Try(function() return sbl:GetLocalSize(geo) end)
    local ww, wh = size and tonumber(Try(function() return size.X end)), size and tonumber(Try(function() return size.Y end))
    if not (ww and wh and ww > 1 and wh > 1) and Valid(ownTex) then  -- no size from the widget: the game's own picture fits the frame
        ww = tonumber(Try(function() return ownTex:Blueprint_GetSizeX() end)); wh = tonumber(Try(function() return ownTex:Blueprint_GetSizeY() end))
    end
    if not (tw and th and ww and wh and tw > 0 and th > 0 and ww > 1 and wh > 1) then
        return false, string.format("sizes not known yet (texture %s x %s, frame %s x %s)", tostring(tw), tostring(th), tostring(ww), tostring(wh))
    end
    local ta, wa = tw / th, ww / wh
    local u0, v0, u1, v1
    local fades = ""
    if mid then
        v0, v1 = PICTURE_PART.top, PICTURE_PART.bottom
        local w = (v1 - v0) * wa / ta                   -- the UV width that keeps the picture's shape
        u0 = (1 - w) / 2; u1 = u0 + w
        local b0, b1 = 1 - v1, 1 - v1 + PICTURE_PART.fade * (v1 - v0)
        local okF = pcall(function()
            mid:SetScalarParameterValue(FName("BottomAlpha0Offset"), b0)
            mid:SetScalarParameterValue(FName("BottomAlpha1Offset"), b1)
        end)
        fades = string.format("; bottom fade %.2f..%.2f (%s, reads %s..%s)", b0, b1, okF and "set" or "FAILED",
            tostring(MatScalar(mid, "BottomAlpha0Offset")), tostring(MatScalar(mid, "BottomAlpha1Offset")))
    else
        u0, u1, v0, v1 = 0, 1, 0, 1
        if wa > ta then local h = ta / wa; v0 = math.min(0.08, 1 - h); v1 = v0 + h
        elseif wa < ta then local w = wa / ta; u0 = (1 - w) / 2; u1 = u0 + w end
    end
    local ok, err = pcall(function()
        local r = img.Brush.UVRegion
        r.Min.X = u0; r.Min.Y = v0; r.Max.X = u1; r.Max.Y = v1
        r.bIsValid = true
    end)
    pcall(function() img:InvalidateLayoutAndVolatility() end)
    local back = Try(function() return img.Brush.UVRegion.bIsValid end)
    return ok and back == true, string.format("%s, texture %d x %d, frame %.0f x %.0f: UV %.2f,%.2f - %.2f,%.2f (%s)%s", mid and "through the material" or "plain image",
        tw, th, ww, wh, u0, v0, u1, v1, ok and ("region valid " .. tostring(back)) or ("failed: " .. tostring(err)), fades)
end
local function RacePicture()
    for _, panel in ipairs(Try(function() return FindAllOf("CharacterAdvancedPanelSelectorAncestry") end) or {}) do
        if Valid(panel) and not panel:GetFullName():find("Default__", 1, true) and Try(function() return panel:IsVisible() end) == true then
            local tag = Try(function() return panel.SelectedOptionTag.TagName:ToString() end)
            local img = Try(function() return panel.AncestryImage end)
            local tex = Load(KOBOLD_PICTURE, true)
            if Valid(img) and tex then
                local ia = img:GetAddress()
                local pic = PICTURE[ia]
                local cur = Try(function() return img.Brush.ResourceObject end)
                local mid = IsMaterial(cur) and cur or nil
                local showingOurs = Valid(cur) and cur:GetAddress() == tex:GetAddress()
                if tag == "Ruleset.Ancestry.Gnome" then
                    if not pic then pic = {}; PICTURE[ia] = pic end
                    local pair = nil
                    if mid then
                        -- the game's material: its picture becomes the kobold pair (or one kobold), set again whenever
                        -- the game puts its own back
                        pic.mid = mid
                        local t = MatTex(mid)
                        local ours = Valid(t) and (t:GetAddress() == tex:GetAddress() or (Valid(PAIR.rt) and t:GetAddress() == PAIR.rt:GetAddress()))
                        if Valid(t) and not ours then pic.ownTex = t end
                        if pic.b0 == nil then pic.b0, pic.b1 = MatScalar(mid, "BottomAlpha0Offset"), MatScalar(mid, "BottomAlpha1Offset") end
                        pair = PairPicture(pic.ownTex)
                        local want = pair or tex
                        if not (Valid(t) and t:GetAddress() == want:GetAddress()) then
                            if not PICTURE_LOGGED then pcall(LogPictureMaterial, mid) end
                            local ok, err = pcall(function() mid:SetTextureParameterValue(FName("PortraitTexture"), want) end)
                            pic.cropped = false
                            if not PICTURE_LOGGED then
                                PICTURE_LOGGED = true
                                Log("race picture: %s's material %s shows %s instead of %s (%s; reads %s)", Name(img), Name(mid), Name(want), Name(t),
                                    ok and "set" or ("failed: " .. tostring(err)), Name(MatTex(mid)))
                            end
                        end
                    elseif not showingOurs then
                        -- a plain image: the kobold texture as its brush
                        if Valid(cur) then pic.own = cur end
                        local ok, err = pcall(function() img:SetBrushFromTexture(tex, false) end)
                        pic.cropped = false
                        if not PICTURE_LOGGED then
                            PICTURE_LOGGED = true
                            Log("race picture: %s [%s] %s -> %s (%s)", Name(img), ClassOf(img), Name(cur), Name(tex), ok and "set" or ("failed: " .. tostring(err)))
                        end
                    end
                    if pair then
                        -- the pair is made at the frame's shape: the whole of it, with the game's own fades
                        if not pic.cropped then
                            pcall(function() img.Brush.UVRegion.bIsValid = false end)
                            if pic.b0 then pcall(function() mid:SetScalarParameterValue(FName("BottomAlpha0Offset"), pic.b0) end) end
                            if pic.b1 then pcall(function() mid:SetScalarParameterValue(FName("BottomAlpha1Offset"), pic.b1) end) end
                            pic.cropped = true
                            if not PICTURE_CROP_LOGGED then PICTURE_CROP_LOGGED = true; Log("race picture: the kobold pair is shown whole") end
                        end
                    elseif not pic.cropped or Try(function() return img.Brush.UVRegion.bIsValid end) ~= true then
                        local done, how = CropPicture(img, tex, mid, pic.ownTex)
                        if done then pic.cropped = true end
                        if done or not pic.notYet then
                            pic.notYet = true
                            Log("race picture cropped%s: %s", done and "" or " (not yet)", how)
                        end
                    end
                elseif pic then
                    -- another ancestry: the game's own picture back, whole, with its own fades
                    pcall(function() img.Brush.UVRegion.bIsValid = false end)
                    local m = pic.mid
                    if Valid(m) then
                        if pic.b0 then pcall(function() m:SetScalarParameterValue(FName("BottomAlpha0Offset"), pic.b0) end) end
                        if pic.b1 then pcall(function() m:SetScalarParameterValue(FName("BottomAlpha1Offset"), pic.b1) end) end
                        local t = MatTex(m)                 -- the game sets the new ancestry's picture itself; only ours is undone
                        local ours = Valid(t) and (t:GetAddress() == tex:GetAddress() or (Valid(PAIR.rt) and t:GetAddress() == PAIR.rt:GetAddress()))
                        if ours and Valid(pic.ownTex) then
                            pcall(function() m:SetTextureParameterValue(FName("PortraitTexture"), pic.ownTex) end)
                        end
                    end
                    if showingOurs and Valid(pic.own) then pcall(function() img:SetBrushFromMaterial(pic.own) end) end
                    Log("race picture: %s picked, the game's picture is back (%s)", tostring(tag), Valid(m) and Name(MatTex(m)) or Name(pic.own))
                    PICTURE[ia] = nil
                end
            end
        end
    end
end
Every(500, function()
    if RACE_DONE then
        local ok, err = pcall(RacePicture)
        if not ok and not PICTURE_ERROR then PICTURE_ERROR = true; Log("race picture failed: %s", tostring(err)) end
    end
end)
local raceTicks = 0
Every(1000, function()
    raceTicks = raceTicks + 1
    if raceTicks % 10 == 5 then pcall(KeepKoboldDefinitions) end
    if raceTicks % 10 == 0 and earlyDone then
        local ok, err = pcall(KoboldRace)
        if not ok then Log("Kobold race failed: %s", tostring(err)) end
    end
    if raceTicks == 3 then pcall(HookPortraits) end
    if raceTicks == 6 and KCFG.Lab then
        local okP, errP = pcall(LogPowerSetups)
        if not okP then Log("power setup log failed: %s", tostring(errP)) end
    end
    if raceTicks >= 5 then
        local okP, errP = pcall(PortraitUpkeep)
        if not okP then Log("portrait upkeep failed: %s", tostring(errP)) end
        local ok, err = pcall(AutoKobold)
        if not ok then Log("auto kobold failed: %s", tostring(err)) end
    end
end)

--------------------------------------------------------------------------------------------------
-- the studio: the game's own takes recorded through its audio mixer (Ctrl+Shift+U starts and stops)
--------------------------------------------------------------------------------------------------
local STUDIO = { on = false, queue = nil, idx = 0, phase = "idle", t0 = 0, comp = nil, cur = nil, made = 0,
    lib = nil, gs = nil, submix = nil, class = nil, master = false, checked = false, abs = nil }
function STUDIO.Dir()
    if STUDIO.abs then return STUDIO.abs end
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local proj = Str(Try(function() return ksl:GetProjectDirectory() end))
    if proj and #proj > 0 then STUDIO.abs = proj .. "Binaries/Win64/Kobold_studio" end
    return STUDIO.abs
end
function STUDIO.Wav(name) return STUDIO.Dir() .. "/" .. name .. ".wav" end
function STUDIO.Exists(name)
    local f = io.open(STUDIO.Wav(name), "rb")
    if f then f:close(); return true end
    return false
end
function STUDIO.Load()
    local q, f = {}, io.open(STUDIO.Dir() .. "/queue.txt", "r")
    if not f then return nil end
    for raw in f:lines() do
        local path, secs = raw:match("^(%S+)%s+([%d%.]+)")
        if path then q[#q + 1] = { path = path, name = path:match("([^%.]+)$"), secs = tonumber(secs) or 5 } end
    end
    f:close()
    return q
end
function STUDIO.Rms(path)                         -- the RMS (0..1) of a 16-bit WAV, every 4th sample
    local f = io.open(path, "rb")
    if not f then return nil end
    local b = f:read("*a"); f:close()
    local p = b:find("data", 13, true)
    if not p then return nil end
    local n = string.unpack("<I4", b, p + 4)
    local sum, cnt, i, last = 0.0, 0, p + 8, math.min(#b - 1, p + 8 + n - 2)
    while i <= last do local v = string.unpack("<i2", b, i); sum = sum + v * v; cnt = cnt + 1; i = i + 8 end
    return cnt > 0 and math.sqrt(sum / cnt) / 32768 or 0
end
function STUDIO.Toggle()
    if STUDIO.on then
        STUDIO.on = false
        if STUDIO.phase ~= "idle" then
            pcall(function() if Valid(STUDIO.comp) then STUDIO.comp:Stop() end end)
            pcall(function() STUDIO.lib:StopRecordingOutput(UEHelpers.GetPlayerController(), 0, "discard", "", STUDIO.submix, nil) end)
        end
        STUDIO.phase = "idle"
        Log("studio: stopped; %d takes recorded this time, %d of %d in all", STUDIO.made, STUDIO.idx, STUDIO.queue and #STUDIO.queue or 0)
        return
    end
    if not STUDIO.Dir() then Log("studio: the game's folder was not found"); return end
    STUDIO.queue = STUDIO.Load()
    if not STUDIO.queue or #STUDIO.queue == 0 then Log("studio: nothing to record (%s/queue.txt)", STUDIO.Dir()); return end
    STUDIO.lib = StaticFindObject("/Script/AudioMixer.Default__AudioMixerBlueprintLibrary")
    STUDIO.gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if not Valid(STUDIO.lib) or not Valid(STUDIO.gs) then Log("studio: the audio libraries were not found"); return end
    if not STUDIO.master then
        STUDIO.submix = Try(function() return LoadAsset("/Game/Audio/Mix/Submix/SM_VOICES_CS.SM_VOICES_CS") end)
        STUDIO.class = Try(function() return LoadAsset("/Game/Audio/Mix/SoundClass/SC_VOICES_CS.SC_VOICES_CS") end)
        if not Valid(STUDIO.submix) then STUDIO.submix = nil; STUDIO.master = true end
    end
    STUDIO.idx, STUDIO.made, STUDIO.phase, STUDIO.on = 0, 0, "idle", true
    local _, o, v = KVOL.GameVolume()
    Log("studio: %d takes listed; recording %s into %s (the game's master volume %s, voice %s)", #STUDIO.queue,
        STUDIO.master and "the master mix" or "the cutscene voice submix", STUDIO.Dir(), KVOL.Dec3(o), KVOL.Dec3(v))
end
function STUDIO.Tick()
    if not STUDIO.on then return end
    local now = os.clock()
    local pc = UEHelpers.GetPlayerController()
    if STUDIO.phase == "idle" then
        while STUDIO.idx < #STUDIO.queue and STUDIO.Exists(STUDIO.queue[STUDIO.idx + 1].name) do STUDIO.idx = STUDIO.idx + 1 end
        if STUDIO.idx >= #STUDIO.queue then
            STUDIO.on = false
            Log("studio: all %d takes are recorded (%d this time)", #STUDIO.queue, STUDIO.made)
            return
        end
        local q = STUDIO.queue[STUDIO.idx + 1]
        local snd = Try(function() return LoadAsset(q.path) end)
        if not Valid(snd) then
            STUDIO.misses = (STUDIO.misses or 0) + 1
            Log("studio: %s could not be loaded; skipped", q.name)
            STUDIO.idx = STUDIO.idx + 1
            if STUDIO.misses >= 3 then STUDIO.on = false; Log("studio: the campaign's voice files are not loaded here - load a save, then Ctrl+Shift+U"); STUDIO.idx = 0 end
            return
        end
        STUDIO.misses = 0
        local ok, err = pcall(function() STUDIO.lib:StartRecordingOutput(pc, q.secs + 2.0, STUDIO.submix) end)
        if not ok then STUDIO.on = false; Log("studio: the recorder did not start (%s); stopped", tostring(err)); return end
        local comp = Try(function() return STUDIO.gs:CreateSound2D(pc, snd, 1.0, 1.0, 0.0, nil, false, true) end)
        if not Valid(comp) then Log("studio: %s could not be played; skipped", q.name); STUDIO.idx = STUDIO.idx + 1; STUDIO.phase = "tail"; STUDIO.t0 = now; STUDIO.cur = nil; return end
        pcall(function() comp.bIsUISound = true end)                       -- plays on in the pause menu
        if Valid(STUDIO.class) then pcall(function() comp.SoundClassOverride = STUDIO.class end) end
        pcall(function() comp:Play(0.0) end)
        STUDIO.comp, STUDIO.cur, STUDIO.phase, STUDIO.t0 = comp, q, "playing", now
    elseif STUDIO.phase == "playing" then
        local playing = Valid(STUDIO.comp) and Try(function() return STUDIO.comp:IsPlaying() end) == true
        -- the game keeps saying the sound plays for seconds after a take ends: its own length decides (+0.6 s)
        if (not playing and now - STUDIO.t0 > 0.4) or now - STUDIO.t0 > STUDIO.cur.secs + 0.6 then STUDIO.phase, STUDIO.t0 = "tail", now end
    elseif STUDIO.phase == "tail" then                                  -- a little room after the take, then the file
        if now - STUDIO.t0 > 0.3 then
            local name = STUDIO.cur and STUDIO.cur.name or "discard"
            local ok, err = pcall(function() STUDIO.lib:StopRecordingOutput(pc, STUDIO.cur and 1 or 0, name, STUDIO.cur and STUDIO.Dir() or "", STUDIO.submix, nil) end)
            if not ok then STUDIO.on = false; Log("studio: the recorder did not stop (%s); stopped", tostring(err)); return end
            STUDIO.phase, STUDIO.t0 = STUDIO.cur and "write" or "idle", now
        end
    elseif STUDIO.phase == "write" then                                 -- the file is written on a worker thread
        local name = STUDIO.cur.name
        if STUDIO.Exists(name) and now - STUDIO.t0 > 0.4 then
            if not STUDIO.checked then                                  -- the first file: did the take reach that submix?
                local rms = STUDIO.Rms(STUDIO.Wav(name)) or 0
                Log("studio: the first take's level is %.4f (%s)", rms, STUDIO.master and "master mix" or "cutscene voice submix")
                if rms < 0.0005 then
                    os.remove(STUDIO.Wav(name))
                    if STUDIO.master then STUDIO.on = false; Log("studio: the recording is silent; stopped"); return end
                    STUDIO.master, STUDIO.submix = true, nil
                    Log("studio: nothing reached the cutscene voice submix; recording the master mix instead (music and ambience down helps)")
                    STUDIO.phase = "idle"
                    return
                end
                STUDIO.checked = true
            end
            STUDIO.made, STUDIO.idx, STUDIO.phase = STUDIO.made + 1, STUDIO.idx + 1, "idle"
            Log("studio: %d/%d %s (%.2f s)", STUDIO.idx, #STUDIO.queue, name, STUDIO.cur.secs)
        elseif now - STUDIO.t0 > 5 then
            STUDIO.on = false
            Log("studio: no file came out for %s (the recorder may not write files in this build); stopped", name)
        end
    end
end
Every(100, function()
    local ok, err = pcall(STUDIO.Tick)
    if not ok then STUDIO.on = false; Log("studio failed: %s", tostring(err)) end
end)
function StudioToggle() STUDIO.Toggle() end

--------------------------------------------------------------------------------------------------
-- keys: the input thread only sets flags; the game thread acts
--------------------------------------------------------------------------------------------------
local PRESSED = { dump = false, on = false, off = false, anatomy = false, zoom = false, kquieter = false, klouder = false, studio = false }
if KCFG.Lab then RegisterKeyBind(Key.U, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.studio = true end) end
if Key.OEM_COMMA and Key.OEM_PERIOD then               -- the , and . keys (< >): the kobold voice level ([ ] would reach the console key)
    RegisterKeyBind(Key.OEM_COMMA, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.kquieter = true end)
    RegisterKeyBind(Key.OEM_PERIOD, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.klouder = true end)
else
    Log("kobold voice: no , . keys in this UE4SS; the level is Kobold.ini's")
end
if KCFG.Lab then                                         -- the developer keys
    RegisterKeyBind(Key.P, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.zoom = true end)
    RegisterKeyBind(Key.H, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.anatomy = true end)
    RegisterKeyBind(Key.J, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.dump = true end)
    RegisterKeyBind(Key.K, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.on = true end)
    RegisterKeyBind(Key.L, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.off = true end)
end
Every(100, function()
    if PRESSED.studio then
        PRESSED.studio = false
        local ok, err = pcall(StudioToggle)
        if not ok then Log("studio toggle failed: %s", tostring(err)) end
    end
    if PRESSED.kquieter or PRESSED.klouder then
        local up = PRESSED.klouder
        PRESSED.kquieter, PRESSED.klouder = false, false
        local ok, err = pcall(KoboldGainStep, up)
        if not ok then Log("kobold voice level failed: %s", tostring(err)) end
    end
    if PRESSED.dump then PRESSED.dump = false; local ok, err = pcall(Dump); if not ok then Log("dump failed: %s", tostring(err)) end end
    if PRESSED.anatomy then PRESSED.anatomy = false; local ok, err = pcall(Anatomy); if not ok then Log("anatomy failed: %s", tostring(err)) end end
    if PRESSED.zoom then
        PRESSED.zoom = false
        local nextZ = ZOOMS[1]
        for i, z in ipairs(ZOOMS) do if math.abs(z - PORTRAIT_ZOOM) < 0.01 then nextZ = ZOOMS[i % #ZOOMS + 1] end end
        PORTRAIT_ZOOM = nextZ
        RETAKEN = {}
        Log("Ctrl+Shift+P: the portrait camera distance x%.1f; the kobold portraits are retaken", PORTRAIT_ZOOM)
    end
    if PRESSED.on then
        PRESSED.on = false
        local pawn = CurrentPawn()
        if pawn then local ok, err = pcall(KoboldOn, pawn); if not ok then Log("kobold failed: %s", tostring(err)) end
        else Log("no hero is selected") end
    end
    if PRESSED.off then
        PRESSED.off = false
        local pawn = CurrentPawn()
        if pawn and KOBOLD[pawn:GetAddress()] then
            local ok, err = pcall(KoboldOff, pawn); if not ok then Log("undo failed: %s", tostring(err)) end
        else
            local n = 0
            for addr, st in pairs(KOBOLD) do
                local p = st.pawn
                if p and Valid(p) and Name(p) == st.name then
                    n = n + 1
                    local ok, err = pcall(KoboldOff, p); if not ok then Log("undo failed: %s", tostring(err)) end
                end
            end
            if n == 0 then Log("no kobold to turn back") end
        end
    end
end)

Log("loaded: Ctrl+Shift+, and . the kobold voice level%s", KCFG.Lab and "; developer keys: Ctrl+Shift+J dump, H anatomy, K / L kobold on / off, P portrait distance, U the studio" or "")
