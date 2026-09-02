#!/usr/bin/env python3
"""Set a version in a plugin or marketplace manifest, in place, line by line.

A jq round-trip would rewrite the whole file: these manifests keep one-line
objects (`"owner": { "name": "..." }`) that json.dumps splits, and a release
diff has to show one changed line, not a reformat.

  set-version.py FILE NEW                 # the top-level "version"
  set-version.py FILE NEW --plugin NAME   # the "version" inside that plugin's entry
"""
import re
import sys

VERSION_LINE = re.compile(r'^(\s*"version"\s*:\s*")([^"]*)(".*)$')


def main() -> int:
    args = sys.argv[1:]
    plugin = None
    if "--plugin" in args:
        i = args.index("--plugin")
        plugin = args[i + 1]
        del args[i:i + 2]
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    path, new = args

    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()

    start = 0
    if plugin is not None:
        marker = re.compile(r'^\s*"name"\s*:\s*"%s"' % re.escape(plugin))
        start = next((i + 1 for i, l in enumerate(lines) if marker.match(l)), -1)
        if start == 0 or start == -1:
            print("error: no plugin entry named %r in %s" % (plugin, path), file=sys.stderr)
            return 1

    for i in range(start, len(lines)):
        m = VERSION_LINE.match(lines[i])
        if m:
            if m.group(2) == new:
                print("error: %s is already at %s" % (path, new), file=sys.stderr)
                return 1
            lines[i] = "%s%s%s\n" % (m.group(1), new, m.group(3))
            with open(path, "w", encoding="utf-8") as fh:
                fh.writelines(lines)
            return 0

    print("error: no version line found in %s" % path, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
