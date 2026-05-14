param(
    [int]$Port = 9100,
    [string]$OutputDir = "$PSScriptRoot\escpos-captures"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

function Write-HexDump {
    param(
        [byte[]]$Bytes,
        [string]$Path
    )

    $lines = New-Object System.Collections.Generic.List[string]
    for ($offset = 0; $offset -lt $Bytes.Length; $offset += 16) {
        $sliceLength = [Math]::Min(16, $Bytes.Length - $offset)
        $slice = $Bytes[$offset..($offset + $sliceLength - 1)]
        $hex = ($slice | ForEach-Object { $_.ToString("X2") }) -join " "
        $ascii = ($slice | ForEach-Object {
            if ($_ -ge 32 -and $_ -le 126) {
                [char]$_
            } else {
                "."
            }
        }) -join ""
        $lines.Add(("{0:X8}  {1,-47}  {2}" -f $offset, $hex, $ascii))
    }
    [System.IO.File]::WriteAllLines($Path, $lines)
}

$listener = [System.Net.Sockets.TcpListener]::new(
    [System.Net.IPAddress]::Loopback,
    $Port
)
$listener.Start()

Write-Host "ESC/POS test printer listening on 127.0.0.1:$Port"
Write-Host "Captures will be written to: $OutputDir"
Write-Host "Press Ctrl+C to stop."

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $remote = $client.Client.RemoteEndPoint
        Write-Host "Accepted print job from $remote"

        $stream = $client.GetStream()
        $memory = [System.IO.MemoryStream]::new()
        $buffer = New-Object byte[] 4096

        do {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -gt 0) {
                $memory.Write($buffer, 0, $read)
            }
        } while ($read -gt 0)

        $bytes = $memory.ToArray()
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
        $rawPath = Join-Path $OutputDir "job-$timestamp.bin"
        $hexPath = Join-Path $OutputDir "job-$timestamp.hex.txt"
        $textPath = Join-Path $OutputDir "job-$timestamp.text.txt"

        [System.IO.File]::WriteAllBytes($rawPath, $bytes)
        Write-HexDump -Bytes $bytes -Path $hexPath
        [System.IO.File]::WriteAllText(
            $textPath,
            [System.Text.Encoding]::Default.GetString($bytes)
        )

        Write-Host "Captured $($bytes.Length) bytes"
        Write-Host "  RAW : $rawPath"
        Write-Host "  HEX : $hexPath"
        Write-Host "  TEXT: $textPath"

        $stream.Close()
        $client.Close()
        $memory.Close()
    }
} finally {
    $listener.Stop()
}
