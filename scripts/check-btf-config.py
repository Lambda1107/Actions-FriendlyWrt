#!/usr/bin/env python3
"""Reject changes other than full DWARF and pahole version metadata."""

import json
import re
import sys
from pathlib import Path


ASSIGNMENT = re.compile(r"(CONFIG_[A-Za-z0-9_]+)=(.+)")
UNSET = re.compile(r"# (CONFIG_[A-Za-z0-9_]+) is not set")
VALUE = re.compile(r'(?:[ymn]|-?[0-9]+|0[xX][0-9a-fA-F]+|"(?:[^"\\]|\\.)*")')

# These are evidence from szr, not additional kernel features to enable.
REQUIRED = {
    "CONFIG_ARM64": "y",
    "CONFIG_64BIT": "y",
    "CONFIG_CC_VERSION_TEXT": '"aarch64-linux-gnu-gcc (ctng-1.25.0-119g-FA) 11.3.0"',
    "CONFIG_CC_IS_GCC": "y",
    "CONFIG_CC_IS_CLANG": "n",
    "CONFIG_GCC_VERSION": "110300",
    "CONFIG_CLANG_VERSION": "0",
    "CONFIG_AS_IS_GNU": "y",
    "CONFIG_AS_VERSION": "23800",
    "CONFIG_LD_IS_BFD": "y",
    "CONFIG_LD_VERSION": "23800",
    "CONFIG_LLD_VERSION": "0",
    "CONFIG_DEBUG_INFO": "y",
    "CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT": "y",
    "CONFIG_DEBUG_INFO_BTF": "n",
    "CONFIG_DEBUG_INFO_BTF_MODULES": "n",
    "CONFIG_KPROBES": "n",
    "CONFIG_BPF_STREAM_PARSER": "n",
    "CONFIG_NET_SOCK_MSG": "y",
    "CONFIG_INET": "y",
}


def read_config(path):
    values = {}
    for number, raw in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        unset = UNSET.fullmatch(line)
        assignment = ASSIGNMENT.fullmatch(line)
        if unset:
            key, value = unset.group(1), "n"
        elif assignment:
            key, value = assignment.groups()
            if not VALUE.fullmatch(value):
                raise ValueError(f"{path}:{number}: invalid value for {key}: {value!r}")
        elif not line or (line.startswith("#") and not line.startswith("# CONFIG_")):
            continue
        else:
            raise ValueError(f"{path}:{number}: malformed config line: {line!r}")
        if key in values:
            raise ValueError(f"{path}:{number}: duplicate symbol {key}")
        values[key] = value
    return values


def main(argv):
    report = {"ok": False, "changes": [], "checks": {}, "errors": []}
    if len(argv) != 3:
        report["errors"].append("usage: check-btf-config.py BASE_CONFIG BUILT_CONFIG")
        print(json.dumps(report, indent=2, sort_keys=True))
        return 2

    configs = {}
    for label, path in zip(("baseline", "built"), argv[1:]):
        report[label] = path
        try:
            configs[label] = read_config(path)
        except (OSError, UnicodeError, ValueError) as error:
            report["errors"].append(str(error))
    if len(configs) != 2:
        print(json.dumps(report, indent=2, sort_keys=True))
        return 1

    baseline, built = configs["baseline"], configs["built"]
    for key in sorted(baseline.keys() | built.keys()):
        # Kconfig omits invisible disabled symbols instead of writing "not set".
        before, after = baseline.get(key, "n"), built.get(key, "n")
        if before == after:
            continue
        reason = None
        if key == "CONFIG_DEBUG_INFO_REDUCED" and (before, after) == ("y", "n"):
            reason = "Full DWARF for standalone BTF extraction only"
        elif (
            key == "CONFIG_PAHOLE_VERSION"
            and before.isdecimal()
            and after.isdecimal()
            and int(before) > 0
            and int(after) > 0
        ):
            reason = "Pahole version metadata; capability booleans must remain identical"
        report["changes"].append({
            "key": key,
            "baseline": before,
            "built": after,
            "allowed": reason is not None,
            "reason": reason,
        })
        if reason is None:
            report["errors"].append(f"Forbidden config drift: {key}: {before} -> {after}")

    requirements = {key: (value, value) for key, value in REQUIRED.items()}
    requirements["CONFIG_DEBUG_INFO_REDUCED"] = ("y", "n")
    for key, (expected_baseline, expected_built) in sorted(requirements.items()):
        before, after = baseline.get(key, "n"), built.get(key, "n")
        passed = (before, after) == (expected_baseline, expected_built)
        report["checks"][key] = {"baseline": before, "built": after, "ok": passed}
        if not passed:
            report["errors"].append(
                f"{key}: expected baseline={expected_baseline}, built={expected_built}; "
                f"got baseline={before}, built={after}"
            )

    report["ok"] = not report["errors"]
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
