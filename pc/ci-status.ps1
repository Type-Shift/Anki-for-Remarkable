<#
    Report GitHub Actions status for this repo.

    Reads a fine-grained PAT (Actions: read, Contents: read) stored DPAPI-
    encrypted outside the repo, so no secret is ever committed or pasted
    into a transcript.

    Create the token file with:
        Read-Host "Paste token" -AsSecureString |
          ConvertFrom-SecureString |
          Set-Content "$env:LOCALAPPDATA\rmanki-offline\gh-token.txt" -Encoding utf8

    Usage:
        .\ci-status.ps1              # latest run summary
        .\ci-status.ps1 -Jobs        # per-step detail (use when a run fails)
#>
[CmdletBinding()]
param(
    [string]$Repo      = 'Type-Shift/Anki-for-Remarkable',
    [string]$TokenPath = "$env:LOCALAPPDATA\rmanki-offline\gh-token.txt",
    [switch]$Jobs
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $TokenPath)) {
    Write-Error "No token at $TokenPath. See the header of this script."
}

# Decrypt in-process; never write the plaintext anywhere.
# Set-Content -Encoding utf8 on PowerShell 5.1 emits a UTF-8 BOM, which
# ConvertTo-SecureString rejects with "Input string was not in a correct
# format". Strip the BOM and any trailing newline before decrypting.
$raw    = [System.IO.File]::ReadAllText($TokenPath).TrimStart([char]0xFEFF).Trim()
$secure = $raw | ConvertTo-SecureString
$token  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
             [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))

$headers = @{
    Authorization          = "Bearer $token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'rmanki-ci-status'
}

function Get-Api {
    param([string]$Path)
    Invoke-RestMethod -Uri "https://api.github.com$Path" -Headers $headers -TimeoutSec 30
}

$runs = Get-Api "/repos/$Repo/actions/runs?per_page=5"

if (-not $runs.workflow_runs -or $runs.workflow_runs.Count -eq 0) {
    Write-Output "No workflow runs found for $Repo."
    return
}

Write-Output "=== recent runs ($Repo) ==="
$runs.workflow_runs | ForEach-Object {
    # No ?? operator: this environment is Windows PowerShell 5.1.
    $conclusion = if ($_.conclusion) { $_.conclusion } else { '-' }
    $subject    = $_.head_commit.message.Split("`n")[0]
    '{0,-12} {1,-12} {2}  {3}' -f $_.status, $conclusion, $_.created_at, $subject
} | Write-Output

$latest = $runs.workflow_runs[0]
Write-Output ""
Write-Output "latest: run #$($latest.run_number)  status=$($latest.status)  conclusion=$($latest.conclusion)"
Write-Output "url:    $($latest.html_url)"

if ($Jobs -or $latest.conclusion -eq 'failure') {
    Write-Output ""
    Write-Output "=== steps ==="
    $jobData = Get-Api "/repos/$Repo/actions/runs/$($latest.id)/jobs"
    foreach ($job in $jobData.jobs) {
        Write-Output "job: $($job.name)  [$($job.conclusion)]"
        foreach ($step in $job.steps) {
            $mark = switch ($step.conclusion) {
                'success' { '  ok  ' }
                'failure' { ' FAIL ' }
                'skipped' { ' skip ' }
                default   { '  ..  ' }
            }
            Write-Output "  $mark $($step.name)"
        }
    }
}
