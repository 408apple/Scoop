# Description: Functions for interacting with the Scoop database cache

<#
.SYNOPSIS
    Get SQLite .NET driver
.DESCRIPTION
    Download and extract the SQLite .NET driver from NuGet.
.PARAMETER Version
    System.String
    The version of the SQLite .NET driver to download.
.INPUTS
    None
.OUTPUTS
    System.Boolean
    True if the SQLite .NET driver was successfully downloaded and extracted, otherwise false.
#>
function Get-SQLite {
    param (
        [string]$Version = '1.0.118'
    )
    # Install SQLite
    try {
        Write-Host "Downloading SQLite $Version..." -ForegroundColor DarkYellow
        $sqlitePkgPath = "$env:TEMP\sqlite.nupkg"
        $sqliteTempPath = "$env:TEMP\sqlite"
        $sqlitePath = "$PSScriptRoot\..\supporting\sqlite"
        Invoke-WebRequest -Uri "https://api.nuget.org/v3-flatcontainer/stub.system.data.sqlite.core.netframework/$version/stub.system.data.sqlite.core.netframework.$version.nupkg" -OutFile $sqlitePkgPath
        Write-Host "Extracting SQLite $Version..." -ForegroundColor DarkYellow -NoNewline
        Expand-Archive -Path $sqlitePkgPath -DestinationPath $sqliteTempPath -Force
        New-Item -Path $sqlitePath -ItemType Directory -Force | Out-Null
        Move-Item -Path "$sqliteTempPath\build\net45\*" -Destination $sqlitePath -Exclude '*.targets' -Force
        Move-Item -Path "$sqliteTempPath\lib\net45\System.Data.SQLite.dll" -Destination $sqlitePath -Force
        Remove-Item -Path $sqlitePkgPath, $sqliteTempPath -Recurse -Force
        Write-Host ' Done' -ForegroundColor DarkYellow
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
    Close a SQLite database.
.DESCRIPTION
    Close a SQLite database connection.
.PARAMETER InputObject
    System.Data.SQLite.SQLiteConnection
    The SQLite database connection to close.
.INPUTS
    System.Data.SQLite.SQLiteConnection
.OUTPUTS
    None
#>
function Close-ScoopDB {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [System.Data.SQLite.SQLiteConnection]
        $InputObject
    )
    process {
        $InputObject.Dispose()
    }
}

<#
.SYNOPSIS
    Create a new SQLite database.
.DESCRIPTION
    Create a new SQLite database connection and create the necessary tables.
.PARAMETER PassThru
    System.Management.Automation.SwitchParameter
    Return the SQLite database connection.
.INPUTS
    None
.OUTPUTS
    None
    Default

    System.Data.SQLite.SQLiteConnection
    The SQLite database connection if **PassThru** is used.
#>
function New-ScoopDB ([switch]$PassThru) {
    # Load System.Data.SQLite
    if (!('System.Data.SQLite.SQLiteConnection' -as [Type])) {
        try {
            if (!(Test-Path -Path "$PSScriptRoot\..\supporting\sqlite\System.Data.SQLite.dll")) {
                Get-SQLite | Out-Null
            }
            Add-Type -Path "$PSScriptRoot\..\supporting\sqlite\System.Data.SQLite.dll"
        } catch {
            throw "Scoop's Database cache requires the ADO.NET driver:`n`thttp://system.data.sqlite.org/index.html/doc/trunk/www/downloads.wiki"
        }
    }
    $dbPath = Join-Path $scoopdir 'scoop.db'
    $db = New-Object -TypeName System.Data.SQLite.SQLiteConnection
    $db.ConnectionString = "Data Source=$dbPath"
    $db.ParseViaFramework = $true # Allow UNC path
    $db.Open()
    $tableCommand = $db.CreateCommand()
    $tableCommand.CommandText = "CREATE TABLE IF NOT EXISTS 'app' (
        name TEXT NOT NULL COLLATE NOCASE,
        description TEXT NOT NULL,
        version TEXT NOT NULL,
        bucket VARCHAR NOT NULL,
        manifest JSON NOT NULL,
        binary TEXT,
        shortcut TEXT,
        dependency TEXT,
        suggest TEXT,
        PRIMARY KEY (name, version, bucket)
    )"
    $tableCommand.ExecuteNonQuery() | Out-Null
    $tableCommand.Dispose()
    if ($PassThru) {
        return $db
    } else {
        $db.Dispose()
    }
}

