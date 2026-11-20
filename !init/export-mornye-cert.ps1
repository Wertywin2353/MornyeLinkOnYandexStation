[CmdletBinding()]
param(
    [string]$Server = 'https://192.168.1.102:47710',
    [string]$Fingerprint = 'b02bc7a30bec6d5f991e841612b033caefbbbb3ccd9dce79bd4f6eca3979f470',
    [string]$AdbSerial = ''
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
    throw 'ADB не найден в PATH. Укажи путь к Android Platform Tools.'
}
$script:ExpectedFingerprint = $Fingerprint.Trim().ToLowerInvariant()
if ($script:ExpectedFingerprint -notmatch '^[0-9a-f]{64}$') {
    throw 'Fingerprint должен состоять из 64 шестнадцатеричных символов SHA-256.'
}
$script:Server = $Server.TrimEnd('/')
$script:CertificateDer = $null
$script:ObservedFingerprint = $null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::ServerCertificateValidationCallback = {
    param($sender, $certificate, $chain, $sslPolicyErrors)
    if ($null -eq $certificate) { return $false }
    $der = $certificate.GetRawCertData()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $actual = -join ($sha.ComputeHash($der) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
    $script:ObservedFingerprint = $actual
    $script:CertificateDer = $der
    return [string]::Equals($actual, $script:ExpectedFingerprint, [System.StringComparison]::OrdinalIgnoreCase)
}

Write-Host "Получаю сертификат Mornye Link: $script:Server" -ForegroundColor Cyan
$request = [Net.HttpWebRequest]::Create($script:Server + '/mornye/v1/info')
$request.Method = 'GET'
$request.Accept = 'application/json'
$request.Timeout = 12000
$request.ReadWriteTimeout = 12000
$response = $null
try {
    $response = $request.GetResponse()
    $reader = [IO.StreamReader]::new($response.GetResponseStream())
    try { $infoText = $reader.ReadToEnd() }
    finally { $reader.Dispose() }
}
finally {
    if ($null -ne $response) { $response.Dispose() }
}
if ($null -eq $script:CertificateDer) { throw 'Windows не получил TLS-сертификат сервера.' }
if ($script:ObservedFingerprint -ne $script:ExpectedFingerprint) {
    throw 'Fingerprint сертификата не совпал с доверенным значением. Файл не установлен.'
}
$info = $infoText | ConvertFrom-Json
if ($info.fingerprint -ne $script:ExpectedFingerprint) {
    throw 'Fingerprint в /info не совпадает с TLS-сертификатом.'
}

$base64 = [Convert]::ToBase64String($script:CertificateDer)
$lines = for ($i = 0; $i -lt $base64.Length; $i += 64) {
    $base64.Substring($i, [Math]::Min(64, $base64.Length - $i))
}
$pem = "-----BEGIN CERTIFICATE-----`r`n" + ($lines -join "`r`n") + "`r`n-----END CERTIFICATE-----`r`n"
$tempFile = Join-Path $env:TEMP ('mornye-link-cert-{0}.pem' -f [guid]::NewGuid().ToString('N'))
try {
    [IO.File]::WriteAllText($tempFile, $pem, ([Text.UTF8Encoding]::new($false)))
    $adbPrefix = @()
    if (-not [string]::IsNullOrWhiteSpace($AdbSerial)) { $adbPrefix = @('-s', $AdbSerial) }
    & adb @adbPrefix push $tempFile '/data/local/tmp/mornye-link-cert.pem' | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'ADB push завершился с ошибкой.' }
    # Pass the complete su command as ONE adb-shell argument.  On this Station
    # firmware, `adb shell su -c <several PowerShell args>` is split incorrectly
    # and su interprets /data/local/etc as a username.
    $remote = "su -c 'mkdir -p /data/local/etc && chmod 700 /data/local/etc && cp /data/local/tmp/mornye-link-cert.pem /data/local/etc/mornye-link-cert.pem && chmod 600 /data/local/etc/mornye-link-cert.pem && rm -f /data/local/tmp/mornye-link-cert.pem && test -s /data/local/etc/mornye-link-cert.pem'"
    $installOutput = & adb @adbPrefix shell $remote 2>&1
    $installExit = $LASTEXITCODE
    $installOutput | Out-Host
    if ($installExit -ne 0) { throw 'Не удалось установить сертификат на колонку. Проверь выдачу root для adb shell.' }

    # Do not trust adb's transport exit code alone: verify the destination file.
    $verifyRemote = "su -c 'test -s /data/local/etc/mornye-link-cert.pem && echo MORNye_CERT_OK || echo MORNye_CERT_MISSING'"
    $verifyOutput = & adb @adbPrefix shell $verifyRemote 2>&1
    $verifyExit = $LASTEXITCODE
    $verifyText = ($verifyOutput | Out-String)
    if ($verifyExit -ne 0 -or $verifyText -notmatch 'MORNye_CERT_OK') {
        throw 'ADB передал файл, но сертификат не найден в /data/local/etc/mornye-link-cert.pem.'
    }
}
finally {
    if (Test-Path $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
}
Write-Host "Сертификат Mornye Link установлен и проверен: $script:ObservedFingerprint" -ForegroundColor Green
Write-Host 'Файл на колонке: /data/local/etc/mornye-link-cert.pem' -ForegroundColor Green
