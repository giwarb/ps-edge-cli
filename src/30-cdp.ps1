function Invoke-PseHttpJson {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Method = 'GET'
    )

    $uri = "http://127.0.0.1:$Port$Path"
    $request = [System.Net.WebRequest]::Create($uri)
    $request.Method = $Method
    $request.KeepAlive = $false
    $request.Timeout = 5000

    $response = $null
    $stream = $null
    $reader = $null
    try {
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $content = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($content)) {
            return $null
        }
        return $content | ConvertFrom-Json
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        } elseif ($null -ne $stream) {
            $stream.Dispose()
        }
        if ($null -ne $response) {
            $response.Dispose()
        }
    }
}

function Get-PseTargets {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $parsed = Invoke-PseHttpJson -Port $Port -Path '/json/list'
    return @($parsed | ForEach-Object { $_ } | Where-Object { $_.type -eq 'page' })
}

function Connect-PseCdp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebSocketUrl
    )

    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $cts = [System.Threading.CancellationTokenSource]::new()
    try {
        $cts.CancelAfter(30000)
        [void]$socket.ConnectAsync([Uri]$WebSocketUrl, $cts.Token).GetAwaiter().GetResult()
    } finally {
        $cts.Dispose()
    }

    [pscustomobject]@{
        Socket = $socket
        NextId = 1
        Events = New-Object System.Collections.ArrayList
    }
}

function Receive-PseCdpMessage {
    param(
        [Parameter(Mandatory = $true)]
        $Conn,

        [int]$TimeoutSec = 30
    )

    $buffer = New-Object byte[] 65536
    $segment = [System.ArraySegment[byte]]::new($buffer)
    $stream = New-Object System.IO.MemoryStream
    $cts = [System.Threading.CancellationTokenSource]::new()

    try {
        $cts.CancelAfter([int]($TimeoutSec * 1000))

        do {
            try {
                $result = $Conn.Socket.ReceiveAsync($segment, $cts.Token).GetAwaiter().GetResult()
            } catch [System.OperationCanceledException] {
                throw "Timed out after $TimeoutSec seconds waiting for a CDP message."
            } catch {
                if ($_.Exception.InnerException -is [System.OperationCanceledException]) {
                    throw "Timed out after $TimeoutSec seconds waiting for a CDP message."
                }
                throw
            }

            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                throw 'CDP WebSocket closed while waiting for a message.'
            }

            if ($result.Count -gt 0) {
                $stream.Write($buffer, 0, $result.Count)
            }
        } while (-not $result.EndOfMessage)

        $json = [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
        if ([string]::IsNullOrWhiteSpace($json)) {
            return $null
        }
        return $json | ConvertFrom-Json
    } finally {
        $stream.Dispose()
        $cts.Dispose()
    }
}

function Send-PseCdp {
    param(
        [Parameter(Mandatory = $true)]
        $Conn,

        [Parameter(Mandatory = $true)]
        [string]$Method,

        [hashtable]$Params,

        [int]$TimeoutSec = 30
    )

    $id = [int]$Conn.NextId
    $Conn.NextId = $id + 1

    $message = @{
        id = $id
        method = $Method
    }
    if ($PSBoundParameters.ContainsKey('Params')) {
        $message.params = $Params
    }

    $json = ConvertTo-PseJson $message
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $segment = [System.ArraySegment[byte]]::new($bytes)
    $cts = [System.Threading.CancellationTokenSource]::new()

    try {
        $cts.CancelAfter([int]($TimeoutSec * 1000))
        [void]$Conn.Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()
    } catch [System.OperationCanceledException] {
        throw "Timed out after $TimeoutSec seconds sending CDP method $Method."
    } catch {
        if ($_.Exception.InnerException -is [System.OperationCanceledException]) {
            throw "Timed out after $TimeoutSec seconds sending CDP method $Method."
        }
        throw
    } finally {
        $cts.Dispose()
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds)
        if ($remaining -lt 1) {
            $remaining = 1
        }

        $response = Receive-PseCdpMessage -Conn $Conn -TimeoutSec $remaining
        if ($null -eq $response) {
            continue
        }

        $idProperty = $response.PSObject.Properties['id']
        if ($null -eq $idProperty) {
            [void]$Conn.Events.Add($response)
            continue
        }

        if ([int]$response.id -ne $id) {
            continue
        }

        if ($null -ne $response.PSObject.Properties['error']) {
            $code = $response.error.code
            $errorMessage = $response.error.message
            throw "CDP error $code`: $errorMessage ($Method)"
        }

        return $response.result
    }

    throw "Timed out after $TimeoutSec seconds waiting for CDP response to $Method."
}

function Wait-PseCdpEvent {
    param(
        [Parameter(Mandatory = $true)]
        $Conn,

        [Parameter(Mandatory = $true)]
        [string]$EventName,

        [int]$TimeoutSec = 30
    )

    for ($i = 0; $i -lt $Conn.Events.Count; $i++) {
        $event = $Conn.Events[$i]
        if ($event.method -eq $EventName) {
            $Conn.Events.RemoveAt($i)
            return $event.params
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds)
        if ($remaining -lt 1) {
            $remaining = 1
        }

        $message = Receive-PseCdpMessage -Conn $Conn -TimeoutSec $remaining
        if ($null -eq $message) {
            continue
        }

        $idProperty = $message.PSObject.Properties['id']
        if ($null -ne $idProperty) {
            continue
        }

        if ($message.method -eq $EventName) {
            return $message.params
        }

        [void]$Conn.Events.Add($message)
    }

    throw "Timed out after $TimeoutSec seconds waiting for CDP event $EventName."
}

function Close-PseCdp {
    param(
        [Parameter(Mandatory = $true)]
        $Conn
    )

    try {
        if ($null -ne $Conn -and $null -ne $Conn.Socket) {
            if ($Conn.Socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $cts = [System.Threading.CancellationTokenSource]::new()
                try {
                    $cts.CancelAfter(2000)
                    [void]$Conn.Socket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'close', $cts.Token).GetAwaiter().GetResult()
                } catch {
                } finally {
                    $cts.Dispose()
                }
            }
            $Conn.Socket.Dispose()
        }
    } catch {
    }
}
