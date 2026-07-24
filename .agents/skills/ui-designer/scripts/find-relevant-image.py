#!/usr/bin/env python3
"""
Find a relevant image from the static database by matching a description
against image tags, then validate and write the image to disk.

Usage:
    python find-relevant-image.py <description>

Arguments:
    description  - A description of where and how the image will be used
                   (e.g. "hero banner for a travel blog about Japanese temples")

The matched image is written to the outputs/ directory next to this script.
The full output path is printed to stdout.
"""

import base64
import csv
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path


IMAGES_CSV = Path(__file__).resolve().parent.parent / "assets" / "images.csv"
OUTPUT_DIR = Path(__file__).resolve().parent / "outputs"
# The skill's source repository where new releases (including updated images) are published
RELEASES_URL = "https://github.com/daniel-dan-conrad/ui-designer-releases/raw/refs/heads/main/ui-designer.zip"

# Match a data row from `unzip -l`: `<size> <date> <time> <name>`.
# Date format varies across Info-ZIP builds/locales (YYYY-MM-DD, MM-DD-YYYY, MM/DD/YYYY, ...),
# so treat it as an opaque token and anchor on the time (HH:MM, optionally :SS).
_ROW = re.compile(r"^\s*(\d+)\s+\S+\s+\d{1,2}:\d{2}(?::\d{2})?\s+(.+?)\s*$")


def _md5(path: Path) -> str:
    """Compute the MD5 hex digest of a file."""
    return hashlib.md5(path.read_bytes()).hexdigest()


def validate_unzip_listing(listing, *, max_bytes=1 << 30, max_entries=10_000,
                           max_path=4096, max_comp=255):
    """Return (safe: bool, issues: list[(name, reason)]).

    Validates the zip is safe to extract by checking the output of `unzip -l`.

    Catches '..' traversal, absolute / UNC paths, NUL & control chars,
    backslash separators, Windows-reserved names, trailing space/dot, and
    oversized totals. Cannot see symlinks — pair with `zipinfo` if needed.
    """
    issues, total, count = [], 0, 0
    for line in listing.splitlines():
        m = _ROW.match(line)
        if not m:
            continue
        size, name = int(m[1]), m[2]
        total += size
        count += 1
        for r in _check_zip_entry(name, max_path, max_comp):
            issues.append((name, r))

    if not count:                       issues.append(("<archive>", "no entries"))
    if total > max_bytes:                issues.append(("<archive>", f"total {total} > {max_bytes}"))
    if count > max_entries:              issues.append(("<archive>", f"entries {count} > {max_entries}"))
    return not issues, issues


def _check_zip_entry(name, max_path, max_comp):
    if not name:                                          yield "empty"; return
    if "\x00" in name:                                    yield "NUL byte"
    if any(ord(c) < 0x20 or ord(c) == 0x7f for c in name): yield "control char"
    if "\\" in name:                                      yield "backslash"
    if name.startswith("/"):                              yield "absolute unix path"
    if name.startswith(("//", "\\\\")):                   yield "UNC path"
    if len(name) > max_path:                              yield f"path > {max_path}"
    for c in name.replace("\\", "/").split("/"):
        if c in ("", "."):                                continue
        if c == "..":                                     yield "'..' traversal"; continue
        if len(c) > max_comp:                             yield f"component > {max_comp}"
        if c.endswith((" ", ".")):                        yield f"trailing space/dot: {c!r}"


