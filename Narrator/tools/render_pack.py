"""Render the cast script (text/world_events_cast.json) with Gemini voices.

    python tools/render_pack.py --only 0200/0,0201/1 --out <file.wav>     render a few passages into one clip
    python tools/render_pack.py --previews                                 design missing voices, keep their previews
    python tools/render_pack.py --audition                                 one announced line per character
    python tools/render_pack.py --pack <folder> [--only ...]               passages as MP3s + index.json
    python tools/render_pack.py --day <folder> --minutes 9                  one burst of the job (for a daily cloud
        routine): renders until Google's daily limit, the time is up, or everything is done; says which
    python tools/render_pack.py --run <folder> --sync <game Narrator dir>  the whole job, day after day: the
        missing voices, then every passage; sleeps through each day's request limit and carries on, copying
        finished recordings into the game as it goes. Resumable: finished lines and passages are never redone.

Voices are designed once from the cast's voice briefs and remembered in text/voices.json (voice id per
speaker, with the brief it was made from; a changed brief makes a new voice). Every line is synthesized
on its own (designed voices cannot share a multi-speaker request) and the lines are joined with short
pauses; "A+B" lines are both voices at once. Delivery hints from the text become style directions.
"""
import argparse, hashlib, json, os, re, shutil, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TEXT = os.path.join(ROOT, "text")
sys.path.insert(0, HERE)
import gemini_tts as g

# genders as the game text has them (English pronouns; where English is neutral, most translations);
# the voices nothing fixes are left to the description
GENDER = {"NARRATOR": "female", "TWOSA": "female", "KELANA": "female", "ELF_WRITER": "female", "THE_LADY": "female",
          "WITCH": "female", "DAUGHTER": "female", "VILLAGER_W": "female"}
UNGENDERED = {"GHOSTS", "MAGIC_MOUTH", "UNDEAD_HOST"}
LANGUAGE = {"LEPRECHAUN": "en-IE"}
STYLE_WORDS = [
    (r"\bgrunts?\b", "gruff, grunting"), (r"\bgrowls?\b", "growling"), (r"\bhiss(es)?\b", "hissing"),
    (r"\bsqueals?\b", "squealing in shock"), (r"\bscreams?\b", "screaming"), (r"\bscreeches\b", "screeching"),
    (r"\bwhispers?\b", "whispering"), (r"\bcroaks?\b", "croaking"), (r"\brasps?\b", "rasping"),
    (r"\blaugh(s|ter)?\b", "laughing"), (r"\bguffaws\b", "guffawing"), (r"\bcackles\b", "cackling"),
    (r"\bexclaims\b", "exclaiming"), (r"\bcries\b|\bcry\b", "crying out"), (r"\bshouts?\b", "shouting"),
    (r"\bsnaps\b", "snapping irritably"), (r"\bretorts\b", "retorting"), (r"\bdryly\b", "dry, deadpan"),
    (r"\bdribbles\b", "dim and slack-jawed"), (r"\binterrupts\b", "a sudden, sharp interruption"),
    (r"\brumbles\b", "low and rumbling"), (r"\bmurmurs\b", "murmuring"), (r"\bmutters\b", "muttering"),
    (r"\brejoice\b", "gleeful"), (r"\bsneer\b", "sneering"), (r"\bgrin\b", "with a devious grin"),
    (r"\blilted\b", "lilting and amused"), (r"\blingers\b", "a lingering whisper"), (r"\bgruffly\b", "gruff"),
    (r"\bweakly\b", "weak and faint"), (r"\bpoliteness\b", "exaggeratedly polite"), (r"\bcalls out\b", "calling out"),
    (r"\bfrightened\b", "frightened"), (r"\bexplains\b", "explaining"),
]

def style_of(cue):
    found = []
    for pat, words in STYLE_WORDS:
        if re.search(pat, cue or "", re.I) and words not in found:
            found.append(words)
    return ", ".join(found) or None

def load(name, default):
    p = os.path.join(TEXT, name)
    return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else default

def save(name, obj):
    json.dump(obj, open(os.path.join(TEXT, name), "w", encoding="utf-8"), indent=1, ensure_ascii=False)

PITCH = {"BOY": "high", "TWOSA": "high"}
for _who in ("ETTIN_BRIDGE_1", "ETTIN_BRIDGE_2", "ETTIN_COOK_1", "ETTIN_COOK_2", "ETTIN_COOK_3", "ETTIN_COOK_4"):
    PITCH[_who] = "low"                       # ogres: never fall back to a light, young voice

