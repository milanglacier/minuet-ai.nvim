#!/bin/sh
# Delegates to the real diff after a delay, keeping a recorder diff in flight
# long enough for tests to observe the in-flight and cancellation paths.
sleep 1
exec diff "$@"
