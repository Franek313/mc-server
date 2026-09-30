<#
.SYNOPSIS
    Automatyczne uruchomienie serwera Minecraft (Paper) w sieci lokalnej (LAN),
    z automatycznym sprzataniem po sobie (firewall) po zamknieciu serwera.

.OPIS DZIALANIA
    1. Sprawdza aktywne polaczenie sieciowe (LAN/WiFi) i wyswietla Twoj adres IP.
    2. Sprawdza czy jest zainstalowana Java, jesli nie - probuje ja zainstalowac.
    3. Pobiera serwer Paper (jesli jeszcze go nie masz w folderze serwera).
    4. Akceptuje EULA i ustawia server.properties (port, nasluch na wszystkich interfejsach).
    5. Dodaje regule w Zaporze systemu Windows zezwalajaca na polaczenia przychodzace na porcie serwera.
    6. Uruchamia serwer.
    7. Po zatrzymaniu serwera (komenda "stop" w konsoli, Ctrl+C) - USUWA dodana regule
       firewalla, przywracajac komputer do stanu sprzed uruchomienia.

.UWAGA
    - Wymaga uruchomienia jako Administrator (sam sie o to poprosi przez UAC).
    - NIE ustawia statycznego IP na karcie sieciowej - to celowe (ryzyko zerwania
      polaczenia z siecia). Zamiast tego pokazuje adres MAC, zebys mogl zrobic
      rezerwacje DHCP w ustawieniach routera - to bezpieczny sposob na "staly IP".
    - Jesli zamkniesz okno "na krzyzyk" zamiast wpisac "stop", sprzatanie moze
      sie nie wykonac w 100% przypadkow - w takiej sytuacji uruchom dolaczony
      plik cleanup-mc-server.ps1, zeby na pewno usunac regule firewalla.
#>

