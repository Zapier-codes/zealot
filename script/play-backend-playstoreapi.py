#!/usr/bin/env python3
# play-backend-playstoreapi: the vendored Python `playstoreapi` client behind Play::BackendRunner
# (app/services/play/backend_runner.rb), Z-P25 / docs/UNOFFICIAL-ROUTES.md §1.1 rule 2.
#
# Contract, exactly what the runner expects:
#
#     play-backend-playstoreapi <packageName>   ->   one JSON object on stdout, exit 0, on success
#     (any failure)                             ->   non-zero exit, message on stderr
#
# Why this file exists at all: the vendored library has no CLI, and `GooglePlayAPI.envLogin()` prints
# login chatter ("Anonymous login", the token) to stdout. The runner parses stdout as one JSON object, so
# that chatter would make every read look like "backend output was not JSON". This wrapper calls the
# library with quiet=True and writes NOTHING to stdout but the JSON.
#
# Login comes from the environment (envLogin()'s own rules, so nothing is re-implemented here):
#   PLAYSTORE_TOKEN + PLAYSTORE_GSFID          a saved anonymous token
#   PLAYSTORE_DISPENSER_URL                    a token dispenser, for a fresh anonymous login
#   PLAYSTORE_LOCALE / PLAYSTORE_TIMEZONE      optional, default en_US / UTC
# Either source works; with neither, the wrapper exits non-zero and the runner counts it a miss (which is
# the correct degrade: the panel hides rather than the page erroring).

import json
import os
import sys


def fail(message, code=1):
    print(message, file=sys.stderr)
    sys.exit(code)


def main(argv):
    if len(argv) != 1:
        fail("usage: play-backend-playstoreapi <packageName>")
    package = argv[0].strip()
    if not package:
        fail("empty package name")

    # This script lives in <repo>/script/, so the vendored client is a sibling of the repo root.
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    vendored = os.path.join(root, "vendor", "play", "playstoreapi")
    if not os.path.isdir(vendored):
        fail("vendored playstoreapi not found at %s (run script/vendor-play-clients.sh)" % vendored)
    sys.path.insert(0, vendored)

    try:
        from playstoreapi.googleplay import GooglePlayAPI
    except Exception as error:  # noqa: BLE001 - the runner only needs a non-zero exit and a reason
        fail("cannot import vendored playstoreapi: %s" % error)

    api = GooglePlayAPI(
        locale=os.environ.get("PLAYSTORE_LOCALE", "en_US"),
        timezone=os.environ.get("PLAYSTORE_TIMEZONE", "UTC"),
    )

    try:
        # quiet=True: keep the library's login prints off stdout.
        api.envLogin(quiet=True)
    except Exception as error:  # noqa: BLE001
        fail("login failed: %s" % error)

    try:
        detail = api.details(package)
    except Exception as error:  # noqa: BLE001
        fail("details failed: %s" % error)

    if not detail:
        fail("no detail returned for %s" % package)

    # `default=str` keeps an unexpected protobuf leaf (a bytes/enum) from turning a readable panel into a
    # crash; the normaliser only reads the string/number fields it knows.
    try:
        sys.stdout.write(json.dumps(detail, default=str, ensure_ascii=False))
        sys.stdout.write("\n")
    except Exception as error:  # noqa: BLE001
        fail("cannot serialise detail: %s" % error)


if __name__ == "__main__":
    main(sys.argv[1:])
