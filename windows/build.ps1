# Builds Churchfront Video for Windows into windows\dist: ChurchfrontVideo.exe and
# cuevideo-mcp.exe side by side (each one file, .NET included, nothing to install),
# and a zip of the two for handing out.
#
#   .\build.ps1            build
#   .\build.ps1 -Test      run the smoke test against the fake switcher first
param([switch]$Test, [string]$Out = "$PSScriptRoot\dist")
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if ($Test) {
    dotnet build tools\FakeDevices -nologo -v q
    if ($LASTEXITCODE) { throw "FakeDevices didn't build" }
    dotnet run --project tests\Smoke -nologo
    if ($LASTEXITCODE) { throw "Smoke test failed" }
}

if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
$common = @('-c', 'Release', '-r', 'win-x64', '--self-contained', '-p:PublishSingleFile=true', '-p:DebugType=none', '-p:EnableCompressionInSingleFile=true', '-nologo', '-o', $Out)
dotnet publish src\ChurchfrontVideo @common -p:IncludeNativeLibrariesForSelfExtract=true
if ($LASTEXITCODE) { throw "ChurchfrontVideo didn't build" }
dotnet publish src\CueVideoMcp @common
if ($LASTEXITCODE) { throw "cuevideo-mcp didn't build" }

$version = ([xml](Get-Content Directory.Build.props)).Project.PropertyGroup.Version
$zip = Join-Path $Out "ChurchfrontVideo-$version-windows-x64.zip"
Compress-Archive -Path (Join-Path $Out 'ChurchfrontVideo.exe'), (Join-Path $Out 'cuevideo-mcp.exe') -DestinationPath $zip
Get-ChildItem $Out | Format-Table Name, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