<#
.SYNOPSIS
    Set Scoop database item(s).
.DESCRIPTION
    Insert or replace Scoop database item(s) into the database.
.PARAMETER InputObject
    System.Object[]
    The database item(s) to insert or replace.
.INPUTS
    System.Object[]
.OUTPUTS
    None
#>
function Set-ScoopDBItem {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [psobject[]]
        $InputObject
    )

    begin {
        $db = New-ScoopDB -PassThru
        $dbTrans = $db.BeginTransaction()
        # TODO Support [hashtable]$InputObject
        $colName = @($InputObject | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
        $dbQuery = "INSERT OR REPLACE INTO app ($($colName -join ', ')) VALUES ($('@' + ($colName -join ', @')))"
        $dbCommand = $db.CreateCommand()
        $dbCommand.CommandText = $dbQuery
    }
    process {
        foreach ($item in $InputObject) {
            $item.PSObject.Properties | ForEach-Object {
                $dbCommand.Parameters.AddWithValue("@$($_.Name)", $_.Value) | Out-Null
            }
            $dbCommand.ExecuteNonQuery() | Out-Null
        }
    }
    end {
        try {
            $dbTrans.Commit()
        } catch {
            $dbTrans.Rollback()
            throw $_
        } finally {
            $db.Dispose()
        }
    }
}

<#
.SYNOPSIS
    Set Scoop app database item(s).
.DESCRIPTION
    Insert or replace Scoop app(s) into the database.
.PARAMETER Path
    System.String
    The path to the bucket.
.PARAMETER CommitHash
    System.String
    The commit hash to compare with the HEAD.
.INPUTS
    None
.OUTPUTS
    None
#>
function Set-ScoopDB {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, ValueFromPipeline)]
        [string[]]
        $Path
    )

    begin {
        $list = [System.Collections.Generic.List[PSCustomObject]]::new()
        $arch = Get-DefaultArchitecture
    }
    process {
        if ($Path.Count -eq 0) {
            $bucketPath = Get-LocalBucket | ForEach-Object { Find-BucketDirectory $_ }
            $Path = (Get-ChildItem $bucketPath -Filter '*.json' -Recurse).FullName
        }
        $Path | ForEach-Object {
            $manifestRaw = [System.IO.File]::ReadAllText($_)
            $manifest = ConvertFrom-Json $manifestRaw -ErrorAction SilentlyContinue
            if ($null -ne $manifest.version) {
                $list.Add([pscustomobject]@{
                        name        = $($_ -replace '.*[\\/]([^\\/]+)\.json$', '$1')
                        description = if ($manifest.description) { $manifest.description } else { '' }
                        version     = $manifest.version
                        bucket      = $($_ -replace '.*buckets[\\/]([^\\/]+)(?:[\\/].*)', '$1')
                        manifest    = $manifestRaw
                        binary      = $(
                            $result = @()
                            @(arch_specific 'bin' $manifest $arch) | ForEach-Object {
                                if ($_ -is [System.Array]) {
                                    $result += "$($_[1]).$($_[0].Split('.')[-1])"
                                } else {
                                    $result += $_
                                }
                            }
                            $result -replace '.*?([^\\/]+)?(\.(exe|bat|cmd|ps1|jar|py))$', '$1' -join ' | '
                        )
                        shortcut    = $(
                            $result = @()
                            @(arch_specific 'shortcuts' $manifest $arch) | ForEach-Object {
                                $result += $_[1]
                            }
                            $result -replace '.*?([^\\/]+$)', '$1' -join ' | '
                        )
                        dependency  = $manifest.depends -join ' | '
                        suggest     = $(
                            $suggest_output = @()
                            $manifest.suggest.PSObject.Properties | ForEach-Object {
                                $suggest_output += $_.Value -join ' | '
                            }
                            $suggest_output -join ' | '
                        )
                    })
            }
        }
    }
    end {
        if ($list.Count -ne 0) {
            Set-ScoopDBItem $list
        }
    }
}

