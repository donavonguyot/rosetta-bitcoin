#!/usr/bin/env bash
set -euo pipefail

if [ -d /data ]; then
  chown -R opam:opam /data
fi

exec runuser -u opam -- opam exec -- dune exec -- ocbitnode "$@"

