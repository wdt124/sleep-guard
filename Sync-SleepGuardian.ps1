[CmdletBinding()]
param(
    [ValidateSet('Status', 'Push', 'Pull')]
    [string]$Action = 'Status',
    [string]$Message = 'Update Sleep Guardian'
)

$ErrorActionPreference = 'Stop'
$RepositoryPath = $PSScriptRoot

Push-Location $RepositoryPath
try {
    & git rev-parse --is-inside-work-tree 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '当前目录还没有初始化为 Git 仓库。' }

    switch ($Action) {
        'Status' {
            & git status --short --branch
        }
        'Pull' {
            if (& git status --porcelain) { throw '本地有未提交修改，请先提交或处理后再拉取。' }
            & git pull --ff-only origin main
            if ($LASTEXITCODE -ne 0) { throw '拉取失败；没有改写本地历史。' }
        }
        'Push' {
            & git check-ignore --quiet -- config.json
            if ($LASTEXITCODE -ne 0) { throw '安全检查失败：config.json 没有被 .gitignore 排除。' }

            & git ls-files --error-unmatch -- config.json 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { throw '安全检查失败：config.json 已被 Git 跟踪。' }

            & git add --all
            & git diff --cached --quiet
            if ($LASTEXITCODE -eq 1) {
                & git commit -m $Message
                if ($LASTEXITCODE -ne 0) { throw '提交失败。' }
            }
            & git push origin main
            if ($LASTEXITCODE -ne 0) { throw '推送失败；本地提交仍然安全保留。' }
        }
    }
}
finally {
    Pop-Location
}
