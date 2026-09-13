#!/usr/bin/env python3
"""Seed a Booklip simulator container with public-domain sample books."""
import json, os, shutil, subprocess, sys, uuid, zipfile, re, time
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

UDID = sys.argv[1]
BUNDLE = "qbit-core.Booklip"
S = os.path.dirname(os.path.abspath(__file__))
BOOKS = os.path.join(S, "books")

container = subprocess.check_output(
    ["xcrun", "simctl", "get_app_container", UDID, BUNDLE, "data"]).decode().strip()
docs = os.path.join(container, "Documents")
os.makedirs(docs, exist_ok=True)
for f in os.listdir(docs):
    p = os.path.join(docs, f)
    if os.path.isfile(p): os.remove(p)

REF = datetime(2001, 1, 1, tzinfo=timezone.utc)
def ts(days_ago):
    return (datetime.now(timezone.utc) - timedelta(days=days_ago) - REF).total_seconds()

def epub_cover(path):
    z = zipfile.ZipFile(path)
    cont = ET.fromstring(z.read("META-INF/container.xml"))
    ns = {"c": "urn:oasis:names:tc:opendocument:xmlns:container"}
    opf_path = cont.find(".//c:rootfile", ns).get("full-path")
    opf = ET.fromstring(z.read(opf_path))
    base = os.path.dirname(opf_path)
    ons = {"o": "http://www.idpf.org/2007/opf"}
    href = None
    for item in opf.iter("{http://www.idpf.org/2007/opf}item"):
        if "cover-image" in (item.get("properties") or ""):
            href = item.get("href"); break
    if href is None:
        cid = None
        for m in opf.iter("{http://www.idpf.org/2007/opf}meta"):
            if m.get("name") == "cover": cid = m.get("content")
        for item in opf.iter("{http://www.idpf.org/2007/opf}item"):
            if item.get("id") == cid: href = item.get("href")
    if href is None: return None
    return z.read(os.path.normpath(os.path.join(base, href)).replace("\\", "/"))

def epub_meta(path):
    z = zipfile.ZipFile(path)
    cont = ET.fromstring(z.read("META-INF/container.xml"))
    ns = {"c": "urn:oasis:names:tc:opendocument:xmlns:container"}
    opf_path = cont.find(".//c:rootfile", ns).get("full-path")
    opf = ET.fromstring(z.read(opf_path))
    dc = "{http://purl.org/dc/elements/1.1/}"
    t = opf.find(".//" + dc + "title"); a = opf.find(".//" + dc + "creator")
    return (t.text if t is not None else "", a.text if a is not None else "Unknown")

# (file, title override, author override, progress, days_ago)
SPEC = [
    ("1342.epub", "Pride and Prejudice", "Jane Austen", 0.42, 1),
    ("11.epub", "Alice's Adventures in Wonderland", "Lewis Carroll", 1.0, 30),
    ("84.epub", "Frankenstein", "Mary Wollstonecraft Shelley", 0.18, 6),
    ("1661.epub", "The Adventures of Sherlock Holmes", "Arthur Conan Doyle", 0.63, 3),
    ("2701.epub", "Moby Dick", "Herman Melville", 0.07, 12),
    ("98.epub", "A Tale of Two Cities", "Charles Dickens", 0.0, 20),
    ("unsu.txt", "운수 좋은 날", "현진건", 0.31, 2),
]
if len(sys.argv) > 2 and sys.argv[2] == "full":
    SPEC += [
        ("174.epub", "The Picture of Dorian Gray", "Oscar Wilde", 0.55, 8),
        ("345.epub", "Dracula", "Bram Stoker", 0.12, 15),
        ("120.epub", "Treasure Island", "Robert Louis Stevenson", 1.0, 40),
        ("43.epub", "The Strange Case of Dr. Jekyll and Mr. Hyde", "Robert Louis Stevenson", 0.0, 4),
        ("1400.epub", "Great Expectations", "Charles Dickens", 0.27, 10),
    ]

books = []
for fname, title, author, prog, days in SPEC:
    src = os.path.join(BOOKS, fname)
    ext = fname.rsplit(".", 1)[1]
    bid = str(uuid.uuid4()).upper()
    fid = str(uuid.uuid4()).upper()
    dest = f"{fid}.{ext}"
    shutil.copy(src, os.path.join(docs, dest))
    cover = None
    if ext == "epub":
        data = epub_cover(src)
        if data:
            cover = f"{fid}_cover.img"
            open(os.path.join(docs, cover), "wb").write(data)
    size = os.path.getsize(src)
    words = int(size / 6) if ext == "txt" else int(size / 40)
    b = {
        "id": bid, "title": title, "author": author,
        "format": "epub" if ext == "epub" else "txt",
        "fileName": dest, "progress": prog, "charIndex": 0,
        "dateAdded": ts(days), "wordCount": words,
        "progressUpdated": ts(days - 0.5),
    }
    if cover: b["coverFileName"] = cover
    books.append(b)
    print(title, dest, "cover" if cover else "no cover")

PLIST = os.path.join(container, "Library", "Preferences", BUNDLE + ".plist")
subprocess.call(["xcrun", "simctl", "spawn", UDID, "defaults", "delete", PLIST])
def defaults(*args):
    subprocess.check_call(["xcrun", "simctl", "spawn", UDID, "defaults", "write", PLIST, *args])

def write_data(key, obj):
    hexs = json.dumps(obj, ensure_ascii=False).encode("utf-8").hex()
    defaults(key, "-data", hexs)

write_data("savedBooks", books)

# Bookmarks for Pride and Prejudice
pp = books[0]
bms = [
    {"id": str(uuid.uuid4()).upper(), "bookID": pp["id"], "progress": 0.12,
     "snippet": "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.", "date": ts(4)},
    {"id": str(uuid.uuid4()).upper(), "bookID": pp["id"], "progress": 0.27,
     "snippet": "I could easily forgive his pride, if he had not mortified mine.", "date": ts(2)},
    {"id": str(uuid.uuid4()).upper(), "bookID": pp["id"], "progress": 0.41,
     "snippet": "Till this moment I never knew myself.", "date": ts(1)},
]
write_data(f"bookmarks_{pp['id']}", bms)

defaults("fontName", "Georgia")
defaults("fontSize", "-int", "19")
defaults("lineSpacing", "-int", "8")
defaults("presetId", "sepia")
defaults("pageEffect", "Paper Book")
defaults("useEmbeddedFont", "-bool", "YES")
defaults("viewMode", "Large" if len(sys.argv) > 2 else "Medium")
defaults("uuidTitleMigrationDone", "-bool", "YES")
defaults("stats_totalSeconds", "-float", str(47 * 3600 + 23 * 60))
days = [(datetime.now() - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(0, 14)]
days += [(datetime.now() - timedelta(days=i)).strftime("%Y-%m-%d") for i in (17, 18, 21, 25, 26, 30, 33)]
defaults("stats_readingDays", "-array", *days)
print("seeded", container)
