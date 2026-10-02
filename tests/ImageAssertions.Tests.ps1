param()
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'Framework\GeneratedScriptRuntime.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('agta-image-fixture-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root);$script:checks=0
function Check($value,$message) {if (-not $value) {throw $message};$script:checks++}
function Reject([scriptblock]$body,$message) {$caught=$false;try {& $body | Out-Null} catch {$caught=$true};Check $caught $message}
try {
    Add-Type -AssemblyName System.Drawing
    $path=Join-Path $root 'fixture.png'
    $bitmap=[Drawing.Bitmap]::new(3,2)
    try {
        $bitmap.SetPixel(0,0,[Drawing.Color]::Red);$bitmap.SetPixel(1,0,[Drawing.Color]::Red)
        $bitmap.SetPixel(2,0,[Drawing.Color]::Blue);$bitmap.SetPixel(0,1,[Drawing.Color]::FromArgb(0,255,0,0))
        $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)
    } finally {$bitmap.Dispose()}
    $colors=@(@{name='red';rMin=180;gMax=100;bMax=100},@{name='blue';rMax=120;gMax=160;bMin=150})
    $held=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)
    try {$info=Assert-ImageContainsColors $path -ColorRanges $colors -ExpectedFormat Png -PassThru} finally {$held.Dispose()}
    Check ($info.width -eq 3 -and $info.height -eq 2 -and $info.format -eq 'Png' -and $info.colorCounts.red -eq 2 -and $info.colorCounts.blue -eq 1) 'Shared image read lost actual colors, alpha filtering or dimensions.'
    Reject {Assert-ImageContainsColors $path -ColorRanges $colors -MinimumPixels 2} 'Insufficient color pixels passed.'
    Reject {Assert-ImageContainsColors $path -ColorRanges $colors -ExpectedFormat Jpeg} 'A filename/decoder substituted for actual image format.'
    Reject {Assert-ImageContainsColors $path -ColorRanges $colors -MaxPixels 5} 'Decoded pixel bound was ignored.'
    Reject {Assert-ImageContainsColors $path -ColorRanges $colors -MaxBytes 8} 'File byte bound was ignored.'
    Reject {Assert-ImageContainsColors $path -ColorRanges @(@{name='bad';rMin=300})} 'Invalid color range was accepted.'
    $wrong=Join-Path $root 'misnamed.png';[IO.File]::WriteAllBytes($wrong,[Text.Encoding]::ASCII.GetBytes('0000ftypmif1'))
    Reject {Assert-ImageContainsColors $wrong -ColorRanges $colors -ExpectedFormat Png} 'Misnamed non-PNG output passed.'
    $help=Get-AGTARuntimeHelp Assert-ImageContainsColors
    Check ($help.available -and $help.note -match 'compiled pixel scan') 'Image helper was not published in targeted help.'
    "Image assertion checks: $script:checks passed"
} finally {
    $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'agta-image-fixture-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
