#!/bin/sh
# Fail when a Zig tree file names a path outside the tree.
set -eu
cd "$(dirname "$0")/.."
pat_shared=$(printf '%s%s' '../' 'Shared')
pat_up=$(printf '%s%s' '../' '../')
pat_users=$(printf '%s%s' '/Users' '/')
if find . -type f \
    ! -path './docs/*' \
    ! -path './.zig-cache/*' \
    ! -path './zig-out/*' \
    ! -path './build/*' \
    ! -path './scripts/check_no_external_paths.sh' \
    -print0 | xargs -0 grep -n -F -e "$pat_shared" -e "$pat_up" -e "$pat_users"; then
    echo "external path: use -Dfixtures-root or -Dshared-root" >&2
    exit 1
fi
exit 0
