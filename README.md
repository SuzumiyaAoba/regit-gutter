# regit-gutter

An independent, performance-first Git gutter for Emacs 29.1+. No dependency on
`git-gutter`, no advice on Emacs primitives, and no native compiler dependency.
Requires Git. Tested on macOS with Emacs 31.1.

## Features

- `+`, `~`, `-` indicators in the left margin, in GUI and terminal Emacs.
- Next/previous hunk navigation, with wraparound.
- Hunk preview, stage, and confirmed discard.
- Asynchronous, file-scoped Git reads **and writes**.
- Saved-file changes relative to the index, including partially staged files.
- Multiple windows, linked worktrees and submodule `.git` files.
- Automatic refresh after save/revert; explicit refresh after external Git work.
- Buffer-local mode and `global-regit-gutter-mode`.

This is a standalone implementation, not a patch, fork, or API-compatible drop-in
replacement for `git-gutter`.

## Install

Put this directory on `load-path`. Byte-compile for the lowest load overhead:

```sh
make compile
```

```elisp
(add-to-list 'load-path "/path/to/regit-gutter")
(require 'regit-gutter)
(global-regit-gutter-mode 1)

;; Optional bindings; the package does not take global keys itself.
(keymap-global-set "C-c g n" #'regit-gutter-next-hunk)
(keymap-global-set "C-c g p" #'regit-gutter-previous-hunk)
(keymap-global-set "C-c g v" #'regit-gutter-popup-hunk)
(keymap-global-set "C-c g s" #'regit-gutter-stage-hunk)
(keymap-global-set "C-c g r" #'regit-gutter-revert-hunk)
```

Alternatively, enable `regit-gutter-mode` in individual buffers. Disable other
Git gutter modes before using this package: they may compete for margin space.

For external index changes, call `regit-gutter-refresh` or
`regit-gutter-refresh-all`. An optional Magit integration is:

```elisp
(with-eval-after-load 'magit
  (add-hook 'magit-post-refresh-hook #'regit-gutter-refresh-all))
```

## Commands and options

| Command | Action |
| --- | --- |
| `regit-gutter-refresh` | Debounce a fresh saved-file diff in this buffer |
| `regit-gutter-refresh-all` | Refresh all enabled buffers |
| `regit-gutter-next-hunk` / `regit-gutter-previous-hunk` | Navigate; numeric prefix supported |
| `regit-gutter-popup-hunk` | Show the patch at point |
| `regit-gutter-stage-hunk` | Stage the complete hunk at point |
| `regit-gutter-revert-hunk` | Confirm and discard the complete saved hunk |

`regit-gutter-delay` defaults to 0.15 seconds. `regit-gutter-prefetch-lines`
defaults to 8. `regit-gutter-max-reads` defaults to 4 and bounds concurrent
background diffs; extra buffers wait in a queue. Signs and faces are
customizable; signs should occupy one column.
`regit-gutter-git-executable` selects Git. The buffer-local
`regit-gutter--error` retains the most recent diff error for diagnostics.

A deletion is indicated on the preceding surviving line, or the first position
for a deletion at the start of the file. Mode-only changes, binary changes and
unmerged/combined diffs do not produce text hunk indicators.

## Performance architecture

1. **Cheap load.** Common Lisp macros are compile-time dependencies. Byte-compiled
   loading does not require `cl-lib` or `comp`, install advice, start a process,
   or register a timer. Enabling a mode does a local ancestor search for `.git`.
2. **Event-driven work.** Save/revert/explicit-refresh requests are debounced.
   Each buffer has at most one background diff. A replacement cancels obsolete
   read work. There are no repeating timers and no post-command hook.
3. **No whole-repository status.** Git reads use a literal pathspec for one file,
   zero-context output, no external diff driver, and no textconv. There is no
   shell command construction in the library.
4. **Indexed hunk data.** Parse each result once; map positions in a forward pass.
   Rendering binary-searches the hunk vector at each visible range.
5. **Visible-only overlays.** Retain overlays only for displayed lines plus a
   small look-ahead. Reuse unchanged overlays, and skip unchanged window ranges.
   A stale `window-end` cannot cause full-buffer rendering: window height also
   bounds the range. Multiple windows share the union of visible overlays.
6. **No filesystem polling.** The package never repeatedly checks Git status
   while the user is idle or typing. The first unsaved edit clears stale signs;
   subsequent keystrokes do not launch Git.

