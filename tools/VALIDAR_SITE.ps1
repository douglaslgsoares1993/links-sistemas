Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$indexPath = Join-Path $root "index.html"
$contractPath = Join-Path $PSScriptRoot "CONTRATO_SITE.json"
$errors = New-Object System.Collections.Generic.List[string]
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Add-ValidationError {
  param([Parameter(Mandatory = $true)][string]$Message)
  $errors.Add($Message)
}

function Get-Utf8Sha256 {
  param([Parameter(Mandatory = $true)][string]$Text)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
  }
  finally {
    $sha.Dispose()
  }
}

if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
  throw "index.html nao encontrado: $indexPath"
}
if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
  throw "Contrato nao encontrado: $contractPath"
}

$html = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath
$normalized = $html.Replace("`r`n", "`n")
$contract = Get-Content -Raw -Encoding UTF8 -LiteralPath $contractPath | ConvertFrom-Json
$dataStart = $normalized.IndexOf("const data")
$dataEnd = $normalized.IndexOf("const badgeText")

if ($dataStart -lt 0 -or $dataEnd -le $dataStart) {
  Add-ValidationError "Bloco const data nao foi localizado."
  $dataBlock = ""
}
else {
  $dataBlock = $normalized.Substring($dataStart, $dataEnd - $dataStart)
}

$itemPattern = '\{n:"(?<name>[^"]+)",\s*u:"(?<url>[^"]+)"(?<rest>[^}]*)\}'
$items = @([regex]::Matches($dataBlock, $itemPattern))
$urlTokens = [regex]::Matches($dataBlock, '\bu:"').Count
$subheads = [regex]::Matches($dataBlock, '\{sub:').Count
$sectionMatches = @([regex]::Matches($dataBlock, '\{\s*id:"(?<id>[^"]+)"'))
$sectionIds = @($sectionMatches | ForEach-Object { $_.Groups["id"].Value })
$externalItems = @($items | Where-Object { $_.Groups["rest"].Value -notmatch '\binternal\s*:\s*true\b' })
$internalItems = @($items | Where-Object { $_.Groups["rest"].Value -match '\binternal\s*:\s*true\b' })

if ($items.Count -ne $urlTokens) {
  Add-ValidationError ("Parser capturou {0} de {1} itens com URL." -f $items.Count, $urlTokens)
}
if ($items.Count -ne [int]$contract.links) {
  Add-ValidationError ("Links: esperado {0}, encontrado {1}." -f $contract.links, $items.Count)
}
if ($externalItems.Count -ne [int]$contract.externalLinks) {
  Add-ValidationError ("Links externos: esperado {0}, encontrado {1}." -f $contract.externalLinks, $externalItems.Count)
}
if ($internalItems.Count -ne [int]$contract.internalLinks) {
  Add-ValidationError ("Links internos: esperado {0}, encontrado {1}." -f $contract.internalLinks, $internalItems.Count)
}
if ($subheads -ne [int]$contract.subheads) {
  Add-ValidationError ("Subcabecalhos: esperado {0}, encontrado {1}." -f $contract.subheads, $subheads)
}
if ($sectionIds.Count -ne [int]$contract.sections) {
  Add-ValidationError ("Secoes: esperado {0}, encontrado {1}." -f $contract.sections, $sectionIds.Count)
}

$expectedSectionIds = @($contract.sectionIds | ForEach-Object { [string]$_ })
if (($sectionIds -join "|") -ne ($expectedSectionIds -join "|")) {
  Add-ValidationError ("IDs ou ordem das secoes divergiram: {0}." -f ($sectionIds -join ", "))
}
if (@($sectionIds | Group-Object | Where-Object { $_.Count -gt 1 }).Count -gt 0) {
  Add-ValidationError "Ha IDs de secao duplicados."
}

$externalUrls = @($externalItems | ForEach-Object { $_.Groups["url"].Value })
$duplicateUrls = @($externalUrls | Group-Object | Where-Object { $_.Count -gt 1 })
foreach ($duplicate in $duplicateUrls) {
  Add-ValidationError ("URL externa duplicada: {0}." -f $duplicate.Name)
}
foreach ($url in $externalUrls) {
  if ($url -notmatch '^https?://') {
    Add-ValidationError ("Protocolo externo invalido: {0}." -f $url)
  }
}

foreach ($item in $internalItems) {
  $relativePath = $item.Groups["url"].Value.Replace("/", [IO.Path]::DirectorySeparatorChar)
  $fullPath = [IO.Path]::GetFullPath((Join-Path $root $relativePath))
  if (-not $fullPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    Add-ValidationError ("Pagina interna ausente ou fora da raiz: {0}." -f $item.Groups["url"].Value)
  }
}

$iconMatches = @([regex]::Matches($dataBlock, '\bimg:"(?<file>[^"]+)"'))
foreach ($iconName in @($iconMatches | ForEach-Object { $_.Groups["file"].Value } | Sort-Object -Unique)) {
  $iconPath = Join-Path (Join-Path $root "icon") $iconName
  if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
    Add-ValidationError ("Icone ausente: icon/{0}." -f $iconName)
  }
}

