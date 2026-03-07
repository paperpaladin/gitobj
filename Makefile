CC      ?= gcc
# -ffile-prefix-map keeps the build directory out of DWARF .debug_line_str, so
# the binary is byte-identical no matter where the tree sits.
CFLAGS  ?= -std=c11 -O2 -Wall -Wextra -Wpedantic -ffile-prefix-map=$(CURDIR)=.

all: gitobj

gitobj: gitobj.c
	$(CC) $(CFLAGS) -o $@ $<

test: gitobj
	@t/run.sh ./gitobj

# We parse zlib streams, pack headers and delta instruction streams whose
# every length field is chosen by whoever wrote the file, so the sanitiser
# build is the one that matters.
#
# exitcode=86 is load-bearing: a sanitiser abort exits 1 by default, and
# t/run.sh's refute() requires exit 1 exactly to mean "cleanly refused this
# input", so without this a sanitiser abort would be indistinguishable from a
# refusal and test-asan could not fail. That was literally true only from the
# commit that made refute() check the status: before it, refute accepted any
# nonzero exit, so this rationale described a guarantee the harness did not
# provide. UBSan needs halt_on_error because it otherwise prints and carries
# on.
SANOPT = ASAN_OPTIONS=exitcode=86 \
	 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1:exitcode=86

test-asan: gitobj.c
	$(CC) -std=c11 -g -O1 -Wall -Wextra -Wpedantic \
		-ffile-prefix-map=$(CURDIR)=. \
		-fsanitize=address,undefined -fno-omit-frame-pointer \
		-o gitobj-asan gitobj.c
	@$(SANOPT) t/run.sh ./gitobj-asan

clean:
	rm -f gitobj gitobj-asan
	rm -rf t/tmp*

.PHONY: all test test-asan clean