Git still needs to compute the diff. Parsing scales with patch size and hunk
count; mapping hunk positions scans the required part of the file. These occur
on completion and are **not constant-time**. Output and hunk data remain in
memory. The overlay bound is not a bound on total patch memory or callback time.
Background diffs are globally bounded by `regit-gutter-max-reads`; buffers that
would exceed the limit queue until a read finishes. Git writes invoked by
stage/discard commands bypass the queue.

## Safety and deliberate scope

- This version compares the **saved working file with the index**, not unsaved
  buffer contents. Save to update signs. It does not silently save your edits.
- Before stage/discard, an asynchronous fresh diff must exactly match the
  displayed snapshot. Buffer generation, character tick, file identity and
  visited-file modification time are checked. Git apply then validates patch
  applicability. Index updates use Git's normal locking.
- Discard changes the saved file after confirmation. Discarding an intent-to-add
  file's full hunk deletes the new file; the confirmation explicitly says so.
  The buffer is reloaded only
  if it has not been edited or renamed while the operation was running. New
  unsaved edits are preserved; in that case the buffer and disk can differ and
  must be reconciled explicitly. Do not rely on Emacs undo to undo a discard.
- These checks are not a transaction across arbitrary external worktree writers.
  Avoid concurrent writes to the same file. A running Git write is **not killed**
  when the mode is disabled or buffer is closed; it may complete. Obsolete reads
  are cancelled and cannot publish results.
- Local, nonsymlink, UTF-8/ASCII files only. Remote, other-encoding and indirect
  buffers are not enabled. Untracked files have no index baseline and no signs;
  add them with Git first (or use `git add -N`).
- Narrowing restricts navigation, but a stage/discard still operates on the whole
  selected hunk, possibly including text outside the restriction.
- Git's content filters and arbitrarily folded/invisible listings are not
  supported as alternate line mappings. Margins can conflict with other gutter
  packages. Existing nonzero margin widths and the right margin are preserved;
  restoring owned margin space does not overwrite a subsequently changed width.
- No region/individual-line staging, staged-versus-HEAD gutter, or Git Gutter API
  aliases in this initial version.

## Verification

```sh
make check                         # strict byte compilation + ERT
python3 scripts/smoke.py            # real terminal, including stage/discard
python3 scripts/smoke.py --gui      # real GUI, including stage/discard
make benchmark                     # JSON, simulated 40-line viewport
python3 scripts/benchmark-load.py --git-gutter-dir /path/to/git-gutter
```

The 34 ERT tests cover actual Git staging/discard, stale snapshots, edits during
async operations, cancellation of discard, initial insertions and empty-file
deletions, missing final newlines, literal/newline/Unicode filenames, linked
worktrees, intent-to-add, line-offset staging, independent file-mode changes,
multiple windows, narrowing, overlay reuse and bounds, coalescing, margin cleanup,
visited-file rename, major-mode changes and process cleanup.
The interactive smoke also passed in GUI and a controlling PTY. Linux, Windows,
and the minimum supported Emacs version have not been tested.

## Initial measurements

macOS 26.5.1 arm64, Emacs 31.1. Raw results: `benchmarks/load.json` and
`benchmarks/workload.json`.

Fresh-process require, one untimed warm-up per package, then five interleaved
samples; medians (both byte-compiled):

| Package | Require | Loaded `comp` during require |
| --- | ---: | --- |
| regit-gutter 0.1.0 | 1.40 ms | No, all samples |
| git-gutter 20241212.1415 | 237.31 ms | Yes, all samples |

Native JIT was disabled for this test; native subr trampolines were **not**
disabled. The comparison includes each package's own dependency loads. OS caches
were not cleared. These are load measurements, not whole-editor speedups.

Single-process workload benchmark, one warm-up fixture then three samples per
case; 40 simulated visible lines plus 8 look-ahead lines, zero debounce delay:

| Lines / hunks | Enable return | Diff ready, including Git | Overlays | 1,000 cached renders | 50 scroll updates |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1,000 / 1 | 0.31 ms | 32 ms | 48 | 11.6 ms | 3.8 ms |
| 100,000 / 1 | 0.64 ms | 340 ms | 48 | 15.1 ms | 5.1 ms |
| 100,000 / 10,000 | 0.21 ms | 242 ms | 5 | 19.4 ms | 6.3 ms |

Fixture creation is outside timing. “Enable return” is only asynchronous
scheduling, **not time until signs appear**. “Diff ready” includes Git, output
parsing, position mapping and overlay creation. This batch test does not measure
actual screen repaint, input latency, or Git Gutter's update path. The GUI/TTY
smoke checks behavior, not a latency distribution.

## License

GPL-3.0-or-later; see [LICENSE](LICENSE).
