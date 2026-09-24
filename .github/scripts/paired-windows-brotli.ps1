$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = $env:GITHUB_WORKSPACE
$evidence = Join-Path $root 'evidence'
$deps = Join-Path $root 'diagnostic-deps'
New-Item -ItemType Directory -Path $evidence, $deps -Force | Out-Null
$vcvars = 'C:\Program Files\Microsoft Visual Studio\18\Enterprise\VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars)) { throw 'Original VS18 toolchain is unavailable on this runner.' }
$targets = @(
    @{ name = 'base'; sha = '859aea422b5be17ee9fc0f7678e9de302eb67b72' },
    @{ name = 'candidate'; sha = '70be2886587ab3443736a0a0d7f28c9caf735626' }
)
$machine = [ordered]@{
    imageOS = $env:ImageOS; imageVersion = $env:ImageVersion
    runnerOS = $env:RUNNER_OS; runnerArch = $env:RUNNER_ARCH
    cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, Manufacturer, NumberOfCores, NumberOfLogicalProcessors)
    note = 'Both sources build and run in this same job. This does not guarantee the historical failing runner CPU or image is identical.'
}
$machine | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $evidence 'machine.json')
$results = [Collections.Generic.List[object]]::new()

function Run-Batch([string]$Name, [string]$Directory, [string[]]$Lines) {
    $batch = Join-Path $evidence ($Name + '.cmd')
    $log = Join-Path $evidence ($Name + '.log')
    @('@echo off', ('call "' + $vcvars + '"'), 'if errorlevel 1 exit /b %errorlevel%', ('cd /d "' + $Directory + '"'), ('set "PATH=' + $Directory + ';%PATH%"'), ('set "OPENSSL_MODULES=' + $Directory + '\providers"'), ('set "OPENSSL_ENGINES=' + $Directory + '\engines"'), 'set OPENSSL_CONF=') + $Lines | Set-Content -LiteralPath $batch -Encoding ascii
    & cmd.exe /d /c $batch 2>&1 | Out-File -LiteralPath $log -Encoding utf8
    $code = $LASTEXITCODE
    $results.Add([ordered]@{ name = $Name; exitCode = $code; log = (Split-Path $log -Leaf) })
    $results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $evidence 'results.json')
    Write-Host "$Name exit=$code"
    return $code
}

