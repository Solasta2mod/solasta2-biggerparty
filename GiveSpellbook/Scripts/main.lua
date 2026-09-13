-- GiveSpellbook — Solasta II (Brimstone) UE4SS Lua mod
--
-- Works around the multiplayer bug where multiclassing into Wizard doesn't grant the
-- spellbook: builds a Wizard spellbook with the game's own item factory and grants it
-- into the character's bag with spellcasting enabled.
--
-- Must run on the HOST (or in single player) — item creation is server-authoritative and
-- the game has no client->server RPC for it. The book then replicates to the client.
--
-- Hotkeys:
--   Ctrl+Backspace        report: lists every hero and whether the game thinks they're missing a spellbook
--   Ctrl+Delete         grant: gives a spellbook to every hero whose spellcasting reports "missing required spellbook"
--   Ctrl+Shift+Delete   force: gives a spellbook to EVERY hero that has no Wizard spellbook (use if Ctrl+Delete finds nobody)
--
-- Built against game build CL-112340 (2026-09-10). Signatures below were recovered from the shipped PDB:
--   UItemBuildingComponent::CreateItem(ItemTag, ItemLocation, OptionalSource, bForceIdentify,
--       bAutoRecreateOnLoad, ExplicitCount, ExplicitCharges, bPreviewItem, RulesetActorScope) -> ARulesetActor*
--   UCharacterInventoryComponent::GrantItem(ItemActor, bCheckWeight, bAutoEquip, bRefresh, bSilent, bCanStack,
--       bEnforceAbilityConstraints, bCanReplaceEquipped, bEnableSpellcasting, bSkipUpdateItemOwnershipKnowledge,
--       bSilentOnFailure)
--   UHeroInventoryComponent::FindSpellbookWithTag(SpellcastingTag, bCheckStash) -> ARulesetActor*
--   UMagicUseComponent::IsMissingRequiredSpellbook() -> bool

local CFG = {
    SPELLBOOK_ITEM_TAG    = "Equipment.Spellbook.Wizard",   -- DA_IT_WizardSpellbook
    LOCATION_TAG          = "ItemLocation.Carried",
    SPELLCASTING_TAG      = "Ruleset.SpellCasting.Wizard",
    -- ERulesetActorScope: None=0, Default=1, DefaultSkipRegistration=2, Transient=3, EditionLocal=4
    SCOPE                 = 1,
    -- If the book vanishes after save+load, flip this to true and grant again.
    AUTO_RECREATE_ON_LOAD = false,
}

local function Log(fmt, ...)
    print(string.format("[GiveSpellbook] " .. fmt .. "\n", ...))
end

-- FGameplayTag is a struct with a single FName field; UE4SS accepts a table for struct params.
local function Tag(name)
    return { TagName = FName(name) }
end

local function IsInstance(obj)
    return obj and obj:IsValid() and not obj:GetFullName():find("Default__", 1, true)
end

-- Live (non-CDO) components of a class, keyed by owner full name.
local function ComponentsByOwner(className)
    local out = {}
    for _, comp in ipairs(FindAllOf(className) or {}) do
        if IsInstance(comp) then
            local owner = comp:GetOwner()
            if owner:IsValid() then out[owner:GetFullName()] = comp end
        end
    end
    return out
end

local function FindItemBuilder()
    for _, comp in ipairs(FindAllOf("ItemBuildingComponent") or {}) do
        if IsInstance(comp) then
            local owner = comp:GetOwner()
            if owner:IsValid() and owner:HasAuthority() then return comp end
        end
    end
    return nil
end

local function ShortName(fullName)
    return fullName:match("([^%.:]+)$") or fullName
end

-- Returns a list of { name=, inv=, magic=, missing=bool|nil, hasBook=bool }
local function SurveyHeroes()
    local heroes = {}
    local magics = ComponentsByOwner("MagicUseComponent")
    for ownerName, inv in pairs(ComponentsByOwner("HeroInventoryComponent")) do
        local magic = magics[ownerName]
        local missing = nil
        if magic then
            local ok, res = pcall(function() return magic:IsMissingRequiredSpellbook() end)
            if ok then missing = res else Log("IsMissingRequiredSpellbook failed for %s: %s", ShortName(ownerName), tostring(res)) end
        end
        local hasBook = false
        local ok, book = pcall(function() return inv:FindSpellbookWithTag(Tag(CFG.SPELLCASTING_TAG), true) end)
        if ok then hasBook = book ~= nil and book:IsValid() else Log("FindSpellbookWithTag failed for %s: %s", ShortName(ownerName), tostring(book)) end
        table.insert(heroes, { name = ownerName, inv = inv, magic = magic, missing = missing, hasBook = hasBook })
    end
    table.sort(heroes, function(a, b) return a.name < b.name end)
    return heroes
