"""Print a TOML file as JSON, for the jq in scan.sh to read.

This is the scan's only Python. Bash, awk, sed, grep, and jq can't parse
TOML, and the caller's osv-scanner.toml is TOML. A hand-written parser could
read a suppression differently from osv-scanner itself, and no TOML tool is
preinstalled on GitHub-hosted runners except Python's tomllib (Python 3.11
or later), so the scan converts the file here and does everything else in jq.

Dates and times become UTC timestamps such as 2027-01-31T00:00:00Z, the form
jq's fromdateiso8601 reads. A date means midnight UTC at its start, and a
date-time without an offset is read as UTC.

Usage: python3 -I toml-to-json.py <file.toml>
"""

import datetime
import json
import sys
import tomllib


def timestamp(value):
    if isinstance(value, datetime.datetime):
        if value.tzinfo is not None:
            value = value.astimezone(datetime.timezone.utc)
        return value.strftime("%Y-%m-%dT%H:%M:%SZ")
    if isinstance(value, datetime.date):
        return value.strftime("%Y-%m-%dT00:00:00Z")
    raise TypeError(f"can't convert {type(value).__name__} to JSON")


with open(sys.argv[1], "rb") as fh:
    json.dump(tomllib.load(fh), sys.stdout, default=timestamp)
print()
