# New-AiFoundryAgent.ps1
# Creates an AI agent on an Azure AI Foundry project using the Foundry Agents API.
# Uses the services.ai.azure.com endpoint with project-scoped paths and CosmosDB-backed thread storage.
# Requires: Az PowerShell module, Azure AI User role on the project.

param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [string]$ModelDeploymentName = "gpt-4o",
    [string]$AgentName = "test-agent",
    [string]$Instructions = "You are a helpful assistant.",
    [string]$TestMessage
)

$ErrorActionPreference = "Stop"

# --- Auth & discovery ---
if (-not (Get-AzContext)) { Connect-AzAccount }

$account = Get-AzCognitiveServicesAccount -ResourceGroupName $ResourceGroupName |
    Where-Object { $_.AccountType -eq 'AIServices' } | Select-Object -First 1
if (-not $account) { throw "No AIServices account found in '$ResourceGroupName'." }

$project = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType "Microsoft.CognitiveServices/accounts/projects" | Select-Object -First 1
if (-not $project) { throw "No AI Foundry project found in '$ResourceGroupName'." }
$projectName = ($project.Name -split '/')[-1]

$endpoint = "$($account.Properties.Endpoints.'AI Foundry API'.TrimEnd('/'))".TrimEnd('/')
$projectEndpoint = "$endpoint/api/projects/$projectName"

$token = (Get-AzAccessToken -ResourceUrl "https://ai.azure.com").Token
$h = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

Write-Host "Project: $projectEndpoint" -ForegroundColor Cyan

# --- Create agent ---
$body = @{ model = $ModelDeploymentName; name = $AgentName; instructions = $Instructions } | ConvertTo-Json
$agent = Invoke-RestMethod -Uri "$projectEndpoint/assistants?api-version=v1" -Headers $h -Method Post -Body $body

Write-Host "Agent created: $($agent.id) ($($agent.name), $($agent.model))" -ForegroundColor Green

# --- Test (optional) ---
if ($TestMessage) {
    Write-Host "Sending: $TestMessage" -ForegroundColor Cyan

    $threadBody = @{ messages = @(@{ role = "user"; content = $TestMessage }) } | ConvertTo-Json -Depth 3
    $runBody = @{ assistant_id = $agent.id; thread = ($threadBody | ConvertFrom-Json) } | ConvertTo-Json -Depth 5
    $run = Invoke-RestMethod -Uri "$projectEndpoint/threads/runs?api-version=v1" -Headers $h -Method Post -Body $runBody

    do { Start-Sleep 3; $run = Invoke-RestMethod -Uri "$projectEndpoint/threads/$($run.thread_id)/runs/$($run.id)?api-version=v1" -Headers $h }
    while ($run.status -in @("queued","in_progress"))

    if ($run.status -eq "completed") {
        $msgs = Invoke-RestMethod -Uri "$projectEndpoint/threads/$($run.thread_id)/messages?api-version=v1&order=desc&limit=1" -Headers $h
        Write-Host "`nResponse:" -ForegroundColor Green
        Write-Host ($msgs.data[0].content | Where-Object { $_.type -eq "text" } | Select-Object -First 1).text.value
    } else {
        Write-Warning "Run status: $($run.status) — $($run.last_error.message)"
    }

    Invoke-RestMethod -Uri "$projectEndpoint/threads/$($run.thread_id)?api-version=v1" -Headers $h -Method Delete | Out-Null
}

Write-Host "`nAgent ID: $($agent.id)" -ForegroundColor Cyan
