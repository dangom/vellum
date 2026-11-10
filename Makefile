# The module is one Objective-C file; the Command Line Tools are enough.

EMACS ?= emacs
EMACS_INCLUDE ?= $(shell $(EMACS) --batch --eval \
  '(princ (expand-file-name "../include" data-directory))' 2>/dev/null)

CFLAGS  = -O2 -fobjc-arc -Wall -Wextra -Wno-unused-parameter -I$(EMACS_INCLUDE)
LDFLAGS = -dynamiclib -framework Cocoa -framework WebKit

vellum-module.dylib: src/vellum-module.m
	clang $(CFLAGS) $(LDFLAGS) -o $@ $<

.PHONY: clean
clean:
	rm -f vellum-module.dylib
