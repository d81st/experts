#!/usr/bin/env python3
"""Собрать один релиз тиков из уже скачанных артефактов Actions.

Берёт только месячные ticks_XAUUSDm_2026-MM.csv.gz, manifest.json и
validation.json. export_info.txt и журналы не копируются. Хеш каждого
gzip сверяется с таблицей прогона до того, как файл попадёт в релиз.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TAG = "data-ticks-XAUUSDm-2026-v1"
REPO = "d81st/experts"

# Прогоны, из которых берётся v1. Другие артефакты (compile-results, сентябрьский
# пробный прогон) сюда не входят.
SOURCES = (
    (40066709615, "ticks-XAUUSDm-2024-01-01-2026-03-31", "validation-2026-01_2026-03.json", ("2026-01", "2026-02", "2026-03")),
    (40067583912, "ticks-XAUUSDm-2026-04-01-2026-06-30", "validation-2026-04_2026-06.json", ("2026-04", "2026-05", "2026-06")),
    (40068293007, "ticks-XAUUSDm-2026-07-01-2026-09-30", "validation-2026-07_2026-09.json", ("2026-07", "2026-08", "2026-09")),
    (40068991395, "ticks-XAUUSDm-2026-10-01-2026-10-23", "validation-2026-10.json", ("2026-10",)),
)

# sha256 и размер gzip-байтов, как в отчёте архива.
EXPECTED = {
    "2026-01": ("ticks_XAUUSDm_2026-01.csv.gz", "d1582f18a35206c49cf03643da4df1d56a9dded54880471714239ee281d35048", 116790345),
    "2026-02": ("ticks_XAUUSDm_2026-02.csv.gz", "1d3489bc7025538bae76b21ab62a31dddc653efde0f19ac34b91d326310ae0cb", 73431239),
    "2026-03": ("ticks_XAUUSDm_2026-03.csv.gz", "b7a39a3bbb3c7866cd4b3c1ef95e380cc2e80d3d0df385bb956cde2d74dd5955", 107109099),
    "2026-04": ("ticks_XAUUSDm_2026-04.csv.gz", "ccfada3971afe3cf6e304adb41ad06539eb567fd444597af22f5a04e4f6953fe", 59741351),
    "2026-05": ("ticks_XAUUSDm_2026-05.csv.gz", "0d06c40912cc44be42439c6433048c81140a4b720aeab4a3ffe83c82c117800d", 54041809),
    "2026-06": ("ticks_XAUUSDm_2026-06.csv.gz", "4c79d8cfe1db257f9fd9781133dde881b1445df5ad3e028b5d2bedae66f8615a", 71234047),
    "2026-07": ("ticks_XAUUSDm_2026-07.csv.gz", "fb3c233f94008bcaf04a40c8c5d44fc4f5d435a2c701ee503767602ab4ba2f30", 59999934),
    "2026-08": ("ticks_XAUUSDm_2026-08.csv.gz", "926af93e6b0e913fbc63856b592803e6aca3da1cae36d692da4dac35e1dcd348", 58179053),
    "2026-09": ("ticks_XAUUSDm_2026-09.csv.gz", "297f6e0a22d55b34ee62bb281378e128d0e7c0327e47d9eb84e5a2dcd5a04b3d", 59358224),
    "2026-10": ("ticks_XAUUSDm_2026-10.csv.gz", "06d7e0f498d3fc3b3e8f5e07f257bdd0489eb74f0c00a3465ce6fa0b9b3a14c1", 39670490),
}

IP_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
FORBIDDEN_KEYS = {"login", "password", "account", "server", "ip", "token"}
REQUEST_KEYS = {"run", "tag", "target_branch", "prerelease", "note"}


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _walk_keys(value, found):
    if isinstance(value, dict):
        for key, item in value.items():
            if str(key).lower() in FORBIDDEN_KEYS:
                found.append(str(key).lower())
            _walk_keys(item, found)
    elif isinstance(value, list):
        for item in value:
            _walk_keys(item, found)


def scan_text(path):
    """Отклонить файл, если в нём адрес или поле учётки. Значение наружу не печатается."""
    raw = path.read_bytes()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError(path.name + " is not utf-8 text") from exc
    if IP_RE.search(text):
        raise ValueError(path.name + " contains a network address")
    if path.suffix == ".json":
        try:
            data = json.loads(text)
        except json.JSONDecodeError as exc:
            raise ValueError(path.name + " is not valid JSON") from exc
        found = []
        _walk_keys(data, found)
        if found:
            raise ValueError(path.name + " contains a forbidden field")
    return text


def _require(cond, message):
    if not cond:
        raise ValueError(message)


def assemble(batch_dirs, out_dir, expected=None, batches=None):
    expected = EXPECTED if expected is None else expected
    if batches is None:
        batches = [(name, months) for _run, _artifact, name, months in SOURCES]
    _require(len(batch_dirs) == len(batches), "batch count does not match")
    out_dir = Path(out_dir)
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)
    files = []
    copied = []
    for batch_dir, (validation_name, months) in zip(batch_dirs, batches):
        root = Path(batch_dir)
        manifests = list(root.rglob("manifest.json"))
        validations = [p for p in root.rglob("validation.json")]
        _require(len(manifests) == 1, "expected one manifest.json")
        _require(len(validations) == 1, "expected one validation.json")
        scan_text(manifests[0])
        scan_text(validations[0])
        manifest = json.loads(manifests[0].read_text(encoding="utf-8"))
        by_month = {item.get("month"): item for item in manifest.get("files", [])}
        for month in months:
            filename, digest, size = expected[month]
            matches = [p for p in root.rglob(filename)]
            _require(len(matches) == 1, "missing " + filename)
            src = matches[0]
            _require(src.stat().st_size == size, filename + " size does not match")
            actual = sha256_file(src)
            _require(actual == digest, filename + " sha256 does not match")
            entry = by_month.get(month)
            _require(entry is not None, "manifest has no entry for " + month)
            _require(entry.get("sha256") == digest, "manifest sha256 does not match " + filename)
            _require(entry.get("bytes") == size, "manifest size does not match " + filename)
            _require(entry.get("file") == filename, "manifest filename does not match " + filename)
            dest = out_dir / filename
            shutil.copyfile(src, dest)
            _require(sha256_file(dest) == digest, "copy changed " + filename)
            files.append(entry)
            copied.append(filename)
        dest_validation = out_dir / validation_name
        shutil.copyfile(validations[0], dest_validation)
        _require(dest_validation.read_bytes() == validations[0].read_bytes(), "validation copy changed")
        scan_text(dest_validation)
        copied.append(validation_name)
    months_out = [item["month"] for item in files]
    _require(months_out == list(expected), "months are not the full 2026 range")
    basis = json.loads((Path(batch_dirs[0]).rglob("manifest.json").__next__()).read_text(encoding="utf-8"))
    combined = {
        "symbol": "XAUUSDm",
        "release_tag": TAG,
        "range": "2026-01-01 .. 2026-10-23",
        "time_basis": basis.get("time_basis", ""),
        "columns": basis.get("columns", []),
        "digits": basis.get("digits"),
        "point": basis.get("point", ""),
        "source_runs": [
            {"run_id": run_id, "artifact": artifact, "validation_file": validation_name}
            for run_id, artifact, validation_name, _months in SOURCES
        ],
        "files": files,
    }
    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(combined, indent=2) + "\n", encoding="ascii")
    scan_text(manifest_path)
    names = sorted(p.name for p in out_dir.iterdir() if p.is_file())
    lines = []
    for name in names:
        lines.append(sha256_file(out_dir / name) + "  " + name)
    sums_path = out_dir / "SHA256SUMS"
    sums_path.write_text("\n".join(lines) + "\n", encoding="ascii")
    scan_text(sums_path)
    present = sorted(p.name for p in out_dir.iterdir() if p.is_file())
    allowed = set(copied) | {"manifest.json", "SHA256SUMS"}
    _require(set(present) == allowed, "release directory has an unexpected file")
    for path in out_dir.iterdir():
        _require(path.suffix != ".log", "refusing a log file")
        _require(path.name != "export_info.txt", "refusing export_info")
    return present


def verify_dir(out_dir, expected=None):
    out_dir = Path(out_dir)
    expected = EXPECTED if expected is None else expected
    sums = (out_dir / "SHA256SUMS").read_text(encoding="ascii").splitlines()
    listed = {}
    for line in sums:
        _require("  " in line, "SHA256SUMS line is malformed")
        digest, name = line.split("  ", 1)
        _require(re.fullmatch(r"[0-9a-f]{64}", digest), "SHA256SUMS hash is malformed")
        listed[name] = digest
    _require("SHA256SUMS" not in listed, "SHA256SUMS must not list itself")
    present = {p.name for p in out_dir.iterdir() if p.is_file()}
    _require(present == set(listed) | {"SHA256SUMS"}, "uploaded files do not match SHA256SUMS")
    for name, digest in listed.items():
        actual = sha256_file(out_dir / name)
        _require(actual == digest, name + " sha256 does not match SHA256SUMS")
        if name.endswith(".json") or name == "SHA256SUMS":
            scan_text(out_dir / name)
    for month, (filename, digest, size) in expected.items():
        path = out_dir / filename
        _require(path.is_file(), "missing " + filename)
        _require(path.stat().st_size == size, filename + " size changed after upload")
        _require(sha256_file(path) == digest, filename + " sha256 changed after upload")
        _require(listed.get(filename) == digest, "SHA256SUMS does not match " + month)
    for path in out_dir.iterdir():
        _require(not path.name.endswith(".log"), "log file in the release")
        _require(path.name != "export_info.txt", "export_info in the release")
        _require(path.suffix != ".ini", "config file in the release")


def check_request(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    _require(isinstance(data, dict), "request must be an object")
    extra = set(data) - REQUEST_KEYS
    _require(not extra, "request has an unexpected field")
    note = data.get("note", "")
    _require(isinstance(note, str) and re.fullmatch(r"[A-Za-z0-9 ._-]{0,80}", note), "request note is invalid")
    _require(data.get("tag") == TAG, "tag is not the v1 release")
    _require(data.get("target_branch") == "grok", "target branch is not grok")
    _require(data.get("prerelease") is True, "prerelease must be true")
    _require(data.get("run") is True or data.get("run") is False, "run must be a boolean")
    return data.get("run") is True


def release_notes():
    lines = [
        "XAUUSDm real ticks, 2026-01-01 through 2026-10-23.",
        "",
        "Prerelease. This tag is not the Latest release.",
        "",
        "The monthly gzip CSV files are the bytes from the Actions artifacts below.",
        "manifest.json is the combined manifest. SHA256SUMS covers every other asset.",
        "validation-*.json are the validation summaries from those runs.",
        "Terminal logs are not included.",
        "",
        "Source runs:",
    ]
    for run_id, artifact, _validation, _months in SOURCES:
        lines.append(f"- https://github.com/{REPO}/actions/runs/{run_id} ({artifact})")
    return "\n".join(lines) + "\n"


def download_sources(dest):
    dest = Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    for run_id, artifact, _validation, _months in SOURCES:
        target = dest / artifact
        if target.exists():
            shutil.rmtree(target)
        target.mkdir(parents=True)
        subprocess.run(
            ["gh", "run", "download", str(run_id), "--repo", REPO, "--name", artifact, "--dir", str(target)],
            check=True,
        )


def _expect(cond, message):
    if not cond:
        raise AssertionError(message)


def self_test():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        expected = {
            "2026-01": ("ticks_XAUUSDm_2026-01.csv.gz", "", 0),
        }
        batch = root / "batch"
        batch.mkdir()
        payload = b"tick-bytes\n"
        gz = batch / "ticks_XAUUSDm_2026-01.csv.gz"
        gz.write_bytes(payload)
        digest = hashlib.sha256(payload).hexdigest()
        expected["2026-01"] = ("ticks_XAUUSDm_2026-01.csv.gz", digest, len(payload))
        manifest = {
            "time_basis": "server clock",
            "columns": ["time_msc"],
            "digits": 3,
            "point": "0.001",
            "files": [
                {
                    "file": "ticks_XAUUSDm_2026-01.csv.gz",
                    "month": "2026-01",
                    "sha256": digest,
                    "bytes": len(payload),
                    "symbol": "XAUUSDm",
                    "row_count": 1,
                }
            ],
        }
        (batch / "manifest.json").write_text(json.dumps(manifest), encoding="ascii")
        (batch / "validation.json").write_text('{"ok": true, "months": []}\n', encoding="ascii")
        (batch / "export_info.txt").write_text("complete=1\nlogin=1\n", encoding="ascii")
        (batch / "terminal.log").write_bytes(b"secret log")
        out = root / "out"
        names = assemble([batch], out, expected, [("validation-2026-01.json", ("2026-01",))])
        _expect("export_info.txt" not in names, "export_info was copied")
        _expect("terminal.log" not in names, "log was copied")
        _expect((out / "ticks_XAUUSDm_2026-01.csv.gz").read_bytes() == payload, "gzip bytes changed")
        verify_dir(out, expected)
        leaked = batch / "validation.json"
        leaked.write_text('{"ok": true, "login": "1"}\n', encoding="ascii")
        try:
            assemble([batch], root / "out2", expected, [("validation-2026-01.json", ("2026-01",))])
            raise AssertionError("forbidden field must fail")
        except ValueError as exc:
            _expect("login" not in str(exc), "rejection must not echo the field")
        request = root / "request.json"
        request.write_text(
            json.dumps(
                {
                    "run": True,
                    "tag": TAG,
                    "target_branch": "grok",
                    "prerelease": True,
                    "note": "assemble-v1",
                }
            ),
            encoding="ascii",
        )
        _expect(check_request(request) is True, "armed request")
        request.write_text(
            json.dumps({"run": False, "tag": TAG, "target_branch": "grok", "prerelease": True}),
            encoding="ascii",
        )
        _expect(check_request(request) is False, "disarmed request")
    print("assemble_tick_release self-test passed")


def main(argv):
    if "--self-test" in argv:
        self_test()
        return 0
    if "--check-request" in argv:
        slot = argv.index("--check-request")
        armed = check_request(argv[slot + 1])
        path = os.environ.get("GITHUB_OUTPUT")
        if path:
            with open(path, "a", encoding="utf-8") as handle:
                handle.write("run=" + ("true" if armed else "false") + "\n")
        print("run=" + ("true" if armed else "false"))
        return 0
    if "--notes" in argv:
        slot = argv.index("--notes")
        Path(argv[slot + 1]).write_text(release_notes(), encoding="utf-8")
        return 0
    if "--download" in argv:
        slot = argv.index("--download")
        download_sources(argv[slot + 1])
        return 0
    if "--assemble" in argv:
        slot = argv.index("--assemble")
        source = Path(argv[slot + 1])
        out = Path(argv[slot + 2])
        dirs = [source / artifact for _run, artifact, _validation, _months in SOURCES]
        names = assemble(dirs, out)
        print("assembled " + " ".join(names))
        return 0
    if "--verify" in argv:
        slot = argv.index("--verify")
        verify_dir(argv[slot + 1])
        print("uploaded assets match the archive sha256 table")
        return 0
    raise SystemExit(
        "usage: assemble_tick_release.py --self-test | --check-request FILE | --download DIR | --assemble SOURCE OUT | --verify DIR | --notes FILE"
    )


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except ValueError as exc:
        print("failure: " + str(exc))
        sys.exit(2)
