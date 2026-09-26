"""Package our diagnostic executable as a private NSWorkspace launch fixture."""
import pathlib
import plistlib
import shutil
import subprocess
import sys

binary = pathlib.Path(sys.argv[1]).resolve()
root = pathlib.Path(sys.argv[2]).resolve()
if not (root / ".codex-tmp").is_file():
    raise SystemExit("A marked task test directory is required")
bundle = root / "TZBoxProbe.app"
contents = bundle / "Contents"
executables = contents / "MacOS"
executables.mkdir(parents=True, exist_ok=False)
shutil.copy2(binary, executables / "TZBoxProbe")
library = binary.parent / "libTZBoxCore.dylib"
if library.is_file():
    frameworks = contents / "Frameworks"
    frameworks.mkdir()
    shutil.copy2(library, frameworks / library.name)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(frameworks / library.name)], check=True)
with (contents / "Info.plist").open("wb") as stream:
    plistlib.dump({
        "CFBundleExecutable": "TZBoxProbe",
        "CFBundleIdentifier": "dev.tzbox.probe",
        "CFBundlePackageType": "APPL",
        "CFBundleName": "TZBox Probe",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "0.1.0",
        "LSBackgroundOnly": True,
        "TZBoxProbeOutput": str(root / "probe-output.json"),
    }, stream)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(bundle)], check=True)
