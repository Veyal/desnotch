#!/usr/bin/env python3
"""Independent verifier for the desnotch voice audit log (hash chain).

usage: python3 -I scripts/voice-harness/verify-audit.py <voice-audit.jsonl> [more rotated files, oldest first]

It re-implements the chain from docs/voice/WP-PLATFORM.md section 3.7 without any desnotch code:
hash = sha256(prevHash + "\\n" + canonical_json(record with hash = "")), canonical = sorted keys,
compact separators, no escaping of "/" or non-ASCII. Only the keys present on the line are
encoded (the Swift encoder omits nil fields). Prints the head hash to anchor outside the file.
Exit 0 = valid, 1 = broken or unreadable. Never prints record contents.
"""
import hashlib
import json
import sys


def canonical(record):
    clean = dict(record)
    clean["hash"] = ""
    return json.dumps(clean, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def main(paths):
    previous = None
    count = 0
    for path in paths:
        try:
            with open(path, "r", encoding="utf-8") as handle:
                lines = [line.rstrip("\n") for line in handle if line.strip()]
        except OSError as error:
            print("verify-audit: cannot read %s: %s" % (path, error.strerror))
            return 1
        for number, line in enumerate(lines, 1):
            try:
                record = json.loads(line)
                seq = record["seq"]
                prev_hash = record["prevHash"]
                stored = record["hash"]
            except (ValueError, KeyError, TypeError):
                print("verify-audit: BROKEN at %s line %d (not a record)" % (path, number))
                return 1
            if previous is not None:
                if seq != previous["seq"] + 1 or prev_hash != previous["hash"]:
                    print("verify-audit: BROKEN at seq %s (chain link)" % seq)
                    return 1
            expected = hashlib.sha256((prev_hash + "\n" + canonical(record)).encode("utf-8")).hexdigest()
            if expected != stored:
                print("verify-audit: BROKEN at seq %s (hash mismatch)" % seq)
                return 1
            previous = record
            count += 1
    head = previous["hash"] if previous else ""
    print("verify-audit: ok (%d records, head %s)" % (count, head))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(64)
    sys.exit(main(sys.argv[1:]))
