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
script_source = (ROOT / "Scripts" / "copy_kimi_builtin_env.sh").read_text() if (ROOT / "Scripts" / "copy_kimi_builtin_env.sh").exists() else ""
kimi_body_source = chapter_source.split("private func kimiChatCompletionsBody", 1)[1].split("private static let remoteChaptersSchema", 1)[0]


require(
    ".env" in gitignore and ".env.*" in gitignore,
    "Kimi built-in credentials must be read from a local .env that Git ignores.",
)

require(
    "Copy Kimi Built-In Key" in project_source
    and "Scripts/copy_kimi_builtin_env.sh" in project_source
    and "KimiBuiltin.env" in script_source
    and "KIMI_BUILTIN_API_KEY" in script_source,
    "The app target must copy only a locally generated Kimi credential resource from .env during build.",
)

require(
    "case kimiAPI" in engine_source
    and "kimi-k2.6-api-key" in engine_source
    and 'remoteModelName: "kimi-k2.6"' in engine_source
    and "Kimi K2.6" in engine_source
    and "hasKimiAPIKey" in engine_source
    and "kimiAPIKeyPreview" in engine_source
    and "kimiBuiltinEnvResourceName" in engine_source,
    "Kimi K2.6 must be a selectable chapter model with built-in or user-provided credentials.",
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
    and "validateRemoteChapterStartEvidence" in chapter_source
    and "rawChapterStartEvidenceIssue" in chapter_source
    and "remote-chapter-evidence-retry-started" in chapter_source
    and '"response_format"' in chapter_source
    and '"json_schema"' in chapter_source
    and '"thinking": ["type": "disabled"]' in chapter_source,
    "Kimi generation must use Moonshot's Chat Completions endpoint with grounded full-transcript block prompts and structured JSON output.",
)

require(
    '"temperature"' not in kimi_body_source
    and '"top_p"' not in kimi_body_source,
    "Kimi K2.6 rejects non-default sampling parameters in non-thinking mode; the app must not send them.",
)

env_path = ROOT / ".env"
if env_path.exists():
    env_values = {}
    for raw_line in env_path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env_values[key.strip()] = value.strip()

    kimi_key = env_values.get("KIMI_BUILTIN_API_KEY", "")
    require(kimi_key.startswith("sk-") and len(kimi_key) > 20, "Local .env must define KIMI_BUILTIN_API_KEY.")

    for path in [
        ROOT / "Classes" / "TranscriptionEngine.swift",
        ROOT / "Classes" / "ChapterGenerator.swift",
        ROOT / "Classes" / "TranscriptionSettingsViewController.m",
        ROOT / "Instacast.xcodeproj" / "project.pbxproj",
        ROOT / "Scripts" / "copy_kimi_builtin_env.sh",
    ]:
        require(kimi_key not in path.read_text(errors="ignore"), f"Kimi key leaked into tracked source: {path.relative_to(ROOT)}")
