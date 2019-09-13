Open-GCPSqlConnection Postgres

$data = Invoke-SqlQuery "SELECT
    n.nspname AS schema
    , t.relname as table
    , i.relname as index
    , a.attname as column
FROM pg_namespace AS n
    INNER JOIN pg_class i
        ON n.oid = i.relnamespace
    INNER JOIN pg_index AS ix
        ON i.oid = ix.indexrelid
    INNER JOIN pg_class AS t
        ON ix.indrelid = t.oid
    INNER JOIN pg_attribute AS a
        ON t.oid = a.attrelid
            AND a.attnum = ANY(ix.indkey)
WHERE t.relkind = 'r'
    AND t.relname not like '%\_%'
    AND i.relname not like 'pk\_%'
    AND i.relname not like '%\_pkey'
    AND n.nspname IN ('gcdefault','gcverbase00001','gcversa00001')
order by
    t.relname,
    i.relname;" -Stream

$data |
    Select-Object -Unique Schema, Index |
    ForEach-Object { 
        Invoke-SqlUpdate -Query ("DROP INDEX {0}.{1};" -f $_.schema, $_.index)
    } | Out-Null

Initialize-GCPPostgresDb -cn default

Optimize-GCPPostgres -cn default

Close-SqlConnection