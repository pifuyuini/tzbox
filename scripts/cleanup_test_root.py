"""Remove only the marked, recorded test directory when its contents are known."""
import pathlib
import shutil
import sys

repo = pathlib.Path(sys.argv[1]).resolve()
root = pathlib.Path(sys.argv[2])
if root.is_symlink() or root.resolve().parent != (repo / "tmp").resolve() or not (root / ".codex-tmp").is_file():
    raise SystemExit(f"Refusing cleanup of unmarked/non-task directory: {root}")
known_files = {
    ".codex-tmp", "probe-output.json", "fixture-requests.jsonl", "fixture-server.json",
    "TZBoxProbe.app/Contents/Info.plist", "TZBoxProbe.app/Contents/MacOS/TZBoxProbe",
    "TZBoxProbe.app/Contents/_CodeSignature/CodeResources",
    "TZBoxProbe.app/Contents/Frameworks/libTZBoxCore.dylib",
}
known_directories = {
    "TZBoxProbe.app", "TZBoxProbe.app/Contents", "TZBoxProbe.app/Contents/MacOS",
    "TZBoxProbe.app/Contents/_CodeSignature", "TZBoxProbe.app/Contents/Frameworks",
}
for path in root.rglob("*"):
    relative = path.relative_to(root).as_posix()
    if path.is_symlink() or (path.is_file() and relative not in known_files) or (path.is_dir() and relative not in known_directories):
        raise SystemExit(f"Retaining unexpected test artifact: {path}")
shutil.rmtree(root)
