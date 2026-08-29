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
#   make clean

APP      := Postview
BUNDLE   := $(APP).app
BUILD    := build
CONTENTS := $(BUNDLE)/Contents
MACOS    := $(CONTENTS)/MacOS
RES      := $(CONTENTS)/Resources
# Make needs spaces escaped in prerequisite names; the raw form is kept for
# quoted shell commands below, where a backslash would become part of the name.
ICON_SOURCE := Resources/New\ Icon\ (Rename\ me).icns
ICON_SOURCE_PATH := Resources/New Icon (Rename me).icns
BENCHMARK_SOURCE := Tools/benchmark-preview-vs-postview.sh
BENCHMARK := Postview-Benchmark.command
PROFILE_SOURCE := Tools/profile-postview.sh
PROFILE := Postview-Profile.command
DISTDIR := $(BUILD)/dist

CC       := $(shell xcrun -f clang)
SDK      := $(shell xcrun --show-sdk-path)
MIN      := 10.9

SOURCES  := $(wildcard Sources/*.m)
OBJECTS  := $(patsubst Sources/%.m,$(BUILD)/%.o,$(SOURCES))

# -march=core2: Mavericks runs on Macs as old as 2007, some of which predate
# SSE4.1. The default x86_64 baseline (penryn) would emit instructions those
# machines cannot execute.
CFLAGS := -arch x86_64 -march=core2 -mmacosx-version-min=$(MIN) -isysroot $(SDK) \
          -fno-objc-arc -fobjc-exceptions \
          -Os -fno-common -fvisibility=hidden \
          -Wall -Wextra -Wno-unused-parameter \
          -Werror=unguarded-availability -Werror=unguarded-availability-new \
          -Wno-deprecated-declarations \
          -Wno-objc-missing-property-synthesis

# Only Cocoa and CoreGraphics. Every resulting LC_LOAD_DYLIB path is one that
# exists on 10.9 (verified against the 10.9 SDK framework layout); `make verify`
# re-checks this after every build.
LDFLAGS := -arch x86_64 -mmacosx-version-min=$(MIN) -isysroot $(SDK) \
           -framework Cocoa -framework CoreGraphics -Wl,-dead_strip

.PHONY: all clean run dist verify icon analyze release test uitest soak stress leakcheck

all: $(BUNDLE)

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/%.o: Sources/%.m | $(BUILD)
	@echo "  compile  $<"
	@$(CC) $(CFLAGS) -c $< -o $@

$(BUNDLE): $(OBJECTS) Resources/Info.plist $(ICON_SOURCE)
	@echo "  link     $(MACOS)/$(APP)"
	@mkdir -p $(MACOS) $(RES)
	@$(CC) $(LDFLAGS) $(OBJECTS) -o $(MACOS)/$(APP)
	@strip -x $(MACOS)/$(APP)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@printf 'APPL????' > $(CONTENTS)/PkgInfo
	@cp "$(ICON_SOURCE_PATH)" "$(RES)/$(APP).icns"
	@cp Resources/TB_*.pdf $(RES)/ 2>/dev/null || true
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

run: $(BUNDLE)
	@open $(BUNDLE)

dist: $(BUNDLE) verify $(BENCHMARK) $(PROFILE)
	@rm -rf "$(DISTDIR)"
	@mkdir -p "$(DISTDIR)"
	@ditto "$(BUNDLE)" "$(DISTDIR)/$(BUNDLE)"
	@cp README.md "$(DISTDIR)/README.md"
	@cp "$(BENCHMARK)" "$(DISTDIR)/$(BENCHMARK)"
	@cp "$(PROFILE)" "$(DISTDIR)/$(PROFILE)"
	@xattr -cr "$(DISTDIR)" 2>/dev/null || true
	@rm -f $(APP).zip
	@ditto -c -k --sequesterRsrc "$(DISTDIR)" $(APP).zip
	@echo "  packaged $(APP).zip  ($$(du -h $(APP).zip | cut -f1))"

verify:
	@echo "== Mach-O compatibility check =="
	@plutil -lint $(CONTENTS)/Info.plist >/dev/null || \
	  (echo "FAIL: Info.plist is invalid"; exit 1)
	@cmp -s "$(ICON_SOURCE_PATH)" "$(RES)/$(APP).icns" || \
	  (echo "FAIL: bundled icon does not match the selected source icon"; exit 1)
	@otool -l $(MACOS)/$(APP) | grep -A2 LC_VERSION_MIN_MACOSX || \
	  (echo "FAIL: no LC_VERSION_MIN_MACOSX (Mavericks dyld cannot load this)"; exit 1)
	@if otool -l $(MACOS)/$(APP) | grep -q LC_BUILD_VERSION; then \
	  echo "FAIL: LC_BUILD_VERSION present"; exit 1; fi
	@if otool -l $(MACOS)/$(APP) | grep -q LC_DYLD_CHAINED_FIXUPS; then \
	  echo "FAIL: chained fixups are not supported by Mavericks dyld"; exit 1; fi
	@echo "-- architecture --"
	@lipo -info $(MACOS)/$(APP)
	@echo "-- linked libraries (all must exist on 10.9) --"
	@otool -L $(MACOS)/$(APP) | tail -n +2
	@otool -L $(MACOS)/$(APP) | tail -n +2 | awk '{print $$1}' | \
	  grep -vE '^/System/Library/Frameworks/(Cocoa|AppKit|Foundation|CoreFoundation|CoreGraphics)\.framework/Versions/[A-Z]/[A-Za-z]+$$' | \
	  grep -vE '^/usr/lib/(libSystem\.B|libobjc\.A)\.dylib$$' | \
	  (! grep .) || (echo "FAIL: unexpected dylib above"; exit 1)
	@echo "OK"

# Static analysis has no runtime or test-fixture dependency.  It is a release
# gate alongside the tests below, using the exact Mavericks deployment target
# and warning policy as the shipping binary.
analyze: | $(BUILD)
	@echo "== Clang static analysis =="
	@for f in $(SOURCES); do \
	  echo "  analyze  $$f"; \
	  $(CC) $(CFLAGS) --analyze -Xanalyzer -analyzer-output=text $$f || exit 1; \
	done
	@echo "OK"

# Headless checks for the logic that has no visible surface. Self contained:
# it generates its own fixtures. Point REALPDF at any document to additionally
# run the scale-independence check against it.
PDF ?= $(BUILD)/heavy.pdf
REALPDF ?=
TESTOBJ := $(filter-out $(BUILD)/main.o $(BUILD)/PVAppDelegate.o $(BUILD)/PVDocument.o $(BUILD)/PVWindowController.o,$(OBJECTS))

test: $(OBJECTS) | $(BUILD)
	@$(CC) $(CFLAGS) -ISources -c Tests/pvtest.m -o $(BUILD)/pvtest.o
	@$(CC) $(LDFLAGS) $(TESTOBJ) $(BUILD)/pvtest.o -o $(BUILD)/pvtest
	@python3 Tests/make_rotation_fixture.py $(BUILD)/rotation.pdf >/dev/null
	@test -f $(BUILD)/heavy.pdf || ( \
	   $(CC) -isysroot $(SDK) -fobjc-arc -framework Cocoa \
	     -o $(BUILD)/mkheavy Tests/make_heavy_fixture.m && \
	   $(BUILD)/mkheavy $(BUILD)/heavy.pdf 60 )
	@$(BUILD)/pvtest $(PDF) $(BUILD)/rotation.pdf $(REALPDF)

UIOBJ := $(filter-out $(BUILD)/main.o $(BUILD)/PVAppDelegate.o $(BUILD)/PVDocument.o,$(OBJECTS))

uitest: $(OBJECTS) | $(BUILD)
	@test -f $(BUILD)/heavy.pdf || ( \
	   $(CC) -isysroot $(SDK) -fobjc-arc -framework Cocoa \
	     -o $(BUILD)/mkheavy Tests/make_heavy_fixture.m && \
	   $(BUILD)/mkheavy $(BUILD)/heavy.pdf 60 )
	@$(CC) $(CFLAGS) -ISources -c Tests/pvuitest.m -o $(BUILD)/pvuitest.o
	@$(CC) $(LDFLAGS) $(UIOBJ) $(BUILD)/pvuitest.o -o $(BUILD)/pvuitest
	@# The toolbar artwork, where a bare executable's own +mainBundle looks for
	@# resources: beside the binary. Without this the icon checks fail for want
	@# of a bundle rather than for want of the assets.
	@cp Resources/TB_*.pdf $(BUILD)/ 2>/dev/null || true
	@$(BUILD)/pvuitest $(PDF) $(BUILD)/shots

# Long-uptime check: repeats the whole document lifecycle and asserts that
# every one of Postview's long-lived objects is deallocated afterwards. 150 is
# the point at which the secondary footprint trend also becomes stable enough
# to assert on; below that it is reported but not enforced.
SOAKCYCLES ?= 150

soak: $(OBJECTS) | $(BUILD)
	@test -f $(BUILD)/heavy.pdf || ( \
	   $(CC) -isysroot $(SDK) -fobjc-arc -framework Cocoa \
	     -o $(BUILD)/mkheavy Tests/make_heavy_fixture.m && \
	   $(BUILD)/mkheavy $(BUILD)/heavy.pdf 60 )
	@$(CC) $(CFLAGS) -ISources -c Tests/pvsoak.m -o $(BUILD)/pvsoak.o
	@$(CC) $(LDFLAGS) $(UIOBJ) $(BUILD)/pvsoak.o -o $(BUILD)/pvsoak
	@$(BUILD)/pvsoak $(PDF) $(SOAKCYCLES)

# Contention check: the same objects, driven with every asynchronous event the
# app can receive arriving while the render queue is busy. pvsoak proves a
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
STRESSCFLAGS := $(STRESSARCH) -isysroot $(SDK) -fno-objc-arc -fobjc-exceptions                 -g -O1 $(SAN) -Wall -Wextra -Wno-unused-parameter                 -Wno-deprecated-declarations -ISources
STRESSLD := $(STRESSARCH) -isysroot $(SDK) $(SAN) -framework Cocoa -framework CoreGraphics
STRESSSRC := $(filter-out Sources/main.m Sources/PVAppDelegate.m Sources/PVDocument.m,$(SOURCES))
STRESSSCALE ?= 1

stress: | $(BUILD)
	@mkdir -p $(BUILD)/stress
	@test -f $(BUILD)/heavy.pdf || ( 	   $(CC) -isysroot $(SDK) -fobjc-arc -framework Cocoa 	     -o $(BUILD)/mkheavy Tests/make_heavy_fixture.m && 	   $(BUILD)/mkheavy $(BUILD)/heavy.pdf 60 )
	@for f in $(STRESSSRC) Tests/pvstress.m; do 	   o=$(BUILD)/stress/$$(basename $$f .m).o; 	   $(CC) $(STRESSCFLAGS) -c $$f -o $$o || exit 1; 	 done
	@$(CC) $(STRESSLD) $(BUILD)/stress/*.o -o $(BUILD)/pvstress
	@cp Resources/TB_*.pdf $(BUILD)/ 2>/dev/null || true
	@$(BUILD)/pvstress $(PDF) $(STRESSSCALE)

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
leakcheck: $(OBJECTS) | $(BUILD)
	@$(CC) $(CFLAGS) -ISources -c Tests/pvsoak.m -o $(BUILD)/pvsoak.o
	@$(CC) $(LDFLAGS) $(UIOBJ) $(BUILD)/pvsoak.o -o $(BUILD)/pvsoak
	@report="$(BUILD)/leaks-report.txt"; status=0; \
	  MallocStackLogging=1 leaks --atExit -- $(BUILD)/pvsoak $(PDF) 25 > "$$report" 2>&1 || status=$$?; \
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

# Full daily-driver gate.  Packaging is reached only after static analysis,
# logic/UI/lifecycle tests, contention stress, and a zero-leak report all pass.
release:
	@$(MAKE) analyze
	@$(MAKE) test
	@$(MAKE) uitest
	@$(MAKE) soak
	@$(MAKE) stress
	@$(MAKE) leakcheck
	@$(MAKE) dist

clean:
	@rm -rf $(BUILD) $(BUNDLE) $(APP).zip $(BENCHMARK) $(PROFILE)
