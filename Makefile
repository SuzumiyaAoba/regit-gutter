EMACS ?= emacs
LOAD_PATH_FLAGS ?=

.PHONY: check compile test benchmark clean
check: compile test
compile:
	$(EMACS) -Q --batch -L . $(LOAD_PATH_FLAGS) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile regit-gutter.el
test:
	$(EMACS) -Q --batch -L . $(LOAD_PATH_FLAGS) -l test/regit-gutter-test.el -f ert-run-tests-batch-and-exit
benchmark:
	@$(EMACS) -Q --batch -L . $(LOAD_PATH_FLAGS) -l bench-regit-gutter.el
clean:
	rm -f regit-gutter.elc
