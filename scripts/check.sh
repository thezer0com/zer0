#!/usr/bin/env bash
# Everything that must be green before calling anything done.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Before the record is checked, the checker is. A green run from adr-check.sh
# means nothing on its own: gut its lock resolution and every lock in the
# project resolves, this script says "all green", and the decision record is
# unguarded with nothing red anywhere. The fixtures are broken ADRs it has to
# reject, so weakening it costs a failing build.
echo "==> adr fixtures"
./scripts/adr-fixtures.sh

# Then the record itself, still before the compilers, because it is the cheapest
# thing here: a lock pointing at a test that no longer exists should be heard
# before spending minutes compiling.
echo "==> adr"
./scripts/adr-check.sh

# Screenshot harnesses are how anyone looks at a view on a machine with no
# screen, and they have found defects no assertion could. They are worth
# keeping. What they must not do is run by default: they pump the run loop for
# tens of seconds, which starves the timing tests until those fail for reasons
# that have nothing to do with them — and the failure lands on a *different*
# test each run, so it reads as flakiness rather than as this.
#
# So the rule is not "no harnesses", it is "a harness is opt-in". Run one with
# ZER0_SHOT=1 swift test --filter ZZ.
echo "==> harnesses are opt-in"
for harness in $(find apple/Tests -name 'ZZ*.swift' 2>/dev/null); do
	# Every @Test in the file must carry the gate. One ungated case is enough
	# to slow every run, so counting is the check.
	tests=$(grep -c '@Test' "$harness" || true)
	gated=$(grep -c 'ZER0_SHOT"\] == nil' "$harness" || true)
	if ((tests > gated)); then
		echo "error: $harness has $tests @Test case(s) but only $gated gated." >&2
		echo "  A harness that runs by default starves the timing tests, and the" >&2
		echo "  failure surfaces on an unrelated test. Add to each case:" >&2
		echo '    .disabled(if: ProcessInfo.processInfo.environment["ZER0_SHOT"] == nil)' >&2
		exit 1
	fi
done

# Also before the compilers, and for the same reason as the record: a test that
# names a path another test also means does not fail where the mistake is. It
# fails on whichever one lost the race, reads as flakiness, gets rerun, and
# teaches nobody anything.
echo "==> scratch paths"
./scripts/scratch-check.sh

# Also cheap, also before the compilers: SF Symbols are Apple-only and the
# shell is going multi-platform (ADR-0116). The budget keeps the count moving
# down as components migrate to the licensed set, instead of quietly up.
echo "==> sf symbol budget"
./scripts/sf-symbol-budget.sh

# Also cheap, also before the compilers: the design tokens are data in
# design/tokens.toml and the Swift shell is a hand-written consumer of them
# (ADR-0117). This is what keeps the copy honest — one side edited without
# the other is a red build here, not two platforms drifting apart quietly.
echo "==> design tokens"
./scripts/token-check.sh

echo "==> cargo fmt"
cargo fmt --all --check

echo "==> cargo clippy"
cargo clippy --all-targets --all-features -- -D warnings

echo "==> cargo test"
cargo test --all-features

# The Swift side only exists on macOS; skip it elsewhere so Linux CI still runs
# the core.
if [[ "$(uname)" == "Darwin" ]]; then
	echo "==> swift build"
	./apple/scripts/build-core.sh
	export ZER0_RUST_PROFILE=debug
	# The suite runs in two processes, and the second list is what decides the
	# split. Measured on macOS 27.0 beta 5 (installed 2026-08-14, the day this
	# broke): one WebContent process receiving a sibling's IPC teardown dies
	# with EXC_ARM_PAC_FAIL inside IPC::Connection::dispatchDidCloseAndInvalidate
	# (~/Library/Logs/DiagnosticReports/com.apple.WebKit.WebContent-*.ips), and
	# with a whole-run mesh in flight each death cascades — WebKit relaunches
	# the crashed processes, every load already in flight is orphaned, and the
	# WebKit suites hang past their 90 s deadlines until 53 issues report.
	# Identical issues on identical suites across runs, green in under 5 s for
	# the same suites isolated: a scheduling cliff, not a slow machine.
	# PageProcessTests kills web content processes on purpose, so the cascade
	# has a trigger every run; all this repo can choose is the size of the mesh
	# the trigger lands in. Two processes of 482 and 180 tests each stay green
	# (25.8 s and 4.0 s); one process of 662 goes red every time. The second
	# list must stay a filter the first line can name exactly: run one is
	# "everything except these", so a new suite can never fall between the two
	# runs — it lands in run one, which has headroom to spare.
	#
	# 2026-08-16: the multi-host groundwork grew the suite past run one's
	# headroom — 470 tests flaked red in 11 of 19 full runs, the victim
	# varying per run (restored file:// loads failing "Cannot open file"
	# transiently, download resume, autoplay policy), every failure a WebKit
	# load starving past its deadline, green in isolation and green on the
	# clean HEAD under synthetic load 13. ADR-0115 names this exact moment:
	# "if run one starts failing as suites are added, the cliff has moved,
	# not the machine: grow the second list." The fragile end-to-end victims
	# moved here; PageProcessTests — the trigger — stays in run one, whose
	# mesh is now the smaller one for it.
	readonly HEAVY='DownloadEndToEndTests|DownloadResumeTests|EnginePolicyTests|NavigationRoundTripTests|NavigationStateTests|ExtensionApiTests|ExtensionPageTests|ExtensionHostTests|ExtensionDownloadRefusalTests|InstallOfferTests|ExtensionCompatTests|ExtensionStatusTests|ExtensionTabTests|ExtensionConsentTests|ExtensionConsentScrollTests|ExtensionPinTests|ExtensionPopupDialogTests|StoreInstallButtonStateTests|StoreInstallFallbackTests|StoreInstallHostRuleTests|StoreInstallMessageTests|StoreInstallRequestTests|SplitPersistenceTests|SplitShortcutTests|SplitTests|TabDragTests|UpdateChannelTests|UserAgentTests|UserAgentRecordTests|WebInspectorTests|WindowRoleTests|WindowTopTests|Zer0MarkTests|ZZ'
	(cd apple &&
		swift build &&
		echo "==> swift test (main)" &&
		swift test --skip "$HEAVY" &&
		echo "==> swift test (second list)" &&
		swift test --filter "$HEAVY")
fi

echo "all green"
