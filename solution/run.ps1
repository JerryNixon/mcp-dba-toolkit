#requires -Version 7.3
[CmdletBinding()]
param([switch] $Demo)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Get-Command docker -ErrorAction Stop | Out-Null
$sqlName = 'agentic-dba-sql-database'
$dabName = 'agentic-dba-mcp-server'
$endpoint = 'http://127.0.0.1:5678/mcp'

function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Get-DemoContainer([string] $Name) {
    if (@(docker ps -a --filter "name=^/$Name$" --format '{{.Names}}').Count -eq 0) { return $null }
    $container = (docker inspect $Name | ConvertFrom-Json)[0]
    Assert ($container.Config.Labels.'agentic-dba' -eq 'demo') "Container '$Name' is not owned by this demo."
    return $container
}
function Invoke-Sql([string] $Query, [string] $Database = 'McpDbaDemo') {
    $output = docker exec $sqlName /bin/bash -c 'export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"; exec /opt/mssql-tools18/bin/sqlcmd "$@"' `
        sqlcmd -C -S localhost -U sa -d $Database -b -h -1 -W -Q "SET NOCOUNT ON; $Query"
    return ($output -join "`n").Trim()
}

$sql = Get-DemoContainer $sqlName
$dab = Get-DemoContainer $dabName
$composeArguments = @('compose', '--project-directory', $PSScriptRoot, '--file', (Join-Path $PSScriptRoot 'compose.yaml'))
$previousSaPassword = $env:MSSQL_SA_PASSWORD
$previousConnectionString = $env:SQL_CONN_STRING
$saPassword = $null
$connection = $null
$httpClients = [Collections.Generic.List[System.Net.Http.HttpClient]]::new()
try {
    $saPassword = Read-Host 'SQL sa password (use the existing password when reusing demo data)' -AsSecureString
    Assert ($saPassword.Length -gt 0) 'The SQL sa password must not be empty.'
    $env:MSSQL_SA_PASSWORD = [PSCredential]::new('sa', $saPassword).GetNetworkCredential().Password
    $connection = [System.Data.Common.DbConnectionStringBuilder]::new()
    $connection.set_ConnectionString('Server=sql;Database=McpDbaDemo;User Id=sa;Encrypt=True;TrustServerCertificate=True;Application Name=McpDbaDemo;Command Timeout=150')
    $connection['Password'] = $env:MSSQL_SA_PASSWORD
    $env:SQL_CONN_STRING = $connection.ConnectionString

    docker @composeArguments config --quiet
    if ($dab -and $dab.State.Running) { docker @composeArguments stop mcp }
    docker @composeArguments up -d --wait sql
    Invoke-Sql "IF DB_ID(N'McpDbaDemo') IS NULL CREATE DATABASE McpDbaDemo;" -Database master | Out-Null
    docker exec $sqlName /bin/bash -c 'export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"; exec /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -d McpDbaDemo -b -i /demo/database.sql'
    docker @composeArguments up -d --wait mcp

    $healthClient = [Net.Http.HttpClient]::new()
    $httpClients.Add($healthClient)
    $healthClient.Timeout = [TimeSpan]::FromSeconds(3)
    $ready = $false
    $lastHealthError = 'No health response.'
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            $response = $healthClient.GetAsync('http://127.0.0.1:5678/health').GetAwaiter().GetResult()
            try {
                if ($response.IsSuccessStatusCode) {
                    $health = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
                    if ($health.status -eq 'Healthy') { $ready = $true; break }
                }
                $lastHealthError = "Health HTTP status: $([int] $response.StatusCode)."
            }
            finally { $response.Dispose() }
        }
        catch [Net.Http.HttpRequestException] { $lastHealthError = $_.Exception.Message }
        catch [Threading.Tasks.TaskCanceledException] { $lastHealthError = $_.Exception.Message }
        Start-Sleep -Seconds 2
    }
    Assert $ready "DAB did not become healthy: $lastHealthError Inspect docker logs agentic-dba-mcp-server."
    Write-Host 'SQL and DAB deployed. Checking the MCP flow...'

    $script:requestId = 0
    function Send-Rpc([string] $Method, [hashtable] $Parameters, [Net.Http.HttpClient] $Client = $script:main) {
        $body = @{ jsonrpc = '2.0'; id = ++$script:requestId; method = $Method; params = $Parameters } | ConvertTo-Json -Depth 10 -Compress
        $content = [Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
        return $Client.PostAsync($endpoint, $content)
    }
    function Receive-Rpc($Task) {
        $response = $Task.GetAwaiter().GetResult()
        try {
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            Assert $response.IsSuccessStatusCode "MCP HTTP error $([int] $response.StatusCode): $text"
            if ($response.Content.Headers.ContentType.MediaType -eq 'text/event-stream') {
                $messages = @($text -split "`n" | Where-Object { $_ -match '^data:\s*\{' } |
                    ForEach-Object { ($_ -replace '^data:\s*', '') | ConvertFrom-Json -AsHashtable -NoEnumerate })
                $replies = @($messages | Where-Object { $_.ContainsKey('id') })
                Assert ($replies.Count -eq 1) 'Expected one MCP reply in the event stream.'
                $reply = $replies[0]
            }
            else { $reply = $text | ConvertFrom-Json -AsHashtable -NoEnumerate }
            Assert (-not $reply.error) "MCP protocol error: $($reply.error.message)"
            return $reply.result
        }
        finally { $response.Dispose() }
    }
    function New-McpClient {
        $client = [Net.Http.HttpClient]::new()
        $httpClients.Add($client)
        $client.Timeout = [TimeSpan]::FromSeconds(150)
        $client.DefaultRequestHeaders.Add('Accept', 'application/json, text/event-stream')
        $task = Send-Rpc 'initialize' @{
            protocolVersion = '2024-11-05'; capabilities = @{}
            clientInfo = @{ name = 'dba-demo'; version = '1.0' }
        } -Client $client
        $response = $task.GetAwaiter().GetResult()
        if ($response.Headers.Contains('Mcp-Session-Id')) {
            $client.DefaultRequestHeaders.Add('Mcp-Session-Id', @($response.Headers.GetValues('Mcp-Session-Id'))[0])
        }
        $initialized = Receive-Rpc $task
        Assert ($null -ne $initialized.serverInfo) 'MCP initialization failed.'
        $client.DefaultRequestHeaders.Add('MCP-Protocol-Version', $initialized.protocolVersion)
        $content = [Net.Http.StringContent]::new('{"jsonrpc":"2.0","method":"notifications/initialized"}', [Text.Encoding]::UTF8, 'application/json')
        $notification = $client.PostAsync($endpoint, $content).GetAwaiter().GetResult()
        try { Assert $notification.IsSuccessStatusCode 'MCP initialization notification failed.' }
        finally { $notification.Dispose() }
        return $client
    }
    function Call-Tool([string] $Name, [hashtable] $Arguments) {
        return Receive-Rpc (Send-Rpc 'tools/call' @{ name = $Name; arguments = $Arguments })
    }
    function Get-Rows($Result) {
        Assert (-not $Result.isError) "Tool error: $($Result.content.text -join ' ')"
        $texts = @($Result.content | Where-Object type -eq 'text')
        Assert ($texts.Count -eq 1) 'Expected one JSON text result.'
        $payload = $texts[0].text | ConvertFrom-Json -AsHashtable -NoEnumerate
        Assert ($payload -is [Collections.IDictionary] -and $payload.status -eq 'success' -and $payload.value.value -is [array]) "Unexpected result shape: $($texts[0].text)"
        $rows = @($payload.value.value)
        if ($rows.Count) {
            Assert ($rows[0] -is [Collections.IDictionary] -and $rows[0].Contains('observed_at_utc')) "Unexpected row shape: $($texts[0].text)"
        }
        return $rows
    }
    function Get-Active {
        return @(Get-Rows (Call-Tool 'active_requests' @{ top_count = 100; min_elapsed_ms = 0 }))
    }

    $script:main = New-McpClient
    $tools = Receive-Rpc (Send-Rpc 'tools/list' @{})
    $names = @('active_requests', 'blocking_chain', 'session_details', 'kill_session', 'cause_problem')
    Assert ((($tools.tools.name | Sort-Object) -join ',') -eq (($names | Sort-Object) -join ',')) 'Expected exactly five custom tools.'
    Assert ((Call-Tool 'active_requests' @{ top_count = 0 }).isError) 'Invalid diagnostic input must fail.'
    Assert ((Call-Tool 'cause_problem' @{ confirm = $false }).isError) 'Demo must require confirmation.'
    $baseline = [int] (Invoke-Sql 'SELECT counter FROM dba.DemoLock WHERE id=1;')
    $blockerClient = New-McpClient
    $waiterClient = New-McpClient
    $seconds = if ($Demo) { 120 } else { 30 }
    $blockerCall = Send-Rpc 'tools/call' @{ name = 'cause_problem'; arguments = @{ role = 'blocker'; duration_seconds = $seconds; confirm = $true } } -Client $blockerClient
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $blockers = @(Get-Active | Where-Object { $_.database_name -eq 'McpDbaDemo' -and $_.program_name -like 'McpDbaDemo,*' -and $_.command -eq 'WAITFOR' })
        if ($blockers.Count) { break }
        if ($blockerCall.IsCompleted) { Get-Rows (Receive-Rpc $blockerCall) | Out-Null; throw 'Demo blocker completed before a lock was observed.' }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($blockers.Count -eq 1) 'Expected one demo blocker.'
    $blockerId = [int] $blockers[0].session_id
    $waiterCall = Send-Rpc 'tools/call' @{ name = 'cause_problem'; arguments = @{ role = 'waiter'; confirm = $true } } -Client $waiterClient
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $waiters = @(Get-Active | Where-Object { $_.program_name -like 'McpDbaDemo,*' -and $_.blocking_session_id -eq $blockerId -and $_.wait_type -like 'LCK_M_*' })
        if ($waiters.Count) { break }
        if ($waiterCall.IsCompleted) { Get-Rows (Receive-Rpc $waiterCall) | Out-Null; throw 'Demo waiter completed before blocking was observed.' }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert ($waiters.Count -eq 1) 'Expected one lock-blocked demo waiter.'
    $waiterId = [int] $waiters[0].session_id
    $chain = @(Get-Rows (Call-Tool 'blocking_chain' @{}) | Where-Object blocked_session_id -eq $waiterId)
    Assert ($chain.Count -eq 1 -and $chain[0].root_blocker_session_id -eq $blockerId -and -not $chain[0].chain_incomplete) 'Head blocker was not identified.'
    $details = @(Get-Rows (Call-Tool 'session_details' @{ session_id = $blockerId }))
    Assert ($details.Count -eq 1 -and $details[0].program_name -like 'McpDbaDemo,*' -and $details[0].open_transaction_count -gt 0) 'Blocker ownership or transaction evidence is missing.'
    if ($Demo) {
        Write-Host "Demo ready: session $waiterId is blocked by session $blockerId. Ask your agent: Why is my SQL slow?"
        Write-Host 'The blocker rolls back after 120 seconds unless you explicitly approve termination sooner.'
    }
    else {
        $kill = @{ session_id = $blockerId; expected_login_time = $details[0].login_time; confirm = $false }
        Assert ((Call-Tool 'kill_session' $kill).isError) 'Termination must require confirmation.'
        $kill.confirm = $true
        $kill.expected_login_time = '2000-01-01T00:00:00.000'
        Assert ((Call-Tool 'kill_session' $kill).isError) 'Stale session identity must be rejected.'
        $fresh = @(Get-Rows (Call-Tool 'session_details' @{ session_id = $blockerId }))
        $kill.expected_login_time = $fresh[0].login_time
        $killed = @(Get-Rows (Call-Tool 'kill_session' $kill))
        Assert ($killed.Count -eq 1 -and $killed[0].status -eq 'termination_requested') 'Termination request was not acknowledged.'
    }
    $waiter = @(Get-Rows (Receive-Rpc $waiterCall))
    Assert ($waiter.Count -eq 1 -and $waiter[0].outcome -eq 'rolled_back') 'Waiter did not resume and roll back.'
    $blocker = Receive-Rpc $blockerCall
    if (-not $Demo) { Assert $blocker.isError 'Terminated blocker must report an error.' }
    elseif ($blocker.isError) { Write-Host "Blocker error (expected if terminated): $($blocker.content.text -join ' ')" }
    else { Assert (@(Get-Rows $blocker)[0].outcome -eq 'rolled_back') 'Bounded blocker did not roll back.' }
    $remaining = @(Get-Rows (Call-Tool 'blocking_chain' @{}) | Where-Object { $_.blocked_session_id -eq $waiterId -or $_.root_blocker_session_id -eq $blockerId })
    Assert ($remaining.Count -eq 0) 'Demo blocking did not clear.'
    if (-not $Demo) {
        $natural = @(Get-Rows (Call-Tool 'cause_problem' @{ role = 'blocker'; duration_seconds = 5; confirm = $true }))
        Assert ($natural.Count -eq 1 -and $natural[0].outcome -eq 'rolled_back') 'Bounded demo did not roll back naturally.'
    }
    Assert ([int] (Invoke-Sql 'SELECT counter FROM dba.DemoLock WHERE id=1;') -eq $baseline) 'Demo changed its table data.'
    Assert ([int] (Invoke-Sql 'SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process=1 AND database_id=DB_ID() AND open_transaction_count>0;') -eq 0) 'Demo left an open transaction.'
    Write-Host "PASS: five tools; blocking -> head blocker -> session details -> rollback and cleanup. MCP ready at $endpoint"
}
finally {
    foreach ($client in $httpClients) { $client.Dispose() }
    if ($saPassword) { $saPassword.Dispose() }
    if ($connection) { $connection.Clear() }
    [Environment]::SetEnvironmentVariable('MSSQL_SA_PASSWORD', $previousSaPassword, 'Process')
    [Environment]::SetEnvironmentVariable('SQL_CONN_STRING', $previousConnectionString, 'Process')
}