def library_voice(speaker, gender):
    """A ready-made voice from Google's library when a design is refused: same gender; for voices meant to be
    high, the highest pitch the library has, then the youngest listed; for voices meant to be low, the lowest
    pitch, then the oldest."""
    rank = {"high": 3, "medium": 2, None: 1, "low": 0}
    want = PITCH.get(speaker)
    best = None
    for v in g.list_voices(language_code="en-GB", gender=gender or "male"):
        m = re.search(r"(\d+)-year-old", v.get("description", ""))
        age = int(m.group(1)) if m else (99 if want != "low" else 0)
        r = rank.get(v.get("pitch"), 1)
        key = (-r, age) if want == "high" else ((r, -age) if want == "low" else (0, age))
        if best is None or key < best[0]: best = (key, v)
    return best[1]["id"] if best else None

def is_daily_limit(e):
    return isinstance(e, g.ApiError) and e.status == 429 and "daily limit" in str(e)

def is_fatal(e):
    """Errors that retrying will not fix today: no key or a bad one, no network, no credit left."""
    if not isinstance(e, g.ApiError): return False
    msg = str(e)
    return e.status in (0, 401, 402, 403) or "network proxy" in msg or (e.status == 400 and "API key" in msg)

LAST_ERROR = [None]

def ensure_voice(speaker, cast, voices, previews=True):
    """The designed voice id for a speaker, designing it (and keeping its preview) when missing or re-briefed."""
    if speaker == "PARTY":
        speaker = "NARRATOR"
    brief = cast["voices"][speaker]["brief"]
    rec = voices.get(speaker)
    if rec and rec.get("brief") == brief:
        return rec["voice"]
    who = cast["voices"][speaker]["who"]
    gender = None if speaker in UNGENDERED else GENDER.get(speaker, "male")
    try:
        try:
            vid, sample = g.design_voice("Solasta " + who[:40], brief, gender=gender, language_code=LANGUAGE.get(speaker, "en-GB"))
        except g.ApiError as e:
            if speaker not in LANGUAGE or is_daily_limit(e) or "safety" in str(e): raise
            print("  %s: %s - designing with en-GB instead" % (speaker, e))
            vid, sample = g.design_voice("Solasta " + who[:40], brief, gender=gender, language_code="en-GB")
    except g.ApiError as e:
        if e.status != 400 or "safety" not in str(e): raise
        vid = library_voice(speaker, gender)
        how = "library voice %s" % vid
        if not vid:                                    # nothing fits: the narrator reads this character
            vid, how = ensure_voice("NARRATOR", cast, voices), "the narrator's voice"
        voices[speaker] = {"voice": vid, "brief": brief, "made": time.strftime("%Y-%m-%d %H:%M"), "library": True}
        save("voices.json", voices)
        print("  %s: design refused by the safety filter; using %s" % (speaker, how))
        return vid
    voices[speaker] = {"voice": vid, "brief": brief, "made": time.strftime("%Y-%m-%d %H:%M")}
    save("voices.json", voices)
    if previews and sample:
        os.makedirs(os.path.join(TEXT, "voice_previews"), exist_ok=True)
        open(os.path.join(TEXT, "voice_previews", speaker + ".wav"), "wb").write(sample)
    print("  designed %-16s %s" % (speaker, vid))
    return vid

CACHE = os.path.join(TEXT, "render_cache")

def line_audio(text, voice, style):
    """One synthesized line, from the local cache when the same voice, style and words were rendered before."""
    key = hashlib.sha1(("%s|%s|%s" % (voice, style or "", text)).encode("utf-8")).hexdigest()
    path = os.path.join(CACHE, key + ".wav")
    if os.path.exists(path):
        return open(path, "rb").read()
    audio = g.synthesize(text, voice, style)
    os.makedirs(CACHE, exist_ok=True)
    open(path + ".part", "wb").write(audio); os.replace(path + ".part", path)
    return audio

def segment_keys(p, cast, voices):
    """The cache keys a passage's lines use (None when a voice is not made yet)."""
    keys = []
    for s in p["segments"]:
        style = "speaking directly to someone, firm" if s["speaker"] == "PARTY" else style_of(s.get("cue"))
        for w in s["speaker"].split("+"):
            rec = voices.get("NARRATOR" if w == "PARTY" else w)
            if not rec: return None
            keys.append(hashlib.sha1(("%s|%s|%s" % (rec["voice"], style or "", s["text"])).encode("utf-8")).hexdigest())
    return keys

