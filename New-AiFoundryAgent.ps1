
# deploy-agent.ps1 — Sample script to create and test an AI Foundry agent.
# Reads SP credentials from .env if present, otherwise uses interactive login.
# Usage: .\deploy-agent.ps1

$ErrorActionPreference = "Stop"

# ── Configuration ─────────────────────────────
$ResourceGroupName  = "rg-aifoundry-test-westus3"
$ModelDeploymentName = "gpt-4o"
$AgentName           = "test-agent"
$Instructions        = "You are a helpful assistant. Answer questions clearly and concisely."
$TestMessage         = "What is Azure AI Foundry?"

# ── Load .env file ────────────────────────────
$envFile = Join-Path $PSScriptRoot ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]+?)\s*=\s*(.+)$') {
            [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
}

# ── Login ─────────────────────────────────────
if ($env:SP_APP_ID -and $env:SP_SECRET -and $env:SP_TENANT_ID) {
    $secSecret = ConvertTo-SecureString $env:SP_SECRET -AsPlainText -Force
    $cred = [PSCredential]::new($env:SP_APP_ID, $secSecret)
    $connectParams = @{ ServicePrincipal = $true; Credential = $cred; Tenant = $env:SP_TENANT_ID }
    if ($env:SP_SUBSCRIPTION_ID) { $connectParams.Subscription = $env:SP_SUBSCRIPTION_ID }
    Connect-AzAccount @connectParams | Out-Null
    Write-Host "Authenticated as service principal: $($env:SP_APP_ID)" -ForegroundColor Cyan
} else {
    if (-not (Get-AzContext)) { Connect-AzAccount }
}

Write-Host "Using subscription: $((Get-AzContext).Subscription.Name)" -ForegroundColor Cyan

# ── Discover AI Foundry account ───────────────
$aiFoundry = Get-AzCognitiveServicesAccount -ResourceGroupName $ResourceGroupName |
    Where-Object { $_.Kind -eq 'AIServices' -or $_.AccountType -eq 'AIServices' } | Select-Object -First 1

if (-not $aiFoundry) { Write-Error "No AIServices account in '$ResourceGroupName'."; exit 1 }

$endpoint = $aiFoundry.Properties.Endpoints.'OpenAI Language Model Instance API'
if (-not $endpoint) { $endpoint = $aiFoundry.Endpoint -replace '\.cognitiveservices\.azure\.com', '.openai.azure.com' }
if (-not $endpoint.EndsWith('/')) { $endpoint += '/' }

Write-Host "Endpoint: $endpoint" -ForegroundColor Cyan

# ── Get access token ──────────────────────────
$token = (Get-AzAccessToken -ResourceUrl "https://cognitiveservices.azure.com").Token
$headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }
$apiVersion = "2024-05-01-preview"

# ── Create agent ──────────────────────────────
Write-Host "`nCreating agent '$AgentName'..." -ForegroundColor Cyan

$body = @{ model = $ModelDeploymentName; name = $AgentName; instructions = $Instructions } | ConvertTo-Json
$agent = Invoke-RestMethod -Uri "${endpoint}openai/assistants?api-version=$apiVersion" -Headers $headers -Method Post -Body $body

Write-Host "Agent created: $($agent.id)" -ForegroundColor Green

# ── Test the agent ────────────────────────────
Write-Host "Sending: '$TestMessage'" -ForegroundColor Cyan

$thread = Invoke-RestMethod -Uri "${endpoint}openai/threads?api-version=$apiVersion" -Headers $headers -Method Post -Body "{}"

$msgBody = @{ role = "user"; content = $TestMessage } | ConvertTo-Json
Invoke-RestMethod -Uri "${endpoint}openai/threads/$($thread.id)/messages?api-version=$apiVersion" -Headers $headers -Method Post -Body $msgBody | Out-Null

$run = Invoke-RestMethod -Uri "${endpoint}openai/threads/$($thread.id)/runs?api-version=$apiVersion" -Headers $headers -Method Post -Body (@{ assistant_id = $agent.id } | ConvertTo-Json)

# Poll for completion
$elapsed = 0
do {
    $elapsed += 3; Start-Sleep -Seconds 3
    Write-Host "  Waiting... ($elapsed`s)" -ForegroundColor DarkGray
    $run = Invoke-RestMethod -Uri "${endpoint}openai/threads/$($thread.id)/runs/$($run.id)?api-version=$apiVersion" -Headers $headers
} while ($run.status -in @("queued", "in_progress") -and $elapsed -lt 120)

if ($run.status -eq "completed") {
    $msgs = Invoke-RestMethod -Uri "${endpoint}openai/threads/$($thread.id)/messages?api-version=$apiVersion&order=desc&limit=1" -Headers $headers
    $reply = ($msgs.data[0].content | Where-Object { $_.type -eq "text" } | Select-Object -First 1).text.value
    Write-Host "`nResponse:" -ForegroundColor Green
    Write-Host $reply
} else {
    Write-Warning "Run ended with status: $($run.status) — $($run.last_error.message)"
}

# Cleanup
Invoke-RestMethod -Uri "${endpoint}openai/threads/$($thread.id)?api-version=$apiVersion" -Headers $headers -Method Delete | Out-Null
Write-Host "`nAgent ID: $($agent.id)  |  Endpoint: $endpoint" -ForegroundColor Cyan
