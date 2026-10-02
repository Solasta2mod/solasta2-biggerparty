-- Narrator - Solasta II (Brimstone), UE4SS.
--
-- World events are text only. This mod reads the event's story text as the game types it out and hands
-- each completed sentence to a companion program (Narrator/SolastaNarrator.exe next to the game exe) through a
-- queue file (Narrator/queue.txt, one JSON line per utterance). The companion plays the recorded voice pack
-- (Narrator/pack) for them; a line without a recording is not read. Titles, options, the choice made and the
-- rewards are deliberately not narrated.
--
--   Ctrl+Shift+M        mute / unmute (saved to Narrator/narrator.ini)
--   Ctrl+Shift+= / -    volume up / down
--
-- Everything runs on the game thread (see BiggerParty's docs/internals.md on UE4SS threads).

local TAG = "[Narrator] "
local function Out(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end
local function Try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end; return nil end
local function Str(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and s or nil
end
local function ShortName(full) return full:match("([^%.:]+)$") or full end
local function ClassName(o) local ok, s = pcall(function() return o:GetClass():GetFullName() end); return ok and (s:match("([^%.]+)$") or s) or "?" end

-- game-thread scheduling only (see BiggerParty's notes on UE4SS threads)
local function After(ms, fn)
    if ExecuteInGameThreadWithDelay then ExecuteInGameThreadWithDelay(ms, function() pcall(fn) end)
    else ExecuteWithDelay(ms, function() ExecuteInGameThread(function() pcall(fn) end) end) end
end

-- the queue file lives next to the game exe (the ini lookup BiggerParty uses, same folder)
local QUEUE = nil
local function QueuePath()
    if QUEUE then return QUEUE end
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local proj = Str(Try(function() return ksl:GetProjectDirectory() end))
    if proj and #proj > 0 then
        local bpl = StaticFindObject("/Script/Engine.Default__BlueprintPathsLibrary")
        local full = Str(Try(function() return bpl:ConvertRelativePathToFull(proj, "") end))
        QUEUE = (full or proj) .. "Binaries/Win64/Narrator/queue.txt"
    else
        QUEUE = "Narrator/queue.txt"
    end
    return QUEUE
end
local SEQ = 0
local function Say(kind, text)
    if not text or text == "" then return end
    text = text:gsub("<[^>]->", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")   -- rich text tags out, whitespace collapsed
    SEQ = SEQ + 1
    Out("%s: %s", kind, text)
    local f = io.open(QueuePath(), "a")
    if f then
        local esc = text:gsub("\\", "\\\\"):gsub('"', '\\"')
        f:write(string.format('{"seq":%d,"kind":"%s","text":"%s"}\n', SEQ, kind, esc)); f:close()
    end
end
local function Stop()
    local f = io.open(QueuePath(), "a")
    if f then f:write('{"kind":"stop"}\n'); f:close() end
end
-- the opening of a first sentence still being typed: lets the companion start a recorded passage early
-- (never spoken by itself; the companion only uses it to find a recording)
local function Probe(kind, text)
    text = text:gsub("<[^>]*$", ""):gsub("<[^>]->", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local f = io.open(QueuePath(), "a")
    if f then
        local esc = text:gsub("\\", "\\\\"):gsub('"', '\\"')
        f:write(string.format('{"kind":"probe","for":"%s","text":"%s"}\n', kind, esc)); f:close()
    end
end

-- reward lines are not narrated: experience, items, gold and the like
-- roll results the game prints in front of an outcome (never narrated); longest first so "Critical Success"
-- is taken whole
local RESULT_WORDS = { "Ability Check Success", "Ability Check Failure", "Group Check Success", "Group Check Failure",
    "Critical Success", "Critical Failure", "Auto Success", "Success", "Failure", "Failed", "Fail" }
local function IsReward(text)
    local t = text:lower()
    if t:match("^each party member") or t:match("^the party ") or t:match("^the whole party ") or t:match("^your party ") then return true end
    if t:match("%d+%s*xp") or t:match("%(×%d+%)") or t:match("%(x%d+%)") then return true end
    if t:match(" gold%.?$") or t:match(" gold pieces") or t:match("treasury") then return true end
    if t:match("^[%w' ]- gains ") or t:match("^[%w' ]- loses ") or t:match("^[%w' ]- receives ") or t:match("^[%w' ]- learns ") then return true end
    return false
end

-- every text block inside a widget, in tree order (tags kept, for the outcome lines)
local function RawTexts(root, out, depth)
    depth = depth or 0
    if depth > 30 or not (root and root:IsValid()) then return end
    local cn = ClassName(root)
    if cn:match("TextBlock") or cn:match("RichText") then
        local t = Str(Try(function() return root:GetText() end))
        if t and t ~= "" then out[#out + 1] = t end
    end
    local tree = Try(function() return root.WidgetTree end)
    local rootW = tree and tree:IsValid() and Try(function() return tree.RootWidget end)
    if rootW and rootW:IsValid() then RawTexts(rootW, out, depth + 1) return end
    local n = Try(function() return root:GetChildrenCount() end)
    if n then
        for i = 0, n - 1 do local c = Try(function() return root:GetChildAt(i) end); if c then RawTexts(c, out, depth + 1) end end
    else
        local c = Try(function() return root:GetContent() end); if c then RawTexts(c, out, depth + 1) end
    end
end

-- every text block inside a widget, in tree order
local function Texts(root, out, depth)
    depth = depth or 0
    if depth > 30 or not (root and root:IsValid()) then return end
    local cn = ClassName(root)
    if cn:match("TextBlock") or cn:match("RichText") then
        local t = Str(Try(function() return root:GetText() end))
        if t and t ~= "" then out[#out + 1] = t end
    end
    local tree = Try(function() return root.WidgetTree end)
    local rootW = tree and tree:IsValid() and Try(function() return tree.RootWidget end)
    if rootW and rootW:IsValid() then Texts(rootW, out, depth + 1) return end
    local n = Try(function() return root:GetChildrenCount() end)
    if n then
        for i = 0, n - 1 do local c = Try(function() return root:GetChildAt(i) end); if c then Texts(c, out, depth + 1) end end
    else
        local c = Try(function() return root:GetContent() end); if c then Texts(c, out, depth + 1) end
    end
end

-- The screen's own functions (Bind, AddOutcomeMessage, ShowResponses, Terminate) are called from C++ and
-- never pass through the event dispatcher, so hooks on them do not fire. Instead: while a world event
-- screen is visible, read its text blocks four times a second and speak whatever is new, in order.
local function Instances(className)
    local out = {}
    local ok, found = pcall(FindAllOf, className)
    for _, o in ipairs((ok and found) or {}) do
        if o and o:IsValid() and not o:GetFullName():find("Default__", 1, true) then out[#out + 1] = o end
    end
    return out
end
-- direct children of a panel widget
local function Children(panel)
    local out = {}
    local n = Try(function() return panel:GetChildrenCount() end) or 0
    for i = 0, n - 1 do local c = Try(function() return panel:GetChildAt(i) end); if c and c:IsValid() then out[#out + 1] = c end end
    return out
end
-- The game types text out letter by letter. Every text on the screen (the description, each outcome line)
-- is a stream: a sentence is spoken as soon as it is complete, the rest once the text has stopped changing
local STABLE_POLLS = 4          -- four polls at 250 ms: a second without change
local SCREEN_SEEN = nil
local STREAMS = {}              -- slot -> { last, stable, spoken, done, muted }
local CHOSEN = {}               -- outcome slots already counted as a newly chosen option on this screen
-- Markup out (the description blocks are rich text: a credit line comes as a styled run), whitespace
-- collapsed, and the author's credit that community events carry in front is not narrated
local function CleanText(text)
    text = text:gsub("<[^>/][^>]-/>", " "):gsub("<[^>]->", "")
    text = text:gsub("%s+", " "):gsub("^%s+", "")
    text = text:gsub("^%(Written by [^%)]*%)%s*", "")
    return text
end
-- A sentence ends with punctuation, optional closing quotes or brackets, then a space. The curly quotes
-- and the ellipsis are three bytes each: the search runs on a same-length ASCII shadow of the text so
-- that the positions carry over to the original
local RSQ, RDQ, ELL = string.char(226, 128, 153), string.char(226, 128, 157), string.char(226, 128, 166)
local function SplitSentences(text)
    local shadow = text:gsub(RSQ, "'''"):gsub(RDQ, '"""'):gsub(ELL, "...")
    local pieces, pos, from = {}, 1, 1
    while true do
        local _, e = shadow:find([=[[%.!?]+["'%)]*%s]=], from)
        if not e then break end
        -- a sentence never starts with a lower-case letter: '"Come!" he cries.' stays whole
        local nxt = shadow:sub(e + 1, e + 1)
        if nxt ~= "" and nxt:match("%l") then from = e + 1
        else pieces[#pieces + 1] = text:sub(pos, e); pos = e + 1; from = pos end
    end
    return pieces, text:sub(pos)                          -- complete sentences, and the tail still being typed
end
local function ConsiderStream(slot, kind, text, markup, hold)
    if not text or text == "" then return end
    local st = STREAMS[slot]
    if not st then st = { last = "", stable = 0, spoken = {}, done = false }; STREAMS[slot] = st end
    if st.muted then return end                       -- an option was chosen since: this text is left behind
    if text == st.last then st.stable = st.stable + 1 else st.last = text; st.stable = 1 end
    if hold and st.stable < STABLE_POLLS then return end   -- not yet known to follow a choice (see Poll): wait
    local pieces, tail = SplitSentences(text)
    -- while the first sentence is still being typed, its opening goes out every couple of words: a recorded
    -- passage that is the only one in the game starting that way can begin before the sentence is finished
    if not st.done and #pieces == 0 and next(st.spoken) == nil then
        local words = select(2, tail:gsub("%S+", ""))
        if words >= 6 and words <= 40 and words >= (st.probed or 0) + 2 then st.probed = words; Probe(kind, tail) end
    end
    if st.stable >= STABLE_POLLS then
        pieces[#pieces + 1] = tail                        -- the typewriter is done: the rest is complete too
        if not st.done and markup then Out("%s markup: %s", slot, (markup:sub(1, 200):gsub("%s+", " "))) end
        st.done = true
    end
    for _, sen in ipairs(pieces) do
        local t = sen:gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" and not st.spoken[t] then st.spoken[t] = true; Say(kind, t) end
    end
end
local function Poll()
    local screen = nil
    for _, w in ipairs(Instances("WorldEventResponseScreen")) do
        if Try(function() return w:IsVisible() end) then screen = w break end
    end
    if not screen then
        if SCREEN_SEEN then Stop(); Out("event closed"); SCREEN_SEEN = nil; STREAMS = {}; CHOSEN = {} end
        return
    end
    local key = screen:GetAddress()
    if SCREEN_SEEN ~= key then
        SCREEN_SEEN = key; STREAMS = {}; CHOSEN = {}
        Out("event opened: %s", ShortName(screen:GetFullName()))
    end
    -- the story text is narrated: the description, then the narrative part of each outcome line.
    -- Not narrated: the title, the options, the chosen option's label, and the reward lines.
    local descTexts = {}
    local d = Try(function() return screen.DescriptionText end)
    if d then Texts(d, descTexts) end
    local descMarkup = table.concat(descTexts, " ")
    ConsiderStream("description", "description", CleanText(descMarkup), descMarkup)
    local oc = Try(function() return screen.OutcomeLinesContainer end)
    if oc then
        for i, line in ipairs(Children(oc)) do
            local t = {}
            RawTexts(line, t)
            -- the game puts an icon in front of each line: WorldEventChoice on the outcome of a chosen option,
            -- its own icon on a reward line (HeroicInspiration, ...)
            local icon = table.concat(t, " "):match('<img id="([^"]*)"')
            -- the chosen option's label: its own short block in front of the message, or a styled run at the start
            if #t >= 2 then
                local first = t[1]:gsub("<[^>]->", ""):gsub("^%s+", ""):gsub("%s+$", "")
                local words = select(2, first:gsub("%S+", ""))
                if words <= 5 and not first:match("[%.!?]") then table.remove(t, 1) end
            end
            local raw = table.concat(t, " ")
            local markup = raw
            raw = raw:gsub("<[^>/][^>]-/>", " ")                   -- icons (<img .../>) out first; not the </> that closes a run
            -- then the leading styled runs: the chosen option's label ("We'll join you in song!:") and the
            -- roll's result ("Success"). Labels are short or end with a colon; a long styled sentence is narration
            while true do
                local run = raw:match("^%s*<[^>]->([^<]*)</>")
                if not run or (select(2, run:gsub("%S+", "")) > 12 and not run:match(":%s*$")) then break end
                raw = raw:gsub("^%s*<[^>]->[^<]*</>%s*", "", 1)
            end
            local text = raw:gsub("<[^>]->", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
            -- a roll result left in plain text in front of the sentence ("Success This bridge...")
            for _, word in ipairs(RESULT_WORDS) do
                text = text:gsub("^" .. word .. "[%s:!%.%-]+(%u)", "%1")
            end
            local reward = (icon and icon ~= "WorldEventChoice") or IsReward(text)
            if text ~= "" and not reward then
                local slot = "outcome" .. i
                -- a new outcome line follows a click on an option: whatever is still being read stops and the
                -- narration moves on to it, before a word of it is read. A line with the choice icon counts at
                -- once; one without an icon once it has five words (a reward line typing out never does), and
                -- it is held back until then, so that the stop cannot cut its own first sentence
                if not CHOSEN[slot] and (icon == "WorldEventChoice" or select(2, text:gsub("%S+", "")) >= 5) then
                    CHOSEN[slot] = true
                    Stop()
                    for s, st in pairs(STREAMS) do if s ~= slot then st.muted = true end end
                    Out("option chosen: narration moves on to outcome %d", i)
                end
                ConsiderStream(slot, "outcome", text, markup, not CHOSEN[slot])
            end
        end
    end
end
if LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(250, function() local ok, err = pcall(Poll); if not ok then Out("poll error: %s", tostring(err)) end end)
else
    LoopAsync(250, function() ExecuteInGameThread(function() pcall(Poll) end) return false end)
end

-- Mute and volume, from the keyboard: written to narrator.ini (next to the companion) and pushed to the
-- running companion.
local function IniPath() return QueuePath():gsub("queue%.txt$", "narrator.ini") end
local function ReadIniValue(key)
    local f = io.open(IniPath(), "r")
    if not f then return nil end
    local v = nil
    for line in f:lines() do local k, val = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$"); if k and k:lower() == key:lower() then v = val end end
    f:close()
    return v
end
local function WriteIniValue(key, value)
    local lines, seen = {}, false
    local f = io.open(IniPath(), "r")
    if f then
        for line in f:lines() do
            local k = line:match("^%s*([%w_]+)%s*=")
            if k and k:lower() == key:lower() then lines[#lines + 1] = key .. "=" .. value; seen = true else lines[#lines + 1] = line end
        end
        f:close()
    else
        lines[1] = "[Narrator]"
    end
    if not seen then lines[#lines + 1] = key .. "=" .. value end
    local w = io.open(IniPath(), "w")
    if not w then return false end
    w:write(table.concat(lines, "\n"), "\n"); w:close()
    return true
end
local function Command(kind, extra)
    local f = io.open(QueuePath(), "a")
    if f then f:write(string.format('{"kind":"%s"%s}\n', kind, extra or "")); f:close() end
end
local MUTED = (ReadIniValue("Enabled") == "0")
local function ToggleMute()
    MUTED = not MUTED
    WriteIniValue("Enabled", MUTED and "0" or "1")
    Command(MUTED and "mute" or "unmute")
    Out("narration %s", MUTED and "muted" or "on")
end
-- playback volume, 10 to 100 %, kept in narrator.ini; the companion applies it to the line playing at once and
-- answers with the announcement's recording, or a chime
local function ChangeVolume(delta)
    local cur = tonumber(ReadIniValue("PlaybackVolume") or "") or 100
    local new = math.max(10, math.min(100, math.floor(cur + delta + 0.5)))
    WriteIniValue("PlaybackVolume", tostring(new))
    Command("volume", string.format(',"level":%d', new))
    SEQ = SEQ + 1
    local f = io.open(QueuePath(), "a")
    if f then f:write(string.format('{"seq":%d,"kind":"sample","text":"Narrator volume, %d percent."}\n', SEQ, new)); f:close() end
    Out("volume: %d%%", new)
end
local PRESSED = { mute = false, louder = false, quieter = false }
RegisterKeyBind(Key.M, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.mute = true end)
if Key.OEM_PLUS and Key.OEM_MINUS then                   -- the = and - keys
    RegisterKeyBind(Key.OEM_PLUS, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.louder = true end)
    RegisterKeyBind(Key.OEM_MINUS, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.quieter = true end)
end
if LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(50, function()
        if PRESSED.mute then PRESSED.mute = false; pcall(ToggleMute) end
        if PRESSED.louder then PRESSED.louder = false; pcall(ChangeVolume, 10) end
        if PRESSED.quieter then PRESSED.quieter = false; pcall(ChangeVolume, -10) end
    end)
end

-- the companion program speaks the queue: start it with the game (it exits when the game does)
local function StartCompanion()
    local exe = QueuePath():gsub("queue%.txt$", "SolastaNarrator.exe")
    local f = io.open(exe, "rb")
    if not f then Out("companion not found (%s): lines are logged only", exe) return end
    f:close()
    local dir = exe:gsub("[/\\]SolastaNarrator%.exe$", "")
    local cmd = string.format('start "" /D "%s" "%s"', dir:gsub("/", "\\\\"), exe:gsub("/", "\\\\"))
    local ok, how, code = os.execute(cmd)
    Out("companion start: %s", tostring(ok))
end
pcall(StartCompanion)

Out("loaded — narrating world events (Ctrl+Shift+M mute, Ctrl+Shift+= / - volume); queue %s", QueuePath())