def prune_cache(cast, voices, folder):
    """Drop cached lines no passage still waiting for its recording needs (keeps a cloud repo small)."""
    need = set()
    for p in cast["passages"]:
        name = hashlib.sha1(norm_text(p["text"]).encode("utf-8")).hexdigest()[:16] + ".mp3"
        if os.path.exists(os.path.join(folder, name)): continue
        keys = segment_keys(p, cast, voices)
        if keys is None: return 0
        need.update(keys)
    gone = 0
    if os.path.isdir(CACHE):
        for f in os.listdir(CACHE):
            if f.endswith(".wav") and f[:-4] not in need:
                os.remove(os.path.join(CACHE, f)); gone += 1
    return gone

def render_passage(p, cast, voices):
    parts = []
    for s in p["segments"]:
        who = s["speaker"].split("+")
        style = style_of(s.get("cue"))
        if s["speaker"] == "PARTY":
            style = "speaking directly to someone, firm"
        try:
            clips = [line_audio(s["text"], ensure_voice(w, cast, voices), style) for w in who]
        except g.ApiError as e:
            if e.status != 400 or who == ["NARRATOR"] or is_fatal(e): raise
            print("  %s: %s refused (%s); read by the narrator" % (p["key"], s["speaker"], e))
            clips = [line_audio(s["text"], ensure_voice("NARRATOR", cast, voices), None)]
        parts.append(clips[0] if len(clips) == 1 else g.mix_wavs(clips[0], clips[1]))
    return g.join_wavs(parts, gap_ms=280)

def norm_text(t):
    """The matching key for a passage or a sentence: lower case letters and digits, single spaces.
    The companion (companion/narrator.py) uses the same function on what the game shows."""
    t = re.sub(r"[^a-z0-9]+", " ", (t or "").lower())
    return re.sub(r"\s+", " ", t).strip()

def to_mp3(wav_bytes, kbps=64):
    import lameenc
    rate, ch, width, pcm = g.pcm_of(wav_bytes)
    enc = lameenc.Encoder()
    enc.set_bit_rate(kbps); enc.set_in_sample_rate(rate); enc.set_channels(ch); enc.set_quality(2)
    return bytes(enc.encode(pcm) + enc.flush())

def write_index(folder, index, cast):
    """index.json for the companion: the recorded passages, plus every passage's text ("all"), so that it can
    tell when an opening still being typed can only be one passage in the game."""
    data = {"format": 1, "passages": index, "all": sorted({norm_text(p["text"]) for p in cast["passages"]})}
    json.dump(data, open(os.path.join(folder, "index.json"), "w", encoding="utf-8"))

def build_pack(cast, voices, folder, only=None, deadline=None):
    """Render passages into <folder>/<hash>.mp3 and write <folder>/index.json for the companion.
    Returns True when every chosen passage is recorded."""
    os.makedirs(folder, exist_ok=True)
    index, t0, done = [], time.time(), 0
    try:
        complete = _pack_passages(cast, voices, folder, only, index, t0, deadline)
    finally:                                  # whatever happens, the index lists what is recorded
        write_index(folder, index, cast)
    print("pack: %d passages in %s" % (len(index), folder))
    return complete

def _pack_passages(cast, voices, folder, only, index, t0, deadline=None):
    done, complete = 0, True
    for p in cast["passages"]:
        if only and p["key"] not in only: continue
        n = norm_text(p["text"])
        name = hashlib.sha1(n.encode("utf-8")).hexdigest()[:16] + ".mp3"
        path = os.path.join(folder, name)
        if not os.path.exists(path) and deadline and time.time() > deadline:
            complete = False; continue                 # time is up: the rest stays for the next burst
        if not os.path.exists(path):
            try:
                mp3 = to_mp3(render_passage(p, cast, voices))
            except g.ApiError as e:
                if is_daily_limit(e) or is_fatal(e): raise
                LAST_ERROR[0] = "%s: %s" % (p["key"], e)
                print("  %s FAILED: %s" % (p["key"], e)); complete = False; continue
            open(path + ".part", "wb").write(mp3); os.replace(path + ".part", path)
        index.append({"key": p["key"], "norm": n, "file": name})
        done += 1
        if done % 10 == 0:
            print("  %d/%d passages (%.0f min)" % (done, len(cast["passages"]), (time.time() - t0) / 60))
            write_index(folder, index, cast)
    return complete

def cached_only(text, voice, style):
    key = hashlib.sha1(("%s|%s|%s" % (voice, style or "", text)).encode("utf-8")).hexdigest()
    return os.path.exists(os.path.join(CACHE, key + ".wav"))

