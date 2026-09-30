<#
.SYNOPSIS
    Awaryjne "sprzatanie" - usuwa regule Zapory dodana przez start-mc-server.ps1.
    Uzyj tego skryptu, jesli zamknales okno serwera "na krzyzyk" zamiast wpisac "stop",
    i chcesz miec pewnosc, ze port zostal z powrotem zamkniety w Zaporze.

.PARAMETR Port
    Port, na ktorym dzialal serwer (domyslnie 25565 - standardowy port Minecrafta).
#>

param(
    [int]$Port = 25565
)

function Test-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "Wymagane uprawnienia administratora. Uruchamiam ponownie..." -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Port $Port"
    exit
}

$FirewallRuleName = "MinecraftServer-TCP-$Port"
$rule = Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue

if ($rule) {
    Remove-NetFirewallRule -DisplayName $FirewallRuleName
    Write-Host "Usunieto regule Zapory: $FirewallRuleName" -ForegroundColor Green
} else {
    Write-Host "Nie znaleziono takiej reguly Zapory (mozliwe, ze zostala juz usunieta)." -ForegroundColor Yellow
}

Read-Host "Nacisnij Enter, aby zamknac"
