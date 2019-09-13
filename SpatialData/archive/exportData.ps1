param([string]$dbName = "SpatialData.db"
    , [Parameter()][string[]]$TableList = @()
    , [Parameter()][string]$sourceCN = "default")

if($TableList.count -eq 0) {
    [string[]]$TableList = @(
        "gcdefault.dbversion"
        "gcdefault.mapnote"
        "gcdefault.mapnotecategory"
        "gcdefault.version"
        "gcdefault.versionhistory"
        "gcverbase00001.county"
        "gcverbase00001.places"
        "gcverbase00001.railroads"
        "gcverbase00001.streets"
        "gcverbase00001.surfacewater"
        "gcverbase00001.water"
        "gcverbase00001.parcel"
        "gcversa00001.servicearea"
    )
}

[string]$schemaQuery = "SELECT column_name AS ColumnName
        , CASE udt_name 
            WHEN 'int4' THEN 'INTEGER'
            WHEN 'int8' THEN 'INTEGER'
            WHEN 'timestamp' THEN 'datetime'
            WHEN 'bool' THEN 'boolean'
            ELSE 'TEXT'
            END AS ColumnType
        , CASE udt_name
            WHEN 'geometry' THEN 'ST_AsText(' || column_name || ') AS ' || column_name
            END AS Transform
    FROM information_schema.columns
    WHERE table_schema = @schema
        AND table_name = @table
    ORDER BY ordinal_position"

Open-SQLiteConnection -ConnectionName dest -DataSource $dbName

foreach($tbl in $TableList) {
    Write-Verbose "[$tbl] Getting schema"
    $schema = Invoke-SqlQuery -ConnectionName $sourceCN -Query $schemaQuery -Parameters @{schema = $tbl.split(".")[0]; table = $tbl.split(".")[1]} #-Stream

    Write-Verbose "[$tbl] Creating table"
    [string[]]$ColList = $schema | ForEach-Object { "{0} {1}" -f $_.ColumnName, $_.ColumnType }
    [string]$createTable = "DROP TABLE IF EXISTS [$tbl]; CREATE TABLE [$tbl] (" + ($ColList -join ", ") + ")"

    Invoke-SqlUpdate -ConnectionName dest -Query $createTable | Out-Null
    
    Write-Verbose "[$tbl] Copying data"
    [string]$SelectQuery = "SELECT {0} FROM $tbl LIMIT 500" -f (($schema | ForEach-Object { if($_.transform -ne [dbnull]::Value) { $_.Transform } else { $_.ColumnName }}) -join ", ")
    $SelectQuery
    Invoke-SqlBulkCopy -SourceConnectionName $sourceCN -DestinationConnectionName dest -SourceQuery $SelectQuery -DestinationTable $tbl -Notify -BatchSize 25
}

Close-SqlConnection -ConnectionName dest