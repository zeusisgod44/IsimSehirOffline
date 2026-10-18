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
