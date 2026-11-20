[CmdletBinding()]
param(
    [string]$Server = 'https://192.168.1.102:47710',
    [string]$Fingerprint = 'b02bc7a30bec6d5f991e841612b033caefbbbb3ccd9dce79bd4f6eca3979f470',
    [string]$DeviceName = 'Yandex Station 2',
    [string]$AdbSerial = ''
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
    throw 'ADB не найден в PATH. Установи Android Platform Tools и повтори запуск.'
}
$script:ExpectedFingerprint = $Fingerprint.Trim().ToLowerInvariant()
$script:Server = $Server.TrimEnd('/')

if ($script:ExpectedFingerprint -notmatch '^[0-9a-f]{64}$') {
    throw 'Fingerprint должен состоять из 64 шестнадцатеричных символов SHA-256.'
}

# Trust only the exact self-signed certificate fingerprint reported by Mornye.
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
    param($sender, $certificate, $chain, $sslPolicyErrors)
    if ($null -eq $certificate) { return $false }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $actual = -join ($sha.ComputeHash($certificate.GetRawCertData()) | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha.Dispose()
    }
    return [string]::Equals($actual, $script:ExpectedFingerprint, [System.StringComparison]::OrdinalIgnoreCase)
}

function Invoke-MornyeJson {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('GET','POST')][string]$Method,
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$Body = ''
    )

    $request = [System.Net.HttpWebRequest]::Create($script:Server + $Path)
    $request.Method = $Method
    $request.Accept = 'application/json'
    $request.UserAgent = 'Mornye-Station2-Pair/1.0'
    $request.Timeout = 12000
    $request.ReadWriteTimeout = 12000
    $request.KeepAlive = $false

    if ($Method -eq 'POST') {
        $request.ContentType = 'application/json; charset=utf-8'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) }
        finally { $stream.Dispose() }
    }

    try {
        $response = $request.GetResponse()
        try {
            $reader = [System.IO.StreamReader]::new($response.GetResponseStream())
            try { $text = $reader.ReadToEnd() }
            finally { $reader.Dispose() }
        }
        finally { $response.Dispose() }
    }
    catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($null -ne $response) {
            try {
                $reader = [System.IO.StreamReader]::new($response.GetResponseStream())
                try { $text = $reader.ReadToEnd() }
                finally { $reader.Dispose() }
                throw "Mornye вернул HTTP $([int]$response.StatusCode): $text"
            }
            finally { $response.Dispose() }
        }
        throw "Не удалось подключиться к Mornye: $($_.Exception.Message)"
    }

    try { return ($text | ConvertFrom-Json) }
    catch { throw "Сервер вернул не JSON: $text" }
}

Write-Host "Проверяю Mornye Link: $script:Server" -ForegroundColor Cyan
$info = Invoke-MornyeJson -Method GET -Path '/mornye/v1/info'

if ($info.fingerprint -ne $script:ExpectedFingerprint) {
    throw 'Fingerprint в /info не совпадает с заданным. Сопряжение остановлено.'
}
if (-not $info.pairing) {
    throw 'Окно сопряжения закрыто. В Mornye Desktop нажми Pair a phone и запусти скрипт снова.'
}
Write-Host ("Сервер подтверждён: {0} (Mornye {1}), окно сопряжения открыто." -f $info.name, $info.appVersion) -ForegroundColor Green

$pin = Read-Host 'Введи шестизначный PIN, показанный в окне сопряжения Mornye Desktop'
if ($pin -notmatch '^\d{6}$') { throw 'PIN должен содержать ровно 6 цифр.' }

$deviceId = [guid]::NewGuid().ToString().ToLowerInvariant()
$proofMessage = 'mornye-link-pair-v1:{0}:{1}' -f $script:ExpectedFingerprint, $deviceId
$hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($pin))
try {
    $proofBytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($proofMessage))
}
finally { $hmac.Dispose() }
$proof = -join ($proofBytes | ForEach-Object { $_.ToString('x2') })

$body = [ordered]@{
    deviceId = $deviceId
    name = $DeviceName
    platform = 'linux'
    proof = $proof
} | ConvertTo-Json -Compress

Write-Host 'Выполняю сопряжение...' -ForegroundColor Cyan
$paired = Invoke-MornyeJson -Method POST -Path '/mornye/v1/pair' -Body $body

if ([string]::IsNullOrWhiteSpace([string]$paired.apiKey)) {
    throw 'В ответе сервера отсутствует apiKey. Конфигурация не сохранена.'
}
if ($paired.fingerprint -ne $script:ExpectedFingerprint -or $paired.serverId -ne $info.serverId) {
    throw 'Ответ pairing относится к другому серверу. Конфигурация не сохранена.'
}

$config = [ordered]@{
    server = $script:Server
    fingerprint = $script:ExpectedFingerprint
    serverId = [string]$paired.serverId
    serverName = [string]$paired.name
    deviceId = $deviceId
    apiKey = [string]$paired.apiKey
}
$tempFile = Join-Path $env:TEMP ('mornye-station2-{0}.json' -f [guid]::NewGuid().ToString('N'))
try {
    $json = $config | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($tempFile, $json, ([System.Text.UTF8Encoding]::new($false)))

    $adbPrefix = @()
    if (-not [string]::IsNullOrWhiteSpace($AdbSerial)) { $adbPrefix = @('-s', $AdbSerial) }
    & adb @adbPrefix push $tempFile '/data/local/tmp/mornye-link.json' | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'ADB push завершился с ошибкой. Проверь adb devices.' }
    $remote = "su -c 'mkdir -p /data/local/etc && chmod 700 /data/local/etc && cp /data/local/tmp/mornye-link.json /data/local/etc/mornye-link.json && chmod 600 /data/local/etc/mornye-link.json && rm -f /data/local/tmp/mornye-link.json'"
    & adb @adbPrefix shell $remote | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось установить конфигурацию на колонку. Проверь, что su выдаёт root через adb shell.' }
    Write-Host 'API-ключ сохранён на Станции 2: /data/local/etc/mornye-link.json' -ForegroundColor Green
    Write-Host 'Секретный API-ключ не выводится на экран.' -ForegroundColor Green
}
finally {
    if (Test-Path $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
}

Write-Host 'Сопряжение завершено. Окно pairing в Mornye должно закрыться.' -ForegroundColor Green
