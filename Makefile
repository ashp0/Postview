# Postview — a PDF viewer for OS X 10.9 Mavericks.
#
# Built with a current Xcode toolchain but targeted at 10.9. Two things make
# that safe:
#   * -mmacosx-version-min=10.9 makes the linker emit LC_VERSION_MIN_MACOSX
#     (Mavericks' dyld does not understand the newer LC_BUILD_VERSION).
#   * -Werror=unguarded-availability turns any use of an API newer than 10.9
#     into a hard compile error, so nothing post-Mavericks can slip in.
#
#   make            build Postview.app
#   make run        build and launch it locally
#   make dist       build and produce Postview.zip for AirDrop
#   make verify     check the built binary really is Mavericks-compatible
#   make test       the unit suite      (Tests/pvsuite.m, subcommand `unit`)
#   make uitest     a driven controller (               subcommand `ui`)
#   make soak       long-uptime memory  (               subcommand `soak`)
#   make stress     contention, sanitized (             subcommand `stress`)
#   make power      CPU, wakeups, battery (             subcommand `power`)
#   make fuzz       malformed documents vs the viewer (a search, not a gate)
#   make statecontend  two Postviews quitting at once (forks; not a gate)
#   make helperkill SIGKILL the helper, check recovery (not a gate)
#   make helperprotocol  a helper that LIES; is the viewer hardened? (not a gate)
#   make verify-all every gate, in order
#   make clean

comma    := ,
APP      := Postview
BUNDLE   := $(APP).app
BUILD    := build
CONTENTS := $(BUNDLE)/Contents
MACOS    := $(CONTENTS)/MacOS
RES      := $(CONTENTS)/Resources
# Make needs spaces escaped in prerequisite names; the raw form is kept for
# quoted shell commands below, where a backslash would become part of the name.
# No spaces in the name, so no escaped and unescaped copies of the same path:
# Make needs backslashes in a prerequisite and a quoted shell command must not
# have them, which is why this used to be two variables that had to agree.
ICON_SOURCE := Resources/$(APP).icns
BENCHMARK_SOURCE := Tools/benchmark-preview-vs-postview.sh
BENCHMARK := Postview-Benchmark.command
PROFILE_SOURCE := Tools/profile-postview.sh
PROFILE := Postview-Profile.command
SHOWDOWN_SOURCE := Tools/showdown.sh
SHOWDOWN := Postview-Showdown.command
DISTDIR := $(BUILD)/dist

CC       := $(shell xcrun -f clang)
SDK      := $(shell xcrun --show-sdk-path)
MIN      := 10.9

