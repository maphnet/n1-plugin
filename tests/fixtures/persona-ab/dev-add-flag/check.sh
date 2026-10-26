#!/usr/bin/env bash
# Pass when --shout upper-cases the greeting and the default is unchanged.
cd "$1" || exit 1
[ "$(python3 greet.py Bob)" = "Hello, Bob!" ] || exit 1
[ "$(python3 greet.py Bob --shout)" = "HELLO, BOB!" ]