def audition(cast, voices, out, offline=False):
    """One characteristic line per character, each announced by the narrator, into one reel.
    offline: only what is already made (no requests); characters still missing are listed.
    Returns (refused, failed): characters whose line the API refused, and those that failed otherwise."""
    lines = {}
    for p in cast["passages"]:
        for sg in p["segments"]:
            who = sg["speaker"]
            if who in ("NARRATOR", "PARTY") or "+" in who: continue
            score = abs(len(sg["text"]) - 120) + (0 if 30 <= len(sg["text"]) <= 220 else 500)
            if who not in lines or score < lines[who][0]:
                lines[who] = (score, sg)
    parts, refused, failed = [], [], []
    for who in cast["voices"]:
        if who not in lines: continue
        sg = lines[who][1]
        if offline:
            rec = voices.get(who)
            name = cast["voices"][who]["who"].split(",")[0].split("(")[0].strip()
            if not (rec and rec.get("brief") == cast["voices"][who]["brief"]
                    and cached_only(sg["text"], rec["voice"], style_of(sg.get("cue")))
                    and cached_only(name + ".", voices["NARRATOR"]["voice"], "announcing a name, brief and clear")):
                print("  %-16s not made yet" % who); continue
        try:
            name = cast["voices"][who]["who"].split(",")[0].split("(")[0].strip()
            intro = line_audio(name + ".", ensure_voice("NARRATOR", cast, voices), "announcing a name, brief and clear")
            clip = line_audio(sg["text"], ensure_voice(who, cast, voices), style_of(sg.get("cue")))
            os.makedirs(os.path.join(TEXT, "auditions"), exist_ok=True)
            open(os.path.join(TEXT, "auditions", who + ".wav"), "wb").write(clip)
            parts.append(g.join_wavs([intro, clip], gap_ms=450))
            print("  %-16s ok: %s" % (who, sg["text"][:60]))
        except g.ApiError as e:
            if is_daily_limit(e) or is_fatal(e): raise
            print("  %-16s FAILED: %s" % (who, e))
            (refused if e.status == 400 else failed).append(who)
    if parts:
        open(out, "wb").write(g.join_wavs(parts, gap_ms=1100))
        rate, ch, width, pcm = g.pcm_of(open(out, "rb").read())
        print("wrote %s: %.0f s" % (out, len(pcm) / (rate * ch * width)))
    return refused, failed

def sync_pack(folder, dest):
    """Copy new recordings, then the index, into the game's Narrator folder (read at the next game start)."""
    if not dest or not os.path.isdir(folder): return 0          # nothing recorded yet
    target = os.path.join(dest, "pack"); os.makedirs(target, exist_ok=True); n = 0
    for name in os.listdir(folder):
        if name.endswith(".mp3") and not os.path.exists(os.path.join(target, name)):
            shutil.copy2(os.path.join(folder, name), os.path.join(target, name)); n += 1
    if os.path.exists(os.path.join(folder, "index.json")):
        shutil.copy2(os.path.join(folder, "index.json"), os.path.join(target, "index.json"))
    return n

def run_day(cast, voices, folder, minutes):
    """One burst: voices, the audition reel (as MP3), passages until the daily limit or the time is up."""
    logp = os.path.join(TEXT, "render_progress.log")
    def say(msg):
        line = time.strftime("[%Y-%m-%d %H:%M UTC] ", time.gmtime()) + msg
        print(line); open(logp, "a", encoding="utf-8").write(line + "\n")
    def done_count():
        path = os.path.join(folder, "index.json")
        return len(json.load(open(path, encoding="utf-8"))["passages"]) if os.path.exists(path) else 0
    try:
        import lameenc  # noqa: F401  (the MP3 encoder; without it no passage can be saved)
    except ImportError:
        status = ("stopped - the MP3 encoder lameenc is not installed (pip install lameenc); in a cloud"
                  " environment, Network access must reach pypi.org (the Trusted level does)")
        say("%s: %d of %d passages recorded" % (status, done_count(), len(cast["passages"])))
        return status
    deadline = time.time() + minutes * 60
    before = done_count()
    reel = os.path.join(TEXT, "audition_reel.mp3")
    try:
        for who in cast["voices"]:
            if who != "PARTY": ensure_voice(who, cast, voices)
        if not os.path.exists(reel):
            wav = os.path.join(TEXT, "audition_reel.wav")
            refused, failed = audition(cast, voices, wav)
            if failed:
                if os.path.exists(wav): os.remove(wav)
                say("audition reel waits: %s failed, tried again next time" % ", ".join(failed))
            elif os.path.exists(wav):
                open(reel, "wb").write(to_mp3(open(wav, "rb").read())); os.remove(wav)
                say("audition reel complete%s: %s" % (" (%s refused, left out)" % ", ".join(refused) if refused else "", reel))
        complete = build_pack(cast, voices, folder, deadline=deadline)
        status = "finished" if complete else ("time up" if time.time() > deadline else "some passages failed")
    except g.ApiError as e:
        if is_daily_limit(e): status = "daily limit reached"
        elif is_fatal(e): status = "stopped - %s" % e
        else: raise
    if status in ("time up", "some passages failed") and done_count() == before:
        status = "stopped - nothing new recorded (last error: %s)" % (LAST_ERROR[0] or "none")
    gone = prune_cache(cast, voices, folder) if os.path.exists(reel) else 0   # the reel reuses cached lines
    say("%s: %d of %d passages recorded (%d cached lines no longer needed removed)" % (status, done_count(), len(cast["passages"]), gone))
    return status