# The render helper is a separate executable, so its main() is kept out of the
# application's object list and linked on its own below.
HELPER          := PostviewRenderHelper
HELPER_MAIN     := Sources/PVRenderHelperMain.m
ALL_SOURCES     := $(wildcard Sources/*.m)
SOURCES         := $(filter-out $(HELPER_MAIN),$(ALL_SOURCES))
OBJECTS         := $(patsubst Sources/%.m,$(BUILD)/%.o,$(SOURCES))
HELPER_SOURCES  := $(HELPER_MAIN) Sources/PVRenderCore.m
HELPER_OBJECTS  := $(patsubst Sources/%.m,$(BUILD)/helper-%.o,$(HELPER_SOURCES))

# Resources copied into the bundle, listed rather than globbed. A wildcard that
# matches nothing used to be swallowed by `|| true`, which is how a release can
# ship without its toolbar artwork and still report success.
TOOLBAR_RESOURCES := Resources/TB_contentAndThumbs.pdf \
                     Resources/TB_zoomIn.pdf \
                     Resources/TB_zoomOut.pdf

# Every input that changes what an object file IS, hashed into one stamp.
#
# Make rebuilds an object when its sources are newer than it. It has no opinion
# whatever about the compiler, the SDK or the flags -- so switching SDK=, or
# editing CFLAGS here, leaves every existing .o in place and links a binary from
# objects compiled against two different sets of headers. That is not a warning
# or a link error; it is a program whose structs disagree with each other, which
# is exactly the failure that is hardest to recognise from the outside.
#
# The stamp is written at parse time rather than by a rule, so its timestamp is
# already correct before Make decides what is out of date. The Makefile's own
# checksum is in the key, so any flag change anywhere in this file counts.
#
# But the stamp cannot be left to do this by timestamp alone, and that is the
# part that was wrong. GNU Make 3.81 -- the make on every Mac this ships to --
# compares modification times at ONE-SECOND resolution, and "not newer" counts
# as up to date. Rewrite the stamp inside the same second that the previous
# build wrote its objects and every one of those objects is considered current
# against it. Reproduced by switching SDK= twice in quick succession: the final
# helper advertised SDK 10.9 while helper-PVRenderCore.o inside it had been
# compiled against the modern one, and `make verify` passed, because verify
# reads the Mach-O load commands of the LINK and cannot see what went into it.
#
# So a changed key deletes the artefacts outright instead of hoping to outrank
# them. Deletion has no resolution and nothing to lose a race with.
CONFIG_KEY := $(shell printf '%s|%s|%s|%s|%s|%s|%s' \
	"$(CC)" "$(SDK)" "$(MIN)" "$(CFLAGS)" "$(LDFLAGS)" "$(HELPER_LDFLAGS)" \
	"$$(shasum Makefile 2>/dev/null | cut -d' ' -f1)" | shasum | cut -d' ' -f1)
CONFIG_STAMP := $(BUILD)/config.stamp
IGNORE := $(shell /bin/mkdir -p "$(BUILD)"; \
	if [ "$$(/bin/cat "$(CONFIG_STAMP)" 2>/dev/null)" != "$(CONFIG_KEY)" ]; then \
	  /bin/rm -f "$(BUILD)"/*.o "$(BUILD)"/*.d \
	             "$(BUILD)/stress"/*.o "$(BUILD)/stress/helper"/*.o \
	             "$(BUILD)/$(HELPER)" "$(BUILD)/stress/$(HELPER)" \
	             "$(MACOS)/$(APP)" "$(MACOS)/$(HELPER)"; \
	  tmp="$$(/usr/bin/mktemp "$(CONFIG_STAMP).XXXXXX")" || exit 1; \
	  printf '%s\n' '$(CONFIG_KEY)' > "$$tmp" && \
	    /bin/mv -f "$$tmp" "$(CONFIG_STAMP)"; \
	fi)

# Header dependencies, generated by the compiler. Without these an object is
# only rebuilt when its own .m changes, so a header change can leave an
# executable holding a mixture of old and new objects that never agreed on a
# struct layout.
DEPS := $(OBJECTS:.o=.d) $(HELPER_OBJECTS:.o=.d)

# -Wunguarded-availability is the guard that keeps post-10.9 API out of the
# build, and it is worth failing the build over -- but it is also a warning
# group that Xcode 5/6-era clang does not know, and an unknown -Werror= group is
# itself an error there. Building this tree ON the Mavericks machine is a stated
# fallback, so the flag is feature-tested rather than assumed: where the
# compiler understands it, it is armed; where it does not, the build proceeds
# without it instead of failing on the flag itself.
#
# This is not a substitute for compiling against a real 10.9 SDK. A modern SDK
# with -mmacosx-version-min=10.9 checks the availability annotations it happens
# to carry; only the 10.9 headers and framework stubs prove the symbols existed.
# Point SDK= at one for the release compile.
AVAILABILITY_CFLAGS := $(shell \
	printf '' | $(CC) -x objective-c -fsyntax-only -Werror \
	  -Wunguarded-availability -Wunguarded-availability-new - \
	  >/dev/null 2>&1 && \
	printf '%s' '-Werror=unguarded-availability -Werror=unguarded-availability-new')

# -march=core2: Mavericks runs on Macs as old as 2007, some of which predate
# SSE4.1. The default x86_64 baseline (penryn) would emit instructions those
# machines cannot execute.
CFLAGS := -arch x86_64 -march=core2 -mmacosx-version-min=$(MIN) -isysroot $(SDK) \
          -fno-objc-arc -fobjc-exceptions \
          -Os -fno-common -fvisibility=hidden \
          -Wall -Wextra -Wno-unused-parameter \
          $(AVAILABILITY_CFLAGS) \
          -Wno-deprecated-declarations \
          -Wno-objc-missing-property-synthesis

# Only Cocoa and CoreGraphics. Every resulting LC_LOAD_DYLIB path is one that
# exists on 10.9 (verified against the 10.9 SDK framework layout); `make verify`
# re-checks this after every build.
LDFLAGS := -arch x86_64 -mmacosx-version-min=$(MIN) -isysroot $(SDK) \
           -framework Cocoa -framework CoreGraphics -Wl,-dead_strip

# The render helper draws PDF pages and speaks a byte protocol on two pipes. It
# has no user interface and must never bring AppKit into a process whose whole
# purpose is to be killed and restarted, so it links Foundation rather than
# Cocoa.
HELPER_LDFLAGS := -arch x86_64 -mmacosx-version-min=$(MIN) -isysroot $(SDK) \
                  -framework Foundation -framework CoreGraphics -Wl,-dead_strip

.PHONY: all clean distclean run dist package verify icon analyze release test uitest soak stress leakcheck verify-all band power suite sign helper fuzz statecontend helperkill helperprotocol

all: $(BUNDLE)

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/%.o: Sources/%.m $(CONFIG_STAMP) | $(BUILD)
	@echo "  compile  $<"
	@$(CC) $(CFLAGS) -MMD -MP -MF $(@:.o=.d) -c $< -o $@

$(BUILD)/helper-%.o: Sources/%.m $(CONFIG_STAMP) | $(BUILD)
	@echo "  compile  $< (helper)"
	@$(CC) $(CFLAGS) -MMD -MP -MF $(@:.o=.d) -c $< -o $@

-include $(DEPS)

# The helper lives beside whatever executable spawns it: in the bundle for the
# app, and in $(BUILD) for every test binary, which is where a bare executable's
# own +mainBundle looks.
helper: $(BUILD)/$(HELPER)

$(BUILD)/$(HELPER): $(HELPER_OBJECTS) $(CONFIG_STAMP)
	@echo "  link     $@"
	@$(CC) $(HELPER_LDFLAGS) $(HELPER_OBJECTS) -o $@
	@strip -x $@

$(BUNDLE): $(OBJECTS) $(BUILD)/$(HELPER) $(CONFIG_STAMP) Resources/Info.plist $(ICON_SOURCE) $(TOOLBAR_RESOURCES)
	@echo "  link     $(MACOS)/$(APP)"
	@mkdir -p $(MACOS) $(RES)
	@$(CC) $(LDFLAGS) $(OBJECTS) -o $(MACOS)/$(APP)
	@strip -x $(MACOS)/$(APP)
	@cp $(BUILD)/$(HELPER) $(MACOS)/$(HELPER)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@printf 'APPL????' > $(CONTENTS)/PkgInfo
	@cp $(ICON_SOURCE) $(RES)/$(APP).icns
	@cp $(TOOLBAR_RESOURCES) $(RES)/
	@touch $(BUNDLE)
	@echo "  built    $(BUNDLE)"

# The chosen supplied icon is an ICNS source asset, not generated artwork.  A
# generated icon used to overwrite it on every build and made the release
# depend on the build host's icon tool.
icon: $(ICON_SOURCE)

$(BENCHMARK): $(BENCHMARK_SOURCE)
	@cp "$(BENCHMARK_SOURCE)" "$@"
	@chmod 755 "$@"

$(PROFILE): $(PROFILE_SOURCE)
	@cp "$(PROFILE_SOURCE)" "$@"
	@chmod 755 "$@"

$(SHOWDOWN): $(SHOWDOWN_SOURCE)
	@cp "$(SHOWDOWN_SOURCE)" "$@"
	@chmod 755 "$@"
	@echo "  wrote    $@"

run: $(BUNDLE)
	@open $(BUNDLE)

# Packaging runs the whole gate first. `dist` used to depend on `verify` alone,
# so a tree that had never run the tests could still produce a ZIP that looked
# like a release.
# `dist` is the release: prove it, sign it, wrap it, in that order.
#
# The wrapping is `package`, split out and separately invocable. That split is
# not a way around the gates -- `dist` still runs every one of them first -- it
# is so that re-wrapping an already-verified tree does not mean re-running an
# hour of soak and sanitizers to change a README. `package` says plainly that it
# proves nothing on its own, because a target that produces a shippable archive
# should not be quiet about what it did not check.
# Sequenced by recursive make, not by prerequisites.
#
# `dist: verify-all sign package` names three things that must happen and says
# nothing whatever about their ORDER. Under `make -j` that is not a subtlety:
# make is free to start packaging while verification is still running, and does
# -- a dry run confirmed the archive being assembled from a tree that had not
# finished being checked. A gate the packaging step can overtake is not a gate.
#
# Prerequisites cannot express this, because they mean "needs" and not "after",
# and these are whole phases rather than files. Three sub-makes can, and they
# stay correct however many jobs the caller asked for.
dist:
	@$(MAKE) --no-print-directory verify-all
	@$(MAKE) --no-print-directory sign
	@$(MAKE) --no-print-directory package
	@echo "  dist     $(APP).zip built from a fully verified tree"

package: $(BUNDLE) $(SUITE) $(BENCHMARK) $(PROFILE) $(SHOWDOWN)
	@rm -rf "$(DISTDIR)"
	@mkdir -p "$(DISTDIR)"
	@ditto "$(BUNDLE)" "$(DISTDIR)/$(BUNDLE)"
	@cp README.md "$(DISTDIR)/README.md"
	@cp "$(BENCHMARK)" "$(DISTDIR)/$(BENCHMARK)"
	@cp "$(PROFILE)" "$(DISTDIR)/$(PROFILE)"
	@cp "$(SHOWDOWN)" "$(DISTDIR)/$(SHOWDOWN)"
	@cp $(SUITE) "$(DISTDIR)/pvsuite"
	@# The whole test suite, not just the band probe it replaces. It is one
	@# x86_64/10.9 binary either way, and the Mavericks machine is the one place
	@# `pvsuite power` can measure what this program costs on the hardware it was
	@# written for -- so shipping only the probe was shipping the least
	@# interesting subcommand.
	@#
	@# It spawns the render helper from beside its own executable, which in the
	@# archive is the top level and not the bundle. Shipping the probe without it
	@# shipped a tool that could not run: the released pvband exited 2 with
	@# "cannot open <file>" on every document, which reads as a bad PDF rather
	@# than a missing renderer. 21 KB to make the diagnostic tool in a diagnostic
	@# archive actually work.
	@cp "$(MACOS)/$(HELPER)" "$(DISTDIR)/$(HELPER)"
	@xattr -cr "$(DISTDIR)" 2>/dev/null || true
	@rm -f $(APP).zip
	@ditto -c -k --sequesterRsrc "$(DISTDIR)" $(APP).zip
	@# The archive is the artefact that ships, and until now nothing checked
	@# that it held what was just built. Unpack it again and compare.
	@tmp=$$(/usr/bin/mktemp -d /tmp/postview-dist-verify.XXXXXX) || exit 1; \
	  status=0; \
	  /usr/bin/ditto -x -k "$(APP).zip" "$$tmp" || status=$$?; \
	  [ "$$status" -eq 0 ] && /usr/bin/diff -qr -x __MACOSX \
	      "$(DISTDIR)" "$$tmp" || status=$$?; \
	  /bin/rm -R "$$tmp"; \
	  [ "$$status" -eq 0 ] || { echo "FAIL: ZIP differs from staging"; exit 1; }
	@echo "  packaged $(APP).zip  ($$(du -h $(APP).zip | cut -f1))"
	@echo "  verified $(APP).zip matches $(DISTDIR)"
	@echo "  note     'package' wraps whatever is in $(BUNDLE); it runs no gates."
	@echo "           'make dist' is the target that proves the tree first."

# Every Mach-O the bundle ships. The helper is loaded by the same dyld on the
# same machine, so anything that would stop the app from launching on 10.9 stops
# the helper too, and a check that only looked at the app would not say so.
MACHO := $(MACOS)/$(APP) $(MACOS)/$(HELPER)

verify:
	@echo "== Mach-O compatibility check =="
	@plutil -lint $(CONTENTS)/Info.plist >/dev/null || \
	  (echo "FAIL: Info.plist is invalid"; exit 1)
	@cmp -s $(ICON_SOURCE) $(RES)/$(APP).icns || \
	  (echo "FAIL: bundled icon does not match the selected source icon"; exit 1)
	@for r in $(TOOLBAR_RESOURCES); do \
	  cmp -s "$$r" "$(RES)/$$(basename $$r)" || \
	    { echo "FAIL: missing or stale bundled resource $$r"; exit 1; }; \
	done
	@test -x $(MACOS)/$(HELPER) || \
	  { echo "FAIL: $(HELPER) is missing from the bundle"; exit 1; }
	@for m in $(MACHO); do \
	  echo "-- $$m --"; \
	  archs="$$(lipo -archs $$m)"; \
	  [ "$$archs" = "x86_64" ] || \
	    { echo "FAIL: architectures: $$archs"; exit 1; }; \
	  min="$$(otool -l $$m | \
	    awk '/LC_VERSION_MIN_MACOSX/{getline; getline; print $$2; exit}')"; \
	  [ "$$min" = "10.9" ] || \
	    { echo "FAIL: minimum OS is $$min"; exit 1; }; \
	  sdk="$$(otool -l $$m | \
	    awk '/LC_VERSION_MIN_MACOSX/{getline; getline; getline; print $$2; exit}')"; \
	  if [ "$(REQUIRE_SDK)" = "any" ]; then \
	    echo "   x86_64, minimum OS $$min, built against SDK $$sdk (not checked)"; \
	  else \
	    [ "$$sdk" = "$(REQUIRE_SDK)" ] || { \
	      echo "FAIL: built against SDK $$sdk, not $(REQUIRE_SDK)."; \
	      echo "      Point SDK= at a real MacOSX$(REQUIRE_SDK).sdk, or pass"; \
	      echo "      REQUIRE_SDK=any for a development build."; \
	      exit 1; }; \
	    echo "   x86_64, minimum OS $$min, SDK $$sdk"; \
	  fi; \
	  if otool -l $$m | grep -q LC_BUILD_VERSION; then \
	    echo "FAIL: LC_BUILD_VERSION present"; exit 1; fi; \
	  if otool -l $$m | grep -q LC_DYLD_CHAINED_FIXUPS; then \
	    echo "FAIL: chained fixups are not supported by Mavericks dyld"; exit 1; fi; \
	  if otool -l $$m | grep -q LC_RPATH; then \
	    echo "FAIL: LC_RPATH present"; exit 1; fi; \
	  otool -L $$m | tail -n +2 | sed 's/^/   /'; \
	  otool -L $$m | tail -n +2 | awk '{print $$1}' | \
	    grep -vE '^/System/Library/Frameworks/(Cocoa|AppKit|Foundation|CoreFoundation|CoreGraphics)\.framework/Versions/[A-Z]/[A-Za-z]+$$' | \
	    grep -vE '^/usr/lib/(libSystem\.B|libobjc\.A)\.dylib$$' | \
	    (! grep .) || { echo "FAIL: unexpected dylib above"; exit 1; }; \
	done
	@echo "OK"

# Mavericks does understand Developer ID. What it does not understand is a
# SHA-256-only signature: 10.9.5 introduced the version-2 requirements, and the
# compatible form for a binary that must validate both there and on a current
# system is the dual SHA-1/SHA-256 digest below. The hardened runtime is a
# 10.14 feature and must NOT be enabled for this target -- Mavericks' Gatekeeper
# rejects what it cannot parse.
#
# There is no default identity on purpose. An unsigned release is a decision,
# and it should have to be typed out rather than reached by omission.
# The SDK a shipping binary must have been built against, checked by `verify`.
#
# -mmacosx-version-min=10.9 sets the MINIMUM in LC_VERSION_MIN_MACOSX and
# nothing else: a binary compiled against the 27.0 headers records minimum 10.9
# and SDK 27.0, passes every check that only reads the minimum, and is still a
# binary whose availability annotations, struct layouts and inline functions
# came from a system a decade newer than the one it claims to run on. Both
# numbers are in the load command; only one of them was being read.
#
# `REQUIRE_SDK=any` skips the check for a development build on a machine with no
# 10.9 SDK. It is spelled out rather than being the default, because the default
# is what a release takes.
# Fixture generators build a PDF and then are thrown away. They are host tools:
# nothing about them ships, nothing about them runs on 10.9, and the file they
# emit is a PDF, which has no architecture.
#
# So they are deliberately built with NO -isysroot and NO -mmacosx-version-min,
# unlike everything else here -- and both omissions are load-bearing. They used
# to inherit `-isysroot $(SDK)`, which is fine while SDK is the host's and fails
# two different ways when it is a real MacOSX10.9.sdk: clang then defaults to
# arm64, which that SDK has no slice of, and pinning the SDK also pins a 10.9
# deployment target, at which -fobjc-arc needs libarclite_macosx.a -- a runtime
# shim current toolchains no longer ship at all. Adding `-arch x86_64` fixes the
# first and leaves the second, which is why the answer is to stop pinning rather
# than to pin more precisely.
# $(CC) is the absolute path xcrun resolved, not the `xcrun clang` wrapper, so
# it has no SDK of its own to fall back on and needs one named explicitly. This
# is the HOST's, asked for separately, so that SDK= on the command line moves
# the app's SDK without dragging the build tools along with it.
HOST_SDK := $(shell xcrun --show-sdk-path)
FIXTURE_CFLAGS := -isysroot $(HOST_SDK) -fobjc-arc

REQUIRE_SDK ?= 10.9

SIGN_IDENTITY ?=

SIGN_FLAGS = --force --timestamp --digest-algorithm=sha1,sha256 \
             --sign "$(SIGN_IDENTITY)"

# Nested code is signed FIRST, then the bundle that contains it.
#
# codesign seals the contents of a bundle into the bundle's own signature, so
# signing the outer bundle over an unsigned executable seals "there is an
# unsigned Mach-O in here". It does not fail at signing time; it fails at
# --verify --strict with "code object is not signed at all", naming
# PostviewRenderHelper -- which is what the previous recipe did, because the
# helper did not exist when it was written and nothing added it.
#
# SIGN_IDENTITY=none produces a deliberately unsigned build. Spelled out rather
# than reachable by omission, and announced, because an unsigned app is a
# decision about what the person receiving it will see from Gatekeeper.
sign: $(BUNDLE)
	@test -n "$(SIGN_IDENTITY)" || { \
	    echo "FAIL: SIGN_IDENTITY is required (e.g. make dist SIGN_IDENTITY=\"Developer ID Application: ...\")."; \
	    echo "      Pass SIGN_IDENTITY=none to package deliberately unsigned."; \
	    exit 1; \
	}
	@if [ "$(SIGN_IDENTITY)" = "none" ]; then \
	    echo "  WARNING: packaging UNSIGNED (SIGN_IDENTITY=none)."; \
	    echo "           Gatekeeper will refuse this on a stock machine; the"; \
	    echo "           recipient must right-click > Open, or clear the"; \
	    echo "           quarantine attribute by hand."; \
	else \
	    /usr/bin/codesign $(SIGN_FLAGS) "$(MACOS)/$(HELPER)" && \
	    /usr/bin/codesign $(SIGN_FLAGS) "$(BUNDLE)" && \
	    /usr/bin/codesign --verify --strict --verbose=2 "$(MACOS)/$(HELPER)" && \
	    /usr/bin/codesign --verify --strict --verbose=2 "$(BUNDLE)" && \
	    echo "  signed   $(BUNDLE) (helper first, then bundle)"; \
	fi



# Static analysis has no runtime or test-fixture dependency.  It is a release
# gate alongside the tests below, using the exact Mavericks deployment target
# and warning policy as the shipping binary.
# `clang --analyze` exits 0 whether or not it found anything: its findings are
# warnings, and a warning is not a failure. So this used to print the analyser's
# complaints and then report OK, which means the "static analysis: passed" line
# in a release report was true of the exit status and not of the analysis. The
# output is captured and any diagnostic in it fails the gate.
analyze: | $(BUILD)
	@echo "== Clang static analysis =="
	@log=$(BUILD)/analyze.log; : > $$log; status=0; \
	for f in $(ALL_SOURCES); do \
	  echo "  analyze  $$f"; \
	  $(CC) $(CFLAGS) --analyze -Xanalyzer -analyzer-output=text $$f \
	    >> $$log 2>&1 || status=1; \
	done; \
	if grep -qE '(warning|error):' $$log; then \
	  echo "FAIL: the static analyser reported the following:"; \
	  cat $$log; exit 1; fi; \
	[ "$$status" -eq 0 ] || { echo "FAIL: the static analyser could not run"; \
	  cat $$log; exit 1; }
	@echo "OK"

# The test suite. One program, Tests/pvsuite.m, with a subcommand per suite;
# the targets below are the fixtures and the environment each of them needs.
#
# It used to be five programs (pvtest, pvuitest, pvsoak, pvstress, pvband) built
# from five files with four copies of the same OK()/Pump() harness between them.
# The merge is not tidiness: the suites could not compare notes. `power` reads
# the rasterisation counters the UI suite asserts on and the process accounting
# the soak uses, and none of that was reachable from one place before.
#
# Point REALPDF at any document to additionally run the unit suite's
# scale-independence check against it.
PDF ?= $(BUILD)/heavy.pdf
REALPDF ?=

# The fixture generator is written to run under both 2.7 and 3.x, so whichever
# the host has will do. Mavericks has only /usr/bin/python (2.7); current macOS
# has only python3.
PYTHON ?= $(shell command -v python3 2>/dev/null || command -v python 2>/dev/null)

# Everything the suite links. main.m has its own main(), and PVDocument is the
# NSDocument shell -- the suite drives PVWindowController directly, which is
# the point.
#
# This used to be two lists: the unit suite additionally excluded
# PVWindowController.o, because pvtest.m did not reference it. One file
# references all of it now, and -Wl,-dead_strip means an object nothing calls
# costs the binary nothing.
#
# PVAppDelegate came off this list when the sleep hook was added. It is the
# application shell, but it is also where the reading position is committed
# before the machine sleeps, and that registration is on NSWorkspace's
# notification centre rather than the default one -- a distinction with no
# symptom except silence. Testing it needs the class. It drags in nothing new:
# PVAppDelegate references only PVWindowController and
# PVWelcomeWindowController, both of which the suite already linked.
#
# Three builds compile Tests/pvsuite.m -- this one, the native cross-check in
# `band`, and the stress/sanitizer builds below. All three list the same
# exclusions and all three had to change together.
SUITEOBJ := $(filter-out $(BUILD)/main.o $(BUILD)/PVDocument.o,$(OBJECTS))
SUITE    := $(BUILD)/pvsuite

# The heavy fixture, generated once and reused by every suite below.
define mkheavy
	@test -f $(BUILD)/heavy.pdf || ( \
	   $(CC) $(FIXTURE_CFLAGS) -framework Cocoa \
	     -o $(BUILD)/mkheavy Tests/make_heavy_fixture.m && \
	   $(BUILD)/mkheavy $(BUILD)/heavy.pdf 60 )
endef

# Built for the shipping target, x86_64 / 10.9, like everything else here --
# which is also what lets `make package` ship this binary to the Mavericks
# machine as the diagnostic tool. See `package` above.
#
# The toolbar artwork is copied beside it because a bare executable's own
# +mainBundle looks for resources next to the binary. Without it the UI suite's
# icon checks fail for want of a bundle rather than for want of the assets.
$(SUITE): Tests/pvsuite.m $(OBJECTS) $(BUILD)/$(HELPER) | $(BUILD)
	@echo "  compile  Tests/pvsuite.m"
	@$(CC) $(CFLAGS) -ISources -c Tests/pvsuite.m -o $(BUILD)/pvsuite.o
	@$(CC) $(LDFLAGS) $(SUITEOBJ) $(BUILD)/pvsuite.o -o $(SUITE)
	@cp $(TOOLBAR_RESOURCES) $(BUILD)/

suite: $(SUITE)
	@echo "  built    $(SUITE)"

# Two probes for design claims the suite states but never exercises.
#
# Deliberately NOT in verify-all, and the distinction is the point. Both are
# adversarial and one of them forks: they belong in the hands of someone reading
# the output, not in a release gate that is supposed to fail for one reason and
# be believed when it does. `fuzz` in particular is a search, not an assertion --
# a clean run is evidence, not proof, and wiring a search into a gate invites
# reading its silence as a guarantee.

# Does a malformed document kill the VIEWER?
#
# PVPDFSource.h opens by arguing that parsing and drawing both happen in a
# helper process precisely so that a document which faults, hangs or aborts
# inside Quartz takes the helper with it and nothing else. The suite tests
# corrupt state files; nothing tested a corrupt document, so the claim the whole
# split exists to make was the one thing not checked. Feeds truncations,
# synthesized pathologies and seeded byte-flip mutations, and asserts the viewer
# is still there afterwards -- with open and render both bounded, so a hang
# fails rather than passing slowly.
FUZZROUNDS ?= 150
FUZZSEED   ?= $(BUILD)/text.pdf

fuzz: $(BUILD)/pvfuzz
	$(mkheavy)
	@$(BUILD)/pvfuzz $(FUZZSEED) $(BUILD)/fuzzwork $(FUZZROUNDS)

$(BUILD)/pvfuzz: Tests/pvfuzz.m $(OBJECTS) $(BUILD)/$(HELPER) | $(BUILD)
	@echo "  compile  Tests/pvfuzz.m"
	@$(CC) $(CFLAGS) -ISources -c Tests/pvfuzz.m -o $(BUILD)/pvfuzz.o
	@$(CC) $(LDFLAGS) $(SUITEOBJ) $(BUILD)/pvfuzz.o -o $(BUILD)/pvfuzz

# Do two Postviews quitting at once lose reading positions?
#
# PVStateStore merges instead of overwriting so that two copies reading
# different documents cannot clobber each other. That merge is exercised in ONE
# process; the flock path that makes the promise true had no test. Forks real
# processes at one state file. Separates writers that retry (nothing may be
# lost) from writers that flush once and exit -- which is what QUITTING is, and
# the case where -flush's 0.25 s give-up has no later flush point to fall back on.
statecontend: $(BUILD)/pvstatecontend
	@$(BUILD)/pvstatecontend

# Kill the render helper and check the viewer comes back.
#
# `fuzz` asks whether a hostile document can kill the viewer; most of what it
# exercises is Quartz's parser inside a process built to die safely. This asks
# the half that is Postview's OWN code. -createImageForPage: has to notice the
# helper is gone, classify that as transient rather than as a page that will
# never draw, kill and reap the remains, and let -ensureRenderHelper: start a
# fresh one on the next call. Misclassify it and a page briefly without a helper
# is retired for the whole session; misreap it and a long session collects
# zombies. Nothing in the suite killed a helper.
#
# Three arms: kill between renders, kill DURING renders from another thread, and
# kill-then-release-immediately. A render that loses its helper is ALLOWED to
# fail -- it is required to say why, and to be followed by one that works.
KILLROUNDS ?= 40

helperkill: $(BUILD)/pvhelperkill
	$(mkheavy)
	@$(BUILD)/pvhelperkill $(PDF) $(KILLROUNDS)

$(BUILD)/pvhelperkill: Tests/pvhelperkill.m $(OBJECTS) $(BUILD)/$(HELPER) | $(BUILD)
	@echo "  compile  Tests/pvhelperkill.m"
	@$(CC) $(CFLAGS) -ISources -c Tests/pvhelperkill.m -o $(BUILD)/pvhelperkill.o
	@$(CC) $(LDFLAGS) $(SUITEOBJ) $(BUILD)/pvhelperkill.o -o $(BUILD)/pvhelperkill

# A helper that LIES, and whether the viewer believes it.
#
# The split exists because the helper is where attacker-controlled bytes are
# interpreted -- which makes the helper the process most likely to be subverted,
# and everything it says back untrusted input. PVPDFSource does check magic,
# version and sequence on every reply and bounds every read with a deadline;
# those branches were reachable only by accident until this.
#
# Runs in its own directory because the viewer finds its helper by looking
# beside its own executable: the liar is installed there under the real name,
# with the genuine helper alongside as RealRenderHelper for the copy and
# geometry conversations it passes through untouched.
PROTODIR := $(BUILD)/protocol

helperprotocol: $(PROTODIR)/pvhelperprotocol
	$(mkheavy)
	@$(PROTODIR)/pvhelperprotocol $(PDF)

$(PROTODIR)/pvhelperprotocol: Tests/pvhelperprotocol.m Tests/pvbadhelper.m \
                              $(OBJECTS) $(BUILD)/$(HELPER) | $(BUILD)
	@mkdir -p $(PROTODIR)
	@echo "  compile  Tests/pvhelperprotocol.m"
	@$(CC) $(CFLAGS) -ISources -c Tests/pvhelperprotocol.m -o $(PROTODIR)/pvhelperprotocol.o
	@$(CC) $(LDFLAGS) $(SUITEOBJ) $(PROTODIR)/pvhelperprotocol.o -o $(PROTODIR)/pvhelperprotocol
	@echo "  compile  Tests/pvbadhelper.m (installed as $(HELPER))"
	@$(CC) $(CFLAGS) -ISources $(HELPER_LDFLAGS) Tests/pvbadhelper.m \
	   -o $(PROTODIR)/$(HELPER)
	@cp $(BUILD)/$(HELPER) $(PROTODIR)/RealRenderHelper

$(BUILD)/pvstatecontend: Tests/pvstatecontend.m $(OBJECTS) | $(BUILD)
	@echo "  compile  Tests/pvstatecontend.m"
	@$(CC) $(CFLAGS) -ISources -c Tests/pvstatecontend.m -o $(BUILD)/pvstatecontend.o
	@$(CC) $(LDFLAGS) $(SUITEOBJ) $(BUILD)/pvstatecontend.o -o $(BUILD)/pvstatecontend

# Headless checks for the logic that has no visible surface. Self contained: it
# generates its own fixtures.
test: $(SUITE)
	@test -n "$(PYTHON)" || { echo "FAIL: no python interpreter found"; exit 1; }
	@$(PYTHON) Tests/make_rotation_fixture.py $(BUILD)/rotation.pdf >/dev/null
	$(mkheavy)
	@$(SUITE) unit $(PDF) $(BUILD)/rotation.pdf $(REALPDF)

# Drives a real PVWindowController and snapshots it, so the sidebar, page
# jumping and position saving are verified without needing Accessibility
# permission to click things.
uitest: $(SUITE)
	$(mkheavy)
	@$(SUITE) ui $(PDF) $(BUILD)/shots

# Long-uptime check: repeats the whole document lifecycle and asserts that
# every one of Postview's long-lived objects is deallocated afterwards. 150 is
# the point at which the secondary footprint trend also becomes stable enough
# to assert on; below that it is reported but not enforced.
SOAKCYCLES ?= 150

soak: $(SUITE)
	$(mkheavy)
	@$(SUITE) soak $(PDF) $(SOAKCYCLES)

# What any of it COSTS. Every other gate here checks that Postview does the
# right thing and none of them checked the price, which for a program whose
# entire design argument is energy (ENGINEERING.md section 1) is the one
# omission that matters.
#
# Asserts on ratios and on zeroes -- an idle document costs no measurable CPU
# and no wakeups, rasterisation is charged to the helper and not the viewer,
# Postview's own cost census agrees with the kernel's, the mains policy asks for
# sharp bitmaps during motion and the battery policy asks for none -- and only
# reports the seconds, because seconds are a property of the machine and the
# machine that decides is not this one. So it is safe in verify-all on any host,
# and it fails for a reason rather than for being slow.
POWERSECONDS ?= 3

power: $(SUITE)
	$(mkheavy)
	@$(SUITE) power $(PDF) $(POWERSECONDS)

# Task 4 stage 1: does a band render cost a fraction of a page render, or does
# per-render PDF parsing overhead dominate? An experiment, not a gate -- it is
# not in verify-all and it asserts nothing. Built for the host architecture as
# well as the Mavericks one, because the quantity it measures is a ratio and a
# ratio that disagrees between the two is a ratio that cannot be trusted to
# transfer to the machine that decides.
BANDPAGES ?= 6
BANDREPS  ?= 3

# The probe cannot be COMPILED on the Mavericks machine -- $(CFLAGS) carries
# -Werror=unguarded-availability, which Xcode 6's clang does not have -- but the
# binary $(SUITE) produces is x86_64/10.9 and RUNS there natively. That is the
# only way the measurement ENGINEERING.md section 7 asks for can be taken on the
# machine that decides, which is why `package` puts the whole suite in the
# distributable.
band: $(SUITE)
	$(mkheavy)
	@test -f $(BUILD)/text.pdf || ( \
	   $(CC) $(FIXTURE_CFLAGS) -framework Cocoa \
	     -o $(BUILD)/mktext Tests/make_text_fixture.m && \
	   $(BUILD)/mktext $(BUILD)/text.pdf 60 )
	@echo "== x86_64 (the shipping architecture; under Rosetta on an Apple silicon host) =="
	@$(SUITE) band $(PDF) $(BANDPAGES) $(BANDREPS)
	@echo ""
	@echo "== $(shell uname -m) (native, as a cross-check that the ratio is not a Rosetta artefact) =="
	@mkdir -p $(BUILD)/native
	@for f in $(filter-out Sources/main.m Sources/PVDocument.m,$(SOURCES)) Tests/pvsuite.m; do \
	   $(CC) -arch $(shell uname -m) -mmacosx-version-min=11.0 -isysroot $(HOST_SDK) \
	     -fno-objc-arc -fobjc-exceptions -Os -ISources -Wno-deprecated-declarations \
	     -c $$f -o $(BUILD)/native/$$(basename $$f .m).o || exit 1; \
	 done
	@$(CC) -arch $(shell uname -m) -mmacosx-version-min=11.0 -isysroot $(HOST_SDK) \
	   -framework Cocoa -framework CoreGraphics \
	   $(BUILD)/native/*.o -o $(BUILD)/pvsuite-native
	@$(BUILD)/pvsuite-native band $(PDF) $(BANDPAGES) $(BANDREPS)

# Contention check: the same objects, driven with every asynchronous event the
# app can receive arriving while the render queue is busy. The soak proves a
# document cycle leaves nothing behind; this proves the cycle is safe while
# something is actually happening. Worth running under ThreadSanitizer, which
# is what it was written for:
#
#   make stress
#   make stress SAN="-fsanitize=thread"     (needs a native arch; see below)
#   make stress SAN="-fsanitize=address,undefined"
#
# The sanitizers do not run under -arch x86_64 -march=core2 on an Apple silicon
# host, so a sanitizer build overrides the architecture to the host's own. The
# shipping binary is still built by `make` with the Mavericks flags; this target
# only ever produces a test executable.
SAN ?=
STRESSARCH := $(if $(SAN),-arch $(shell uname -m) -mmacosx-version-min=11.0,-arch x86_64 -march=core2 -mmacosx-version-min=$(MIN))
# The SDK travels with the architecture, and it has to.
#
# A sanitized build already retargets itself at the host -- the sanitizer
# runtimes only exist for the host architecture -- and it was still compiled
# against $(SDK). That is coherent while SDK is the host's own and incoherent
# the moment it is a real MacOSX10.9.sdk: an arm64, minimum-11.0 translation
# unit reading 10.9 headers fails in <machine/endian.h> with "architecture not
# supported", several hundred errors deep and nowhere near the actual cause.
# The unsanitized build keeps $(SDK), because that one really is the shipping
# configuration and checking it against the shipping SDK is the point.
STRESSSDK := $(if $(SAN),$(HOST_SDK),$(SDK))
STRESSCFLAGS := $(STRESSARCH) -isysroot $(STRESSSDK) -fno-objc-arc -fobjc-exceptions                 -g -O1 $(SAN) -Wall -Wextra -Wno-unused-parameter                 -Wno-deprecated-declarations -ISources
STRESSLD := $(STRESSARCH) -isysroot $(STRESSSDK) $(SAN) -framework Cocoa -framework CoreGraphics
STRESSHELPERLD := $(STRESSARCH) -isysroot $(STRESSSDK) $(SAN) -framework Foundation -framework CoreGraphics
STRESSSRC := $(filter-out Sources/main.m Sources/PVDocument.m,$(SOURCES))
STRESSSCALE ?= 1

# Multiplier on the stress suite's teardown deadlines, in a sanitized build only.
#
# The deadlines assert how long an unwind takes, which is a property of the
# code; they were being checked against wall-clock time, which is a property of
# the build. A page render under address+undefined is roughly an order of
# magnitude slower than the shipping configuration, so the same constant is a
# different assertion in each of the three builds this target produces.
#
# Recorded 2026-08-31: the address+undefined build failed two 60-round unwinds
# on this host while the plain and thread builds passed them and `leakcheck`
# found nothing leaked; at 8x it passes 14/14, so the objects were unwinding and
# not inside a number chosen for a faster build. See DeadlineScale() in
# Tests/pvsuite.m -- it multiplies deadlines and never removes them, so a real
# leak still fails, just later.
DEADLINE_SCALE ?= $(if $(SAN),8,1)

# The sanitized suite and its render helper live in $(BUILD)/stress rather than
# $(BUILD): a sanitized build overrides the architecture to the host's, and a
# helper spawned from beside the binary has to be the same architecture as the
# binary that spawns it. Keeping them together also keeps the x86_64 pair in
# $(BUILD) untouched.
#
# HOME is redirected at a scratch directory because the stress suite asserts on
# the state store, which lives under the real one. The test said it was given a
# scratch HOME and the Makefile never gave it one, so a developer's own resume
# state was both read by the test and rewritten by it. The suite refuses to run
# this subcommand without one, so the claim is now checked rather than commented.
#
# PV_HELPER_DIAGNOSTICS is set for the same class of reason. A render helper is
# spawned with /dev/null for stderr and an empty environment, which is right for
# a shipping viewer and wrong here: it meant a SANITIZED helper reported its
# findings into /dev/null. The whole point of this target is the renderer, and
# the renderer was the one process nothing was listening to.
#
# And the exit status is not the gate on its own. ThreadSanitizer does not abort
# on a report unless told to, so a run can report races and still exit zero --
# the diagnostics are captured and scanned, and a report fails the target.
stress: | $(BUILD)
	@mkdir -p $(BUILD)/stress $(BUILD)/stress/helper
	@test -f $(BUILD)/heavy.pdf || ( 	   $(CC) $(FIXTURE_CFLAGS) -framework Cocoa 	     -o $(BUILD)/mkheavy Tests/make_heavy_fixture.m && 	   $(BUILD)/mkheavy $(BUILD)/heavy.pdf 60 )
	@for f in $(STRESSSRC) Tests/pvsuite.m; do 	   o=$(BUILD)/stress/$$(basename $$f .m).o; 	   $(CC) $(STRESSCFLAGS) -c $$f -o $$o || exit 1; 	 done
	@$(CC) $(STRESSLD) $(BUILD)/stress/*.o -o $(BUILD)/stress/pvsuite
	@for f in $(HELPER_SOURCES); do 	   o=$(BUILD)/stress/helper/$$(basename $$f .m).o; 	   $(CC) $(STRESSCFLAGS) -c $$f -o $$o || exit 1; 	 done
	@$(CC) $(STRESSHELPERLD) $(BUILD)/stress/helper/*.o -o $(BUILD)/stress/$(HELPER)
	@cp $(TOOLBAR_RESOURCES) $(BUILD)/stress/
	@PV_STRESS_HOME=$$(/usr/bin/mktemp -d /tmp/postview-stress-home.XXXXXX) || exit 1; \
	  log="$$PV_STRESS_HOME/diagnostics.txt"; \
	  status=0; \
	  HOME="$$PV_STRESS_HOME" PVSTRESS_DEADLINE_SCALE=$(DEADLINE_SCALE) \
	  PV_HELPER_DIAGNOSTICS=1 \
	    $(BUILD)/stress/pvsuite stress $(PDF) $(STRESSSCALE) 2>"$$log" || status=$$?; \
	  /bin/cat "$$log" >&2; \
	  if /usr/bin/grep -qE 'ERROR: (Address|Thread|UndefinedBehavior|Leak)Sanitizer|runtime error:|SUMMARY: .*Sanitizer' "$$log"; then \
	    echo "FAIL: sanitizer diagnostics were reported during the stress run."; \
	    echo "      These come from the viewer OR from a render helper, which"; \
	    echo "      now keeps its stderr. A clean exit status is not enough:"; \
	    echo "      ThreadSanitizer does not abort on a report by default."; \
	    status=1; \
	  fi; \
	  /bin/rm -R "$$PV_STRESS_HOME"; \
	  exit $$status

# Same loop under the leak checker. Any Objective-C object or CG bitmap that
# manual retain/release drops on the floor is reported here by name.
#
# The gate is Postview's own objects -- anything PV-prefixed, plus the CGImages
# the render queue creates -- and it is zero. What it is deliberately not is
# "leaks found nothing", because that is not achievable and never was: `leaks`
# exits non-zero whenever it reports anything at all, and on a current host
# AppKit hangs an _NSDisplayLink off every window it makes and never releases
# it, which put 120 root leaks in the report for a 25-cycle run and failed the
# build on an object that does not exist on the 10.9 target. Those are listed,
# by class, and not counted against us; anything of ours fails the build.
leakcheck: $(SUITE)
	$(mkheavy)
	@report="$(BUILD)/leaks-report.txt"; status=0; \
	  MallocStackLogging=1 leaks --atExit -- $(SUITE) soak $(PDF) 25 > "$$report" 2>&1 || status=$$?; \
	  sed -n '/leaks Report/,/^Binary Images/p' "$$report" | grep -v '^Binary Images' | head -n 40; \
	  summary=$$(grep -E '[0-9]+ leaks? for [0-9]+ total leaked bytes' "$$report" | tail -n 1); \
	  if [ -z "$$summary" ] || [ "$$status" -gt 1 ]; then \
	    echo "FAIL: leak checker could not run (exit $$status)"; exit 1; fi; \
	  printf '%s\n' "$$summary"; \
	  ours=$$(grep -oE 'ROOT LEAK: <(PV[A-Za-z]+|CGImage)' "$$report" | sed 's/.*<//' | sort | uniq -c); \
	  theirs=$$(grep -oE 'ROOT LEAK: <[A-Za-z_]+' "$$report" | sed 's/.*<//' | grep -vE '^(PV[A-Za-z]+|CGImage)$$' | sort | uniq -c); \
	  if [ -n "$$theirs" ]; then \
	    echo "  Retained by the OS, not by Postview (not a gate):"; \
	    printf '%s\n' "$$theirs" | sed 's/^/    /'; fi; \
	  if [ -n "$$ours" ]; then \
	    echo "FAIL: Postview leaked an object it owns:"; \
	    printf '%s\n' "$$ours" | sed 's/^/    /'; exit 1; fi; \
	  echo "  OK: no Postview-owned object was leaked."

# Full daily-driver gate. This used to re-list a subset of verify-all's gates
# and so quietly ran a weaker check than the one named as the release gate: no
# Mach-O verification, and no sanitizer stress at all. It is now exactly
# verify-all followed by packaging, which is what `dist` already is.
release: dist

# Everything, in one command. This is the gate before a release: the unit and
# UI suites, the soak (memory growth over 175 document cycles), the stress
# suite under three sanitizers, the leak census, the energy and CPU suite and
# the static analyser.
#
# Runs the stress suite three times because each sanitizer excludes the others:
# ASan and TSan cannot be linked together, so a single pass can only ever cover
# one class of fault.
# Every gate, and a claim at the end that they all passed.
#
# Each one runs through `gate`, which exists because `$(MAKE) ... | tail -1` does
# not do what it looks like: a pipeline exits with the status of its LAST
# command, so `tail` succeeding hid whatever the sub-make did. Recorded
# 2026-08-31 -- the ASan stress gate printed "make[1]: *** [stress] Error 1",
# verify-all carried on through four more gates and ended with "every gate
# passed". A verification harness that reports success over a failure it printed
# two lines earlier is worse than not having one.
#
# So: the full log goes to a file, only the summary line is echoed, and a
# non-zero status prints the tail of that log and stops the run. bash -c with
# pipefail would be shorter, but GNU Make 3.81 -- what macOS ships -- has no
# .SHELLFLAGS, and this also keeps the whole log of a failing gate instead of
# its last line.
define gate
	@printf '== %s ==\n' "$(1)"; \
	if $(2) > $(BUILD)/gate.log 2>&1; then \
	    tail -1 $(BUILD)/gate.log; \
	else \
	    tail -1 $(BUILD)/gate.log; \
	    echo ""; \
	    echo "verify-all: FAILED at '$(1)'. Last 40 lines:"; \
	    tail -40 $(BUILD)/gate.log; \
	    exit 1; \
	fi
endef

verify-all: $(BUNDLE) $(SHOWDOWN) | $(BUILD)
	$(call gate,Mach-O verification,$(MAKE) --no-print-directory verify)
	$(call gate,static analyser,$(MAKE) --no-print-directory analyze)
	$(call gate,unit tests,$(MAKE) --no-print-directory test)
	$(call gate,UI tests,$(MAKE) --no-print-directory uitest)
	$(call gate,soak,$(MAKE) --no-print-directory soak)
	$(call gate,stress,$(MAKE) --no-print-directory stress)
	$(call gate,stress + address$(comma)undefined,$(MAKE) --no-print-directory stress SAN="-fsanitize=address$(comma)undefined")
	$(call gate,stress + thread,$(MAKE) --no-print-directory stress SAN="-fsanitize=thread")
	$(call gate,leaks,$(MAKE) --no-print-directory leakcheck)
	$(call gate,energy and CPU,$(MAKE) --no-print-directory power)
	$(call gate,showdown self-test,./$(SHOWDOWN) --selftest $(PDF))
	@echo "" && echo "verify-all: every gate passed"

# Deliberately does NOT remove $(APP).zip.
#
# Everything else here is regenerated by `make` from something tracked, which is
# what makes deleting it safe. The ZIP is not: it is committed on purpose (see
# .gitignore, which spells out why -- the Mavericks machine cannot build this
# tree, so a clone has to carry a working app), and regenerating it now needs a
# Developer ID that the machine doing the cleaning may not have. A `clean` that
# deletes a tracked artefact nobody present can rebuild is a `clean` that loses
# work. Use `distclean` to remove it deliberately.
clean:
	@rm -rf $(BUILD) $(BUNDLE) $(BENCHMARK) $(PROFILE) $(SHOWDOWN)

distclean: clean
	@rm -f $(APP).zip