<#
.SYNOPSIS
    Select Scoop database item(s).
.DESCRIPTION
    Select Scoop database item(s) from the database.
    The pattern is matched against the name, binaries, and shortcuts columns for apps.
.PARAMETER Pattern
    System.String
    The pattern to search for. If is an empty string, all items will be returned.
.INPUTS
    System.String
.OUTPUTS
    System.Data.DataTable
    The selected database item(s).
#>
function Select-ScoopDBItem {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]
        $Pattern,
        [Parameter(Mandatory, Position = 1)]
        [string[]]
        $From
    )

    begin {
        $db = New-ScoopDB -PassThru
        $dbAdapter = New-Object -TypeName System.Data.SQLite.SQLiteDataAdapter
        $result = New-Object System.Data.DataTable
        $dbQuery = "SELECT * FROM app WHERE $(($From -join ' LIKE @Pattern OR ') + ' LIKE @Pattern')"
        $dbQuery = "SELECT * FROM ($($dbQuery + ' ORDER BY version DESC')) GROUP BY name, bucket"
        $dbCommand = $db.CreateCommand()
        $dbCommand.CommandText = $dbQuery
        $dbCommand.CommandType = [System.Data.CommandType]::Text
    }
    process {
        $dbCommand.Parameters.AddWithValue('@Pattern', $(if ($Pattern -eq '') { '%' } else { '%' + $Pattern + '%' })) | Out-Null
        $dbAdapter.SelectCommand = $dbCommand
        [void]$dbAdapter.Fill($result)
    }
    end {
        $db.Dispose()
        return $result
    }
}

<#
.SYNOPSIS
    Get Scoop database item.
.DESCRIPTION
    Get Scoop database item from the database.
.PARAMETER Name
    System.String
    The name of the item to get.
.PARAMETER Bucket
    System.String
    The bucket of the item to get.
.PARAMETER Version
    System.String
    The version of the item to get. If not provided, the latest version will be returned.
.INPUTS
    System.String
.OUTPUTS
    System.Data.DataTable
    The selected database item.
#>
function Get-ScoopDBItem {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [string]
        $Name,
        [Parameter(Mandatory, Position = 1)]
        [string]
        $Bucket,
        [Parameter(Position = 2)]
        [string]
        $Version
    )

    begin {
        $db = New-ScoopDB -PassThru
        $dbAdapter = New-Object -TypeName System.Data.SQLite.SQLiteDataAdapter
        $result = New-Object System.Data.DataTable
        $dbQuery = 'SELECT * FROM app WHERE name = @Name AND bucket = @Bucket'
        if ($Version) {
            $dbQuery += ' AND version = @Version'
        } else {
            $dbQuery += ' ORDER BY version DESC LIMIT 1'
        }
        $dbCommand = $db.CreateCommand()
        $dbCommand.CommandText = $dbQuery
        $dbCommand.CommandType = [System.Data.CommandType]::Text
    }
    process {
        $dbCommand.Parameters.AddWithValue('@Name', $Name) | Out-Null
        $dbCommand.Parameters.AddWithValue('@Bucket', $Bucket) | Out-Null
        $dbCommand.Parameters.AddWithValue('@Version', $Version) | Out-Null
        $dbAdapter.SelectCommand = $dbCommand
        [void]$dbAdapter.Fill($result)
    }
    end {
        $db.Dispose()
        return $result
    }
}