if ($dataBlock.Length -gt 0) {
  $dataHash = Get-Utf8Sha256 -Text $dataBlock
  if ($dataHash -ne [string]$contract.dataSha256) {
    Add-ValidationError "O array data mudou sem atualizacao deliberada do contrato."
  }
  $usefulStart = $dataBlock.IndexOf('{ id:"uteis"')
  $usefulEnd = $dataBlock.IndexOf('{ id:"ferramentas"')
  if ($usefulStart -lt 0 -or $usefulEnd -le $usefulStart) {
    Add-ValidationError "Secao Mais Uteis nao foi localizada para hash."
  }
  else {
    $usefulHash = Get-Utf8Sha256 -Text $dataBlock.Substring($usefulStart, $usefulEnd - $usefulStart)
    if ($usefulHash -ne [string]$contract.maisUteisSha256) {
      Add-ValidationError "A secao Mais Uteis mudou sem autorizacao contratual."
    }
  }
}

$requiredFragments = @(
  'aria-label="Buscar sistema, consulta ou ferramenta"',
  'aria-live="polite"',
  'a.rel = "noopener noreferrer"',
  'window.open(card.href, "_blank", "noopener")',
  'internal:!!it.internal',
  (("vers" + [char]0x00e3 + "o {0}") -f $contract.version)
)
foreach ($fragment in $requiredFragments) {
  if (-not $normalized.Contains($fragment)) {
    Add-ValidationError ("Blindagem obrigatoria ausente: {0}." -f $fragment)
  }
}

$nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
if ($null -eq $nodeCommand) {
  Add-ValidationError "Node.js nao encontrado para validar a sintaxe inline."
}
else {
  $scriptStart = $normalized.IndexOf("const IC")
  $scriptEnd = $normalized.LastIndexOf("</script>")
  if ($scriptStart -lt 0 -or $scriptEnd -le $scriptStart) {
    Add-ValidationError "Script inline nao foi localizado."
  }
  else {
    $tempScript = Join-Path ([IO.Path]::GetTempPath()) ("links-sistemas-{0}.js" -f [guid]::NewGuid().ToString("N"))
    try {
      [IO.File]::WriteAllText($tempScript, $normalized.Substring($scriptStart, $scriptEnd - $scriptStart), $utf8NoBom)
      $nodeOutput = @(& $nodeCommand.Source --check $tempScript 2>&1)
      if ($LASTEXITCODE -ne 0) {
        Add-ValidationError ("Sintaxe JavaScript invalida: {0}." -f ($nodeOutput -join " "))
      }
    }
    finally {
      Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
  }
}

$allowedPublicPhones = @("5581994884114", "5581994887049", "5587988772185")
$scanExtensions = @(".html", ".js", ".ps1", ".bat", ".md", ".json", ".yml", ".yaml", ".txt")
$ignoredGenerated = @("_relatorio_links.txt", "_estado_links.json", "_relatorio_links.tmp", "_estado_links.tmp")
$scanFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
  $scanExtensions -contains $_.Extension.ToLowerInvariant() -and
  $_.FullName -notmatch '[\\/]\.git[\\/]' -and
  $ignoredGenerated -notcontains $_.Name
})
$emailPattern = '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b'
$cpfPattern = '(?<!\d)(?:\d{3}\.\d{3}\.\d{3}-\d{2}|\d{11})(?!\d)'
$phonePattern = '(?<!\d)55\d{10,11}(?!\d)'
$tokenPattern = '(?i)(?:gh' + '[pousr]_|github_pat_|AKIA)[A-Za-z0-9_-]{12,}'
$privateKeyPattern = '-----BEGIN ' + '(?:RSA |EC |OPENSSH )?PRIVATE KEY-----'

foreach ($file in $scanFiles) {
  $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName
  if ([regex]::IsMatch($text, $emailPattern)) {
    Add-ValidationError ("Possivel e-mail individual em {0}." -f $file.FullName.Substring($root.Length + 1))
  }
  if ([regex]::IsMatch($text, $cpfPattern)) {
    Add-ValidationError ("Possivel CPF em {0}." -f $file.FullName.Substring($root.Length + 1))
  }
  foreach ($phoneMatch in [regex]::Matches($text, $phonePattern)) {
    if ($allowedPublicPhones -notcontains $phoneMatch.Value) {
      Add-ValidationError ("Possivel telefone nao autorizado em {0}." -f $file.FullName.Substring($root.Length + 1))
    }
  }
  if ([regex]::IsMatch($text, $tokenPattern) -or [regex]::IsMatch($text, $privateKeyPattern)) {
    Add-ValidationError ("Possivel segredo em {0}." -f $file.FullName.Substring($root.Length + 1))
  }
}

if ($errors.Count -gt 0) {
  Write-Host "VALIDACAO REPROVADA" -ForegroundColor Red
  foreach ($validationError in $errors) {
    Write-Host ("- {0}" -f $validationError) -ForegroundColor Red
  }
  exit 1
}

Write-Host "VALIDACAO OK" -ForegroundColor Green
Write-Host ("Versao: {0}" -f $contract.version)
Write-Host ("Links: {0} externos + {1} internos" -f $externalItems.Count, $internalItems.Count)
Write-Host ("Subcabecalhos: {0} | Secoes: {1} | Icones: {2}" -f $subheads, $sectionIds.Count, $iconMatches.Count)
Write-Host "Sintaxe, contrato, arquivos locais, destinos, PII e segredos: OK"