$checksums = Get-Content -LiteralPath (Join-Path $root 'source-candidate/.github/ci-deps.json') -Raw | ConvertFrom-Json
$installer = Join-Path $deps 'nasm-3.01-installer-x64.exe'
Invoke-WebRequest -Uri 'https://www.nasm.us/pub/nasm/releasebuilds/3.01/win64/nasm-3.01-installer-x64.exe' -OutFile $installer
if ((Get-FileHash -LiteralPath $installer).Hash -ne $checksums.'nasm-3.01-installer-x64.exe') { throw 'NASM SHA256 mismatch' }
$install = Start-Process -FilePath $installer -ArgumentList '/S' -Wait -PassThru -WindowStyle Hidden
if ($install.ExitCode -ne 0) { throw 'NASM installation failed' }
$jomZip = Join-Path $deps 'jom.zip'
Invoke-WebRequest -Uri 'https://download.qt.io/official_releases/jom/jom_1_1_7.zip' -OutFile $jomZip
Expand-Archive -LiteralPath $jomZip -DestinationPath $deps
if ((Get-FileHash -LiteralPath (Join-Path $deps 'jom.exe')).Hash -ne $checksums.'jom-1.1.7.exe') { throw 'jom SHA256 mismatch' }
$env:PATH = "$deps;C:\Program Files\NASM;C:\vcpkg\packages\brotli_x64-windows\bin;$env:PATH"
& vcpkg install brotli:x64-windows 2>&1 | Out-File -LiteralPath (Join-Path $evidence 'vcpkg-install.log')
if ($LASTEXITCODE -ne 0) { throw 'Brotli dependency installation failed' }
& vcpkg list 2>&1 | Out-File -LiteralPath (Join-Path $evidence 'vcpkg-versions.log')
& perl -V 2>&1 | Out-File -LiteralPath (Join-Path $evidence 'perl-version.log')
& nasm -v 2>&1 | Out-File -LiteralPath (Join-Path $evidence 'nasm-version.log')
Get-ChildItem -LiteralPath 'C:\vcpkg\packages\brotli_x64-windows\bin' -Filter '*.dll' | Get-FileHash | Select-Object Path, Hash | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence 'brotli-dll-hashes.json')
$built = @{}
foreach ($target in $targets) {
    $source = Join-Path $root ('source-' + $target.name)
    $actual = (& git -C $source rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actual -ne $target.sha) { throw 'Source commit mismatch' }
    $tree = (& git -C $source rev-parse 'HEAD^{tree}').Trim()
    @{ sha = $actual; tree = $tree } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence ($target.name + '-source.json'))
    & git -C $source submodule update --init --depth 1 fuzz/corpora 2>&1 | Out-File -LiteralPath (Join-Path $evidence ($target.name + '-submodule.log'))
    if ($LASTEXITCODE -ne 0) { throw 'Required submodule checkout failed' }
    $build = Join-Path $source '_build'
    New-Item -ItemType Directory -Path $build | Out-Null
    $code = Run-Batch ($target.name + '-configure') $build @(
        'cl /Bv',
        'perl ..\Configure --strict-warnings enable-comp enable-brotli --with-brotli-include=C:\vcpkg\packages\brotli_x64-windows\include --with-brotli-lib=C:\vcpkg\packages\brotli_x64-windows\lib no-makedepend -DOSSL_WINCTX=openssl VC-WIN64A',
        'if errorlevel 1 exit /b %errorlevel%',
        'perl configdata.pm --dump'
    )
    if ($code -ne 0) { continue }
    if ((Run-Batch ($target.name + '-build') $build @('jom /j4 /S')) -ne 0) { continue }
    $built[$target.name] = $build
    Get-ChildItem -LiteralPath $build -Recurse -File | Where-Object { $_.Extension -in '.exe', '.dll' } | Get-FileHash | Select-Object Path, Hash | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence ($target.name + '-binary-hashes.json'))
    if ((Run-Batch ($target.name + '-version') $build @('apps\openssl.exe version -a', 'if errorlevel 1 exit /b %errorlevel%', 'apps\openssl.exe version -c')) -ne 0) { throw 'Built executable did not load' }
    $versionMatch = [regex]::Match((Get-Content -LiteralPath (Join-Path $evidence ($target.name + '-version.log')) -Raw), '(?m)^OpenSSL (\d+\.\d+)\.')
    if (-not $versionMatch.Success) { throw 'Could not read the built OpenSSL version' }
    $versionPrefix = $versionMatch.Groups[1].Value
    & reg.exe add "HKLM\SOFTWARE\OpenSSL-$versionPrefix-openssl" /v OPENSSLDIR /t REG_EXPAND_SZ /d TESTOPENSSLDIR /reg:32 /f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Runner test registry configuration failed' }
    & reg.exe add "HKLM\SOFTWARE\OpenSSL-$versionPrefix-openssl" /v MODULESDIR /t REG_EXPAND_SZ /d TESTOPENSSLDIR /reg:32 /f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Runner test registry configuration failed' }
}
if ($built.Count -ne 2) { throw 'A build failed; paired runtime comparison is inconclusive. See retained results and build logs.' }
$round = 0
foreach ($label in @('base', 'candidate', 'candidate', 'base')) {
    $round++
    foreach ($recipe in @('test_ige', 'test_evp_extra')) {
        Run-Batch ("$round-$label-$recipe") $built[$label] @("jom test VERBOSE=yes TESTS=$recipe HARNESS_JOBS=1") | Out-Null
    }
}
Run-Batch 'candidate-add1-regression' $built['candidate'] @('jom test VERBOSE=yes TESTS="test_evp_pkey_add1" HARNESS_JOBS=1') | Out-Null
if (@($results | Where-Object exitCode -NE 0).Count) { throw 'One or more controls failed. Read results.json; do not infer which source caused the failure from overall job status.' }