param(
    [string]$ServerDir = "$env:USERPROFILE\Desktop\MinecraftServer",
    [string]$MinecraftVersion = "26.3",
    [string]$FallbackVersion = "26.2",
    [string]$MaxRam = "2G",
    [string]$MinRam = "1G",
    [int]$Port = 25565
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Podniesienie uprawnien do Administratora (potrzebne do zmian w Zaporze)
# ---------------------------------------------------------------------------
function Test-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "Ten skrypt wymaga uprawnien administratora (do konfiguracji Zapory)." -ForegroundColor Yellow
    Write-Host "Uruchamiam ponownie z podniesionymi uprawnieniami..." -ForegroundColor Yellow
    $argList = @("-NoExit", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

$FirewallRuleName = "MinecraftServer-TCP-$Port"
$script:addedFirewallRule = $false

function Invoke-Cleanup {
    Write-Host ""
    Write-Host "== Zamykanie i przywracanie ustawien systemu ==" -ForegroundColor Cyan
    if ($script:addedFirewallRule) {
        $rule = Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue
        if ($rule) {
            Remove-NetFirewallRule -DisplayName $FirewallRuleName
            Write-Host "Usunieto regule Zapory: $FirewallRuleName" -ForegroundColor Green
        }
    } else {
        Write-Host "Regula Zapory istniala juz wczesniej - nie usuwam (nie byla dodana przez ten skrypt)." -ForegroundColor Yellow
    }
    Write-Host "Gotowe. Komputer przywrocony do stanu sprzed uruchomienia serwera." -ForegroundColor Green
}

# Zlap Ctrl+C i normalne zakonczenie, zeby na pewno posprzatac
try {
    [Console]::TreatControlCAsInput = $false
} catch {}

try {
    # -----------------------------------------------------------------
    # 1. Sprawdzenie polaczenia sieciowego
    # -----------------------------------------------------------------
    Write-Host "== Sprawdzanie polaczenia sieciowego ==" -ForegroundColor Cyan
    $adapters = Get-NetIPConfiguration | Where-Object {
        $_.IPv4Address -and
        $_.NetAdapter.Status -eq "Up" -and
        $_.NetAdapter.InterfaceDescription -notmatch "Virtual|Loopback|VPN|Hyper-V"
    }

    if (-not $adapters) {
        Write-Host "Nie wykryto aktywnego polaczenia sieciowego (kabel/WiFi)." -ForegroundColor Red
        Write-Host "Podlacz sie do routera (kablem lub WiFi) i uruchom skrypt ponownie." -ForegroundColor Red
        Read-Host "Nacisnij Enter, aby zamknac"
        exit 1
    }

    Write-Host "Wykryte aktywne interfejsy sieciowe:" -ForegroundColor White
    foreach ($a in $adapters) {
        $ip = $a.IPv4Address.IPAddress
        $mac = (Get-NetAdapter -InterfaceIndex $a.InterfaceIndex).MacAddress
        $name = $a.InterfaceAlias
        Write-Host "  - $name : IP=$ip  MAC=$mac" -ForegroundColor White
    }

    $mainAdapter = $adapters | Select-Object -First 1
    $localIP = $mainAdapter.IPv4Address.IPAddress
    $mainMac = (Get-NetAdapter -InterfaceIndex $mainAdapter.InterfaceIndex).MacAddress

    Write-Host ""
    Write-Host ">>> Adres IP Twojego serwera w sieci lokalnej: $localIP <<<" -ForegroundColor Green
    Write-Host ">>> Znajomi (po kablu i po WiFi, jesli sa w tej samej sieci routera) laczy sie przez: $localIP`:$Port <<<" -ForegroundColor Green
    Write-Host ""
    Write-Host "UWAGA: ten adres moze sie zmienic po restarcie routera/komputera (przydzial DHCP)." -ForegroundColor Yellow
    Write-Host "Jesli chcesz, zeby byl ZAWSZE taki sam, zrob rezerwacje DHCP w panelu routera" -ForegroundColor Yellow
    Write-Host "dla adresu MAC: $mainMac (to bezpieczna metoda, nic nie zmienia na komputerze)." -ForegroundColor Yellow
    Write-Host ""

    # -----------------------------------------------------------------
    # 2. Sprawdzenie / instalacja Javy
    # -----------------------------------------------------------------
    Write-Host "== Sprawdzanie Javy ==" -ForegroundColor Cyan
    $javaOk = $false
    try {
        $javaVersionOutput = & java -version 2>&1 | Out-String
        if ($javaVersionOutput -match '"(\d+)') {
            $javaOk = $true
            Write-Host "Znaleziono Jave: $($javaVersionOutput.Split([Environment]::NewLine)[0])" -ForegroundColor Green
        }
    } catch {
        $javaOk = $false
    }

    if (-not $javaOk) {
        Write-Host "Nie znaleziono Javy w systemie." -ForegroundColor Yellow
        $wingetOk = Get-Command winget -ErrorAction SilentlyContinue
        if ($wingetOk) {
            Write-Host "Probuje zainstalowac Java 25 (Temurin) przez winget - wymagana przez Minecraft $MinecraftVersion..." -ForegroundColor Yellow
            try {
                winget install --id EclipseAdoptium.Temurin.25.JDK -e --accept-source-agreements --accept-package-agreements
                Write-Host "Zainstalowano Jave. Jesli ponizej pojawi sie blad 'java nie jest rozpoznawane',"  -ForegroundColor Green
                Write-Host "zamknij to okno i uruchom skrypt ponownie (odswiezy sie PATH)." -ForegroundColor Green
            } catch {
                Write-Host "Automatyczna instalacja Javy nie powiodla sie." -ForegroundColor Red
                Write-Host "Pobierz i zainstaluj Jave 25 recznie: https://adoptium.net/temurin/releases/?version=25" -ForegroundColor Red
                Read-Host "Nacisnij Enter, aby zamknac"
                exit 1
            }
        } else {
            Write-Host "Brak winget w systemie. Pobierz i zainstaluj Jave 25 recznie:" -ForegroundColor Red
            Write-Host "https://adoptium.net/temurin/releases/?version=25" -ForegroundColor Red
            Read-Host "Nacisnij Enter, aby zamknac"
            exit 1
        }
    }

    # -----------------------------------------------------------------
    # 3. Folder serwera + pobranie Paper (jesli trzeba)
    # -----------------------------------------------------------------
    if (-not (Test-Path $ServerDir)) {
        New-Item -ItemType Directory -Path $ServerDir | Out-Null
    }
    Set-Location $ServerDir

    $jarPath = Join-Path $ServerDir "server.jar"
    if (-not (Test-Path $jarPath)) {
        function Get-PaperJar {
            param([string]$Version)
            $buildsUrl = "https://api.papermc.io/v2/projects/paper/versions/$Version/builds"
            $builds = Invoke-RestMethod -Uri $buildsUrl
            $latest = $builds.builds[-1]
            $jarName = $latest.downloads.application.name
            $downloadUrl = "https://api.papermc.io/v2/projects/paper/versions/$Version/builds/$($latest.build)/downloads/$jarName"
            Invoke-WebRequest -Uri $downloadUrl -OutFile $jarPath
            return $jarName
        }

        Write-Host "== Pobieranie serwera Paper (Minecraft $MinecraftVersion) ==" -ForegroundColor Cyan
        try {
            $jarName = Get-PaperJar -Version $MinecraftVersion
            Write-Host "Pobrano: $jarName" -ForegroundColor Green
        } catch {
            Write-Host "Nie udalo sie pobrac Papera dla wersji $MinecraftVersion" -ForegroundColor Yellow
            Write-Host "(builds dla najnowszych 'drop'ow bywaja jeszcze eksperymentalne / niepublikowane)." -ForegroundColor Yellow
            Write-Host "Probuje wersji zapasowej: $FallbackVersion ..." -ForegroundColor Yellow
            try {
                $jarName = Get-PaperJar -Version $FallbackVersion
                Write-Host "Pobrano: $jarName (wersja zapasowa $FallbackVersion)" -ForegroundColor Green
                Write-Host "UWAGA: klienci Minecraft musza miec wersje $FallbackVersion, zeby sie polaczyc." -ForegroundColor Yellow
            } catch {
                Write-Host "Nie udalo sie pobrac serwera automatycznie (sprawdz polaczenie z internetem" -ForegroundColor Red
                Write-Host "lub sprawdz recznie dostepne wersje na https://papermc.io/downloads/paper)." -ForegroundColor Red
                Write-Host "Blad: $($_.Exception.Message)" -ForegroundColor Red
                Read-Host "Nacisnij Enter, aby zamknac"
                exit 1
            }
        }
    } else {
        Write-Host "Znaleziono istniejacy plik server.jar w $ServerDir - pomijam pobieranie." -ForegroundColor Green
    }

    # -----------------------------------------------------------------
    # 4. EULA + server.properties
    # -----------------------------------------------------------------
    "eula=true" | Set-Content (Join-Path $ServerDir "eula.txt")

    $propsPath = Join-Path $ServerDir "server.properties"
    if (-not (Test-Path $propsPath)) {
        @"
server-port=$Port
server-ip=0.0.0.0
online-mode=true
motd=Serwer lokalny \u2013 graj ze znajomymi!
"@ | Set-Content $propsPath
    } else {
        (Get-Content $propsPath) -replace '^server-port=.*', "server-port=$Port" |
            Set-Content $propsPath
    }

    # -----------------------------------------------------------------
    # 5. Regula Zapory (firewall)
    # -----------------------------------------------------------------
    Write-Host "== Konfiguracja Zapory systemu Windows ==" -ForegroundColor Cyan
    $existingRule = Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue
    if (-not $existingRule) {
        New-NetFirewallRule -DisplayName $FirewallRuleName -Direction Inbound `
            -Protocol TCP -LocalPort $Port -Action Allow -Profile Private,Domain | Out-Null
        $script:addedFirewallRule = $true
        Write-Host "Dodano regule Zapory zezwalajaca na polaczenia na porcie $Port (TCP)." -ForegroundColor Green
    } else {
        Write-Host "Regula Zapory dla tego portu juz istnieje - nie dodaje duplikatu." -ForegroundColor Yellow
    }

    # -----------------------------------------------------------------
    # 6. Start serwera
    # -----------------------------------------------------------------
    Write-Host ""
    Write-Host "== Uruchamianie serwera Minecraft ==" -ForegroundColor Cyan
    Write-Host "Aby bezpiecznie zatrzymac serwer i przywrocic ustawienia zapory," -ForegroundColor Yellow
    Write-Host "wpisz 'stop' w tej konsoli i nacisnij Enter." -ForegroundColor Yellow
    Write-Host ""

    & java "-Xmx$MaxRam" "-Xms$MinRam" -jar $jarPath nogui

} finally {
    Invoke-Cleanup
    Read-Host "Nacisnij Enter, aby zamknac to okno"
}
