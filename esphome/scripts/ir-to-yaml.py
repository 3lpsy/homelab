#!/usr/bin/env python3
"""
Convert a Flipper Zero .ir file (raw mode) to ESPHome remote_transmitter
button blocks.

Usage:
    esphome/scripts/ir-to-yaml.py esphome/Remote.ir [--prefix dreo]
"""

import argparse
import re
import sys
from pathlib import Path

# Per-device rename map: Flipper button name -> HA-side button name.
# Edit this when capturing a new remote.
RENAME = {
    "Power": "Power",
    "Decrease": "Speed Down",
    "Increase": "Speed Up",
    "Rotate": "Oscillate",
    "Mode": "Mode",
}

# Spaces longer than this (microseconds) are treated as frame separators.
# Most consumer-IR protocols use a 5-100ms gap between frames; data-bit
# spaces are < 2ms.
FRAME_GAP_US = 3000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ir_file", type=Path)
    ap.add_argument("--prefix", default="dreo",
                    help="Friendly-name prefix and id_ prefix")
    ap.add_argument("--single-frame", action="store_true",
                    help="Extract first frame only and use ESPHome repeat: "
                         "instead of dumping the full captured signal. Smaller "
                         "binary but some devices reject the simplified pattern.")
    ap.add_argument("--repeats", type=int, default=4,
                    help="(--single-frame only) Frame repeat count")
    ap.add_argument("--gap-ms", type=int, default=8,
                    help="(--single-frame only) Delay between frame repeats")
    args = ap.parse_args()

    text = args.ir_file.read_text()
    blocks = re.split(r"^name: ", text, flags=re.M)[1:]

    print("button:")
    for blk in blocks:
        flipper_name = blk.split("\n", 1)[0].strip()
        pretty = RENAME.get(flipper_name, flipper_name)
        data = re.search(r"^data: (.+)$", blk, re.M)
        if not data:
            print(f"# skipped {flipper_name}: no data line", file=sys.stderr)
            continue

        nums = [int(x) for x in data.group(1).split()]
        if args.single_frame:
            # Extract first frame only; alternate signs (mark+, space-).
            frame = []
            for i, n in enumerate(nums):
                is_space = (i % 2 == 1)
                if is_space and n > FRAME_GAP_US:
                    break
                frame.append(-n if is_space else n)
        else:
            # Use the full captured signal — every frame, every gap. Most
            # reliable across devices; some fans/ACs reject single-frame
            # simplifications. ~3KB per button in compiled flash, fine.
            frame = [n if i % 2 == 0 else -n for i, n in enumerate(nums)]

        slug = pretty.lower().replace(" ", "_")
        code_list = ", ".join(str(c) for c in frame)
        print(f"  - platform: template")
        print(f'    name: "{args.prefix.title()} {pretty}"')
        print(f"    id: {args.prefix}_{slug}")
        print(f"    on_press:")
        if args.single_frame:
            print(f"      - repeat:")
            print(f"          count: {args.repeats}")
            print(f"          then:")
            print(f"            - remote_transmitter.transmit_raw:")
            print(f"                carrier_frequency: 38000")
            print(f"                code: [{code_list}]")
            print(f"            - delay: {args.gap_ms}ms")
        else:
            print(f"      - remote_transmitter.transmit_raw:")
            print(f"          carrier_frequency: 38000")
            print(f"          code: [{code_list}]")


if __name__ == "__main__":
    main()
