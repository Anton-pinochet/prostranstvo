import json
import subprocess
import random
import re
import time
import sys
from tqdm import tqdm

# ============ НАСТРОЙКИ ============
MODEL = "qwen2.5:14b"
PAIRS_PER_TOPIC = 20          # сколько пар просить за раз
ROUNDS_PER_TOPIC = 5          # сколько раз повторять тему (чтобы набрать больше)
OUTPUT = "own_chitchat.jsonl"

TOPICS = [
    "усталость после работы",
    "ссора с близким человеком",
    "одиночество вечером",
    "тревога перед важным событием",
    "радость от маленькой победы",
    "раздражение на бытовые мелочи",
    "чувство вины за прошлое",
    "неуверенность в себе",
    "скучный день, ничего не происходит",
    "проблемы со сном",
    "благодарность за поддержку",
    "злость на несправедливость",
    "ностальгия по прошлому",
    "страх перед будущим",
    "маленькая радость от покупки",
]

PROMPT_TEMPLATE = """Ты — живой человек, который переписывается с другом в мессенджере. Сгенерируй {n} коротких пар «ситуация → поддержка» на русском языке.

Тема: {topic}

Требования:
- Ситуация: 1 предложение, от первого лица, живой разговорный русский. 10–200 символов.
- Поддержка: 1–2 предложения, реакция друга в чате. 15–250 символов. Живая, разговорная, БЕЗ советов и БЕЗ «будь позитивнее».
- В серьёзных ситуациях (тревога, вина, одиночество) — НЕ писать «всё будет хорошо», «не переживай». Вместо этого: «Понимаю», «Это тяжело», «Я рядом», «Расскажи, что случилось?».
- В радостных ситуациях — искренне порадоваться: «Ого, круто!», «Да ладно?», «Молодец!».
- НЕ использовать английские слова, канцелярит, «психологические» термины.
- Каждая пара — уникальная, не повторяй одну и ту же поддержку.

Формат ответа — строго JSON, без markdown:
[
  {{"situation": "...", "support": "..."}},
  {{"situation": "...", "support": "..."}}
]

Сгенерируй {n} пар."""

# ============ ФУНКЦИИ ============
def log(msg):
    print(msg, flush=True)

def call_ollama(prompt):
    try:
        result = subprocess.run(
            ["ollama", "run", MODEL, prompt],
            capture_output=True, text=True, timeout=900
        )
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        log("  ! таймаут 15 мин, пропускаю")
        return ""
    except Exception as e:
        log(f"  ! ошибка: {e}")
        return ""

def parse_json(text):
    text = re.sub(r'^```(?:json)?\s*', '', text.strip())
    text = re.sub(r'\s*```$', '', text)
    try:
        data = json.loads(text)
        if isinstance(data, list):
            return data
    except json.JSONDecodeError:
        pass
    return []

def is_bad(s):
    if not s or len(s) < 10 or len(s) > 300:
        return True
    if len(re.findall(r'[a-zA-Z]{3,}', s)) > 0:
        return True
    bad = ["будь позитивнее", "не переживай", "всё будет хорошо",
           "просто не думай", "улыбнись", "всё пройдёт", "все будет хорошо"]
    if any(p in s.lower() for p in bad):
        return True
    return False

# ============ ОСНОВНОЙ ЦИКЛ ============
def main():
    all_pairs = []
    seen_supports = set()

    total_requests = len(TOPICS) * ROUNDS_PER_TOPIC
    log(f"Модель: {MODEL}")
    log(f"Тем: {len(TOPICS)}, раундов на тему: {ROUNDS_PER_TOPIC}, всего запросов: {total_requests}")
    log(f"Ожидаемое время: ~{total_requests * 3} мин (если 3 мин/запрос)\n")

    pbar = tqdm(total=total_requests, desc="Генерация", unit="запрос", ncols=100, file=sys.stdout)

    for topic_idx, topic in enumerate(TOPICS, 1):
        log(f"\n=== [{topic_idx}/{len(TOPICS)}] Тема: {topic} ===")

        for round_idx in range(1, ROUNDS_PER_TOPIC + 1):
            prompt = PROMPT_TEMPLATE.format(n=PAIRS_PER_TOPIC, topic=topic)
            response = call_ollama(prompt)
            pairs = parse_json(response)

            added = 0
            for p in pairs:
                sit = p.get("situation", "").strip()
                sup = p.get("support", "").strip()
                if is_bad(sit) or is_bad(sup):
                    continue
                key = sup.lower()[:50]
                if key in seen_supports:
                    continue
                seen_supports.add(key)
                all_pairs.append({
                    "topic": topic,
                    "situation": sit,
                    "support": sup,
                })
                added += 1

            pbar.update(1)
            pbar.set_postfix({
                "тема": f"{topic_idx}/{len(TOPICS)}",
                "раунд": f"{round_idx}/{ROUNDS_PER_TOPIC}",
                "пар": len(all_pairs),
            })
            log(f"  раунд {round_idx}/{ROUNDS_PER_TOPIC}: +{added} (всего {len(all_pairs)})")

            # Промежуточное сохранение каждые 5 тем
            if topic_idx % 5 == 0 and round_idx == ROUNDS_PER_TOPIC:
                with open(OUTPUT, "w", encoding="utf-8") as f:
                    for row in all_pairs:
                        f.write(json.dumps(row, ensure_ascii=False) + "\n")
                log(f"  (промежуточное сохранение: {len(all_pairs)} пар)")

    pbar.close()

    # Финальное сохранение
    with open(OUTPUT, "w", encoding="utf-8") as f:
        for row in all_pairs:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    log(f"\n=== ГОТОВО: {len(all_pairs)} пар → {OUTPUT} ===")

if __name__ == "__main__":
    main()
