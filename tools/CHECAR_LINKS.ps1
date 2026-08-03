Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$indexPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\index.html"))
$reportPath = Join-Path $PSScriptRoot "_relatorio_links.txt"
$userAgent = "Mozilla/5.0"

function Get-StatusCode {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$Method
  )

  try {
    $response = Invoke-WebRequest -Uri $Url -Method $Method -UseBasicParsing `
      -TimeoutSec 12 -MaximumRedirection 5 -UserAgent $userAgent -ErrorAction Stop
    return [int]$response.StatusCode
  }
  catch {
    if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
      return [int]$_.Exception.Response.StatusCode
    }
    throw
  }
}

function Get-Classification {
  param([Parameter(Mandatory = $true)][int]$Code)

  if ($Code -in @(200, 301, 302)) { return "OK" }
  if ($Code -in @(403, 405, 429)) { return "OK (anti-bot)" }
  if ($Code -in @(404, 410)) { return "QUEBRADO" }
  if ($Code -in @(500, 502, 503)) { return "FORA DO AR" }
  return "OUTRO"
}

if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
  throw "index.html nao encontrado: $indexPath"
}

$html = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath
$itemPattern = '\{n:"(?<name>[^"]+)",\s*u:"(?<url>[^"]+)"(?<rest>[^}]*)\}'
$found = [regex]::Matches($html, $itemPattern)
$items = @(
  foreach ($match in $found) {
    if ($match.Groups["rest"].Value -notmatch '\binternal\s*:\s*true\b') {
      [pscustomobject]@{
        Name = $match.Groups["name"].Value
        Url = $match.Groups["url"].Value
      }
    }
  }
)

if ($items.Count -eq 0) {
  throw "Nenhuma URL externa encontrada no index.html."
}

Write-Host ("URLs lidas: {0}" -f $items.Count)
Write-Host ""
$results = @(
  foreach ($item in $items) {
    $code = "-"
    $class = "SEM RESPOSTA"
    try {
      $status = Get-StatusCode -Url $item.Url -Method "Head"
      if ($status -in @(404, 405, 410, 501)) {
        $status = Get-StatusCode -Url $item.Url -Method "Get"
      }
      $code = [string]$status
      $class = Get-Classification -Code $status
    }
    catch {
      $code = "-"
      $class = "SEM RESPOSTA"
    }

    Write-Host ("{0,-14}  {1,3}  {2}  {3}" -f $class, $code, $item.Name, $item.Url)
    [pscustomobject]@{
      Class = $class
      Code = $code
      Name = $item.Name
      Url = $item.Url
    }
  }
)

$classOrder = @("QUEBRADO", "FORA DO AR", "SEM RESPOSTA", "OUTRO", "OK (anti-bot)", "OK")
$reportLines = New-Object System.Collections.Generic.List[string]
$reportLines.Add("VERIFICACAO DE LINKS - SISTEMAS PCPE")
$reportLines.Add(("Data/hora: {0}" -f (Get-Date -Format "dd/MM/yyyy HH:mm:ss")))
$reportLines.Add(("URLs lidas: {0}" -f $items.Count))

foreach ($className in $classOrder) {
  $group = @($results | Where-Object { $_.Class -eq $className } | Sort-Object Name)
  if ($className -eq "OUTRO" -and $group.Count -eq 0) { continue }
  $reportLines.Add("")
  $reportLines.Add(("[{0}] ({1})" -f $className, $group.Count))
  foreach ($result in $group) {
    $reportLines.Add(("{0,3}  {1}  {2}" -f $result.Code, $result.Name, $result.Url))
  }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllLines($reportPath, [string[]]$reportLines, $utf8NoBom)

Write-Host ""
Write-Host "RESUMO"
foreach ($className in $classOrder) {
  $count = @($results | Where-Object { $_.Class -eq $className }).Count
  if ($className -eq "OUTRO" -and $count -eq 0) { continue }
  Write-Host ("{0,-14} {1,3}" -f $className, $count)
}
Write-Host ""
Write-Host ("Relatorio: {0}" -f $reportPath)