def run(cast, voices, folder, dest):
    """The whole job, resumable: the voices, the audition reel, every passage; sleeps through daily limits."""
    logp = os.path.join(TEXT, "render_progress.log")
    def say(msg):
        line = time.strftime("[%Y-%m-%d %H:%M] ") + msg
        print(line); open(logp, "a", encoding="utf-8").write(line + "\n")
    def done_count():
        path = os.path.join(folder, "index.json")
        return len(json.load(open(path, encoding="utf-8"))["passages"]) if os.path.exists(path) else 0
    say("job started: %d of %d passages already recorded" % (done_count(), len(cast["passages"])))
    reel_done = False
    while True:
        try:
            for who in cast["voices"]:
                if who != "PARTY": ensure_voice(who, cast, voices)
            if not reel_done:
                audition(cast, voices, os.path.join(TEXT, "audition_reel.wav")); reel_done = True
                say("all %d voices made; audition reel complete" % (len(cast["voices"]) - 1))
            build_pack(cast, voices, folder)
            n = sync_pack(folder, dest)
            say("finished: %d of %d passages recorded (%d copied into the game)" % (done_count(), len(cast["passages"]), n))
            return
        except g.ApiError as e:
            if not is_daily_limit(e):
                say("error: %s - trying again in 10 minutes" % e); time.sleep(600); continue
            n = sync_pack(folder, dest)
            wait = g.retry_seconds(str(e)) + 120
            say("daily limit reached: %d of %d passages recorded so far, %d copied into the game; resuming at %s"
                % (done_count(), len(cast["passages"]), n, time.strftime("%a %H:%M", time.localtime(time.time() + wait))))
            time.sleep(wait)
        except Exception as e:
            say("error: %r - trying again in 10 minutes" % (e,)); time.sleep(600)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="comma-separated passage keys (event/index)")
    ap.add_argument("--out", default="")
    ap.add_argument("--previews", action="store_true")
    ap.add_argument("--audition", action="store_true")
    ap.add_argument("--offline", action="store_true", help="use only what is already rendered")
    ap.add_argument("--pack", default="")
    ap.add_argument("--run", default="")
    ap.add_argument("--day", default="")
    ap.add_argument("--minutes", type=float, default=9)
    ap.add_argument("--sync", default="")
    a = ap.parse_args()
    keys = [k.strip() for k in a.only.split(",") if k.strip()]
    cast = load("world_events_cast.json", None)
    voices = load("voices.json", {})
    if a.audition:
        audition(cast, voices, a.out or os.path.join(TEXT, "audition_reel.wav"), offline=a.offline); return
    if a.day:
        sys.exit(2 if run_day(cast, voices, a.day, a.minutes).startswith("stopped") else 0)
    if a.run:
        run(cast, voices, a.run, a.sync); return
    if a.pack:
        build_pack(cast, voices, a.pack, only=set(keys) if keys else None)
        sync_pack(a.pack, a.sync); return
    chosen = [p for p in cast["passages"] if p["key"] in keys]
    t0 = time.time()
    clips = []
    for p in chosen:
        print("rendering %s %s [%s]" % (p["key"], p["event_name"], p["field"]))
        clips.append(render_passage(p, cast, voices))
    if clips and a.out:
        open(a.out, "wb").write(g.join_wavs(clips, gap_ms=900))
        rate, ch, width, pcm = g.pcm_of(open(a.out, "rb").read())
        print("wrote %s: %.1f s of audio in %.0f s" % (a.out, len(pcm) / (rate * ch * width), time.time() - t0))

if __name__ == "__main__":
    main()
