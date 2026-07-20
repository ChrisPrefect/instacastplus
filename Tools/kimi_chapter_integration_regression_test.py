import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


engine_source = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()
settings_source = (ROOT / "Classes" / "TranscriptionSettingsViewController.m").read_text()
chapter_source = (ROOT / "Classes" / "ChapterGenerator.swift").read_text()
project_source = (ROOT / "Instacast.xcodeproj" / "project.pbxproj").read_text()
gitignore = (ROOT / ".gitignore").read_text()
script_path = ROOT / "Scripts" / "copy_kimi_builtin_env.sh"
german_source = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()
english_source = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()
kimi_body_source = chapter_source.split("private func kimiChatCompletionsBody", 1)[1].split("private static let remoteChaptersSchema", 1)[0]


require(
    ".env" in gitignore and ".env.*" in gitignore,
    "Local developer credentials must remain ignored by Git.",
)

require(
    script_path.exists()
    and "Copy Kimi Built-In Key" in project_source
    and "copy_kimi_builtin_env.sh" in project_source
    and "KimiBuiltin.env" in project_source,
    "The intentionally integrated Kimi access is no longer copied into the app bundle at build time.",
)

require(
    "case kimiAPI" in engine_source
    and "kimi-k3-api-key" in engine_source
    and 'remoteModelName: "kimi-k3"' in engine_source
    and "Kimi K3" in engine_source
    and "hasKimiAPIKey" in engine_source
    and "hasKimiUserAPIKey" in engine_source
    and "kimiAPIKeyPreview" in engine_source
    and "if let userKey = kimiUserAPIKey(), !userKey.isEmpty" in engine_source
    and "return kimiBuiltinAPIKey()" in engine_source
    and "static func kimiUserAPIKey() -> String?" in engine_source
    and "return secret(account: kimiAPIKeyAccount)" in engine_source
    and "if hasKimiUserAPIKey()" in engine_source
    and 'NSLocalizedString("Integrierter Zugang"' in engine_source
    and 'private static let kimiBuiltinEnvResourceName = "KimiBuiltin"' in engine_source
    and 'private static let kimiBuiltinEnvKey = "KIMI_BUILTIN_API_KEY"' in engine_source,
    "Kimi must prefer the user Keychain key and otherwise use the intentionally integrated bundle key.",
)

require(
    "Analyse mit aktivem Reasoning. Geschätzte Kosten pro 1 h Transkript" in engine_source
    and "Eigener Key wird im iOS-Keychain gespeichert und überschreibt den integrierten Kimi-Zugang." in settings_source
    and "Analyse mit aktivem Reasoning. Geschätzte Kosten pro 1 h Transkript" in german_source
    and "Analysis with reasoning enabled. Estimated cost per 1-hour transcript" in english_source
    and "Integrierter Zugang" in german_source
    and "Integrierter Zugang" in english_source,
    "Kimi model and credential settings no longer describe the integrated-access and user-key priority contract.",
)

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

require(
    "case ICChapterModelProviderKimiAPI:" in settings_source
    and "_showKimiAPIKeyEditor" in settings_source
    and "Kimi API-Key" in settings_source
    and "case TSSectionCloud: return 4;" in settings_source
    and "https://platform.kimi.ai" in settings_source,
    "Settings must expose Kimi API key management and model-selection credential setup.",
)

require(
    "https://api.moonshot.ai/v1/chat/completions" in chapter_source
    and "generateKimiJSONObject" in chapter_source
    and "openAIChatCompletionOutputText" in chapter_source
    and "buildRemoteDirectChaptersPrompt" in chapter_source
    and "evidenceText" in chapter_source
    and "Transkript-Bloecke" in chapter_source
    and "transcriptPromptBlockDuration" in chapter_source
    and "cue.end > blockStart" in chapter_source
    and "Promotion wieder in redaktionellen Inhalt uebergeht" in chapter_source
    and "Ein Oberthema reicht nicht als Kapitel" in chapter_source
    and "Vermeide Sammelkapitel" in chapter_source
    and "Ticketverfuegbarkeit" in chapter_source
    and "zusammenhaengenden Unterstuetzungs-, Abo-, Spenden-, Preis-, Zahlungs- oder Mitgliedschaftsblocks" in chapter_source
    and "Reine Servicehinweise zum bestehenden Podcast" in chapter_source
    and "validateRemoteChapterStartEvidence" in chapter_source
    and "rawChapterStartEvidenceIssue" in chapter_source
    and "remote-chapter-evidence-retry-started" in chapter_source
    and "zwei verschiedene Promotion-Segmente nacheinander" in chapter_source
    and '"response_format"' in chapter_source
    and '"json_schema"' in chapter_source
    and '"thinking": ["type": "disabled"]' not in chapter_source,
    "Kimi generation must use Moonshot's Chat Completions endpoint with grounded full-transcript block prompts and structured JSON output.",
)

require(
    '"temperature"' not in kimi_body_source
    and '"top_p"' not in kimi_body_source,
    "Kimi K3 rejects non-default sampling parameters; the app must not send them.",
)
