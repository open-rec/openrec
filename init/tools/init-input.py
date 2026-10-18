#!/usr/bin/env python3
"""Validate bootstrap CSV inputs and select warmup samples without fixture IDs."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import shlex


COLUMNS = {
    "user": "id device_id name gender age country city phone tags register_time login_time ext_fields",
    "item": "id title category tags scene pub_time modify_time expire_time status weight ext_fields",
    "event": "id user_id item_id trace_id scene type value time is_login ext_fields",
}


def read_rows(root, entity):
    path = root / f"{entity}.csv"
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream)
        missing = set(COLUMNS[entity].split()) - set(reader.fieldnames or [])
        if missing:
            raise ValueError(f"{path}: missing columns {sorted(missing)}")
        seen = set()
        for number, row in enumerate(reader, 2):
            if None in row or any(value is None for value in row.values()):
                raise ValueError(f"{path}:{number}: malformed CSV row")
            if not row["id"] or row["id"] in seen:
                raise ValueError(f"{path}:{number}: empty or duplicate id")
            seen.add(row["id"])
            yield row
        if not seen:
            raise ValueError(f"{path}: no data rows")


def inspect(root):
    users = {row["id"]: row for row in read_rows(root, "user")}
    items = {row["id"]: row for row in read_rows(root, "item")}
    sample = None
    for row in read_rows(root, "event"):
        if row["user_id"] not in users or row["item_id"] not in items:
            raise ValueError(f"event {row['id']}: unknown user or item")
        if not row["scene"] or row["scene"] != items[row["item_id"]]["scene"]:
            raise ValueError(f"event {row['id']}: scene does not match item")
        if sample is None and row["type"] == "click":
            sample = row
    if sample is None:
        raise ValueError("event.csv must contain a click for recommendation warmup")
    user, item = users[sample["user_id"]], items[sample["item_id"]]
    return {"smoke_user": user["id"], "smoke_scene": sample["scene"],
            "smoke_item_query": item["title"],
            "smoke_user_query": user["name"] or user["country"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", required=True, type=Path)
    args = parser.parse_args()
    try:
        settings = inspect(args.data)
    except (OSError, ValueError) as error:
        parser.exit(1, f"invalid initialization input: {error}\n")
    reference = json.loads(Path(__file__).with_name("fixture-inputs.json").read_text())
    actual = {}
    for name in reference:
        with (args.data / name).open("rb") as stream:
            digest = hashlib.sha256()
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
            actual[name] = digest.hexdigest()
    settings["OPENREC_FIXTURE_INPUT"] = "true" if actual == reference else "false"
    for name, value in settings.items():
        print(f"{name}={shlex.quote(value)}")


if __name__ == "__main__":
    main()
