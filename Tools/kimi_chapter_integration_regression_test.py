import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


script_path = ROOT / "Scripts" / "copy_kimi_builtin_env.sh"

with tempfile.TemporaryDirectory() as temporary_directory:
    temporary_root = Path(temporary_directory)
    (temporary_root / ".env").write_text("KIMI_BUILTIN_API_KEY=harmless-regression-sentinel\n")
    build_dir = temporary_root / "Build"
    environment = os.environ.copy()
    environment.update(
        {
            "PROJECT_DIR": str(temporary_root),
            "TARGET_BUILD_DIR": str(build_dir),
            "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Resources",
        }
    )
    completed = subprocess.run(
        ["/bin/sh", str(script_path)],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    require(completed.returncode == 0, "The Kimi build script failed against a harmless test credential.")
    generated = build_dir / "Resources" / "KimiBuiltin.env"
    require(
        generated.read_text() == "KIMI_BUILTIN_API_KEY=harmless-regression-sentinel\n",
        "The Kimi build script did not create the expected bundle resource from the configured developer value.",
    )
