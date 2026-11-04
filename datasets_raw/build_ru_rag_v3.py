import pandas as pd
import json
import random
import re
import sys
import torch
from transformers import AutoTokenizer, AutoModelForSeq2SeqLM
from tqdm import tqdm

# ============ 0. УТИЛИТЫ ============
def log(msg):
    print(msg, flush=True)

# ============ 1. НАРЕЗКА ============
log("=== 1. Нарезка 9600 фрагментов ===")
df = pd.read_parquet('empathetic_train.parquet')

def clean(s):
    return str(s).replace('_comma_', ',').replace('_period_', '.').strip()

all_frags = []
for cid, sub in df.groupby('conv_id'):
    sub = sub.sort_values('utterance_idx').reset_index(drop=True)
    emotion = clean(sub['context'].iloc[0]).lower()
    first = sub[sub['utterance_idx'] == 1]
    second = sub[sub['utterance_idx'] == 2]
    if first.empty or second.empty:
        continue
    situation = clean(first['utterance'].iloc[0])
    support = clean(second['utterance'].iloc[0])
    if not situation or not support:
        continue
    all_frags.append({'emotion': emotion, 'situation_en': situation, 'support_en': support})

log(f"Всего валидных пар: {len(all_frags)}")

random.seed(42)
by_emotion = {}
for f in all_frags:
    by_emotion.setdefault(f['emotion'], []).append(f)

selected = []
for emo, lst in by_emotion.items():
    random.shuffle(lst)
    selected.extend(lst[:300])

log(f"Отобрано: {len(selected)} (эмоций: {len(set(f['emotion'] for f in selected))})")

# ============ 2. МОДЕЛЬ ============
log("\n=== 2. Загрузка модели (num_beams=4) ===")
device = "cuda" if torch.cuda.is_available() else "cpu"
log(f"Устройство: {device}")

model_name = "Helsinki-NLP/opus-mt-en-ru"
tokenizer = AutoTokenizer.from_pretrained(model_name)
model = AutoModelForSeq2SeqLM.from_pretrained(model_name).to(device)
model.eval()

# ============ 3. ПЕРЕВОД С ПРОГРЕССОМ ============
def translate_batch_with_progress(texts, desc, batch_size=8):
    results = []
    pbar = tqdm(total=len(texts), desc=desc, unit="фрагм", ncols=100, file=sys.stdout)
    for i in range(0, len(texts), batch_size):
        batch = texts[i:i+batch_size]
        inputs = tokenizer(batch, return_tensors="pt", padding=True, truncation=True, max_length=256).to(device)
        with torch.no_grad():
            outputs = model.generate(
                **inputs,
                max_length=256,
                num_beams=4,
                early_stopping=True,
                do_sample=False,
            )
        decoded = tokenizer.batch_decode(outputs, skip_special_tokens=True)
        results.extend(decoded)
        pbar.update(len(batch))
    pbar.close()
    return results

log("\n=== 3. Перевод ситуаций ===")
situations_ru = translate_batch_with_progress(
    [f['situation_en'] for f in selected], "Ситуации"
)

log("\n=== 4. Перевод поддержки ===")
supports_ru = translate_batch_with_progress(
    [f['support_en'] for f in selected], "Поддержка"
)

# ============ 4. ФИЛЬТР ============
log("\n=== 5. Фильтр ===")

def is_bad(s):
    lat = len(re.findall(r'[a-zA-Z]', s))
    cyr = len(re.findall(r'[а-яА-Я]', s))
    return (not s.strip()) or ('www.' in s) or ('http' in s) or (lat > cyr and lat > 5)

def words(s):
    return set(re.findall(r'[а-яё]{4,}', s.lower()))

def is_linked(sit, sup):
    ws, wp = words(sit), words(sup)
    if not ws or not wp:
        return True
    return len(ws & wp) >= 1

out = []
dropped_bad = 0
dropped_unlinked = 0
for i in tqdm(range(len(selected)), desc="Фильтр", unit="фрагм", ncols=100, file=sys.stdout):
    sit = situations_ru[i]
    sup = supports_ru[i]
    if is_bad(sit) or is_bad(sup):
        dropped_bad += 1
        continue
    if not is_linked(sit, sup):
        dropped_unlinked += 1
        continue
    out.append({'emotion': selected[i]['emotion'], 'situation': sit, 'support': sup})

log(f"Сохранено: {len(out)}")
log(f"Отброшено (мусор): {dropped_bad}")
log(f"Отброшено (не связано): {dropped_unlinked}")

# ============ 5. СОХРАНЕНИЕ ============
log("\n=== 6. Сохранение ===")
with open('empathetic_fragments_ru.jsonl', 'w', encoding='utf-8') as f:
    for row in out:
        f.write(json.dumps(row, ensure_ascii=False) + '\n')

log(f"Готово: {len(out)} фрагментов -> empathetic_fragments_ru.jsonl")

# ============ 6. ПРИМЕРЫ ============
log("\n=== Примеры ===")
for f in out[:5]:
    log(f"[{f['emotion']}] {f['situation'][:90]}")
    log(f"  → {f['support'][:90]}")

log("\n=== ВСЁ ГОТОВО ===")
