#!/bin/bash
# NAS Watchman: one-command install or upgrade on Unraid. Run as root from the unpacked folder:
#   bash install.sh
# Then: watchman setup   (choose disks/containers, connect Discord, send a test message)
# Upgrading keeps your config and alert history; 'watchman rollback' returns to the previous version.
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec bash "$HERE/watchmanctl.sh" install --from "$HERE" "$@"
