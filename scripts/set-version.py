#!/usr/bin/env python3
"""Set a version in a plugin or marketplace manifest, in place, line by line.

A jq round-trip would rewrite the whole file: these manifests keep one-line
objects (`"owner": { "name": "..." }`) that json.dumps splits, and a release
diff has to show one changed line, not a reformat.

  set-version.py FILE NEW                 # the top-level "version"
  set-version.py FILE NEW --plugin NAME   # the "version" inside that plugin's entry
  set-version.py FILE NEW --floor NAME    # every quoted `"name": NAME, "version": ">=…"` floor
"""
import re
import sys

VERSION_LINE = re.compile(r'^(\s*"version"\s*:\s*")([^"]*)(".*)$')


def take(args, flag):
    if flag not in args:
        return None
    i = args.index(flag)
    value = args[i + 1]
    del args[i:i + 2]
    return value


def set_floors(path, lines, name, new):
    semver = re.match(r'^(\d+)\.\d+\.\d+$', new)
    if not semver:
        print("error: %r is not a semver" % new, file=sys.stderr)
        return 2
    quoted = re.compile(r'("name"\s*:\s*"%s"\s*,\s*"version"\s*:\s*")>=[^"]*(")' % re.escape(name))
    # A floor admits every later release of the major it names, and nothing past it.
    bound = ">=%s <%d" % (new, int(semver.group(1)) + 1)
    count = 0
    for i, line in enumerate(lines):
        lines[i], n = quoted.subn(lambda m: m.group(1) + bound + m.group(2), line)
        count += n
    if count == 0:
        print("error: no floor for %r in %s" % (name, path), file=sys.stderr)
        return 1
    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(lines)
    return 0


def main() -> int:
    args = sys.argv[1:]
    plugin = take(args, "--plugin")
    floor = take(args, "--floor")
    if len(args) != 2 or (plugin is not None and floor is not None):
        print(__doc__, file=sys.stderr)
        return 2
    path, new = args

    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()

    if floor is not None:
        return set_floors(path, lines, floor, new)

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
