"""Проверка параметров в конфигах тестера и пресетах против `input` советника.

MT5 молча игнорирует параметр, которого нет у советника (опечатка в имени), и прогон идёт с
настройкой по умолчанию. Скрипт ловит это до запуска:

  * `tester/*.json` — ключ "expert" и параметры в "inputs" и "variants[].inputs";
  * `tools/robot_audit_plan.json` — "presets[].expert" и "presets[].inputs";
  * `research/**/*.set` — пресеты MT5; советник берётся из строки-комментария
    `; expert: путь/к/советнику` (без неё — по имени файла не угадываем, это ошибка).

Для каждого параметра проверяется: есть ли такой `input` (в самом советнике и во всех
подключённых через `#include "…"` файлах) и подходит ли значение к типу — bool, целое,
дробное, строка, перечисление (значение должно быть одним из элементов enum, для
ENUM_TIMEFRAMES — один из периодов MT5).

Конфиг с ключом "retired" (строка с причиной) пропускается: это история прогонов советника,
которого больше нет.

    python3 tools/check_inputs.py            # проверить всё, код возврата 1 при ошибках
    python3 tools/check_inputs.py --self-test
"""
import argparse
import glob
import json
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

INT_TYPES = {"int", "uint", "long", "ulong", "short", "ushort", "char", "uchar", "datetime", "color"}
REAL_TYPES = {"double", "float"}
# Периоды MT5 (значения ENUM_TIMEFRAMES); 0 — PERIOD_CURRENT.
TIMEFRAMES = {0, 1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30, 16385, 16386, 16387, 16388, 16390, 16392,
              16396, 16408, 32769, 49153}
INPUT_RE = re.compile(r"^\s*(?:sinput|input)\s+(?!group\b)([A-Za-z_][\w]*)\s+([A-Za-z_]\w*)\s*(?:=[^;]*)?;", re.M)
INCLUDE_RE = re.compile(r'^\s*#include\s+"([^"]+)"', re.M)
ENUM_RE = re.compile(r"\benum\s+([A-Za-z_]\w*)\s*\{([^}]*)\}", re.S)


def read_source(path):
    raw = open(path, "rb").read()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        text = raw.decode("utf-16")
    else:
        text = raw.decode("utf-8-sig", errors="replace")
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def collect(path, seen=None):
    """Тексты советника и всех его `#include "…"` (рекурсивно)."""
    seen = set() if seen is None else seen
    path = os.path.normpath(path)
    if path in seen or not os.path.exists(path):
        return []
    seen.add(path)
    text = read_source(path)
    out = [text]
    for inc in INCLUDE_RE.findall(text):
        out += collect(os.path.join(os.path.dirname(path), inc), seen)
    return out


def parse_enums(texts):
    enums = {}
    for text in texts:
        for name, body in ENUM_RE.findall(text):
            values, names, nxt = set(), {}, 0
            for item in body.split(","):
                item = item.strip()
                if not item:
                    continue
                if "=" in item:
                    member, expr = (x.strip() for x in item.split("=", 1))
                    try:
                        nxt = int(expr, 0)
                    except ValueError:
                        nxt = names.get(expr, nxt)
                else:
                    member = item
                values.add(nxt)
                names[member] = nxt
                nxt += 1
            enums[name] = (values, names)
    return enums


def expert_inputs(expert):
    """{имя: тип} и перечисления советника; None, если файла нет."""
    path = os.path.join(ROOT, expert + ".mq5")
    if not os.path.exists(path):
        return None, None
    texts = collect(path)
    inputs = {}
    for text in texts:
        for typ, name in INPUT_RE.findall(text):
            inputs[name] = typ
    return inputs, parse_enums(texts)


def check_value(name, typ, value, enums):
    """Текст ошибки или None. value — как в JSON (bool/int/float/str) или строка из .set."""
    if isinstance(value, str) and typ != "string":
        low = value.strip().lower()
        if low in ("true", "false"):
            value = low == "true"
        else:
            try:
                value = int(low, 10)
            except ValueError:
                try:
                    value = float(low)
                except ValueError:
                    pass
    if typ == "bool":
        if isinstance(value, bool) or value in (0, 1):
            return None
        return f"{name}: ожидается bool, получено {value!r}"
    if typ == "string":
        return None if isinstance(value, str) else f"{name}: ожидается строка, получено {value!r}"
    if isinstance(value, bool):
        return f"{name}: тип {typ}, получено bool {value!r}"
    if typ in REAL_TYPES:
        return None if isinstance(value, (int, float)) else f"{name}: ожидается число, получено {value!r}"
    if typ in INT_TYPES:
        if isinstance(value, int) or (isinstance(value, float) and value.is_integer()):
            return None
        return f"{name}: ожидается целое ({typ}), получено {value!r}"
    if typ == "ENUM_TIMEFRAMES":
        if isinstance(value, (int, float)) and int(value) == value and int(value) in TIMEFRAMES:
            return None
        return f"{name}: {value!r} — не период MT5"
    if typ in enums:
        values, names = enums[typ]
        if isinstance(value, str) and value in names:
            return None
        if isinstance(value, (int, float)) and int(value) == value and int(value) in values:
            return None
        return f"{name}: {value!r} не входит в {typ} {sorted(values)}"
    if typ.startswith("ENUM_"):
        # встроенное перечисление MT5 (ENUM_MA_METHOD и т. п.) — только целое
        if isinstance(value, (int, float)) and int(value) == value:
            return None
        return f"{name}: ожидается целое значение {typ}, получено {value!r}"
    return None


