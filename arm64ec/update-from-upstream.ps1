<#
.SYNOPSIS
    Brings the win-arm64ec branch up to date with upstream Bambu Studio and
    re-applies this fork's ARM64EC changes on top.

.DESCRIPTION
    Run from anywhere inside the repo, in Windows PowerShell 5.1 or PowerShell 7.

    Steps:
      1. Checks the working tree is clean and no rebase or am is in progress.
      2. Fetches upstream/master and fast-forwards your local master to it.
      3. Tags the current branch as backup/win-arm64ec-<timestamp> so you can undo.
      4. Re-applies the fork's changes:
           -Mode Rebase  (default) replays this branch's own commits on top of
                         upstream/master. Commits upstream already contains are
                         skipped automatically.
           -Mode Reapply resets the branch to upstream/master and applies
                         arm64ec\fork-arm64ec.patch. Use this if a rebase gets messy.
      5. Regenerates arm64ec\fork-arm64ec.patch from the rebased code commits and
         commits the arm64ec folder if anything in it changed.
      6. With -Push, force-pushes the branch to origin (with lease), which starts
         the "Build Windows ARM64EC" GitHub workflow.

.EXAMPLE
    .\arm64ec\update-from-upstream.ps1
.EXAMPLE
    .\arm64ec\update-from-upstream.ps1 -Push
.EXAMPLE
    .\arm64ec\update-from-upstream.ps1 -Mode Reapply -Push
#>
[CmdletBinding()]
param(
    [ValidateSet('Rebase', 'Reapply')]
    [string]$Mode = 'Rebase',
    [switch]$Push,
    [string]$Branch = 'win-arm64ec',
    [string]$UpstreamRemote = 'upstream',
    [string]$UpstreamBranch = 'master',
    [string]$ForkRemote = 'origin'
)

function Invoke-Git {
    & git @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed (exit code $LASTEXITCODE)." }
}

function Get-GitOutput {
    $out = & git @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed (exit code $LASTEXITCODE)." }
    return $out
}

# --- 0. Locate the repo -------------------------------------------------------
$root = & git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $root) { throw 'Run this script from inside the BambuStudio repository.' }
$ErrorActionPreference = 'Stop'
Set-Location $root
$folder    = Join-Path $root 'arm64ec'
$patchFile = Join-Path $folder 'fork-arm64ec.patch'
$target    = "$UpstreamRemote/$UpstreamBranch"
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'

# --- 1. Safety checks ---------------------------------------------------------
$gitDir = Get-GitOutput rev-parse --git-dir
if ((Test-Path (Join-Path $gitDir 'rebase-merge')) -or (Test-Path (Join-Path $gitDir 'rebase-apply'))) {
    throw 'A rebase or git am is already in progress. Finish it (git rebase --continue / git am --continue) or abort it first.'
}
$dirty = Get-GitOutput status --porcelain --untracked-files=no
if ($dirty) {
    throw "You have uncommitted changes to tracked files. Commit them, or stash them with 'git stash', then run this again."
}
$remotes = Get-GitOutput remote
if ($remotes -notcontains $UpstreamRemote) {
    throw "No '$UpstreamRemote' remote. Add it with: git remote add $UpstreamRemote https://github.com/bambulab/BambuStudio.git"
}

$current = Get-GitOutput rev-parse --abbrev-ref HEAD
if ($current -ne $Branch) {
    Write-Host "Switching from '$current' to '$Branch'..."
    Invoke-Git checkout $Branch
}

# --- 2. Fetch upstream and update local master --------------------------------
Write-Host "Fetching $target..."
Invoke-Git fetch $UpstreamRemote $UpstreamBranch

$behind = [int](Get-GitOutput rev-list --count "HEAD..$target")
$upstreamHead = Get-GitOutput log -1 --format='%h %cd %s' --date=short $target
Write-Host "Upstream is at: $upstreamHead"
Write-Host "Upstream commits not yet on '$Branch': $behind"

# Fast-forward local master to upstream (local only; nothing is pushed).
& git show-ref --verify --quiet "refs/heads/$UpstreamBranch"
if ($LASTEXITCODE -eq 0) {
    & git merge-base --is-ancestor $UpstreamBranch $target
    if ($LASTEXITCODE -eq 0) {
        $targetSha = Get-GitOutput rev-parse $target
        Invoke-Git update-ref -m "update-from-upstream: fast-forward to $target" "refs/heads/$UpstreamBranch" $targetSha
        Write-Host "Local '$UpstreamBranch' fast-forwarded to $target."
    } else {
        Write-Warning "Local '$UpstreamBranch' has commits upstream does not. Left it alone."
    }
}

