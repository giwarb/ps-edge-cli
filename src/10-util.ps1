function ConvertTo-PseJson {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Object
    )

    ConvertTo-Json -InputObject $Object -Depth 12 -Compress
}

function Get-PseFreePort {
    $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
    try {
        $listener.Start()
        $endpoint = [System.Net.IPEndPoint]$listener.LocalEndpoint
        return [int]$endpoint.Port
    } finally {
        $listener.Stop()
    }
}
