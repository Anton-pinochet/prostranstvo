#!/usr/bin/env python3
"""
Заливка generated_chitchat_http.jsonl в chitchat.db.
Вариант B: только chitchat, vec_chitchat создаётся на телефоне.
"""

import json, sqlite3, sys, time
from pathlib import Path
import numpy as np
from onnxruntime import InferenceSession
from tokenizers import Tokenizer

ROOT = Path.home() / "projects" / "prostranstvo"
JSONL = ROOT / "datasets_raw" / "generated_chitchat_http.jsonl"
DB    = ROOT / "chitchat.db"
TOK   = ROOT / "assets" / "tokenizer.json"
ONNX  = ROOT / "assets" / "embedding_model" / "model_quantized.onnx"

for p in (JSONL, TOK, ONNX):
    if not p.exists():
        sys.exit(f"НЕ НАЙДЕНО: {p}")

print(f"JSONL:  {JSONL} ({JSONL.stat().st_size/1024/1024:.1f} МБ)")
print(f"TOK:    {TOK}")
print(f"ONNX:   {ONNX}")

tok = Tokenizer.from_file(str(TOK))
sess = InferenceSession(str(ONNX), providers=["CPUExecutionProvider"])
in_names = [i.name for i in sess.get_inputs()]
print(f"ONNX inputs: {in_names}")

def embed(text: str) -> np.ndarray:
    enc = tok.encode(f"passage: {text}")
    ids = np.array([enc.ids], dtype=np.int64)
    mask = np.array([enc.attention_mask], dtype=np.int64)
    feeds = {}
    for n in in_names:
        if "input_ids" in n: feeds[n] = ids
        elif "attention_mask" in n: feeds[n] = mask
        elif "token_type_ids" in n: feeds[n] = np.zeros_like(ids)
        else: sys.exit(f"Неизвестный вход ONNX: {n}")
    out = sess.run(None, feeds)[0][0]
    n = np.linalg.norm(out) + 1e-12
    return (out / n).astype(np.float32)

if DB.exists():
    print(f"БД уже есть: {DB} ({DB.stat().st_size/1024/1024:.1f} МБ) — удаляю")
    DB.unlink()

db = sqlite3.connect(str(DB))
db.executescript("""
CREATE TABLE chitchat (
  rowid     INTEGER PRIMARY KEY,
  embedding BLOB NOT NULL,
  situation TEXT NOT NULL,
  support   TEXT NOT NULL,
  topic     TEXT
);
""")
# vec_chitchat создаётся на телефоне при первом запуске приложения

n = 0; skipped = 0; t0 = time.time()
with open(JSONL) as f:
    for line in f:
        try: p = json.loads(line)
        except: skipped += 1; continue
        sit = (p.get("situation") or "").strip()
        sup = (p.get("support") or "").strip()
        top = (p.get("topic") or "").strip()
        if not sit or not sup or len(sup) < 20:
            skipped += 1; continue
        v = embed(f"{sit} {sup}")
        blob = v.tobytes()
        db.execute(
            "INSERT INTO chitchat(embedding, situation, support, topic) VALUES (?,?,?,?)",
            (blob, sit, sup, top)
        )
        n += 1
        if n % 1000 == 0:
            db.commit()
            dt = time.time() - t0
            print(f"{n} вставлено, {skipped} пропущено, {dt:.0f}s, {n/dt:.1f}/с")

db.commit()
db.execute("VACUUM")
db.close()

size_mb = DB.stat().st_size / 1024 / 1024
print(f"\n=== ГОТОВО ===")
print(f"Вставлено:  {n}")
print(f"Пропущено:  {skipped}")
print(f"Время:      {time.time()-t0:.0f}s")
print(f"БД:         {DB} ({size_mb:.1f} МБ)")
print("Примечание: vec_chitchat создаётся на телефоне при первом запуске приложения")
