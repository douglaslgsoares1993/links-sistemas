Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$indexPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\index.html"))
$contractPath = Join-Path $PSScriptRoot "CONTRATO_SITE.json"
$reportPath = Join-Path $PSScriptRoot "_relatorio_links.txt"
$reportTempPath = Join-Path $PSScriptRoot "_relatorio_links.tmp"
$statePath = Join-Path $PSScriptRoot "_estado_links.json"
$stateTempPath = Join-Path $PSScriptRoot "_estado_links.tmp"
$userAgent = "Mozilla/5.0"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$mutex = New-Object Threading.Mutex($false, "Local\SistemasPCPE_ChecarLinks")
$ownsMutex = $false

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

function Write-AtomicUtf8 {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$TempPath,
    [Parameter(Mandatory = $true)][string]$Text
  )

  [IO.File]::WriteAllText($TempPath, $Text, $utf8NoBom)
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    $backupPath = $Path + ".bak"
    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    try {
      [IO.File]::Replace($TempPath, $Path, $backupPath, $true)
    }
    finally {
      Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
  }
  else {
    [IO.File]::Move($TempPath, $Path)
  }
}

try {
  try {
    $ownsMutex = $mutex.WaitOne(0)
  }
  catch [Threading.AbandonedMutexException] {
    $ownsMutex = $true
  }

  if (-not $ownsMutex) {
    Write-Host "Outra verificacao de links ja esta em andamento."
    exit 2
  }

  if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
    throw "index.html nao encontrado: $indexPath"
  }
  if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    throw "Contrato do site nao encontrado: $contractPath"
  }

  $html = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath
  $normalized = $html.Replace("`r`n", "`n")
  $dataStart = $normalized.IndexOf("const data")
  $dataEnd = $normalized.IndexOf("const badgeText")
  if ($dataStart -lt 0 -or $dataEnd -le $dataStart) {
    throw "Bloco const data nao foi localizado no index.html."
  }
  $dataBlock = $normalized.Substring($dataStart, $dataEnd - $dataStart)
  $contract = Get-Content -Raw -Encoding UTF8 -LiteralPath $contractPath | ConvertFrom-Json
  $itemPattern = '\{n:"(?<name>[^"]+)",\s*u:"(?<url>[^"]+)"(?<rest>[^}]*)\}'
  $found = @([regex]::Matches($dataBlock, $itemPattern))
  $urlTokens = [regex]::Matches($dataBlock, '\bu:"').Count

  if ($found.Count -ne $urlTokens) {
    throw ("Extracao incompleta: {0} de {1} itens com URL foram interpretados." -f $found.Count, $urlTokens)
  }
  if ($found.Count -ne [int]$contract.links) {
    throw ("Contrato divergente: {0} links esperados, {1} encontrados." -f $contract.links, $found.Count)
  }

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

  if ($items.Count -ne [int]$contract.externalLinks) {
    throw ("Contrato divergente: {0} URLs externas esperadas, {1} encontradas." -f $contract.externalLinks, $items.Count)
  }
  $duplicateUrls = @($items | Group-Object Url | Where-Object { $_.Count -gt 1 })
  if ($duplicateUrls.Count -gt 0) {
    throw ("URLs externas duplicadas: {0}." -f (($duplicateUrls | ForEach-Object Name) -join ", "))
  }
  $invalidUrls = @($items | Where-Object { $_.Url -notmatch '^https?://' })
  if ($invalidUrls.Count -gt 0) {
    throw ("URLs externas com protocolo invalido: {0}." -f (($invalidUrls | ForEach-Object Url) -join ", "))
  }

  $previousResults = @()
  $historyLoaded = $false
  if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
      $parsedState = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath | ConvertFrom-Json
      $previousResults = @(
        foreach ($record in $parsedState) {
          $record
        }
      )
      $historyLoaded = $true
    }
    catch {
      Write-Host "Aviso: historico anterior invalido; a varredura seguira sem comparacao."
    }
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

  $changes = New-Object System.Collections.Generic.List[string]
  $previousByUrl = @{}
  foreach ($previous in $previousResults) {
    $previousByUrl[[string]$previous.Url] = $previous
  }
  $currentUrls = @{}
  foreach ($result in $results) {
    $currentUrls[$result.Url] = $true
    if (-not $previousByUrl.ContainsKey($result.Url)) {
      $changes.Add(("NOVO  {0} -> {1}  {2}" -f $result.Name, $result.Class, $result.Url))
    }
    else {
      $oldClass = [string]$previousByUrl[$result.Url].Class
      if ($oldClass -ne $result.Class) {
        $changes.Add(("MUDOU  {0}  {1} -> {2}  {3}" -f $result.Name, $oldClass, $result.Class, $result.Url))
      }
    }
  }
  foreach ($previous in $previousResults) {
    if (-not $currentUrls.ContainsKey([string]$previous.Url)) {
      $changes.Add(("REMOVIDO  {0}  {1}" -f $previous.Name, $previous.Url))
    }
  }

  $classOrder = @("QUEBRADO", "FORA DO AR", "SEM RESPOSTA", "OUTRO", "OK (anti-bot)", "OK")
  $reportLines = New-Object System.Collections.Generic.List[string]
  $reportLines.Add("VERIFICACAO DE LINKS - SISTEMAS PCPE")
  $reportLines.Add(("Data/hora: {0}" -f (Get-Date -Format "dd/MM/yyyy HH:mm:ss")))
  $reportLines.Add(("URLs lidas: {0}" -f $items.Count))
  $reportLines.Add("")
  $reportLines.Add("[MUDOU DESDE A ULTIMA EXECUCAO]")
  if (-not $historyLoaded) {
    $reportLines.Add("Sem historico anterior.")
  }
  elseif ($changes.Count -eq 0) {
    $reportLines.Add("Nenhuma mudanca de classe.")
  }
  else {
    foreach ($change in $changes) {
      $reportLines.Add($change)
    }
  }

  foreach ($className in $classOrder) {
    $group = @($results | Where-Object { $_.Class -eq $className } | Sort-Object Name)
    if ($className -eq "OUTRO" -and $group.Count -eq 0) { continue }
    $reportLines.Add("")
    $reportLines.Add(("[{0}] ({1})" -f $className, $group.Count))
    foreach ($result in $group) {
      $reportLines.Add(("{0,3}  {1}  {2}" -f $result.Code, $result.Name, $result.Url))
    }
  }

  $reportText = [string]::Join([Environment]::NewLine, [string[]]$reportLines) + [Environment]::NewLine
  Write-AtomicUtf8 -Path $reportPath -TempPath $reportTempPath -Text $reportText

  $checkedAt = (Get-Date).ToString("o")
  $stateRecords = @($results | ForEach-Object {
    [pscustomobject]@{
      Name = $_.Name
      Url = $_.Url
      Class = $_.Class
      Code = $_.Code
      CheckedAt = $checkedAt
    }
  })
  $stateText = $stateRecords | ConvertTo-Json -Depth 3
  Write-AtomicUtf8 -Path $statePath -TempPath $stateTempPath -Text ($stateText + [Environment]::NewLine)

  Write-Host ""
  Write-Host "RESUMO"
  foreach ($className in $classOrder) {
    $count = @($results | Where-Object { $_.Class -eq $className }).Count
    if ($className -eq "OUTRO" -and $count -eq 0) { continue }
    Write-Host ("{0,-14} {1,3}" -f $className, $count)
  }
  Write-Host ("MUDANCAS        {0,3}" -f $changes.Count)
  Write-Host ""
  Write-Host ("Relatorio: {0}" -f $reportPath)
}
finally {
  if ($ownsMutex) {
    $mutex.ReleaseMutex()
  }
  $mutex.Dispose()
  Remove-Item -LiteralPath $reportTempPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $stateTempPath -Force -ErrorAction SilentlyContinue
}
