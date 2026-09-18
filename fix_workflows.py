#!/usr/bin/env python3
import re
import sys
from pathlib import Path

WORKFLOW_DIR = Path(".github/workflows")

TARGET_FILES = [
    "publish_codespace.yml",
    "publish_nighty.yml",
    "publish_preview.yml",
    "publish_release.yml",
]

STEP_PATTERN = re.compile(
    r"[ \t]*- name: Login to Docker Hub\n"
    r"[ \t]*uses: docker/login-action@v4\n"
    r"[ \t]*with:\n"
    r"[ \t]*username: \$\{\{ secrets\.DOCKER_USERNAME \}\}\n"
    r"[ \t]*password: \$\{\{ secrets\.DOCKER_PASSWORD \}\}\n"
    r"\n?",
    re.MULTILINE,
)

def process_file(path):
    if not path.exists():
        print(f"  SKIP  {path} (not found)")
        return False

    original = path.read_text()
    new_content, count = STEP_PATTERN.subn("", original)

    if count == 0:
        print(f"  NOCHANGE  {path} (pattern not found)")
        return False

    backup_path = path.with_suffix(path.suffix + ".bak")
    backup_path.write_text(original)

    path.write_text(new_content)
    print(f"  FIXED  {path} (removed {count} block(s), backup at {backup_path})")
    return True

def main():
    if not WORKFLOW_DIR.exists():
        print(f"Error: {WORKFLOW_DIR} not found. Run this from your repo root.")
        sys.exit(1)

    print(f"Scanning {len(TARGET_FILES)} workflow files in {WORKFLOW_DIR}/...\n")

    changed = 0
    for name in TARGET_FILES:
        if process_file(WORKFLOW_DIR / name):
            changed += 1

    print(f"\nDone. {changed}/{len(TARGET_FILES)} file(s) modified.")
    if changed:
        print("Review with: git diff .github/workflows/")
        print("If it looks good: git add .github/workflows/ && git commit -m 'Remove unused Docker Hub login steps'")

if __name__ == "__main__":
    main()
