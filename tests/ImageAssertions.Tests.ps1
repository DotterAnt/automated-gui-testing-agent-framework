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
    $reference=Join-Path $root 'reference.png';$rotated=Join-Path $root 'rotated.jpg';$screen=Join-Path $root 'screen.png';$crop=Join-Path $root 'crop.png'
    $fixture=[Drawing.Bitmap]::new(80,48)
    try {
        for ($y=0;$y -lt 48;$y++) {for ($x=0;$x -lt 80;$x++) {$fixture.SetPixel($x,$y,[Drawing.Color]::FromArgb([int]($x*3),[int]($y*5),[int](($x+$y)%48*5)))}}
        $fixture.Save($reference,[Drawing.Imaging.ImageFormat]::Png)
        $fixture.RotateFlip([Drawing.RotateFlipType]::Rotate90FlipNone)
        $fixture.Save($rotated,[Drawing.Imaging.ImageFormat]::Jpeg)
        $snapshot=[Drawing.Bitmap]::new(90,100);$graphics=[Drawing.Graphics]::FromImage($snapshot)
        try {$graphics.Clear([Drawing.Color]::Black);$graphics.DrawImageUnscaled($fixture,20,10);$snapshot.Save($screen,[Drawing.Imaging.ImageFormat]::Png)} finally {$graphics.Dispose();$snapshot.Dispose()}
        $cropped=$fixture.Clone([Drawing.Rectangle]::new(0,16,48,64),[Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $stretched=[Drawing.Bitmap]::new(48,80);$graphics=[Drawing.Graphics]::FromImage($stretched)
            try {$graphics.DrawImage($cropped,[Drawing.Rectangle]::new(0,0,48,80));$stretched.Save($crop,[Drawing.Imaging.ImageFormat]::Png)} finally {$graphics.Dispose();$stretched.Dispose()}
        } finally {$cropped.Dispose()}
    } finally {$fixture.Dispose()}
    $hash=(Get-FileHash $reference).Hash
    $info=Assert-ImageRegionMatches $rotated -ReferencePath $reference -ReferenceRotation 90 -PassThru
    Check ($info.contentSource -eq 'DecodedImagePixels' -and $info.meanError -lt 8 -and $info.maxTileError -lt 24) 'Actual compressed rotated content failed measured comparison.'
    $held=[IO.File]::Open($screen,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)
    try {$info=Assert-ImageRegionMatches $screen -ReferencePath $reference -ReferenceRotation 90 -Region @{x=20;y=10;width=48;height=80} -MaxMeanError 0 -MaxTileError 0 -PassThru} finally {$held.Dispose()}
    Check ($info.meanError -eq 0 -and (Get-FileHash $reference).Hash -eq $hash) 'Observed screenshot region changed content or modified the source.'
    Reject {Assert-ImageRegionMatches $reference -ReferencePath $reference -ReferenceRotation 90} 'A no-op passed requested rotation.'
    Reject {Assert-ImageRegionMatches $rotated -ReferencePath $reference -ReferenceRotation 270} 'Wrong rotation direction passed the same dimensions.'
    Reject {Assert-ImageRegionMatches $crop -ReferencePath $reference -ReferenceRotation 90} 'Cropped/stretched content passed matching dimensions.'
    Reject {Assert-ImageRegionMatches $screen -ReferencePath $reference -ReferenceRotation 90 -Region @{x=80;y=10;width=48;height=80}} 'Out-of-bounds screenshot region was accepted.'
    Reject {Assert-ImageRegionMatches $screen -ReferencePath $reference -Region @{x=0;y=0;width=0;height=10}} 'Empty comparison region passed.'
    Reject {Assert-ImageRegionMatches $rotated -ReferencePath $reference -ReferenceRotation 90 -MaxPixels 3000} 'Image comparison ignored its decoded pixel bound.'
    Reject {Assert-ImageRegionMatches $rotated -ReferencePath $reference -ReferenceRotation 90 -MaxBytes 8} 'Image comparison ignored its byte bound.'
    $help=Get-AGTARuntimeHelp Assert-ImageRegionMatches
    Check ($help.available -and $help.note -match 'approximate content comparison') 'Comparison limits were absent from targeted help.'
    "Image assertion checks: $script:checks passed"
} finally {
    $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'agta-image-fixture-*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
