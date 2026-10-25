# ARM64EC fork: keeping up with upstream

This branch (`win-arm64ec`) is Bambu Studio's upstream `master` plus a small set of fork-only changes. It builds an **ARM64EC** version for Windows on ARM (Snapdragon X Elite) that can still load Bambu's x64-only network plugin, so cloud login, LAN printing and the camera all work.

## What the fork adds

Bambu merged the ARM64/ARM64EC build support (PR #11599, by Ryan Ewen) into upstream `master` on 8 Oct 2026, as commit `47a13ee`. So that part now comes from upstream automatically. The fork only adds what's in `fork-arm64ec.patch`:

| Change | Why |
|---|---|
| `.github/workflows/build_win_arm64ec.yml` | Builds only the ARM64EC variant on GitHub's free `windows-11-arm` runner, on every push to `win-arm64ec` or when started by hand, instead of upstream's 9-job matrix. |
| `deps/OpenSSL/OpenSSL.cmake` | Picks vsdevcmd's `-host_arch` from the build machine, so ARM64EC dependencies can also be cross-built on an x64 PC. Upstream hard-codes `arm64`. |
| `.github/workflows/build_deps.yml`, `build_bambu.yml` | Pick the CMake generator from the Visual Studio installed on the runner. Between late September and late October 2026, GitHub's `windows-11-arm` image moved from VS 2022 to VS 2026, and upstream's ARM steps hard-code `Visual Studio 17 2022`, so the build failed with "could not find any instance of Visual Studio". |

## Files in this folder

| File | Purpose |
|---|---|
| `update-from-upstream.ps1` | Pulls in upstream changes and re-applies the fork's changes, in one step |
| `fork-arm64ec.patch` | The fork's code changes as a `git am` patch. The script refreshes it after every update. |
| `.gitattributes` | Keeps the patch byte-exact (no CRLF conversion) so `git am` can always apply it |

## Updating (the usual way)

From the repo root (`C:\git-repos\personal\BambuStudio`), in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\arm64ec\update-from-upstream.ps1 -Push
```

The script does the following, stopping safely if anything goes wrong:

1. Checks there are no uncommitted changes and switches to `win-arm64ec`.
2. Fetches `upstream/master` and fast-forwards your local `master` to it. This is local only; your fork's `master` on GitHub isn't touched.
3. Tags the current branch as `backup/win-arm64ec-<date-time>` so you can undo.
4. Rebases the fork's commits onto the new upstream. Commits that upstream already contains are skipped automatically.
5. Refreshes `fork-arm64ec.patch` and commits this folder if it changed.
6. With `-Push`, force-pushes to your fork (`--force-with-lease`), which starts the **Build Windows ARM64EC** workflow.

Leave off `-Push` to review first, then push yourself:

```powershell
git log --oneline -5
git push --force-with-lease origin win-arm64ec
```

`-ExecutionPolicy Bypass` applies to that one run only. Windows blocks local scripts by default.

## If the rebase stops on a conflict

The script tells you, and leaves the rebase in progress.

1. Run `git status` to see the files marked "both modified".
2. Open each file and resolve the `<<<<<<<` / `>>>>>>>` blocks. Keep upstream's new code *and* the fork's change.
3. Run `git add <file>` for each one, then `git rebase --continue`.
4. Run the script again. It finds nothing new to rebase, refreshes the patch, and can push.

To give up instead, run `git rebase --abort`, which puts everything back as it was.

## Re-apply from scratch (if a rebase gets messy)

```powershell
powershell -ExecutionPolicy Bypass -File .\arm64ec\update-from-upstream.ps1 -Mode Reapply -Push
```

This resets `win-arm64ec` to exactly `upstream/master` and applies `fork-arm64ec.patch` with `git am --3way`. It saves a copy of this folder to your temp directory first, then puts it back.

If `git am` stops:

- On a conflict: fix the files, run `git add <file>`, then `git am --continue`.
- If git reports "patch already applied", upstream has taken the change: run `git am --skip`.

Then copy the folder back and re-run the script. The exact command is printed in the warning.

## The same thing by hand (no script)

```powershell
git checkout win-arm64ec
git fetch upstream
git tag backup/win-arm64ec-manual          # safety point
git rebase upstream/master                  # or: git reset --hard upstream/master; git am --3way <copy of fork-arm64ec.patch>
git push --force-with-lease origin win-arm64ec
```

## Undo an update

Every run leaves a tag. To list the tags and go back to one:

```powershell
git tag -l "backup/*"
git reset --hard backup/win-arm64ec-<date-time>
git push --force-with-lease origin win-arm64ec      # only if you'd already pushed the bad update
```

Tidy up old tags with `git tag -d backup/win-arm64ec-<date-time>`. They're local only and never pushed.

## After pushing

- GitHub builds the portable zip. If upstream didn't change anything under `deps/`, the dependency cache is reused and the build is much quicker.
- Download the `BambuStudio_Windows_<ver>_arm64ec_portable` artifact. Unzip it **over the same folder on the laptop** (for example `C:\Apps\BambuStudio-arm64ec`), so shortcuts and `.3mf` file associations keep working.
- Artifacts are deleted after 90 days, so keep the zip of any build that works well.

## Notes

- Since PR #11599 is now upstream, upstream's own `build_all.yml` includes `windows-11-arm` ARM64 and ARM64EC jobs. Don't push to your fork's `master` unless you want that full matrix to run.
- Upstream commits many times a day, mostly translation and version bumps. Update when you want new features or fixes, not on every commit.
