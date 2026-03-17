# Bobby Wobbin DNS Manager
# Automatically switches DNS based on network location
# Can also be run manually to configure DNS

$HOME_GATEWAY = "10.0.0.1"
$PIHOLE_IPV4 = "10.0.0.2"
$PIHOLE_IPV6 = "2601:2c1:8a01:9850:e65f:1ff:fe1c:867"
$FALLBACK_DNS1 = "9.9.9.9"
$FALLBACK_DNS2 = "149.112.112.112"
$VPN_INTERFACE = "computer"  # WireGuard tunnel name
$SCRIPT_PATH = "C:\Scripts\win-dns-manager.ps1"

function Set-DNS {
    # Check if on home network
    $onHomeNetwork = Test-Connection -ComputerName $HOME_GATEWAY -Count 1 -Quiet -TimeoutSeconds 1

    # Check if VPN is active
    $vpnActive = Get-NetAdapter | Where-Object { $_.Name -like "*$VPN_INTERFACE*" -and $_.Status -eq "Up" }

    $adapters = Get-NetAdapter | Where-Object { 
        $_.Status -eq "Up" -and 
        $_.Name -notlike "*Loopback*" -and 
        $_.Name -notlike "*Bluetooth*" -and
        $_.Name -notlike "*Virtual*" -and
        $_.Name -notlike "*WSL*"
    }

    foreach ($adapter in $adapters) {
        if ($onHomeNetwork) {
            Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ServerAddresses ($PIHOLE_IPV4, $PIHOLE_IPV6)
            Write-Host "Home network detected on $($adapter.Name) - using Pi-hole" -ForegroundColor Green
        } elseif ($vpnActive) {
            Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ServerAddresses ($PIHOLE_IPV4, $PIHOLE_IPV6)
            Write-Host "VPN active on $($adapter.Name) - using Pi-hole" -ForegroundColor Cyan
        } else {
            Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ServerAddresses ($FALLBACK_DNS1, $FALLBACK_DNS2)
            # Set IPv6 DNS to Quad9 as well
            netsh interface ipv6 set dnsservers $adapter.Name static 2620:fe::fe primary
            netsh interface ipv6 add dnsservers $adapter.Name 2620:fe::9 index=2
            Write-Host "Away from home on $($adapter.Name) - using Quad9" -ForegroundColor Yellow
        }
    }

    ipconfig /flushdns | Out-Null
    Write-Host "DNS configured!" -ForegroundColor Green
}

function Install-Task {
    if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Host "Please run as Administrator to install the scheduled task!" -ForegroundColor Red
        exit
    }

    if (-NOT (Test-Path "C:\Scripts")) {
        New-Item -ItemType Directory -Path "C:\Scripts" | Out-Null
    }
    $githubUrl = "https://raw.githubusercontent.com/acz0r/bobbywobbin/main/scripts/win-dns-manager.ps1"
    Invoke-WebRequest -Uri $githubUrl -OutFile $SCRIPT_PATH
    Write-Host "Script downloaded to $SCRIPT_PATH" -ForegroundColor Green

    $taskName = "BobbyWobbinDNSSwitcher"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    $action = New-ScheduledTaskAction `
        -Execute "PowerShell.exe" `
        -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SCRIPT_PATH`" -AutoRun"

    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew

    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -RunLevel Highest

    # Trigger on logon
    $triggerLogon = New-ScheduledTaskTrigger -AtLogOn

    # Trigger on network connected event (EventID 10000)
    $triggerNetworkConnect = New-ScheduledTaskTrigger -AtStartup
    $CIMTriggerClass = Get-CimClass -ClassName "MSFT_TaskEventTrigger" -Namespace "Root/Microsoft/Windows/TaskScheduler"
    $triggerNetworkConnect = New-CimInstance -CimClass $CIMTriggerClass -ClientOnly
    $triggerNetworkConnect.Subscription = @"
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational">
    <Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[EventID=10000]]</Select>
  </Query>
</QueryList>
"@
    $triggerNetworkConnect.Enabled = $true

    # Trigger on network disconnected event (EventID 10001)
    $triggerNetworkDisconnect = New-CimInstance -CimClass $CIMTriggerClass -ClientOnly
    $triggerNetworkDisconnect.Subscription = @"
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational">
    <Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[EventID=10001]]</Select>
  </Query>
</QueryList>
"@
    $triggerNetworkDisconnect.Enabled = $true

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger @($triggerLogon, $triggerNetworkConnect, $triggerNetworkDisconnect) `
        -Settings $settings `
        -Principal $principal `
        -Force | Out-Null

    Write-Host "Scheduled task installed!" -ForegroundColor Green
    Write-Host "DNS will now switch automatically on network changes" -ForegroundColor Green
}

function Uninstall-Task {
    Unregister-ScheduledTask -TaskName "BobbyWobbinDNSSwitcher" -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "✅ Scheduled task removed!" -ForegroundColor Green
}

function Reset-DNS {
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    foreach ($adapter in $adapters) {
        Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ResetServerAddresses
        Write-Host "✅ $($adapter.Name) reset to automatic DNS" -ForegroundColor Green
    }
    ipconfig /flushdns | Out-Null
    Write-Host "DNS reset to automatic!" -ForegroundColor Green
}

# If called with -AutoRun flag just set DNS silently
if ($args -contains "-AutoRun") {
    Set-DNS
    exit
}

# Otherwise show menu
Write-Host "`nBobby Wobbin DNS Manager" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host "  1. Set DNS now"
Write-Host "  2. Reset DNS to automatic"
Write-Host "  3. Install auto-switcher (runs on network change)"
Write-Host "  4. Uninstall auto-switcher"
Write-Host "  5. Exit"

$choice = Read-Host "`nEnter choice"

switch ($choice) {
    "1" { Set-DNS }
    "2" { Reset-DNS }
    "3" { Install-Task }
    "4" { Uninstall-Task }
    "5" { exit }
    default { Write-Host "Invalid choice" -ForegroundColor Red }
}
