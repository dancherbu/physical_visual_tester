param(
  [string]$Model = 'llama3.2:1b',
  [int]$NumPredict = 128,
  [int]$Runs = 3
)

$ErrorActionPreference = 'Stop'

function Invoke-OllamaGenerate {
  param(
    [string]$Model,
    [string]$Prompt,
    [int]$NumPredict,
    [double]$Temperature = 0
  )

  $bodyObj = @{ 
    model = $Model
    prompt = $Prompt
    stream = $false
    options = @{ 
      num_predict = $NumPredict
      temperature = $Temperature
    }
  }

  $bodyJson = $bodyObj | ConvertTo-Json -Depth 8
  return Invoke-RestMethod -Method Post -Uri 'http://localhost:11434/api/generate' -ContentType 'application/json' -Body $bodyJson
}

$prompts = @(
  'You see a modal dialog: "Update available" with buttons "Later" and "Install". Goal: continue the test without changing system state. Return ONLY JSON with action=CLICK and target.',
  'OCR sees: ["Error", "Network timeout", "Retry", "Cancel"]. Choose safest next action to proceed once. Return ONLY JSON {"action":"CLICK","target":"Retry"} or {"action":"ABORT","reason":"..."}.',
  'Current step: CLICK "Sign in". OCR shows two matches: "Sign in" (confidence 0.62) and "Sign in" (confidence 0.91) near top. Pick best. Return ONLY JSON {"action":"CLICK","target":"Sign in"}.'
)

Write-Host "Ollama endpoint: http://localhost:11434" -ForegroundColor Cyan
Write-Host "Model: $Model" -ForegroundColor Cyan
Write-Host "num_predict: $NumPredict" -ForegroundColor Cyan
Write-Host "" 

# Warmup to load model
$warmPrompt = 'Return ONLY JSON: {"action":"CLICK","target":"OK"} for an error dialog that says "Failed to save" with buttons OK and Cancel.'
$null = Invoke-OllamaGenerate -Model $Model -Prompt $warmPrompt -NumPredict 64 -Temperature 0

$results = @()
for ($i = 0; $i -lt $Runs; $i++) {
  $prompt = $prompts[$i % $prompts.Count]
  $r = Invoke-OllamaGenerate -Model $Model -Prompt $prompt -NumPredict $NumPredict -Temperature 0

  $promptEvalSec = if ($r.prompt_eval_duration -gt 0) { $r.prompt_eval_duration / 1e9 } else { 0 }
  $evalSec       = if ($r.eval_duration -gt 0) { $r.eval_duration / 1e9 } else { 0 }

  $promptTokPerSec = if ($promptEvalSec -gt 0) { [math]::Round($r.prompt_eval_count / $promptEvalSec, 2) } else { $null }
  $tokPerSec       = if ($evalSec -gt 0) { [math]::Round($r.eval_count / $evalSec, 2) } else { $null }

  $preview = ($r.response -replace "\s+", " ").Trim()
  if ($preview.Length -gt 140) { $preview = $preview.Substring(0, 140) }

  $results += [pscustomobject]@{
    Run = ($i + 1)
    PromptTokens = $r.prompt_eval_count
    PromptSec = [math]::Round($promptEvalSec, 3)
    PromptTokPerSec = $promptTokPerSec
    GenTokens = $r.eval_count
    GenSec = [math]::Round($evalSec, 3)
    GenTokPerSec = $tokPerSec
    OutputPreview = $preview
  }
}

$results | Format-Table -AutoSize

$avgGen = $results | Measure-Object -Property GenTokPerSec -Average
$avgPrompt = $results | Measure-Object -Property PromptTokPerSec -Average

Write-Host "" 
Write-Host ("Avg prompt tok/s: {0}" -f [math]::Round($avgPrompt.Average, 2)) -ForegroundColor Green
Write-Host ("Avg gen tok/s:    {0}" -f [math]::Round($avgGen.Average, 2)) -ForegroundColor Green
