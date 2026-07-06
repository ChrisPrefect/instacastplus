from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Instacast.xcodeproj" / "project.pbxproj"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


project = PROJECT.read_text()

expectations = {
    "com.iteconomy.instacastplus.watchkitapp": "InstacastPlus Watch Development",
    "com.iteconomy.instacastplus.watchkitapp.widgets": "InstacastPlus Watch Widgets Development",
}

for bundle_id, profile_name in expectations.items():
    matching_blocks = []
    for block in project.split("isa = XCBuildConfiguration;"):
        if f"PRODUCT_BUNDLE_IDENTIFIER = {bundle_id};" in block:
            matching_blocks.append(block)

    require(len(matching_blocks) == 2, f"Expected Debug and Release build settings for {bundle_id}.")

    for block in matching_blocks:
        require(
            "CODE_SIGN_STYLE = Manual;" in block,
            f"{bundle_id} must use manual signing to avoid Xcode choosing the stale wildcard profile.",
        )
        require(
            f'PROVISIONING_PROFILE_SPECIFIER = "{profile_name}";' in block,
            f"{bundle_id} must use the explicit {profile_name} provisioning profile.",
        )
