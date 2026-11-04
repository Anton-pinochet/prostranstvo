import pandas as pd
import json
import random
from transformers import AutoTokenizer, AutoModelForSeq2SeqLM
import torch
from pyaspeller import YandexSpeller

# ============ 1. НАРЕЗКА ============
print("=== 1. Нарезка 9600 фрагментов ===")
df = pd.read_parquet('empathetic_train.parquet')

def clean(s):
    return str(s).replace('_comma_', ',').replace('_period_', '.').strip()

# Собираем все диалоги с idx=1 и idx=2
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
    all_frags.append({'emotion': emotion, 'situation': situation, 'support': support})

print(f"Всего валидных пар: {len(all_frags)}")

# Берём по 300 на эмоцию (фиксированный seed для воспроизводимости)
random.seed(42)
by_emotion = {}
for f in all_frags:
    by_emotion.setdefault(f['emotion'], []).append(f)

selected = []
for emo, lst in by_emotion.items():
    random.shuffle(lst)
    selected.extend(lst[:300])

print(f"Отобрано: {len(selected)} (эмоций: {len(set(f['emotion'] for f in selected))})")

# ============ 2. ПЕРЕВОД ============
print("\n=== 2. Загрузка модели перевода ===")
model_name = "Helsinki-NLP/opus-mt-en-ru"
tokenizer = AutoTokenizer.from_pretrained(model_name)
model = AutoModelForSeq2SeqLM.from_pretrained(model_name)
model.eval()

def translate_batch(texts, batch_size=16):
    results = []
    for i in range(0, len(texts), batch_size):
        batch = texts[i:i+batch_size]
        inputs = tokenizer(batch, return_tensors="pt", padding=True, truncation=True, max_length=256)
        with torch.no_grad():
            outputs = model.generate(**inputs, max_length=256, num_beams=1, do_sample=False)
        decoded = tokenizer.batch_decode(outputs, skip_special_tokens=True)
        results.extend(decoded)
        if (i // batch_size) % 10 == 0:
            print(f"  переведено {i+len(batch)}/{len(texts)}")
    return results

print("Перевод ситуаций...")
situations_ru = translate_batch([f['situation'] for f in selected])
print("Перевод поддержки...")
supports_ru = translate_batch([f['support'] for f in selected])

# ============ 3. ИСПРАВЛЕНИЕ ОПЕЧАТОК ============
print("\n=== 3. Исправление опечаток (pyaspeller) ===")
speller = YandexSpeller()

# Батчируем по 100 текстов, чтобы уложиться в лимиты API
def fix_batch(texts, batch_size=100):
    results = []
    for i in range(0, len(texts), batch_size):
        batch = texts[i:i+batch_size]
        # pyaspeller.spelled принимает один текст, поэтому склеиваем через разделитель
        joined = ' ||| '.join(batch)
        try:
            fixed = speller.spelled(joined)
            parts = fixed.split(' ||| ')
            if len(parts) == len(batch):
                results.extend(parts)
            else:
                results.extend(batch)  # fallback: без исправления
        except Exception as e:
            print(f"  ошибка на батче {i}: {e}")
            results.extend(batch)
        if (i // batch_size) % 10 == 0:
            print(f"  исправлено {i+len(batch)}/{len(texts)}")
    return results

print("Исправление ситуаций...")
situations_fixed = fix_batch(situations_ru)
print("Исправление поддержки...")
supports_fixed = fix_batch(supports_ru)

# ============ 4. СОХРАНЕНИЕ ============
print("\n=== 4. Сохранение ===")
out = []
for i, f in enumerate(selected):
    out.append({
        'emotion': f['emotion'],
        'situation': situations_fixed[i],
        'support': supports_fixed[i],
    })

with open('empathetic_fragments_ru.jsonl', 'w', encoding='utf-8') as fout:
    for row in out:
        fout.write(json.dumps(row, ensure_ascii=False) + '\n')

print(f"Сохранено: empathetic_fragments_ru.jsonl ({len(out)} фрагментов)")

# ============ 5. СТАТИСТИКА ============
print("\n=== 5. Статистика ===")
avg_sit = sum(len(f['situation']) for f in out) / len(out)
avg_sup = sum(len(f['support']) for f in out) / len(out)
print(f"Средняя длина ситуации: {avg_sit:.0f} символов")
print(f"Средняя длина поддержки: {avg_sup:.0f} символов")
print(f"Примеры (первые 3):")
for f in out[:3]:
    print(f"  [{f['emotion']}] {f['situation'][:80]}...")
    print(f"    → {f['support'][:80]}...")
