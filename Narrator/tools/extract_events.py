"""Pull the world-event narration text out of Solasta II's pak into text/world_events.txt (+ .json).

    python tools/extract_events.py [<game folder>]

Reads ST_MainCampaignIngredients.csv straight from Brimstone-Windows.pak (tools/pakread.py; Oodle needs
OODLE_DIR or an oo2core DLL near the game exe) and the event asset names from the IoStore index.
Keeps only what the narrator speaks: event descriptions and outcomes. Titles, option labels, rewards
and "TBD" placeholders are left out. The output is game text: it stays out of the repository.
"""
import csv, io, json, os, re, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "tools"))
from pakread import Pak                                    # the repository's tools/pakread.py

GAME = sys.argv[1] if len(sys.argv) > 1 else r"C:\Program Files (x86)\Steam\steamapps\common\Solasta 2"
PAKS = os.path.join(GAME, "Brimstone", "Content", "Paks")
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "text")
FIELD_WORDS = r"(Description|Desc|Outcome|Outcomes|Response|Responses|Title|Choice|Success|Sucess|Failure|Fail|Result|Message)"

def camel_words(s):
    s = re.sub(r"([a-z])([A-Z])", r"\1 \2", s)
    s = re.sub(r"([A-Za-z])(\d)", r"\1 \2", s)
    return re.sub(r"[_.]+", " ", s).strip()

def split_key(key):
    """(event id, display name, field) from the many key styles the table uses."""
    k = re.sub(r"^(DA_EV_|Event_)", "", key)
    m = re.match(r"^(\d+)_?(.*)$", k)
    if m:                                                      # numbered events: 0360_Seagulls_SearchOutcome_Description, 01_OutcomeHideSuccess
        num, rest = m.group(1), m.group(2)
        m2 = re.match(r"^([A-Za-z]+?)_(.+)$", rest)
        if m2 and not re.match(FIELD_WORDS, m2.group(1)):
            return num.zfill(4), m2.group(1), m2.group(2)
        return num.zfill(4), "", rest
    m = re.match(r"^(C\d+|Board\d+)_?(.*)$", k)
    if m:                                                      # community / board events: C013_WanderingScammerDescription, Board8_Description
        cid, rest = m.group(1), m.group(2)
        m2 = re.match(r"^(.*?)_?" + FIELD_WORDS + r"(.*)$", rest)
        if m2 and m2.group(1):
            return cid, m2.group(1), m2.group(2) + m2.group(3)
        return cid, "", rest
    if "." in k:                                               # quest events: CTLocalQuest2_DestroyedHamlet.Observe.Outcome
        base, field = k.split(".", 1)
        return base, base.split("_", 1)[1] if "_" in base else "", field
    m = re.match(r"^([A-Za-z0-9]+)_(.+)$", k)                   # named events: PavonOnTheRoad_PersuadeFailure, RandomEncounter_AmbushTitle
    if m:
        return m.group(1), m.group(1), m.group(2)
    m = re.match(r"^(.*?)" + FIELD_WORDS + r"(.*)$", k)          # PavonOnTheRoadDescription
    if m and m.group(1):
        return m.group(1), m.group(1), m.group(2) + m.group(3)
    return k, k, ""

NARRATION_FIELDS = r"(outcome|desc|success|sucess|fail|response|result|ending|goodbye|message|conditional|wait)"
def is_label(key, text):
    """Option labels and titles: short lines under a bare action name ("Dive", "Speak About Dredger")."""
    if re.search(r"Title|Choice|ResponseGeneric|WorldEvent\.", key): return True
    words = len(text.split())
    if words <= 8 and not re.search(r"[.!?]", text): return True
    if words <= 12 and not re.search(NARRATION_FIELDS, key, re.I): return True
    return False

def clean(text):
    t = text.replace(chr(92) + "n", chr(10)).replace(chr(0x2028), chr(10))
    t = re.sub(r"^\s*\(Written by [^)]*\)\s*", "", t)             # community credit line
    t = re.sub(r"[ \t]+", " ", t)
    t = re.sub(r"\s*\n\s*", chr(10), t).strip()
    return t

def main():
    pak = Pak(os.path.join(PAKS, "Brimstone-Windows.pak"))
    data = pak.read("Brimstone/Content/Localization/ST_MainCampaignIngredients.csv")
    rows = list(csv.DictReader(io.StringIO(data.decode("utf-8-sig"))))
    utoc = open(os.path.join(PAKS, "Brimstone-Windows.utoc"), "rb").read()
    asset_names = {}
    for m in re.finditer(rb"DA_EV_(\d+)_([A-Za-z0-9_]+)", utoc):
        asset_names.setdefault(m.group(1).decode().zfill(4), m.group(2).decode())
    events = {}
    order = []
    for r in rows:
        key, text = r["Key"], r["SourceString"].strip()
        if not re.match(r"(DA_EV_|Event_|WorldEvent)", key): continue
        if text.startswith("TBD ") or is_label(key, text): continue
        eid, name, field = split_key(key)
        if not name: name = asset_names.get(eid, "")
        if eid not in events:
            events[eid] = {"id": eid, "name": camel_words(name) if name else eid, "lines": []}; order.append(eid)
        events[eid]["lines"].append({"key": key, "field": camel_words(field) or "Text", "text": clean(text)})
    def sort_key(eid):
        return (0, int(eid)) if eid.isdigit() else (1, eid)
    order.sort(key=sort_key)
    for e in events.values():                                   # description first, then the table's order
        e["lines"].sort(key=lambda l: 0 if re.match(r"desc", l["field"], re.I) else 1)
    os.makedirs(OUT, exist_ok=True)
    total = sum(len(l["text"]) for e in events.values() for l in e["lines"])
    count = sum(len(e["lines"]) for e in events.values())
    stamp = time.strftime("%Y-%m-%d")
    with open(os.path.join(OUT, "world_events.txt"), "w", encoding="utf-8", newline=chr(10)) as f:
        f.write("SOLASTA II WORLD EVENTS - narration text (pulled from the game files on %s)\n" % stamp)
        f.write("%d events, %d passages, %d characters. Lines in [brackets] are labels, not narration.\n\n" % (len(events), count, total))
        for eid in order:
            e = events[eid]
            f.write("=" * 72 + chr(10) + "%s  %s" % (e["id"], e["name"]) + chr(10) + "=" * 72 + chr(10) + chr(10))
            for l in e["lines"]:
                f.write("[%s]\n%s\n\n" % (l["field"], l["text"]))
    with open(os.path.join(OUT, "world_events.json"), "w", encoding="utf-8") as f:
        json.dump([events[eid] for eid in order], f, indent=1, ensure_ascii=False)
    print("%d events, %d passages, %d characters -> %s" % (len(events), count, total, OUT))

if __name__ == "__main__":
    main()
