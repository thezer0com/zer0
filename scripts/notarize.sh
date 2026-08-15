#!/usr/bin/env bash
#
# Notarise a built and signed bundle with Apple, then staple the ticket.
# Gatekeeper refuses an unnotarised build on any Mac but the one that built
# it, which is why a release crosses this door after scripts/sign.sh.
#
# This is separate from sign.sh because notarisation needs network and Apple
# credentials, neither of which sign.sh touches. sign.sh runs on a dev machine
# with nothing but a keychain; this script does not.
#
# Two ways in (Apple recommends the first):
#
#   1. Keychain profile, stored once via `xcrun notarytool store-credentials`:
#
#        ZER0_NOTARY_PROFILE=zer0-ci ./scripts/notarize.sh
#
#      This is the shape CI takes. The profile name is the only secret that
#      has to live in the runner's environment; the .p8 key, key id and team
#      id are sealed inside the keychain.
#
#   2. App Store Connect API key, passed in directly:
#
#        ZER0_APPLE_ID=... \
#        ZER0_APPLE_KEY_ID=... \
#        ZER0_APPLE_KEY_PATH=/path/AuthKey.p8 \
#        ZER0_APPLE_TEAM_ID=... \
#        ./scripts/notarize.sh
#
# Prerequisites either way:
#   - App Store Connect API key with App Manager role (or Developer + the
#     notarisation permission).
#   - The bundle has already been through scripts/sign.sh with a Developer ID
#     Application identity. Apple refuses ad-hoc submissions with a clear
#     error, so a dev build fails here fast rather than after a 30-minute
#     wait.
#
# Why --wait: a submission without --wait returns immediately and leaves the
# caller to poll. A release pipeline that does not block on the result ships
# a bundle Apple has not verdict yet, so this script blocks by default. The
# typical wait is 5-30 minutes; Apple queues vary.

set -euo pipefail

cd "$(dirname "$0")/.."

# Resolve the same channel door every other script uses (ADR-0109), so
# `ZER0_CHANNEL=canary ./scripts/notarize.sh` finds the canary bundle without
# a separate flag.
# shellcheck source=../apple/scripts/resolve-bundle.sh
. "apple/scripts/resolve-bundle.sh"
build_bundle_id_parametrized "${ZER0_CHANNEL:-stable}" ||
	{
		echo "error: ZER0_CHANNEL must be 'stable' or 'canary'" >&2
		exit 1
	}
APP="apple/.build/${RB_APP_REL}"

if [ ! -d "$APP" ]; then
	echo "error: $APP is not there. Run ./scripts/build.sh release and ./scripts/sign.sh first." >&2
	exit 1
fi

# Ad-hoc signatures do not notarise. Better to refuse here than after Apple's
# queue -- the failure is the same but the wait is not paid.
SIG="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
case "$SIG" in
*Signature=adhoc*)
	cat >&2 <<EOF
error: $APP is ad-hoc signed. Apple notarisation requires a Developer ID
       signature. Run:

         ZER0_SIGN_IDENTITY="Developer ID Application: ... (TEAMID)" ./scripts/sign.sh
EOF
	exit 1
	;;
esac

# notarytool accepts a zip or a dmg. A zip is the smaller hammer and the
# bundle's size is dominated by the embedded WebKit either way, so there is
# no compression win worth a dmg step here.
ZIP="/tmp/$(basename "$APP").zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

note() { echo "==> $*"; }

# Submit. `--wait` blocks until Apple returns accept or reject; without it the
# submission id comes back immediately and the caller would have to poll, which
# is the wrong default for a release pipeline (see comment at the top).
if [ -n "${ZER0_NOTARY_PROFILE:-}" ]; then
	note "submitting $ZIP via keychain profile '$ZER0_NOTARY_PROFILE'"
	SUBMISSION=$(xcrun notarytool submit "$ZIP" \
		--keychain-profile "$ZER0_NOTARY_PROFILE" \
		--wait 2>&1 | tee /dev/stderr)
else
	for var in ZER0_APPLE_ID ZER0_APPLE_KEY_ID ZER0_APPLE_KEY_PATH ZER0_APPLE_TEAM_ID; do
		if [ -z "${!var:-}" ]; then
			cat >&2 <<EOF
error: $var is not set. Either set the four App Store Connect credentials
       (ZER0_APPLE_ID, ZER0_APPLE_KEY_ID, ZER0_APPLE_KEY_PATH,
        ZER0_APPLE_TEAM_ID) or store a keychain profile once via

         xcrun notarytool store-credentials zer0-ci \\
           --apple-id         \$ZER0_APPLE_ID \\
           --key-id           \$ZER0_APPLE_KEY_ID \\
           --key              \$ZER0_APPLE_KEY_PATH \\
           --team-id          \$ZER0_APPLE_TEAM_ID

       and then:

         ZER0_NOTARY_PROFILE=zer0-ci ./scripts/notarize.sh
EOF
			exit 1
		fi
	done
	note "submitting $ZIP via App Store Connect API key"
	SUBMISSION=$(xcrun notarytool submit "$ZIP" \
		--apple-id "$ZER0_APPLE_ID" \
		--key-id "$ZER0_APPLE_KEY_ID" \
		--key "$ZER0_APPLE_KEY_PATH" \
		--team-id "$ZER0_APPLE_TEAM_ID" \
		--wait 2>&1 | tee /dev/stderr)
fi

# notarytool prints `id: <uuid>` and a status block when --wait returns.
# Rejecting here surfaces an Apple-side refusal before the staple step would
# silently operate on a rejected submission.
case "$SUBMISSION" in
*Invalid*)
	echo "error: Apple rejected the submission." >&2
	exit 1
	;;
esac

# Staple the notarisation ticket to the bundle. After this the bundle
# verifies offline: a stranger's Mac does not have to hit Apple's service to
# accept it.
note "stapling"
xcrun stapler staple "$APP"

# spctl is the same check sign.sh runs, but here it must accept. A reject
# after staple means either the staple is malformed or the signature lost
# something notarisation requires, and either is a release blocker.
note "gatekeeper"
if spctl --assess --type execute --verbose "$APP" 2>&1 | sed 's/^/    /'; then
	echo "    accepted"
else
	echo "    rejected after notarisation + staple -- a release blocker." >&2
	exit 1
fi

echo
echo "==> notarised + stapled: $APP"
