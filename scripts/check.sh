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
while IFS= read -r harness; do
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
done < <(find apple/Tests -name 'ZZ*.swift' -print 2>/dev/null)

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

# The icon pipeline extracts path elements from a shared SVG source. Keep its
# comment handling behind a cheap fixture so disabled artwork cannot silently
# return to the generated app icon.
echo "==> app icon source"
bash ./apple/scripts/test-make-icon.sh

# Also cheap, also before the compilers: version.txt is the one place a WebKit
# revision is written down, and common.sh plus three workflows parse it as
# data -- a key renamed on one side is a channel silently building the other's
# engine, because every cache key still resolves. The contract is held here
# (ADR-0124).
echo "==> webkit versions"
./scripts/webkit/check-versions.sh

# Also cheap, also before the compilers: the release base must have a complete,
# local history without subjects that plainly announce unfinished work. This is
# deliberately not a remote push check; a laptop cannot prove GitHub state.
echo "==> commit history"
./scripts/commit-history.sh

# Also cheap, also before the compilers: the release policy is written in
# two workflow files (ADR-0125) and nothing on a laptop executes a workflow
# -- these greps are what keep "documented" meaning "still written down".
echo "==> release policy"
./scripts/check-release-policy.sh

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
	# Engine-built menus leave process-scoped AppKit state behind on macOS 27.
	# Discover every case rather than maintain a second list, then give each one
	# the clean helper its lifecycle requires (ADR-0135).
	run_page_menu_tests() {
		local page_menu_tests test test_filter output completed
		if ! page_menu_tests="$(swift test list | grep '^Zer0ShellTests\.PageMenuTests/')"; then
			echo "error: swift test list found no PageMenuTests" >&2
			return 1
		fi
		while IFS= read -r test; do
			echo "==> swift test ($test)"
			# SwiftPM lists target/suite/method(), but its filter only matches the
			# method token as a substring. The completion count below is the second
			# half of this lock: a collision must fail rather than run two cases.
			test_filter="${test##*/}"
			test_filter="${test_filter%()}"
			if ! output="$(swift test --skip-build --filter "$test_filter" 2>&1)"; then
				printf '%s\n' "$output"
				return 1
			fi
			printf '%s\n' "$output"
			completed="$(grep -c 'Test run with 1 test in 1 suite passed after' <<<"$output" || true)"
			if ((completed != 1)); then
				echo "error: $test did not record exactly one completed test" >&2
				return 1
			fi
		done <<<"$page_menu_tests"
	}

	# The shared suite runs in measured process groups whose lists decide the
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
	#
	# 2026-09-03: the second process had grown from 180 to 250 tests and crossed
	# the same cliff. Five affected suites all passed in isolation; the stable
	# measured boundary was a 219-test remainder, 19 WebKit I/O tests and the 12
	# ExtensionHost tests. One 31-test process containing both WebKit groups
	# still failed, so that tempting simplification is not equivalent.
	# Later that day the 461-test main process passed while still leaving two
	# WebContent PAC-failure reports. Exact groups between 34 and 89 tests stayed
	# clean; recombinations between 74 and 372 tests reproduced the reports.
	# Keep suite filters anchored: an unanchored SettingsTests filter also matches
	# methods in ChatSettingsTests and silently splits one suite across helpers.
	exact_suites() {
		printf '^Zer0ShellTests\\.(%s)/' "$1"
	}

	readonly HEAVY='EnginePolicyTests|NavigationRoundTripTests|ExtensionPageTests|ExtensionDownloadRefusalTests|InstallOfferTests|ExtensionCompatTests|ExtensionStatusTests|ExtensionTabTests|ExtensionConsentTests|ExtensionConsentScrollTests|ExtensionPinTests|ExtensionPopupDialogTests|StoreInstallButtonStateTests|StoreInstallFallbackTests|StoreInstallHostRuleTests|StoreInstallMessageTests|StoreInstallRequestTests|SplitPersistenceTests|SplitShortcutTests|SplitTests|TabDragTests|UpdateChannelTests|UserAgentTests|UserAgentRecordTests|WebInspectorTests|WindowRoleTests|WindowTopTests|Zer0MarkTests|ZZ.*'
	readonly WEBKIT_IO='DownloadEndToEndTests|DownloadResumeTests|NavigationStateTests|ExtensionApiTests'
	readonly EXTENSION_HOST='ExtensionHostTests'
	readonly APPKIT_STATE='BookmarkTests|CommandBarFocusTests|SettingsTests|ShortcutTests'
	readonly PAGE_SURFACE='HistoryAndDownloadPageTests|ImageCopyNoticeTests|SidebarWidthTests|SiteIconTests'
	readonly WEBKIT_RUNTIME='ContentBlockingTests|ImageCopyTests|InternalPageTests|PageDialogTests|PagePrintTests|PageProcessTests|PopupTests|SitePermissionTests|SpaceLensTests'
	readonly CHAT_AND_IDENTITY='AboutVersionTests|AdoptedPaletteTests|AirTrafficTests|AuthLedgerTests|AuthSourceRuleTests|BrowserWindowClaimTests|BundleIdTests|CertificateFactsTests|ChatPageTests|ChatProseTests|ChatProviderTests|ChatSettingsTests'
	readonly INPUT_AND_DOWNLOADS='ChromeParityTests|ChromeTintTests|CommandBarDestinationTests|ConfigTests|DesignVocabularyTests|DownloadErrorMappingTests|DownloadHonestyTests|DownloadRoundTripTests|DownloadShortcutTests|ExtensionUnreadTests|ExternalSchemeDoorTests|ExternalSchemeTests|KeyPressTests'
	readonly MCP_RUNTIME='LiveProxyTests|LucideIconTests|McpConnectionStatusTests|McpConversationTests|McpFailureTests|McpHttpLinkTests|McpIdentifierTests|McpMalformedTests|McpRuntimeTests|McpVocabularyTests|MotionTests|NativeHostFramingTests|NativeHostRowTests|NativeMessagingConversationTests|NativeMessagingGateTests|NavigationStackReportTests|OnePasswordProbe|OnePasswordSignInProbe|PageChromeTests'
	readonly PERSISTENCE_AND_TRUST='PageDialogSourceRuleTests|PaletteContrastTests|PasswordTests|PersistenceTests|SecretStoreChannelTests|ServerTrustGateTests|SessionPersistenceTests'
	readonly SHARDED="$HEAVY|$WEBKIT_IO|$EXTENSION_HOST|$APPKIT_STATE|$PAGE_SURFACE|$WEBKIT_RUNTIME|$CHAT_AND_IDENTITY|$INPUT_AND_DOWNLOADS|$MCP_RUNTIME|$PERSISTENCE_AND_TRUST"
	# This suite renders real windows on the main actor. In the main shard it
	# starved an unrelated five-second timer past 20 seconds; in HEAVY it moved
	# the same scheduling cliff into the WebKit download suites. Alone it takes
	# six seconds, so a third shard removes the contention rather than hiding it.
	readonly SIDEBAR_LAYOUT='SidebarLayoutTests'
	(cd apple &&
		swift build &&
		echo "==> swift test (main)" &&
		swift test --skip "$(exact_suites "$SHARDED|$SIDEBAR_LAYOUT|PageMenuTests")" &&
		echo "==> swift test (heavy remainder)" &&
		swift test --filter "$(exact_suites "$HEAVY")" &&
		echo "==> swift test (WebKit I/O)" &&
		swift test --filter "$(exact_suites "$WEBKIT_IO")" &&
		echo "==> swift test (extension host)" &&
		swift test --filter "$(exact_suites "$EXTENSION_HOST")" &&
		echo "==> swift test (AppKit state)" &&
		swift test --filter "$(exact_suites "$APPKIT_STATE")" &&
		echo "==> swift test (page surface)" &&
		swift test --filter "$(exact_suites "$PAGE_SURFACE")" &&
		echo "==> swift test (WebKit runtime)" &&
		swift test --filter "$(exact_suites "$WEBKIT_RUNTIME")" &&
		echo "==> swift test (chat and identity)" &&
		swift test --filter "$(exact_suites "$CHAT_AND_IDENTITY")" &&
		echo "==> swift test (input and downloads)" &&
		swift test --filter "$(exact_suites "$INPUT_AND_DOWNLOADS")" &&
		echo "==> swift test (MCP runtime)" &&
		swift test --filter "$(exact_suites "$MCP_RUNTIME")" &&
		echo "==> swift test (persistence and trust)" &&
		swift test --filter "$(exact_suites "$PERSISTENCE_AND_TRUST")" &&
		echo "==> swift test (sidebar layout)" &&
		swift test --filter "$(exact_suites "$SIDEBAR_LAYOUT")" &&
		echo "==> swift test (isolated page menus)" &&
		run_page_menu_tests)

	# The shared set is locked from both sides. `swift build` above proves the
	# macOS half; this proves the same files still compile against the iOS SDK
	# — a shell file that drifts onto a macOS-only API fails here, at the gate,
	# rather than in the iOS host's build a world away (ADR-0123). Typecheck
	# only: no simulator, no Xcode, seconds.
	echo "==> ios typecheck"
	./apple/scripts/typecheck-ios.sh
fi

echo "all green"
