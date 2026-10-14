[CmdletBinding()]
param([string]$PythonPath = '')
$ErrorActionPreference='Stop'
if(-not $PythonPath){
    $bundled=Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    if(Test-Path -LiteralPath $bundled){$PythonPath=$bundled}
    else{$command=Get-Command python.exe -ErrorAction SilentlyContinue;if($command){$PythonPath=$command.Source}}
}
if(-not $PythonPath -or -not (Test-Path -LiteralPath $PythonPath)){
    throw '需要 Python 3 和 pypdfium2。安装后使用 -PythonPath 指定 Python 路径。'
}
& $PythonPath -c 'import pypdfium2'
if($LASTEXITCODE -ne 0){throw '此 Python 缺少 pypdfium2，请执行 python -m pip install pypdfium2 后重试。'}
& $PythonPath (Join-Path $PSScriptRoot 'Import-OfficialQuestions.py') --data-root (Join-Path $env:LOCALAPPDATA 'SleepGuardian')
if($LASTEXITCODE -ne 0){throw '官方题库导入失败，现有题库未被覆盖。'}
