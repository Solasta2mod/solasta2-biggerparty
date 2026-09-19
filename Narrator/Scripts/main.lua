-- Narrator - Solasta II (Brimstone), UE4SS.
--
-- World events are text only. This mod reads the event's story text as the game types it out and hands
-- each completed sentence to a companion program (Narrator/SolastaNarrator.exe next to the game exe) through a
-- queue file (Narrator/queue.txt, one JSON line per utterance). The companion speaks the lines with a
-- Microsoft Edge neural voice and caches the audio. Titles, options, the choice made and the rewards are
-- deliberately not narrated.
--
--   Ctrl+Shift+N   next voice (saved to Narrator/narrator.ini; the new voice introduces itself)
--   Ctrl+Shift+M   mute / unmute
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

-- reward lines are not narrated: experience, items, gold and the like
local function IsReward(text)
    local t = text:lower()
    if t:match("^each party member") or t:match("^the party ") or t:match("^your party ") then return true end
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
-- the game types text out letter by letter: a line is spoken once it has stopped changing for a while
local STABLE_POLLS = 4          -- four polls at 250 ms: a second without change
local SPOKEN, PENDING, SCREEN_SEEN, CHOICES_SEEN, DESC_DONE = {}, {}, nil, nil, false
-- the description is typed out: speak each sentence as soon as it is complete, the tail when it stops
local SENT_SPOKEN, SENT_LAST, SENT_STABLE = {}, "", 0
local function ConsiderSentences(text)
    if not text or text == "" then return end
    if text == SENT_LAST then SENT_STABLE = SENT_STABLE + 1 else SENT_LAST = text; SENT_STABLE = 1 end
    local pieces = {}
    for sentence in text:gmatch("[^%.!?]+[%.!?]+%s") do pieces[#pieces + 1] = sentence end   -- complete sentences (followed by a space)
    local consumed = 0
    for _, sen in ipairs(pieces) do consumed = consumed + #sen end
    local tail = text:sub(consumed + 1)
    if SENT_STABLE >= STABLE_POLLS then
        pieces[#pieces + 1] = tail                     -- the typewriter is done: the rest is complete too
        DESC_DONE = true
    end
    for _, sen in ipairs(pieces) do
        local t = sen:gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" and not SENT_SPOKEN[t] then SENT_SPOKEN[t] = true; Say("description", t) end
    end
end
local function Consider(slot, kind, text)
    if not text or text == "" then return end
    local pend = PENDING[slot]
    if pend and pend.text == text then pend.n = pend.n + 1 else PENDING[slot] = { text = text, n = 1 }; pend = PENDING[slot] end
    if pend.n >= STABLE_POLLS and not SPOKEN[slot .. "|" .. text] then
        SPOKEN[slot .. "|" .. text] = true
        Say(kind, text)
    end
end
local function Poll()
    local screen = nil
    for _, w in ipairs(Instances("WorldEventResponseScreen")) do
        if Try(function() return w:IsVisible() end) then screen = w break end
    end
    if not screen then
        if SCREEN_SEEN then Stop(); Out("event closed"); SCREEN_SEEN = nil; SPOKEN = {}; PENDING = {}; CHOICES_SEEN = nil; DESC_DONE = false; SENT_SPOKEN = {}; SENT_LAST = ""; SENT_STABLE = 0 end
        return
    end
    local key = screen:GetAddress()
    if SCREEN_SEEN ~= key then
        SCREEN_SEEN = key; SPOKEN = {}; PENDING = {}; CHOICES_SEEN = nil; DESC_DONE = false; SENT_SPOKEN = {}; SENT_LAST = ""; SENT_STABLE = 0
        Out("event opened: %s", ShortName(screen:GetFullName()))
    end
    -- the story text is narrated: the description, then the narrative part of each outcome line.
    -- Not narrated: the title, the options, the chosen option's label, and the reward lines.
    local descTexts = {}
    local d = Try(function() return screen.DescriptionText end)
    if d then Texts(d, descTexts) end
    ConsiderSentences(table.concat(descTexts, " "))
    local oc = Try(function() return screen.OutcomeLinesContainer end)
    if oc then
        for i, line in ipairs(Children(oc)) do
            local t = {}
            RawTexts(line, t)
            -- the chosen option's label: its own short block in front of the message, or a styled run at the start
            if #t >= 2 then
                local first = t[1]:gsub("<[^>]->", ""):gsub("^%s+", ""):gsub("%s+$", "")
                local words = select(2, first:gsub("%S+", ""))
                if words <= 5 and not first:match("[%.!?]") then table.remove(t, 1) end
            end
            local raw = table.concat(t, " ")
            raw = raw:gsub("<[^>/][^>]-/>", " ")                   -- icons (<img .../>) out first; not the </> that closes a run
            -- then the leading styled runs: the chosen option's label, and the check's result ("Success")
            local n = 1
            while n > 0 do raw, n = raw:gsub("^%s*<[^>]->[^<]*</>%s*", "") end
            local text = raw:gsub("<[^>]->", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
            -- a result word left in plain text in front of the sentence
            text = text:gsub("^Critical Success[%s:!%.]+(%u)", "%1"):gsub("^Critical Failure[%s:!%.]+(%u)", "%1")
            text = text:gsub("^Success[%s:!%.]+(%u)", "%1"):gsub("^Failure[%s:!%.]+(%u)", "%1")
            if text ~= "" and not IsReward(text) then Consider("outcome" .. i, "outcome", text) end
        end
    end
end
if LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(250, function() local ok, err = pcall(Poll); if not ok then Out("poll error: %s", tostring(err)) end end)
else
    LoopAsync(250, function() ExecuteInGameThread(function() pcall(Poll) end) return false end)
end

-- Voice choice and mute, from the keyboard. The choice is written to narrator.ini (next to the companion) and
-- pushed to the running companion, which introduces the new voice in its own words.
local VOICES = {
    { "en-GB-RyanNeural", "Ryan, British English" }, { "en-GB-ThomasNeural", "Thomas, British English" },
    { "en-GB-SoniaNeural", "Sonia, British English" }, { "en-GB-LibbyNeural", "Libby, British English" },
    { "en-IE-ConnorNeural", "Connor, Irish English" }, { "en-IE-EmilyNeural", "Emily, Irish English" },
    { "en-AU-WilliamNeural", "William, Australian English" }, { "en-AU-NatashaNeural", "Natasha, Australian English" },
    { "en-US-AndrewNeural", "Andrew, American English" }, { "en-US-BrianNeural", "Brian, American English" },
    { "en-US-ChristopherNeural", "Christopher, American English" }, { "en-US-GuyNeural", "Guy, American English" },
    { "en-US-AvaNeural", "Ava, American English" }, { "en-US-AriaNeural", "Aria, American English" },
    { "en-US-JennyNeural", "Jenny, American English" },
}
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
local function NextVoice()
    local current = ReadIniValue("Voice") or VOICES[1][1]
    local idx = 1
    for i, v in ipairs(VOICES) do if v[1] == current then idx = i break end end
    local nxt = VOICES[idx % #VOICES + 1]
    WriteIniValue("Voice", nxt[1])
    Command("voice", string.format(',"voice":"%s"', nxt[1]))
    SEQ = SEQ + 1
    local f = io.open(QueuePath(), "a")
    if f then f:write(string.format('{"seq":%d,"kind":"sample","text":"This is %s. I will narrate the world events."}\n', SEQ, nxt[2])); f:close() end
    Out("voice: %s (%s)", nxt[2], nxt[1])
end
local MUTED = (ReadIniValue("Enabled") == "0")
local function ToggleMute()
    MUTED = not MUTED
    WriteIniValue("Enabled", MUTED and "0" or "1")
    Command(MUTED and "mute" or "unmute")
    Out("narration %s", MUTED and "muted" or "on")
end
local PRESSED = { voice = false, mute = false }
RegisterKeyBind(Key.N, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.voice = true end)
RegisterKeyBind(Key.M, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() PRESSED.mute = true end)
if LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(50, function()
        if PRESSED.voice then PRESSED.voice = false; pcall(NextVoice) end
        if PRESSED.mute then PRESSED.mute = false; pcall(ToggleMute) end
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

Out("loaded — narrating world events (Ctrl+Shift+N next voice, Ctrl+Shift+M mute); queue %s", QueuePath())
