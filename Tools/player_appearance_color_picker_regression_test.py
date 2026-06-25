#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def check_controller(path: str) -> None:
    source = read(path)
    require(
        "_archivedColorForDefaultsKey:" in source
        and "unarchivedObjectOfClass:[UIColor class]" in source,
        f"{path} must read archived UIColor defaults through one source-aware helper.",
    )
    require(
        "self->selectedPlayerColor = [self _archivedColorForDefaultsKey:PlayerThemeColorCode];" in source
        and "picker.selectedColor = self->selectedPlayerColor;" in source,
        f"{path} must open the player color picker with the stored player color selected.",
    )
    require(
        "self->selectedThemeColor = [self _archivedColorForDefaultsKey:InterfaceThemeColorCode];" in source
        and "picker.selectedColor = self->selectedThemeColor;" in source,
        f"{path} must open the interface controls color picker with the stored controls color selected.",
    )


check_controller("Classes/AppearanceSettingsViewController.m")
check_controller("Classes/GeneralSettingsViewController.m")
print("player appearance color picker regression checks passed")
