#!/usr/bin/env python3
"""Append AI-lock matrix rows to one JSON document. Evidence is stdin."""

import datetime
import json
import os
import sys


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def save(path, document):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2)
        handle.write("\n")
    os.replace(temporary, path)


def count_fails(document):
    """How many rows have result FAIL. SKIP, PASS, DRY-RUN, and PREPARED are not fails."""
    rows = document.get("rows") or []
    total = 0
    for row in rows:
        if isinstance(row, dict) and row.get("result") == "FAIL":
            total += 1
    return total


def dump_text(path):
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    if text and not text.endswith("\n"):
        text += "\n"
    return "BEGIN-MATRIX-JSON\n" + text + "END-MATRIX-JSON\n"


def main(argv):
    if len(argv) < 2:
        return 2
    command = argv[1]
    if command == "init":
        if len(argv) != 9:
            return 2
        path, dry_run, phase, hv, core_rev, app_rev, host_kind = argv[2:9]
        document = {
            "version": 1,
            "dry_run": dry_run == "1",
            "phase": phase,
            "host_kind": host_kind,
            "hv_vmm_present": hv,
            "core_rev": core_rev,
            "app_rev": app_rev,
            "started_at": utc_now(),
            "rows": [],
        }
        save(path, document)
        return 0
    if command == "add":
        if len(argv) != 5:
            return 2
        path, name, result = argv[2:5]
        evidence = sys.stdin.read()
        if len(evidence) > 8000:
            evidence = evidence[:8000] + "\n...truncated\n"
        document = load(path)
        document["rows"].append(
            {
                "name": name,
                "result": result,
                "evidence": evidence.rstrip("\n"),
            }
        )
        document["updated_at"] = utc_now()
        save(path, document)
        return 0
    if command == "fails":
        if len(argv) != 3:
            return 2
        print(count_fails(load(argv[2])))
        return 0
    if command == "dump":
        if len(argv) != 3:
            return 2
        sys.stdout.write(dump_text(argv[2]))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
