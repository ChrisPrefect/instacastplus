#!/usr/bin/env python3
import json
import struct
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ICON_ROOT = ROOT / "Resources" / "AppIcons"
PREVIEW_ROOT = ROOT / "Resources" / "Media.xcassets" / "AppIconsToShow"


def paeth(a: int, b: int, c: int) -> int:
    value = a + b - c
    distance_a = abs(value - a)
    distance_b = abs(value - b)
    distance_c = abs(value - c)
    if distance_a <= distance_b and distance_a <= distance_c:
        return a
    if distance_b <= distance_c:
        return b
    return c


def image_bounds(path: Path) -> tuple[tuple[int, int, int, int], tuple[int, int, int, int]]:
    data = path.read_bytes()
    assert data.startswith(b"\x89PNG\r\n\x1a\n"), f"{path}: not a PNG"

    offset = 8
    compressed = bytearray()
    width = height = bit_depth = color_type = interlace = None
    while offset < len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        offset += 12 + length
        if kind == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            break

    assert color_type == 6, f"{path}: expected RGBA PNG, got color type {color_type}"
    assert bit_depth in (8, 16), f"{path}: unsupported bit depth {bit_depth}"
    assert interlace == 0, f"{path}: interlaced PNG is unsupported"

    sample_bytes = bit_depth // 8
    bytes_per_pixel = 4 * sample_bytes
    row_bytes = width * bytes_per_pixel
    raw = zlib.decompress(bytes(compressed))
    assert len(raw) == height * (row_bytes + 1), f"{path}: unexpected decoded byte count"

    previous = bytearray(row_bytes)
    alpha_min_x, alpha_min_y = width, height
    alpha_max_x = alpha_max_y = -1
    marker_min_x, marker_min_y = width, height
    marker_max_x = marker_max_y = -1
    marker_threshold = int(((1 << bit_depth) - 1) * 0.75)
    cursor = 0
    for y in range(height):
        filter_kind = raw[cursor]
        cursor += 1
        encoded = raw[cursor:cursor + row_bytes]
        cursor += row_bytes
        decoded = bytearray(row_bytes)
        for index, byte in enumerate(encoded):
            left = decoded[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            above = previous[index]
            upper_left = previous[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            if filter_kind == 0:
                predictor = 0
            elif filter_kind == 1:
                predictor = left
            elif filter_kind == 2:
                predictor = above
            elif filter_kind == 3:
                predictor = (left + above) // 2
            elif filter_kind == 4:
                predictor = paeth(left, above, upper_left)
            else:
                raise AssertionError(f"{path}: unsupported PNG filter {filter_kind}")
            decoded[index] = (byte + predictor) & 0xFF

        alpha_offset = 3 * sample_bytes
        for x in range(width):
            start = x * bytes_per_pixel + alpha_offset
            if any(decoded[start:start + sample_bytes]):
                alpha_min_x = min(alpha_min_x, x)
                alpha_min_y = min(alpha_min_y, y)
                alpha_max_x = max(alpha_max_x, x)
                alpha_max_y = max(alpha_max_y, y)

            if 96 <= x < 928 and 80 <= y < 944:
                pixel_start = x * bytes_per_pixel
                channels = [
                    int.from_bytes(decoded[pixel_start + channel * sample_bytes:pixel_start + (channel + 1) * sample_bytes], "big")
                    for channel in range(4)
                ]
                if min(channels) >= marker_threshold:
                    marker_min_x = min(marker_min_x, x)
                    marker_min_y = min(marker_min_y, y)
                    marker_max_x = max(marker_max_x, x)
                    marker_max_y = max(marker_max_y, y)
        previous = decoded

    assert alpha_max_x >= 0 and alpha_max_y >= 0, f"{path}: preview is fully transparent"
    assert marker_max_x >= 0 and marker_max_y >= 0, f"{path}: preview has no central podcast marker"
    return (
        (alpha_min_x, alpha_min_y, alpha_max_x + 1, alpha_max_y + 1),
        (marker_min_x, marker_min_y, marker_max_x + 1, marker_max_y + 1),
    )


def classic_shape_position(icon_number: int) -> dict:
    path = ICON_ROOT / f"InstacastPlus_Icon_Classic_Alt{icon_number}.icon" / "icon.json"
    document = json.loads(path.read_text(encoding="utf-8"))
    layers = [layer for group in document["groups"] for layer in group["layers"]]
    matches = [layer for layer in layers if layer.get("image-name") == "Classic Shape.svg"]
    assert len(matches) == 1, f"Alt{icon_number}: expected one Classic Shape layer"
    return matches[0]["position"]


def preview_path(icon_number: int) -> Path:
    name = f"appiconClassicAlt{icon_number}"
    return PREVIEW_ROOT / f"{name}.imageset" / f"{name}.png"


def main() -> None:
    bounds = {number: image_bounds(preview_path(number)) for number in (1, 2, 3, 4)}
    reference_bounds = {bounds[number][0] for number in (1, 2, 3)}
    assert len(reference_bounds) == 1, f"Existing Classic previews disagree: {reference_bounds}"
    expected_bounds = reference_bounds.pop()
    actual_bounds = bounds[4][0]
    assert actual_bounds == expected_bounds, (
        "The blue Grid preview must occupy the same canvas as the other Classic icons; "
        f"expected {expected_bounds}, got {actual_bounds}."
    )

    reference_marker_bounds = [bounds[number][1] for number in (1, 2, 3)]
    reference_widths = sorted(marker[2] - marker[0] for marker in reference_marker_bounds)
    reference_centers_twice = sorted(marker[0] + marker[2] for marker in reference_marker_bounds)
    reference_tops = sorted(marker[1] for marker in reference_marker_bounds)
    reference_bottoms = sorted(marker[3] for marker in reference_marker_bounds)
    expected_width = reference_widths[1]
    expected_center_twice = reference_centers_twice[1]
    expected_top = reference_tops[1]
    expected_bottom = reference_bottoms[1]
    actual_marker_bounds = bounds[4][1]
    actual_width = actual_marker_bounds[2] - actual_marker_bounds[0]
    actual_center_twice = actual_marker_bounds[0] + actual_marker_bounds[2]
    assert (
        abs(actual_width - expected_width) <= 5
        and abs(actual_center_twice - expected_center_twice) <= 2
        and abs(actual_marker_bounds[1] - expected_top) <= 3
        and abs(actual_marker_bounds[3] - expected_bottom) <= 3
    ), (
        "The blue Grid preview podcast marker must match the scale and position of the other Classic previews; "
        f"reference median width/top/bottom/center2 is {expected_width}/{expected_top}/{expected_bottom}/{expected_center_twice}, "
        f"got bounds {actual_marker_bounds}."
    )

    expected_position = classic_shape_position(1)
    for number in (2, 3, 4):
        assert classic_shape_position(number) == expected_position, (
            f"Alt{number}: the podcast mark must use the same scale and position as Alt1."
        )

    print("app icon visual footprint regression checks passed")


if __name__ == "__main__":
    main()
