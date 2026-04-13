# New-AiFoundryAgent.ps1
# Creates an AI agent on an Azure AI Foundry (AIServices) account and optionally tests it.
# Requires: Az PowerShell module, Cognitive Services OpenAI Contributor role on the account.

param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [string]$ModelDeploymentName = "gpt-4o",
    [string]$AgentName = "test-agent",
    [string]$Instructions = "You are a helpful assistant.",
    [string]$TestMessage
)

$ErrorActionPreference = "Stop"
$apiVersion = "2024-05-01-preview"

# --- Auth & discovery ---
if (-not (Get-AzContext)) { Connect-AzAccount }

$account = Get-AzCognitiveServicesAccount -ResourceGroupName $ResourceGroupName |
    Where-Object { $_.AccountType -eq 'AIServices' } | Select-Object -First 1
if (-not $account) { throw "No AIServices account found in '$ResourceGroupName'." }

$endpoint = ($account.Properties.Endpoints.'OpenAI Language Model Instance API' ??
    ($account.Endpoint -replace '\.cognitiveservices\.azure\.com', '.openai.azure.com')).TrimEnd('/') + '/'

$token = (Get-AzAccessToken -ResourceUrl "https://cognitiveservices.azure.com").Token
$h = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

Write-Host "Endpoint: $endpoint" -ForegroundColor Cyan

# --- Create agent ---
$body = @{ model = $ModelDeploymentName; name = $AgentName; instructions = $Instructions } | ConvertTo-Json
$agent = Invoke-RestMethod -Uri "${endpoint}openai/assistants?api-version=$apiVersion" -Headers $h -Method Post -Body $body

Write-Host "Agent created: $($agent.id) ($($agent.name), $($agent.model))" -ForegroundColor Green

# --- Test (optional) ---
if ($TestMessage) {
    Write-Host "Sending: $TestMessage" -ForegroundColor Cyan

    $thread = Invoke-RestMethod -Uri "${endpoint}openai/threads?api-version=$apiVersion" -Headers $h -Method Post -Body "{}"
    Invoke-RestMethod -Uri "${endpoint}openai/threads/$($thread.id)/messages?api-version=$apiVersion" -Headers $h -Method Post -Body (@{role="user";content=$TestMessage}|ConvertTo-Json) | Out-Null
    $run = Invoke-RestMethod -Uri "${endpoint}openai/threads/$($thread.id)/runs?api-version=$apiVersion" -Headers $h -Method Post -Body (@{assistant_id=$agent.id}|ConvertTo-Json)

    do { Start-Sleep 3; $run = Invoke-RestMethod -Uri "${endpoint}openai/threads/$($thread.id)/runs/$($run.id)?api-version=$apiVersion" -Headers $h }
    while ($run.status -in @("queued","in_progress"))

    if ($run.status -eq "completed") {
        $msgs = Invoke-RestMethod -Uri "${endpoint}openai/threads/$($thread.id)/messages?api-version=$apiVersion&order=desc&limit=1" -Headers $h
        Write-Host "`nResponse:" -ForegroundColor Green
        Write-Host ($msgs.data[0].content | Where-Object { $_.type -eq "text" } | Select-Object -First 1).text.value
    } else {
        Write-Warning "Run status: $($run.status) — $($run.last_error.message)"
    }

    Invoke-RestMethod -Uri "${endpoint}openai/threads/$($thread.id)?api-version=$apiVersion" -Headers $h -Method Delete | Out-Null
}

Write-Host "`nAgent ID: $($agent.id)" -ForegroundColor Cyan
