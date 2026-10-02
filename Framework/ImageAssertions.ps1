function Assert-ImageRegionMatches {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$ReferencePath,
        [object]$Region,
        [ValidateSet(0,90,180,270)] [int]$ReferenceRotation=0,
        [ValidateRange(0,255)] [double]$MaxMeanError=8,
        [ValidateRange(0,255)] [double]$MaxTileError=24,
        [ValidateRange(0,0.1)] [double]$AspectTolerance=0.02,
        [ValidateRange(1,16777216)] [int]$MaxPixels=16777216,
        [ValidateRange(1,67108864)] [int]$MaxBytes=16777216,
        [ValidateRange(0,60000)] [int]$TimeoutMs=2000,
        [string]$Message='Actual image region must preserve the reference content and orientation.',
        [switch]$PassThru)
    Add-Type -AssemblyName System.Drawing
    if (-not ('AGTAImagePixels' -as [type])) {Add-Type -Path (Join-Path $PSScriptRoot 'ImagePixels.cs')}
    $resources=New-Object 'Collections.Generic.List[IDisposable]'
    $bitmaps=@();$locks=@();$images=@();$watch=[Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($file in @($Path,$ReferencePath)) {
            do {
                try {$stream=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite);break}
                catch [IO.IOException] {
                    if ($watch.ElapsedMilliseconds -ge $TimeoutMs) {throw}
                    Start-Sleep -Milliseconds ([int][Math]::Max(1,[Math]::Min(100,$TimeoutMs-$watch.ElapsedMilliseconds)))
                }
            } while ($true)
            $resources.Add($stream)
            if ($stream.Length -gt $MaxBytes) {throw 'Image exceeds MaxBytes.'}
            $image=[Drawing.Image]::FromStream($stream,$false,$false);$resources.Add($image)
            if ([long]$image.Width*$image.Height -gt $MaxPixels) {throw 'Decoded image exceeds MaxPixels.'}
            $images+=,$image
        }
        if ($ReferenceRotation) {
            # Transform only a decoded reference in memory. Never create or
            # change an expected artifact, and never rotate the actual output.
            $images[1].RotateFlip([Drawing.RotateFlipType]::("Rotate"+$ReferenceRotation+'FlipNone'))
        }
        $rectangle=[Drawing.Rectangle]::new(0,0,$images[0].Width,$images[0].Height)
        if ($null -ne $Region) {
            foreach ($key in @('x','y','width','height')) {
                if ($null -eq $Region.$key -or [string]$Region.$key -notmatch '^\d+$' -or [decimal]$Region.$key -gt [int]::MaxValue) {throw 'Region needs nonnegative integer x,y,width,height in actual image pixels.'}
            }
            if ([long]$Region.width -lt 1 -or [long]$Region.height -lt 1 -or
                [long]$Region.x+[long]$Region.width -gt $images[0].Width -or [long]$Region.y+[long]$Region.height -gt $images[0].Height) {throw 'Region must be nonempty and entirely inside the actual image.'}
            $rectangle=[Drawing.Rectangle]::new([int]$Region.x,[int]$Region.y,[int]$Region.width,[int]$Region.height)
        }
        $aspectError=[Math]::Abs(($rectangle.Width/[double]$rectangle.Height)/($images[1].Width/[double]$images[1].Height)-1)
        $regionImage=([Drawing.Bitmap]$images[0]).Clone($rectangle,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $resources.Add($regionImage)
        $comparisonImages=@($regionImage,$images[1])
        for ($i=0;$i -lt 2;$i++) {
            $bitmap=[Drawing.Bitmap]::new(128,128,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $resources.Add($bitmap);$bitmaps+=,$bitmap
            $graphics=[Drawing.Graphics]::FromImage($bitmap)
            $attributes=[Drawing.Imaging.ImageAttributes]::new()
            try {
                $graphics.Clear([Drawing.Color]::White)
                $graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $attributes.SetWrapMode([Drawing.Drawing2D.WrapMode]::TileFlipXY)
                $source=[Drawing.Rectangle]::new(0,0,$comparisonImages[$i].Width,$comparisonImages[$i].Height)
                $graphics.DrawImage($comparisonImages[$i],[Drawing.Rectangle]::new(0,0,128,128),$source.X,$source.Y,$source.Width,$source.Height,[Drawing.GraphicsUnit]::Pixel,$attributes)
            } finally {$attributes.Dispose();$graphics.Dispose()}
            $locks+=,$bitmap.LockBits([Drawing.Rectangle]::new(0,0,128,128),[Drawing.Imaging.ImageLockMode]::ReadOnly,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
        }
        $comparison=[AGTAImagePixels]::Compare($locks[0].Scan0,$locks[0].Stride,$locks[1].Scan0,$locks[1].Stride,128)
        $info=[pscustomobject]@{path=$Path;referencePath=$ReferencePath;referenceRotation=$ReferenceRotation;
            region=@{x=$rectangle.X;y=$rectangle.Y;width=$rectangle.Width;height=$rectangle.Height};
            aspectError=$aspectError;meanError=$comparison.meanError;maxTileError=$comparison.maxTileError;contentSource='DecodedImagePixels'}
    } catch {Assert-ExpectedResult -Condition $false -Message "$Message $($_.Exception.Message)";return}
    finally {
        for ($i=0;$i -lt $locks.Count;$i++) {$bitmaps[$i].UnlockBits($locks[$i])}
        for ($i=$resources.Count-1;$i -ge 0;$i--) {$resources[$i].Dispose()}
    }
    Assert-ExpectedResult -Condition ($info.aspectError -le $AspectTolerance -and $info.meanError -le $MaxMeanError -and $info.maxTileError -le $MaxTileError) -Message (
        "$Message Aspect error $($info.aspectError) (limit $AspectTolerance), mean RGB error $($info.meanError) (limit $MaxMeanError), worst tile $($info.maxTileError) (limit $MaxTileError).")
    if ($PassThru) {return $info}
}

function Assert-ImageContainsColors {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [object[]]$ColorRanges,
        [ValidateSet('Png','Jpeg','Bmp','Gif','Tiff')] [string]$ExpectedFormat,
        [ValidateRange(1,16777216)] [int]$MinimumPixels=1,
        [ValidateRange(1,16777216)] [int]$MaxPixels=16777216,
        [ValidateRange(1,67108864)] [int]$MaxBytes=16777216,
        [ValidateRange(0,60000)] [int]$TimeoutMs=2000,
        [string]$Message='Actual image must contain each expected color range.',
        [switch]$PassThru)
    if (-not $ColorRanges.Count -or $ColorRanges.Count -gt 32) {throw 'ColorRanges needs 1..32 objects with unique name and RGB bounds.'}
    $bounds=New-Object 'Collections.Generic.List[int]';$names=@()
    foreach ($color in $ColorRanges) {
        $name=[string]$color.name
        if ([string]::IsNullOrWhiteSpace($name) -or $name -in $names) {throw 'ColorRanges names must be nonempty and unique.'}
        $names+=,$name
        foreach ($channel in @('r','g','b')) {
            $lo=$color.($channel+'Min');$hi=$color.($channel+'Max')
            if ($null -eq $lo) {$lo=0};if ($null -eq $hi) {$hi=255}
            if ($lo -notmatch '^\d+$' -or $hi -notmatch '^\d+$' -or [int]$lo -gt [int]$hi -or [int]$hi -gt 255) {throw 'Color bounds must be integers in 0..255 with Min <= Max.'}
            $bounds.Add([int]$lo);$bounds.Add([int]$hi)
        }
        $alpha=$color.aMin;if ($null -eq $alpha) {$alpha=1}
        if ($alpha -notmatch '^\d+$' -or [int]$alpha -gt 255) {throw 'aMin must be 0..255.'}
        $bounds.Add([int]$alpha)
    }
    Add-Type -AssemblyName System.Drawing
    if (-not ('AGTAImagePixels' -as [type])) {Add-Type -Path (Join-Path $PSScriptRoot 'ImagePixels.cs')}
    $watch=[Diagnostics.Stopwatch]::StartNew();$stream=$null;$image=$null;$bitmap=$null;$locked=$null
    try {
        do {
            try {$stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite);break}
            catch [IO.IOException] {
                if ($watch.ElapsedMilliseconds -ge $TimeoutMs) {throw}
                Start-Sleep -Milliseconds ([int][Math]::Max(1,[Math]::Min(100,$TimeoutMs-$watch.ElapsedMilliseconds)))
            }
        } while ($true)
        if ($stream.Length -gt $MaxBytes) {throw 'Image exceeds MaxBytes.'}
        if ($ExpectedFormat) {
            $header=New-Object byte[] 8;$read=$stream.Read($header,0,8);$stream.Position=0
            $prefix=switch ($ExpectedFormat) {
                Png {@(137,80,78,71,13,10,26,10)};Jpeg {@(255,216,255)};Bmp {@(66,77)};Gif {@(71,73,70,56)}
                Tiff {if ($header[0] -eq 73) {@(73,73,42,0)} else {@(77,77,0,42)}}
            }
            $matches=$read -ge $prefix.Count
            for ($i=0;$i -lt $prefix.Count -and $matches;$i++) {$matches=$header[$i] -eq $prefix[$i]}
            if (-not $matches) {throw "Expected $ExpectedFormat signature; filename extension does not determine saved format. Inspect the GUI's selected file type."}
        }
        $image=[Drawing.Image]::FromStream($stream,$false,$false)
        if ([long]$image.Width*$image.Height -gt $MaxPixels) {throw 'Decoded image exceeds MaxPixels.'}
        $actualFormat=@('Png','Jpeg','Bmp','Gif','Tiff') | Where-Object {([Drawing.Imaging.ImageFormat]::$_).Guid -eq $image.RawFormat.Guid} | Select-Object -First 1
        if ($ExpectedFormat -and $actualFormat -ne $ExpectedFormat) {throw "Decoded image format is $actualFormat, expected $ExpectedFormat."}
        $bitmap=[Drawing.Bitmap]::new($image)
        $rectangle=[Drawing.Rectangle]::new(0,0,$bitmap.Width,$bitmap.Height)
        $locked=$bitmap.LockBits($rectangle,[Drawing.Imaging.ImageLockMode]::ReadOnly,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $counts=[AGTAImagePixels]::Count($locked.Scan0,$locked.Stride,$bitmap.Width,$bitmap.Height,$bounds.ToArray())
        $colorCounts=[ordered]@{}
        for ($i=0;$i -lt $names.Count;$i++) {$colorCounts[$names[$i]]=$counts[$i]}
        $info=[pscustomobject]@{path=$Path;format=$actualFormat;width=$image.Width;height=$image.Height;colorCounts=$colorCounts;contentSource='DecodedImagePixels'}
    } catch {Assert-ExpectedResult -Condition $false -Message "$Message $($_.Exception.Message)";return}
    finally {
        if ($locked) {$bitmap.UnlockBits($locked)}
        if ($bitmap) {$bitmap.Dispose()};if ($image) {$image.Dispose()};if ($stream) {$stream.Dispose()}
    }
    if ($ExpectedFormat) {Assert-ExpectedResult -Condition ($info.format -eq $ExpectedFormat) -Message "$Message Actual format must be $ExpectedFormat."}
    foreach ($name in $names) {Assert-ExpectedResult -Condition ($info.colorCounts[$name] -ge $MinimumPixels) -Message "$Message Color '$name' needs $MinimumPixels pixels; found $($info.colorCounts[$name])."}
    if ($PassThru) {return $info}
}