def check_inputs(source, expert, inputs_list, cache):
    """inputs_list — список (метка, dict параметров). Возврат — список ошибок."""
    if expert not in cache:
        cache[expert] = expert_inputs(expert)
    declared, enums = cache[expert]
    if declared is None:
        return [f"{source}: советник {expert}.mq5 не найден"]
    errors = []
    for label, params in inputs_list:
        for name, value in (params or {}).items():
            where = f"{source}{label}"
            if name not in declared:
                near = [d for d in declared if d.lower() == name.lower()]
                hint = f" (может быть, {near[0]}?)" if near else ""
                errors.append(f"{where}: у {expert} нет параметра {name}{hint}")
                continue
            msg = check_value(name, declared[name], value, enums)
            if msg:
                errors.append(f"{where}: {msg}")
    return errors


def parse_set(path):
    expert, params = None, {}
    for line in open(path, encoding="utf-8-sig", errors="replace"):
        line = line.strip()
        if line.startswith(";"):
            m = re.match(r";\s*expert:\s*(\S+)", line)
            if m:
                expert = m.group(1).removesuffix(".mq5")
            continue
        if "=" in line:
            name, rest = line.split("=", 1)
            params[name.strip()] = rest.split("||", 1)[0]
    return expert, params


def run_all():
    cache, errors, checked = {}, [], 0
    for path in sorted(glob.glob(os.path.join(ROOT, "tester", "*.json"))):
        rel = os.path.relpath(path, ROOT)
        cfg = json.load(open(path, encoding="utf-8"))
        if cfg.get("retired"):
            continue
        items = [("", cfg.get("inputs"))]
        items += [(f" [{v.get('name', i)}]", v.get("inputs")) for i, v in enumerate(cfg.get("variants") or [])]
        errors += check_inputs(rel, cfg["expert"], items, cache)
        checked += 1
    plan = os.path.join(ROOT, "tools", "robot_audit_plan.json")
    if os.path.exists(plan):
        for p in json.load(open(plan, encoding="utf-8")).get("presets", []):
            errors += check_inputs(f"tools/robot_audit_plan.json [{p['id']}]", p["expert"],
                                   [("", p.get("inputs"))], cache)
            checked += 1
    for path in sorted(glob.glob(os.path.join(ROOT, "research", "**", "*.set"), recursive=True)):
        rel = os.path.relpath(path, ROOT)
        expert, params = parse_set(path)
        if not expert:
            errors.append(f"{rel}: нет строки «; expert: путь/к/советнику»")
            continue
        errors += check_inputs(rel, expert, [("", params)], cache)
        checked += 1
    return checked, errors


def self_test():
    enums = {"E": ({0, 1, 5}, {"A": 0, "B": 1, "C": 5})}
    assert check_value("x", "bool", True, enums) is None
    assert check_value("x", "bool", 2, enums)
    assert check_value("x", "int", 3, enums) is None
    assert check_value("x", "int", 2.5, enums)
    assert check_value("x", "double", 2, enums) is None
    assert check_value("x", "ENUM_TIMEFRAMES", 16385, enums) is None
    assert check_value("x", "ENUM_TIMEFRAMES", 61, enums)
    assert check_value("x", "E", 5, enums) is None
    assert check_value("x", "E", 2, enums)
    assert check_value("x", "E", "C", enums) is None
    assert check_value("x", "bool", "true", enums) is None
    text = "enum E { A, B = 4, C };\ninput E Mode = A; // c\ninput group \"g\"\nsinput double Risk = 1.0;"
    assert parse_enums([text])["E"][0] == {0, 4, 5}
    assert dict((n, t) for t, n in INPUT_RE.findall(text)) == {"Mode": "E", "Risk": "double"}
    print("self-test ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        self_test()
        return 0
    checked, errors = run_all()
    for e in errors:
        print("ОШИБКА", e)
    print(f"проверено наборов: {checked}, ошибок: {len(errors)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