end

local function GrantTo(hero)
    local owner = hero.inv:GetOwner()
    if not owner:HasAuthority() then
        Log("SKIP %s — no authority here. This must run on the host (or in single player).", ShortName(hero.name))
        return false
    end
    local builder = FindItemBuilder()
    if not builder then
        Log("No ItemBuildingComponent instance found — are you in a loaded game?")
        return false
    end

    local function Create(source)
        return builder:CreateItem(
            Tag(CFG.SPELLBOOK_ITEM_TAG),   -- ItemTag
            Tag(CFG.LOCATION_TAG),         -- ItemLocation
            source,                        -- OptionalSource
            true,                          -- bForceIdentify
            CFG.AUTO_RECREATE_ON_LOAD,     -- bAutoRecreateOnLoad
            1,                             -- ExplicitCount
            1,                             -- ExplicitCharges (ignored for a book)
            false,                         -- bPreviewItem
            CFG.SCOPE)                     -- RulesetActorScope
    end
    -- Try with no source first; if UE4SS refuses nil for the object param, retry with the hero as source.
    local ok, item = pcall(Create, nil)
    if not ok then
        Log("CreateItem(nil source) threw: %s — retrying with the hero as OptionalSource", tostring(item))
        ok, item = pcall(Create, owner)
    end
    if not ok then Log("CreateItem threw: %s", tostring(item)) return false end
    if not (item and item:IsValid()) then Log("CreateItem returned nothing for %s", CFG.SPELLBOOK_ITEM_TAG) return false end
    Log("created %s", item:GetFullName())

    local ok2, err = pcall(function()
        hero.inv:GrantItem(
            item,
            false,   -- bCheckWeight
            false,   -- bAutoEquip
            true,    -- bRefresh
            false,   -- bSilent
            false,   -- bCanStack
            false,   -- bEnforceAbilityConstraints
            false,   -- bCanReplaceEquipped
            true,    -- bEnableSpellcasting   <- hooks the book up to the wizard's spellcasting
            false,   -- bSkipUpdateItemOwnershipKnowledge
            false)   -- bSilentOnFailure
    end)
    if not ok2 then Log("GrantItem threw: %s", tostring(err)) return false end

    local still = hero.magic and hero.magic:IsMissingRequiredSpellbook()
    Log("granted spellbook to %s — still missing required spellbook: %s", ShortName(hero.name), tostring(still))
    return true
end

local function Report()
    local heroes = SurveyHeroes()
    if #heroes == 0 then Log("no heroes found — load into a game first") return end
    local builder = FindItemBuilder()
    Log("ItemBuildingComponent: %s", builder and builder:GetFullName() or "NOT FOUND")
    for _, h in ipairs(heroes) do
        Log("%-28s authority=%s missingRequiredSpellbook=%s hasWizardSpellbook=%s",
            ShortName(h.name), tostring(h.inv:GetOwner():HasAuthority()), tostring(h.missing), tostring(h.hasBook))
    end
end

local function Grant(force)
    local heroes = SurveyHeroes()
    if #heroes == 0 then Log("no heroes found — load into a game first") return end
    local n = 0
    for _, h in ipairs(heroes) do
        local wants = force and (not h.hasBook) or (h.missing == true)
        if wants then
            if GrantTo(h) then n = n + 1 end
        end
    end
    if n == 0 then
        Log(force and "force: every hero already has a Wizard spellbook"
                  or "nobody reports a missing spellbook (try Ctrl+Backspace for the report, or Ctrl+Shift+Delete to force)")
    else
        Log("done — %d spellbook(s) granted. Save, reload, and confirm the book is still there.", n)
    end
end

RegisterKeyBind(Key.BACKSPACE, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(Report)
end)
RegisterKeyBind(Key.DEL, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function() Grant(false) end)
end)
RegisterKeyBind(Key.DEL, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    ExecuteInGameThread(function() Grant(true) end)
end)

-- Sanity check that the functions we depend on exist in this game build.
for _, path in ipairs({
    "/Script/Brimstone.ItemBuildingComponent:CreateItem",
    "/Script/Brimstone.CharacterInventoryComponent:GrantItem",
    "/Script/Brimstone.HeroInventoryComponent:FindSpellbookWithTag",
    "/Script/Brimstone.MagicUseComponent:IsMissingRequiredSpellbook",
}) do
    local fn = StaticFindObject(path)
    Log("%s %s", (fn and fn:IsValid()) and "OK  " or "MISSING", path)
end
Log("loaded — Ctrl+Backspace report, Ctrl+Delete grant, Ctrl+Shift+Delete force")
