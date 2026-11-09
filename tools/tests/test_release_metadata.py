from pathlib import Path
import plistlib
import re


ROOT = Path(__file__).resolve().parents[2]


def test_bundle_version_matches_documented_release():
    release = re.search(r"This is v(\d+\.\d+):", (ROOT / "README.md").read_text()).group(1)
    with (ROOT / "Resources" / "Info.plist").open("rb") as source:
        metadata = plistlib.load(source)

    assert metadata["CFBundleShortVersionString"].startswith(release + ".")
    assert int(metadata["CFBundleVersion"]) > 0
