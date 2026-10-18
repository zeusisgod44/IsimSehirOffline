$ErrorActionPreference = 'Stop'

$manifest = Join-Path $PSScriptRoot '..\android\app\src\main\AndroidManifest.xml'
$manifest = [System.IO.Path]::GetFullPath($manifest)
if (-not (Test-Path -LiteralPath $manifest)) { throw "Android manifest not found: $manifest" }
$xml = Get-Content -LiteralPath $manifest -Raw
$permissions = @(
  'android.permission.INTERNET',
  'android.permission.ACCESS_NETWORK_STATE',
  'android.permission.ACCESS_WIFI_STATE',
  'android.permission.CHANGE_WIFI_MULTICAST_STATE'
)
foreach ($permission in $permissions) {
  if ($xml -notmatch [regex]::Escape($permission)) {
    $line = "    <uses-permission android:name=`"$permission`" />`n"
    $xml = $xml.Replace('<application', "$line    <application")
  }
}
if ($xml -notmatch 'usesCleartextTraffic') {
  $xml = $xml.Replace('<application ', '<application android:usesCleartextTraffic="true" ')
}
[System.IO.File]::WriteAllText($manifest, $xml, [System.Text.UTF8Encoding]::new($false))

$plist = Join-Path $PSScriptRoot '..\ios\Runner\Info.plist'
$plist = [System.IO.Path]::GetFullPath($plist)
if (-not (Test-Path -LiteralPath $plist)) { throw "iOS Info.plist not found: $plist" }
$xml = Get-Content -LiteralPath $plist -Raw
if ($xml -notmatch 'NSLocalNetworkUsageDescription') {
  $keys = @'
    <key>NSLocalNetworkUsageDescription</key>
    <string>Yakındaki İsim Şehir oyun odalarını bulmak ve yerel ağda oynamak için kullanılır.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_isimsehir._tcp</string>
    </array>
'@
  $closingIndex = $xml.LastIndexOf('</dict>')
  $xml = $xml.Insert($closingIndex, "$keys`n")
}
[System.IO.File]::WriteAllText($plist, $xml, [System.Text.UTF8Encoding]::new($false))