if ($behind -eq 0 -and $Mode -eq 'Rebase') {
    Write-Host "'$Branch' already contains everything from $target. Nothing to re-apply."
} else {
    # --- 3. Backup tag --------------------------------------------------------
    $backup = "backup/$Branch-$stamp"
    Invoke-Git tag $backup
    Write-Host "Saved the current branch as tag '$backup'. To undo everything: git reset --hard $backup"

    if ($Mode -eq 'Rebase') {
        # --- 4a. Rebase -------------------------------------------------------
        Write-Host "Rebasing '$Branch' onto $target..."
        & git rebase $target
        if ($LASTEXITCODE -ne 0) {
            Write-Warning @"
The rebase stopped on a conflict. To finish it:
  1. Run 'git status' to see the conflicted files.
  2. Edit each one: keep upstream's new code AND the ARM64/ARM64EC branches.
  3. 'git add <file>' for each, then 'git rebase --continue'.
  4. Run this script again (it will refresh the patch file and can push).
To give up and go back:  git rebase --abort
"@
            exit 1
        }
    } else {
        # --- 4b. Reset and re-apply the patch file ------------------------------
        if (-not (Test-Path $patchFile)) { throw "Patch file not found: $patchFile" }
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "bambu-arm64ec-$stamp"
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $saved = Join-Path $tmp 'arm64ec'
        Copy-Item -LiteralPath $folder -Destination $saved -Recurse
        Write-Host "Copied the arm64ec folder to $saved before resetting."

        Invoke-Git reset --hard $target
        Write-Host "Applying fork-arm64ec.patch..."
        & git am --3way (Join-Path $saved 'fork-arm64ec.patch')
        if ($LASTEXITCODE -ne 0) {
            Write-Warning @"
The patch did not apply cleanly. To finish it:
  - Fix the conflicted files, 'git add <file>', then 'git am --continue'.
  - If git says the patch is already applied (upstream merged it), run 'git am --skip'.
Then put the folder back and run this script again:
  Copy-Item -LiteralPath '$saved' -Destination '$root' -Recurse -Force
To give up and go back:  git am --abort; git reset --hard $backup
"@
            exit 1
        }
        if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
        Copy-Item -LiteralPath $saved -Destination $root -Recurse
    }
}

# --- 5. Refresh the patch file and commit the arm64ec folder -------------------
# The patch holds only the fork's code commits (everything except this folder).
$exportDir = Join-Path ([IO.Path]::GetTempPath()) "bambu-arm64ec-export-$stamp"
New-Item -ItemType Directory -Path $exportDir | Out-Null
Invoke-Git format-patch --quiet -o $exportDir "$target..HEAD" -- . ':!arm64ec'
$parts = @(Get-ChildItem -Path $exportDir -Filter '*.patch' | Sort-Object Name)
if ($parts.Count -eq 0) {
    Write-Warning "No fork code commits found on top of $target. Upstream may now contain all of them; the patch file was left as it was."
} else {
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $stream = [IO.File]::Create($patchFile)
    try {
        foreach ($p in $parts) {
            $bytes = [IO.File]::ReadAllBytes($p.FullName)
            $stream.Write($bytes, 0, $bytes.Length)
        }
    } finally {
        $stream.Dispose()
    }
    Write-Host "Refreshed arm64ec\fork-arm64ec.patch ($($parts.Count) commit(s))."
}
Remove-Item -Path $exportDir -Recurse -Force

$folderChanges = Get-GitOutput status --porcelain -- arm64ec
if ($folderChanges) {
    Invoke-Git add -- arm64ec
    $base = Get-GitOutput rev-parse --short $target
    Invoke-Git commit --quiet -m "arm64ec: update fork patch and notes (upstream $base)"
    Write-Host 'Committed the updated arm64ec folder.'
}

Write-Host ''
Invoke-Git log --oneline --decorate -n 4

# --- 6. Push -----------------------------------------------------------------------
if ($Push) {
    Write-Host "Pushing '$Branch' to $ForkRemote (force-with-lease)..."
    Invoke-Git push --force-with-lease $ForkRemote $Branch
    Write-Host 'Pushed. The "Build Windows ARM64EC" workflow will start on GitHub.'
} else {
    Write-Host ''
    Write-Host "Not pushed. When you're ready: git push --force-with-lease $ForkRemote $Branch"
}
