---
name: instacast-settings-localization-backup
description: "Use in the InstacastPlus repo when adding, changing, hiding, importing, exporting, or reviewing user settings, defaults, notification toggles, podcast settings, transcription settings, watch settings, or other user-facing preferences. This skill ensures settings are placed consistently, localized in German and English, backed up and restored when durable, and covered by focused regression checks."
---

# Instacast Settings Localization Backup

## Workflow

1. Locate the nearest existing setting pattern before editing.
   - Common controllers include `GeneralSettingsViewController`, `AppearanceSettingsViewController`, podcast settings, transcription settings, and Apple Watch settings.
   - Use existing `USER_DEFAULTS` keys, table sections, cells, switches, and notification patterns.
2. Define the default explicitly.
   - If the user asks for `default off`, keep the stored default and UI state aligned.
   - Do not suppress the underlying feature or error path unless the setting is specifically meant to do that.
3. Add or move UI in the requested section and order.
   - Match existing icon, color, row height, and table style.
   - Use `ICBackgroundColor`, `ICTextColor`, and `ICTintColor` for app UI colors.
4. Localize every user-facing string in both:
   - `Resources/de.lproj/Localizable.strings`
   - `Resources/en.lproj/Localizable.strings`
   Include widget or watch localization files too when the setting appears there.
5. If the setting or feature state is durable user data, update backup export and import together.
   - Export and import must use matching keys and categories.
   - Do not restore transient runtime state such as active downloads unless the existing backup format already does so intentionally.
6. Add or extend the narrowest `Tools/*_regression_test.py` check for the setting, localization, and backup/import contract.
7. Run the focused regression test and `git diff --check` on touched paths. Build only when the setting touches larger compiled surfaces.

## Checklist

- Setting key has one source of truth.
- Default value matches UI and behavior.
- DE and EN strings exist and are referenced by key.
- Backup export and import stay symmetric for durable settings.
- Existing behavior is unchanged when the setting is off.
- No unrelated formatting, refactors, or cleanup.

## Final Response

State where the setting lives, the default, which DE/EN strings were added, whether backup import/export changed, and which validation commands passed.
