"""Split a world-event passage into narrator text and quoted speech.

Double quotes: an opening curly quote always opens (closing any open quote first), a closing curly quote
closes (ignored when nothing is open), a straight quote toggles. Single quotes are only dialogue when a
curly or straight single quote opens at a word start before a capital letter and nothing double-quoted
is open; apostrophes inside words (you're, 'em) never open or close.
"""
import re

LQ, RQ, SQ = "\u201c", "\u201d", '"'
LS, RS = "\u2018", "\u2019"

def split(text):
    segs, buf, mode, i, n = [], [], None, 0, len(text)    # mode: None, "d" (double), "s" (single)
    def push(kind):
        s = "".join(buf).strip()
        if s:
            segs.append((kind, s))
        buf.clear()
    while i < n:
        c = text[i]
        prev = text[i - 1] if i else " "
        nxt = text[i + 1] if i + 1 < n else " "
        if c == LQ:
            push("quote" if mode else "narration"); mode = "d"
        elif c == RQ:
            if mode == "d": push("quote"); mode = None
        elif c == SQ:
            if mode == "d": push("quote"); mode = None
            elif mode is None: push("narration"); mode = "d"
            else: buf.append(c)
        elif c in (LS, "'") and mode is None and not prev.isalnum() and nxt.isupper():
            push("narration"); mode = "s"
        elif c in (RS, "'") and mode == "s" and not nxt.isalpha():
            push("quote"); mode = None
        else:
            buf.append(c)
        i += 1
    push("quote" if mode else "narration")
    return segs