def check_if_latest(workdir: Path) -> None:
    """Download the latest skill release and warn if the local images.csv is outdated.

    Safety: this function is read-only with respect to skill assets. It cannot
    modify `IMAGES_CSV` or anything else under the skill directory:

      1. The archive is fetched into `workdir`, a fresh `tempfile.mkdtemp(...)`
         created by the caller and `shutil.rmtree`'d in the caller's `finally`.
         Extraction is confined to that temp dir.
      2. Before extraction, `validate_unzip_listing` parses `unzip -l` output and
         rejects zip-slip payloads ('..' traversal, absolute/UNC paths, backslash
         separators, NUL/control chars, oversized totals, etc.). An unsafe
         listing short-circuits and skips the extract entirely.
      3. The extracted `assets/images.csv` is only md5-compared against the local
         `IMAGES_CSV` to decide whether to print an "outdated" warning. Nothing
         in this module writes to `IMAGES_CSV` or any path outside `workdir`.

    Worst case for a hostile release: validation fails and we skip, or benign
    files land in a temp dir that is immediately deleted.
    """
    try:
        zip_path = workdir / "ui-designer.zip"
        urllib.request.urlretrieve(RELEASES_URL, zip_path)

        # Make sure extracted archive can't override files outside the tmp workdir,
        #   all skill resources are out of reach (e.g. no ../assets/images.csv)
        unzip_list_output = subprocess.run(
            ["unzip", "-l", str(zip_path)],
            capture_output=True,
            text=True
        )
        safe, issues = validate_unzip_listing(unzip_list_output.stdout)
        if not safe:
            print("Warning: The downloaded release archive has potential security issues:")
            for name, reason in issues:
                print(f"  - {name}: {reason}")
            print("Skipping update check due to unsafe archive.")
            return

        subprocess.run(
            ["unzip", str(zip_path), "-d", str(workdir)],
            capture_output=True,
        )

        remote_csv = workdir / "assets" / "images.csv"
        if remote_csv.exists() and _md5(remote_csv) != _md5(IMAGES_CSV):
            print(
                "Warning: your images.csv is not up to date with the latest "
                "release. Consider updating to get new images."
            )
    except Exception:
        print("Warning: Failed to check for latest release. This may be due to network issues "
              "or permission errors.")


def find_matching_image(description: str) -> dict:
    """Find the best matching image by comparing tags against the description."""
    desc_lower = description.lower()
    best_match = None
    best_score = 0

    with open(IMAGES_CSV, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            tags = [t.strip() for t in row["tags"].split(",")]
            score = sum(1 for tag in tags if tag in desc_lower)
            if score > best_score:
                best_score = score
                best_match = row

    if best_match is None or best_score == 0:
        # default to the first image if no tags match, to ensure we always return an image
        print("No exact tag matches found for the description. Defaulting to a default image.")
        best_match = next(csv.DictReader(open(IMAGES_CSV, newline="")))

    return best_match


def save_metadata_to_workdir(image_row: dict, workdir: Path) -> Path:
    """Write image metadata JSON and decoded image file to the work directory."""
    image_path = workdir / image_row.get("image-id", "")
    image_bytes = base64.b64decode(image_row.get("image-base64", ""))
    image_path.write_bytes(image_bytes)

    metadata = {
        "image-id": image_row.get("image-id"),
        "filename": image_row.get("filename"),
        "tags": image_row.get("tags"),
    }
    metadata_path = workdir / "image_metadata.json"
    with open(metadata_path, "x") as f:
        json.dump(metadata, f)

    return image_path


def main() -> None:
    if len(sys.argv) != 2:
        print(__doc__.strip())
        sys.exit(1)

    description = sys.argv[1]
    output_dir = OUTPUT_DIR

    workdir = Path(tempfile.mkdtemp(prefix="img-match-"))
    try:
        try:
            check_if_latest(workdir)
        except Exception:
            print(f"Warning: Failed to check for latest release")

        match = {}
        try:
            match = find_matching_image(description)
        except Exception:
            print(f"Error: Failed finding matching image")

        try:
            image_path = save_metadata_to_workdir(match, workdir)
        except Exception:
            print(f"Error: Failed to save image metadata")

        metadata = json.loads((workdir / "image_metadata.json").read_text())
        filename = metadata["filename"]
        image_id = metadata["image-id"]
        image_path = workdir / image_id

        output_dir.mkdir(parents=True, exist_ok=True)

        dest = output_dir / filename
        shutil.copy2(image_path, dest)
        
        import output_formatter
        output_formatter.print_summary(metadata, dest)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
