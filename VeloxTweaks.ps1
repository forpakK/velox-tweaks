# ============================================================================
#  Velox Tweaks  -  Optimiseur Windows (PowerShell + WPF)
#  Lancer avec "Lancer Velox Tweaks.bat" (demande les droits administrateur).
# ============================================================================
param([switch]$Tray, [switch]$Updated)

# --- Droits administrateur ----------------------------------------------------
Add-Type -AssemblyName PresentationFramework
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [void][System.Windows.MessageBox]::Show("Velox Tweaks a besoin des droits administrateur.`n`nFais un clic droit sur « Lancer Velox Tweaks.bat » puis « Exécuter en tant qu'administrateur ».", 'Velox Tweaks', 'OK', 'Information')
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

trap {
    try { Add-Content -Path (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'VeloxTweaks\velox.log') -Value "ERREUR : $($_ | Out-String)" -Encoding UTF8 } catch {}
    [void][Windows.MessageBox]::Show("Erreur inattendue :`n`n$($_.Exception.Message)", 'Velox Tweaks', 'OK', 'Error')
    continue
}

$AppVersion = '1.7'
$DataRoot   = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'VeloxTweaks'
$BackupRoot = Join-Path $DataRoot 'Backups'
$LogFile    = Join-Path $DataRoot 'velox.log'
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
$ScriptPath = $PSCommandPath
$ScriptDir  = $PSScriptRoot

# --- Réglages de Velox (settings.json) -------------------------------------------
$SettingsFile = Join-Path $DataRoot 'settings.json'
$Settings = @{
    AutoGame = $false
    Games = 'FortniteClient-Win64-Shipping, VALORANT-Win64-Shipping, cs2, r5apex, RobloxPlayerBeta, javaw, Overwatch, cod, RustClient'
    TrayOnClose = $true
    Accent = '#2D7BFF'
    Cross = $false; CrossStyle = 'Croix'; CrossColor = '#00FF66'; CrossSize = 10; CrossThick = 2; CrossGap = 4
}
try { if (Test-Path $SettingsFile) { $j = Get-Content $SettingsFile -Raw | ConvertFrom-Json; foreach ($p in $j.PSObject.Properties) { $Settings[$p.Name] = $p.Value } } } catch {}
function Save-Settings { try { $Settings | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8 } catch {} }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# --- Une seule copie de Velox à la fois ---------------------------------------------
$script:Mutex = New-Object Threading.Mutex($false, 'Global\VeloxTweaksApp')
$gotMutex = $false
try { $gotMutex = $script:Mutex.WaitOne($(if ($Updated) { 15000 } else { 4000 })) } catch [Threading.AbandonedMutexException] { $gotMutex = $true }
if (-not $gotMutex) {
    [void][Windows.MessageBox]::Show("Velox Tweaks est déjà ouvert.`n`nCherche lʼicône ⚡ près de lʼhorloge (en bas à droite), puis double-clique dessus.", 'Velox Tweaks', 'OK', 'Information')
    exit
}

# --- Couleur d'accent ------------------------------------------------------------------
function Get-MixColor([string]$A, [string]$B, [double]$T) {
    $ca = [Windows.Media.ColorConverter]::ConvertFromString($A); $cb = [Windows.Media.ColorConverter]::ConvertFromString($B)
    '#{0:X2}{1:X2}{2:X2}' -f [int]($ca.R * $T + $cb.R * (1 - $T)), [int]($ca.G * $T + $cb.G * (1 - $T)), [int]($ca.B * $T + $cb.B * (1 - $T))
}
$Accent = '#2D7BFF'
try { [void][Windows.Media.ColorConverter]::ConvertFromString([string]$Settings.Accent); $Accent = [string]$Settings.Accent } catch {}
$AccentMid = Get-MixColor $Accent '#0A0F1C' 0.45
$AccentDark = Get-MixColor $Accent '#0A0F1C' 0.14


# --- Fonctions partagées (UI + tâches en arrière-plan) ------------------------
$Helpers = @'
$ErrorActionPreference = 'Continue'
function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
function Remove-Reg([string]$Path, [string]$Name) {
    if (Test-Path $Path) { Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue }
}
function Get-Reg([string]$Path, [string]$Name) {
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}
function Get-SvcStart([string]$Name) {
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($s) { [string]$s.StartType } else { 'Missing' }
}
function Set-Svc([string]$Name, [string]$Mode) {
    if (-not (Get-Service -Name $Name -ErrorAction SilentlyContinue)) { return }
    $map = @{ Disabled = 'disabled'; Automatic = 'auto'; Manual = 'demand'; Delayed = 'delayed-auto' }
    if ($Mode -eq 'Disabled') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
    sc.exe config $Name start= $($map[$Mode]) | Out-Null
    if ($Mode -eq 'Automatic' -or $Mode -eq 'Delayed') { Start-Service -Name $Name -ErrorAction SilentlyContinue }
}
$GuidRx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
function Get-VeloxPlanGuid {
    $l = powercfg /list | Out-String
    $m = [regex]::Match($l, "($GuidRx)\s+\(Velox Ultimate")
    if ($m.Success) { $m.Groups[1].Value } else { $null }
}
function Test-VeloxPlanActive { (powercfg /getactivescheme | Out-String) -match 'Velox' }
function Enable-VeloxPlan {
    $ErrorActionPreference = 'Continue'
    $g = Get-VeloxPlanGuid
    if (-not $g) {
        $o = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>&1 | Out-String
        $g = [regex]::Match($o, $GuidRx).Value
        if (-not $g) {
            $o = powercfg -duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>&1 | Out-String
            $g = [regex]::Match($o, $GuidRx).Value
        }
        if ($g) { powercfg -changename $g "Velox Ultimate Performance" "Plan Velox Tweaks" | Out-Null }
    }
    if (-not $g) { throw "Impossible de créer le plan dʼalimentation." }
    powercfg -setactive $g
    "Plan actif : Velox Ultimate Performance"
}
function Set-BalancedPlan { powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e; "Plan actif : Utilisation normale (Balanced)" }
'@
. ([scriptblock]::Create($Helpers))

$RestoreCode = @'
Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore" SystemRestorePointCreationFrequency 0
try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop } catch {}
try { Checkpoint-Computer -Description "Velox Tweaks" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; "Point de restauration créé" }
catch { "Point de restauration impossible : " + $_.Exception.Message }
'@

# --- Liste des tweaks -----------------------------------------------------------
# Apply / Revert / Check sont du code PowerShell (texte) exécuté en arrière-plan.
$Tweaks = @(
 @{ Id='gamedvr'; Cat='Gaming'; Impact='HIGH'; Restart=$false; Rec=$true
    Name='Désactiver Game DVR & Game Bar'
    Desc="Coupe lʼenregistrement vidéo en arrière-plan de Windows, qui coûte des FPS sur la plupart des PC."
    Apply='Set-Reg "HKCU:\System\GameConfigStore" GameDVR_Enabled 0; Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" AppCaptureEnabled 0; Set-Reg "HKCU:\Software\Microsoft\GameBar" UseNexusForGameBarEnabled 0; Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" AllowGameDVR 0'
    Revert='Set-Reg "HKCU:\System\GameConfigStore" GameDVR_Enabled 1; Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" AppCaptureEnabled 1; Set-Reg "HKCU:\Software\Microsoft\GameBar" UseNexusForGameBarEnabled 1; Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" AllowGameDVR'
    Check='(Get-Reg "HKCU:\System\GameConfigStore" GameDVR_Enabled) -eq 0' }

 @{ Id='hags'; Cat='Gaming'; Impact='MEDIUM'; Restart=$true; Rec=$false
    Name='Planification GPU accélérée (HAGS)'
    Desc="Laisse le GPU gérer sa propre file dʼattente : images plus régulières et moins de saccades sur les cartes récentes."
    Apply='Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" HwSchMode 2'
    Revert='Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" HwSchMode 1'
    Check='(Get-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" HwSchMode) -eq 2' }

 @{ Id='fgboost'; Cat='Système'; Impact='MEDIUM'; Restart=$false; Rec=$true
    Name='Priorité CPU au premier plan'
    Desc="Donne plus de temps processeur à la fenêtre active (ton jeu) quʼaux tâches en arrière-plan."
    Apply='Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" Win32PrioritySeparation 38'
    Revert='Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" Win32PrioritySeparation 2'
    Check='(Get-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" Win32PrioritySeparation) -eq 38' }

 @{ Id='ultimate'; Cat='Système'; Impact='HIGH'; Restart=$false; Rec=$true
    Name='Plan dʼalimentation performances maximales'
    Desc="Crée et active le plan « Velox Ultimate Performance » : le CPU ne baisse plus sa fréquence en plein jeu."
    Apply='Enable-VeloxPlan'
    Revert='Set-BalancedPlan'
    Check='Test-VeloxPlanActive' }

 @{ Id='visualfx'; Cat='Interface'; Impact='LOW'; Restart=$true; Rec=$false
    Name='Effets visuels : performances'
    Desc="Retire les animations et ombres du bureau pour libérer des ressources pour ton jeu."
    Apply='Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" VisualFXSetting 2; Set-Reg "HKCU:\Control Panel\Desktop" UserPreferencesMask ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) Binary'
    Revert='Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" VisualFXSetting 0; Set-Reg "HKCU:\Control Panel\Desktop" UserPreferencesMask ([byte[]](0x9E,0x1E,0x07,0x80,0x12,0x00,0x00,0x00)) Binary'
    Check='(Get-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" VisualFXSetting) -eq 2' }

 @{ Id='nagle'; Cat='Réseau'; Impact='HIGH'; Restart=$true; Rec=$false
    Name='Désactiver lʼalgorithme de Nagle'
    Desc="Windows nʼattend plus pour regrouper les petits paquets TCP : tes actions partent tout de suite."
    Apply='Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" | ForEach-Object { Set-Reg $_.PSPath TcpAckFrequency 1; Set-Reg $_.PSPath TCPNoDelay 1 }'
    Revert='Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" | ForEach-Object { Remove-Reg $_.PSPath TcpAckFrequency; Remove-Reg $_.PSPath TCPNoDelay }'
    Check='@(Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" | Where-Object { (Get-Reg $_.PSPath TCPNoDelay) -eq 1 }).Count -gt 0' }

 @{ Id='netthrottle'; Cat='Réseau'; Impact='HIGH'; Restart=$false; Rec=$true
    Name='Supprimer la limitation réseau'
    Desc="Enlève le bridage réseau multimédia de Windows et réserve plus de CPU aux applis au premier plan."
    Apply='Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" NetworkThrottlingIndex -1; Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" SystemResponsiveness 10'
    Revert='Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" NetworkThrottlingIndex 10; Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" SystemResponsiveness 20'
    Check='(Get-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" NetworkThrottlingIndex) -eq -1' }

 @{ Id='mouseaccel'; Cat='Gaming'; Impact='HIGH'; Restart=$true; Rec=$true
    Name='Désactiver lʼaccélération souris'
    Desc="Mouvement 1:1 : ta visée reste identique quelle que soit la vitesse de ta main. Actif après déconnexion."
    Apply='Set-Reg "HKCU:\Control Panel\Mouse" MouseSpeed "0" String; Set-Reg "HKCU:\Control Panel\Mouse" MouseThreshold1 "0" String; Set-Reg "HKCU:\Control Panel\Mouse" MouseThreshold2 "0" String'
    Revert='Set-Reg "HKCU:\Control Panel\Mouse" MouseSpeed "1" String; Set-Reg "HKCU:\Control Panel\Mouse" MouseThreshold1 "6" String; Set-Reg "HKCU:\Control Panel\Mouse" MouseThreshold2 "10" String'
    Check='(Get-Reg "HKCU:\Control Panel\Mouse" MouseSpeed) -eq "0"' }

 @{ Id='telemetry'; Cat='Confidentialité'; Impact='MEDIUM'; Restart=$false; Rec=$true
    Name='Désactiver la télémétrie'
    Desc="Coupe le service de collecte de données (DiagTrack) qui tourne en arrière-plan."
    Apply='Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" AllowTelemetry 0; Set-Svc DiagTrack Disabled'
    Revert='Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" AllowTelemetry; Set-Svc DiagTrack Automatic'
    Check='(Get-SvcStart DiagTrack) -eq "Disabled"' }

 @{ Id='adid'; Cat='Confidentialité'; Impact='LOW'; Restart=$false; Rec=$true
    Name='Désactiver lʼidentifiant publicitaire'
    Desc="Empêche les applis dʼutiliser ton identifiant publicitaire Windows pour te cibler."
    Apply='Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" Enabled 0'
    Revert='Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" Enabled 1'
    Check='(Get-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" Enabled) -eq 0' }

 @{ Id='bing'; Cat='Confidentialité'; Impact='LOW'; Restart=$true; Rec=$true
    Name='Retirer Bing de la recherche Démarrer'
    Desc="La recherche du menu Démarrer ne cherche plus sur le web : plus rapide et plus de pubs Bing."
    Apply='Set-Reg "HKCU:\Software\Policies\Microsoft\Windows\Explorer" DisableSearchBoxSuggestions 1; Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" BingSearchEnabled 0'
    Revert='Remove-Reg "HKCU:\Software\Policies\Microsoft\Windows\Explorer" DisableSearchBoxSuggestions; Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" BingSearchEnabled 1'
    Check='(Get-Reg "HKCU:\Software\Policies\Microsoft\Windows\Explorer" DisableSearchBoxSuggestions) -eq 1' }

 @{ Id='bgapps'; Cat='Système'; Impact='MEDIUM'; Restart=$false; Rec=$false
    Name='Bloquer les applis en arrière-plan'
    Desc="Les applis du Store ne tournent plus en fond : moins de RAM et de CPU utilisés."
    Apply='Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" GlobalUserDisabled 1; Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" LetAppsRunInBackground 2'
    Revert='Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" GlobalUserDisabled 0; Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" LetAppsRunInBackground'
    Check='(Get-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" LetAppsRunInBackground) -eq 2' }

 @{ Id='searchidx'; Cat='Système'; Impact='MEDIUM'; Restart=$false; Rec=$false
    Name='Désactiver lʼindexation Windows Search'
    Desc="Arrête lʼindexation des fichiers en fond (gros gain sur disque dur). La recherche de fichiers devient plus lente."
    Apply='Set-Svc WSearch Disabled'
    Revert='Set-Svc WSearch Delayed'
    Check='(Get-SvcStart WSearch) -eq "Disabled"' }

 @{ Id='sysmain'; Cat='Système'; Impact='MEDIUM'; Restart=$false; Rec=$false
    Name='Désactiver SysMain (Superfetch)'
    Desc="Stoppe le préchargement des applis en RAM. Utile sur SSD, à éviter si Windows est sur un disque dur."
    Apply='Set-Svc SysMain Disabled'
    Revert='Set-Svc SysMain Automatic'
    Check='(Get-SvcStart SysMain) -eq "Disabled"' }

 @{ Id='fso'; Cat='Gaming'; Impact='MEDIUM'; Restart=$false; Rec=$false
    Name='Désactiver les optimisations plein écran'
    Desc="Force le vrai plein écran exclusif dans les jeux : souvent moins de latence dʼaffichage."
    Apply='$k="HKCU:\System\GameConfigStore"; Set-Reg $k GameDVR_FSEBehaviorMode 2; Set-Reg $k GameDVR_FSEBehavior 2; Set-Reg $k GameDVR_HonorUserFSEBehaviorMode 1; Set-Reg $k GameDVR_DXGIHonorFSEWindowsCompatible 1'
    Revert='$k="HKCU:\System\GameConfigStore"; Set-Reg $k GameDVR_FSEBehaviorMode 0; Set-Reg $k GameDVR_FSEBehavior 0; Set-Reg $k GameDVR_HonorUserFSEBehaviorMode 0; Set-Reg $k GameDVR_DXGIHonorFSEWindowsCompatible 0'
    Check='(Get-Reg "HKCU:\System\GameConfigStore" GameDVR_FSEBehaviorMode) -eq 2' }

 @{ Id='gamesprio'; Cat='Gaming'; Impact='HIGH'; Restart=$false; Rec=$true
    Name='Priorité GPU/CPU pour les jeux'
    Desc="Le planificateur multimédia de Windows donne la priorité haute aux jeux plutôt quʼaux tâches de fond."
    Apply='$k="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"; Set-Reg $k "GPU Priority" 8; Set-Reg $k Priority 6; Set-Reg $k "Scheduling Category" "High" String; Set-Reg $k "SFIO Priority" "High" String'
    Revert='$k="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"; Set-Reg $k "GPU Priority" 8; Set-Reg $k Priority 2; Set-Reg $k "Scheduling Category" "Medium" String; Set-Reg $k "SFIO Priority" "Normal" String'
    Check='(Get-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" Priority) -eq 6' }

 @{ Id='gamemode'; Cat='Gaming'; Impact='MEDIUM'; Restart=$false; Rec=$true
    Name='Activer le Mode Jeu de Windows'
    Desc="Windows met en pause les mises à jour et tâches de fond quand un jeu est lancé."
    Apply='Set-Reg "HKCU:\Software\Microsoft\GameBar" AutoGameModeEnabled 1; Set-Reg "HKCU:\Software\Microsoft\GameBar" AllowAutoGameMode 1'
    Revert='Remove-Reg "HKCU:\Software\Microsoft\GameBar" AutoGameModeEnabled; Remove-Reg "HKCU:\Software\Microsoft\GameBar" AllowAutoGameMode'
    Check='(Get-Reg "HKCU:\Software\Microsoft\GameBar" AutoGameModeEnabled) -eq 1' }

 @{ Id='dynamictick'; Cat='Gaming'; Impact='MEDIUM'; Restart=$true; Rec=$false
    Name='Timer système plus précis'
    Desc="Désactive le « dynamic tick » : le timer Windows reste régulier, frametime plus stable."
    Apply='bcdedit /set disabledynamictick yes | Out-Null'
    Revert='bcdedit /deletevalue disabledynamictick | Out-Null'
    Check='(bcdedit /enum "{current}" | Out-String) -match "disabledynamictick"' }

 @{ Id='powerthrottle'; Cat='Système'; Impact='MEDIUM'; Restart=$true; Rec=$false
    Name='Désactiver le Power Throttling'
    Desc="Windows ne bride plus les processus quʼil juge « en arrière-plan ». Déconseillé sur portable sur batterie."
    Apply='Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" PowerThrottlingOff 1'
    Revert='Remove-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" PowerThrottlingOff'
    Check='(Get-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" PowerThrottlingOff) -eq 1' }

 @{ Id='hibernate'; Cat='Système'; Impact='LOW'; Restart=$false; Rec=$false
    Name='Désactiver lʼhibernation'
    Desc="Supprime hiberfil.sys (libère plusieurs Go sur C:) et désactive le démarrage rapide."
    Apply='powercfg /hibernate off'
    Revert='powercfg /hibernate on'
    Check='(Get-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Power" HibernateEnabled) -eq 0' }

 @{ Id='delivopt'; Cat='Réseau'; Impact='LOW'; Restart=$false; Rec=$true
    Name='Couper le partage P2P des mises à jour'
    Desc="Ton PC nʼenvoie plus de mises à jour Windows aux autres PC : ta bande passante reste pour toi."
    Apply='Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" DODownloadMode 0'
    Revert='Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" DODownloadMode'
    Check='(Get-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" DODownloadMode) -eq 0' }

 @{ Id='startupdelay'; Cat='Système'; Impact='LOW'; Restart=$false; Rec=$true
    Name='Supprimer le délai des applis au démarrage'
    Desc="Windows lance tout de suite les programmes de démarrage au lieu dʼattendre plusieurs secondes."
    Apply='Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" StartupDelayInMSec 0; Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" WaitForIdleState 0'
    Revert='Remove-Item "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" -Recurse -Force -ErrorAction SilentlyContinue'
    Check='(Get-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" StartupDelayInMSec) -eq 0' }

 @{ Id='menudelay'; Cat='Interface'; Impact='LOW'; Restart=$true; Rec=$true
    Name='Menus instantanés'
    Desc="Les menus et sous-menus sʼouvrent sans les 400 ms dʼattente par défaut."
    Apply='Set-Reg "HKCU:\Control Panel\Desktop" MenuShowDelay "0" String'
    Revert='Set-Reg "HKCU:\Control Panel\Desktop" MenuShowDelay "400" String'
    Check='(Get-Reg "HKCU:\Control Panel\Desktop" MenuShowDelay) -eq "0"' }

 @{ Id='notifs'; Cat='Interface'; Impact='LOW'; Restart=$false; Rec=$false
    Name='Couper les notifications'
    Desc="Plus de bannières ni de sons de notification qui te sortent de ta partie."
    Apply='Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications" ToastEnabled 0'
    Revert='Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications" ToastEnabled 1'
    Check='(Get-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications" ToastEnabled) -eq 0' }

 @{ Id='widgets'; Cat='Interface'; Impact='LOW'; Restart=$true; Rec=$false
    Name='Désactiver les Widgets / Actualités'
    Desc="Retire le panneau Widgets et ses processus qui consomment de la RAM en fond."
    Apply='Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" AllowNewsAndInterests 0'
    Revert='Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" AllowNewsAndInterests'
    Check='(Get-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" AllowNewsAndInterests) -eq 0' }

 @{ Id='transparency'; Cat='Interface'; Impact='LOW'; Restart=$false; Rec=$false
    Name='Désactiver la transparence'
    Desc="Supprime lʼeffet de flou transparent de la barre des tâches et des menus."
    Apply='Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" EnableTransparency 0'
    Revert='Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" EnableTransparency 1'
    Check='(Get-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" EnableTransparency) -eq 0' }

 @{ Id='stickykeys'; Cat='Gaming'; Impact='LOW'; Restart=$false; Rec=$true
    Name='Bloquer la popup des touches rémanentes'
    Desc="Appuyer 5 fois sur Maj en jeu nʼouvre plus la fenêtre des touches rémanentes."
    Apply='Set-Reg "HKCU:\Control Panel\Accessibility\StickyKeys" Flags "506" String'
    Revert='Set-Reg "HKCU:\Control Panel\Accessibility\StickyKeys" Flags "510" String'
    Check='(Get-Reg "HKCU:\Control Panel\Accessibility\StickyKeys" Flags) -eq "506"' }
 @{ Id='nicpower'; Cat='Réseau'; Impact='MEDIUM'; Restart=$true; Rec=$false
    Name='Carte réseau : couper lʼéconomie dʼénergie'
    Desc="Empêche Windows dʼendormir ta carte réseau et coupe Green Ethernet / EEE, qui peuvent causer des micro-coupures."
    Apply='Get-NetAdapter -Physical | Where-Object { $_.Status -eq "Up" } | ForEach-Object { $n = $_.Name; Disable-NetAdapterPowerManagement -Name $n -NoRestart -ErrorAction SilentlyContinue; foreach ($k in "*EEE", "EnableGreenEthernet", "AdvancedEEE", "PowerSavingMode", "GigaLite", "*SelectiveSuspend", "ULPMode", "EnablePME", "ReduceSpeedOnPowerDown") { Set-NetAdapterAdvancedProperty -Name $n -RegistryKeyword $k -RegistryValue 0 -NoRestart -ErrorAction SilentlyContinue } }; Set-Reg "HKLM:\SOFTWARE\VeloxTweaks" NicPower 1'
    Revert='Get-NetAdapter -Physical | ForEach-Object { $n = $_.Name; Enable-NetAdapterPowerManagement -Name $n -NoRestart -ErrorAction SilentlyContinue; foreach ($k in "*EEE", "EnableGreenEthernet", "AdvancedEEE", "PowerSavingMode", "GigaLite", "*SelectiveSuspend", "ULPMode", "EnablePME", "ReduceSpeedOnPowerDown") { Reset-NetAdapterAdvancedProperty -Name $n -RegistryKeyword $k -NoRestart -ErrorAction SilentlyContinue } }; Remove-Reg "HKLM:\SOFTWARE\VeloxTweaks" NicPower'
    Check='(Get-Reg "HKLM:\SOFTWARE\VeloxTweaks" NicPower) -eq 1' }

 @{ Id='intmod'; Cat='Réseau'; Impact='LOW'; Restart=$true; Rec=$false
    Name='Carte réseau : désactiver lʼinterrupt moderation'
    Desc="La carte traite chaque paquet tout de suite au lieu de les regrouper. Gain de latence minime, un peu plus de CPU utilisé."
    Apply='Get-NetAdapter -Physical | Where-Object { $_.Status -eq "Up" } | ForEach-Object { foreach ($k in "*InterruptModeration", "ITR") { Set-NetAdapterAdvancedProperty -Name $_.Name -RegistryKeyword $k -RegistryValue 0 -NoRestart -ErrorAction SilentlyContinue } }; Set-Reg "HKLM:\SOFTWARE\VeloxTweaks" IntMod 1'
    Revert='Get-NetAdapter -Physical | ForEach-Object { foreach ($k in "*InterruptModeration", "ITR") { Reset-NetAdapterAdvancedProperty -Name $_.Name -RegistryKeyword $k -NoRestart -ErrorAction SilentlyContinue } }; Remove-Reg "HKLM:\SOFTWARE\VeloxTweaks" IntMod'
    Check='(Get-Reg "HKLM:\SOFTWARE\VeloxTweaks" IntMod) -eq 1' }

 @{ Id='keyboard'; Cat='Gaming'; Impact='LOW'; Restart=$true; Rec=$true
    Name='Clavier : répétition plus rapide'
    Desc="Délai de répétition minimum et vitesse maximum, et bloque le raccourci des touches filtres (Maj droite maintenue)."
    Apply='Set-Reg "HKCU:\Control Panel\Keyboard" KeyboardDelay "0" String; Set-Reg "HKCU:\Control Panel\Keyboard" KeyboardSpeed "31" String; Set-Reg "HKCU:\Control Panel\Accessibility\Keyboard Response" Flags "122" String'
    Revert='Set-Reg "HKCU:\Control Panel\Keyboard" KeyboardDelay "1" String; Set-Reg "HKCU:\Control Panel\Keyboard" KeyboardSpeed "31" String; Set-Reg "HKCU:\Control Panel\Accessibility\Keyboard Response" Flags "126" String'
    Check='(Get-Reg "HKCU:\Control Panel\Keyboard" KeyboardDelay) -eq "0"' }

 @{ Id='services'; Cat='Système'; Impact='LOW'; Restart=$true; Rec=$false
    Name='Désactiver les services inutiles'
    Desc="Coupe Cartes hors-ligne, Mode démo, Rapports dʼerreurs, Assistant de compatibilité et le service push de télémétrie."
    Apply='foreach ($s in "MapsBroker", "RetailDemo", "WerSvc", "PcaSvc", "dmwappushservice") { Set-Svc $s Disabled }'
    Revert='foreach ($s in "MapsBroker", "RetailDemo", "WerSvc", "PcaSvc", "dmwappushservice") { Set-Svc $s Manual }'
    Check='(Get-SvcStart MapsBroker) -eq "Disabled"' }

 @{ Id='contextmenu'; Cat='Interface'; Impact='LOW'; Restart=$true; Rec=$false
    Name='Ancien menu clic droit (Windows 10)'
    Desc="Le clic droit affiche directement toutes les options, sans passer par « Afficher plus dʼoptions »."
    Apply='New-Item -Path "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" -Value "" -Force | Out-Null'
    Revert='Remove-Item -Path "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}" -Recurse -Force -ErrorAction SilentlyContinue'
    Check='Test-Path "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"' }

 @{ Id='copilot'; Cat='Confidentialité'; Impact='LOW'; Restart=$true; Rec=$false
    Name='Désactiver Copilot et Recall (IA Windows)'
    Desc="Coupe Copilot et les captures dʼécran automatiques de Recall, via les réglages officiels de Windows."
    Apply='Set-Reg "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" TurnOffWindowsCopilot 1; Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" DisableAIDataAnalysis 1; Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" ShowCopilotButton 0'
    Revert='Remove-Reg "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" TurnOffWindowsCopilot; Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" DisableAIDataAnalysis; Remove-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" ShowCopilotButton'
    Check='(Get-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" DisableAIDataAnalysis) -eq 1' }

 @{ Id='startclean'; Cat='Interface'; Impact='LOW'; Restart=$true; Rec=$true
    Name='Menu Démarrer sans pubs ni suggestions'
    Desc="Plus dʼapplis installées toutes seules, de « suggestions » ni de pubs Microsoft dans Démarrer et Paramètres."
    Apply='$k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; foreach ($v in "SystemPaneSuggestionsEnabled", "SilentInstalledAppsEnabled", "SoftLandingEnabled", "SubscribedContent-310093Enabled", "SubscribedContent-338388Enabled", "SubscribedContent-338389Enabled", "SubscribedContent-353694Enabled", "SubscribedContent-353696Enabled") { Set-Reg $k $v 0 }; Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" Start_IrisRecommendations 0; Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" DisableWindowsConsumerFeatures 1'
    Revert='$k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; foreach ($v in "SystemPaneSuggestionsEnabled", "SilentInstalledAppsEnabled", "SoftLandingEnabled", "SubscribedContent-310093Enabled", "SubscribedContent-338388Enabled", "SubscribedContent-338389Enabled", "SubscribedContent-353694Enabled", "SubscribedContent-353696Enabled") { Set-Reg $k $v 1 }; Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" Start_IrisRecommendations 1; Remove-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" DisableWindowsConsumerFeatures'
    Check='(Get-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" SilentInstalledAppsEnabled) -eq 0' }
)
foreach ($t in $Tweaks) {
    $t.CheckSb = [scriptblock]::Create($t.Check)
    $t.Steps   = @($t.Apply -split '[;\n]' | Where-Object { $_.Trim() }).Count
    $t.Active  = $false
}
function Get-Tweak([string]$Id) { $Tweaks | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }

# --- Fenêtre principale (XAML) ----------------------------------------------
$XamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Velox Tweaks" Width="1300" Height="820" MinWidth="1050" MinHeight="640"
        Background="#070B14" Foreground="#E6EAF2" FontFamily="Segoe UI"
        WindowStartupLocation="CenterScreen" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Margin" Value="0,0,0,4"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" CornerRadius="8" Padding="12,8">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#0F1628"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#101B33"/>
                <Setter TargetName="b" Property="BorderBrush" Value="#24406F"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Background" Value="#2D7BFF"/>
      <Setter Property="BorderBrush" Value="#2D7BFF"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Ghost" TargetType="Button" BasedOn="{StaticResource Primary}">
      <Setter Property="Background" Value="#0E1424"/>
      <Setter Property="BorderBrush" Value="#262F45"/>
      <Setter Property="Foreground" Value="#E6EAF2"/>
    </Style>
    <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource Primary}">
      <Setter Property="Background" Value="#1A0E14"/>
      <Setter Property="BorderBrush" Value="#5C2030"/>
      <Setter Property="Foreground" Value="#F87171"/>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#AEB6C6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="box" Width="18" Height="18" CornerRadius="5" BorderThickness="1.5" BorderBrush="#3A4560" Background="#0A0F1C" VerticalAlignment="Center">
                <Path x:Name="tick" Data="M3.5,8 L6.5,11 L12,4.5" Stroke="White" StrokeThickness="2" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="#2D7BFF"/>
                <Setter TargetName="box" Property="BorderBrush" Value="#2D7BFF"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb"><Border Background="#26304A" CornerRadius="4"/></ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="240"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <Border Background="#0A0F1C" BorderBrush="#141B2C" BorderThickness="0,0,1,0">
      <DockPanel Margin="16,22,16,16">
        <StackPanel DockPanel.Dock="Top" Margin="8,0,0,26">
          <TextBlock FontSize="21" FontWeight="Black"><Run Text="VELOX"/><Run Text="." Foreground="#2D7BFF"/></TextBlock>
          <TextBlock Text="T W E A K S" FontSize="9.5" Foreground="#6B7488" Margin="1,0,0,0"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom">
          <Border x:Name="BusyPill" Background="#0F2A1C" BorderBrush="#1D4D32" BorderThickness="1" CornerRadius="12" Padding="10,6" Margin="0,0,0,10">
            <TextBlock x:Name="BusyText" Text="Prêt" Foreground="#4ADE80" FontSize="11" HorizontalAlignment="Center" TextTrimming="CharacterEllipsis"/>
          </Border>
          <TextBlock x:Name="AdminText" Text="Administrateur" Foreground="#2D7BFF" FontSize="10.5" Margin="4,0,0,2"/>
          <TextBlock x:Name="VersionText" Text="Velox Tweaks" Foreground="#6B7488" FontSize="10.5" Margin="4,0,0,0"/>
        </StackPanel>
        <StackPanel>
          <RadioButton x:Name="NavDashboard" Tag="dashboard" GroupName="nav" Style="{StaticResource Nav}">
            <StackPanel><TextBlock Text="Dashboard" FontSize="13" FontWeight="SemiBold" Foreground="#E6EAF2"/><TextBlock Text="Vue dʼensemble &amp; optimisation" FontSize="10.5" Foreground="#6B7488" Margin="0,2,0,0"/></StackPanel>
          </RadioButton>
          <RadioButton x:Name="NavTweaks" Tag="tweaks" GroupName="nav" Style="{StaticResource Nav}">
            <StackPanel><TextBlock Text="Tweaks" FontSize="13" FontWeight="SemiBold" Foreground="#E6EAF2"/><TextBlock Text="Tous les réglages au même endroit" FontSize="10.5" Foreground="#6B7488" Margin="0,2,0,0"/></StackPanel>
          </RadioButton>
          <RadioButton x:Name="NavMaintenance" Tag="maintenance" GroupName="nav" Style="{StaticResource Nav}">
            <StackPanel><TextBlock Text="Maintenance" FontSize="13" FontWeight="SemiBold" Foreground="#E6EAF2"/><TextBlock Text="Nettoyage, DNS, TRIM" FontSize="10.5" Foreground="#6B7488" Margin="0,2,0,0"/></StackPanel>
          </RadioButton>
          <RadioButton x:Name="NavBackup" Tag="backup" GroupName="nav" Style="{StaticResource Nav}">
            <StackPanel><TextBlock Text="Sauvegarde" FontSize="13" FontWeight="SemiBold" Foreground="#E6EAF2"/><TextBlock Text="Restauration &amp; exports registre" FontSize="10.5" Foreground="#6B7488" Margin="0,2,0,0"/></StackPanel>
          </RadioButton>
          <RadioButton x:Name="NavFixes" Tag="fixes" GroupName="nav" Style="{StaticResource Nav}">
            <StackPanel><TextBlock Text="Réparations" FontSize="13" FontWeight="SemiBold" Foreground="#E6EAF2"/><TextBlock Text="Correctifs en un clic" FontSize="10.5" Foreground="#6B7488" Margin="0,2,0,0"/></StackPanel>
          </RadioButton>
          <RadioButton x:Name="NavMonitor" Tag="monitor" GroupName="nav" Style="{StaticResource Nav}">
            <StackPanel><TextBlock Text="Moniteur" FontSize="13" FontWeight="SemiBold" Foreground="#E6EAF2"/><TextBlock Text="CPU, GPU &amp; températures" FontSize="10.5" Foreground="#6B7488" Margin="0,2,0,0"/></StackPanel>
          </RadioButton>
          <RadioButton x:Name="NavStartup" Tag="startup" GroupName="nav" Style="{StaticResource Nav}">
            <StackPanel><TextBlock Text="Démarrage" FontSize="13" FontWeight="SemiBold" Foreground="#E6EAF2"/><TextBlock Text="Applis lancées avec Windows" FontSize="10.5" Foreground="#6B7488" Margin="0,2,0,0"/></StackPanel>
          </RadioButton>
          <RadioButton x:Name="NavTools" Tag="tools" GroupName="nav" Style="{StaticResource Nav}">
            <StackPanel><TextBlock Text="Outils gaming" FontSize="13" FontWeight="SemiBold" Foreground="#E6EAF2"/><TextBlock Text="Sensi, ping &amp; check-up" FontSize="10.5" Foreground="#6B7488" Margin="0,2,0,0"/></StackPanel>
          </RadioButton>
          <RadioButton x:Name="NavGame" Tag="gamemode" GroupName="nav" Style="{StaticResource Nav}">
            <StackPanel><TextBlock Text="Velox Game Mode" FontSize="13" FontWeight="SemiBold" Foreground="#E6EAF2"/><TextBlock Text="Plan performances ultime" FontSize="10.5" Foreground="#6B7488" Margin="0,2,0,0"/></StackPanel>
          </RadioButton>
          <RadioButton x:Name="NavSettings" Tag="settings" GroupName="nav" Style="{StaticResource Nav}">
            <StackPanel><TextBlock Text="Paramètres" FontSize="13" FontWeight="SemiBold" Foreground="#E6EAF2"/><TextBlock Text="Arrière-plan, couleur, à propos" FontSize="10.5" Foreground="#6B7488" Margin="0,2,0,0"/></StackPanel>
          </RadioButton>
        </StackPanel>
      </DockPanel>
    </Border>

    <ScrollViewer Grid.Column="1" x:Name="MainScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel x:Name="PageHost" Margin="30,24,30,28"/>
    </ScrollViewer>
  </Grid>
</Window>
'@
[xml]$Xaml = $XamlText.Replace('#2D7BFF', $Accent).Replace('#24406F', $AccentMid).Replace('#101B33', $AccentDark)
$Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $Xaml))
try { $icoFile = Join-Path $ScriptDir 'build\velox.ico'; if (Test-Path $icoFile) { $Window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$icoFile) } } catch {}
function UI([string]$Name) { $Window.FindName($Name) }
$BusyPill = UI 'BusyPill'; $BusyText = UI 'BusyText'; $PageHost = UI 'PageHost'
(UI 'VersionText').Text = "Velox Tweaks $AppVersion"
(UI 'AdminText').Text = "$env:USERNAME · administrateur"

# --- Petites fonctions de construction d'interface ---------------------------
$BrushConv = New-Object Windows.Media.BrushConverter
$ThickConv = New-Object Windows.ThicknessConverter
function Br([string]$Hex) { $BrushConv.ConvertFromInvariantString($Hex) }
function Th([string]$Value) { $ThickConv.ConvertFromInvariantString($Value) }

function New-Text([string]$Text, [double]$Size = 12, [string]$Color = '#E6EAF2', [string]$Weight = 'Normal', [string]$Margin = '0') {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = Br $Color
    $t.FontWeight = [Windows.FontWeights]::$Weight
    $t.TextWrapping = 'Wrap'; $t.Margin = Th $Margin
    $t
}
function New-Tag([string]$Text, [string]$Fg, [string]$Bg) {
    $b = New-Object Windows.Controls.Border
    $b.Background = Br $Bg; $b.CornerRadius = [Windows.CornerRadius]::new(4)
    $b.Padding = Th '6,2,6,2'; $b.Margin = Th '0,0,6,0'
    $b.Child = New-Text $Text 9.5 $Fg 'SemiBold'
    $b
}
function New-Button([string]$Text, [string]$Style = 'Primary') {
    $b = New-Object Windows.Controls.Button
    $b.Content = $Text; $b.Style = $Window.FindResource($Style)
    $b
}
function New-Panel([string]$Title, [string]$Subtitle, $Content, $Right = $null) {
    $border = New-Object Windows.Controls.Border
    $border.Background = Br '#0B1120'; $border.BorderBrush = Br '#161E30'; $border.BorderThickness = Th '1'
    $border.CornerRadius = [Windows.CornerRadius]::new(12); $border.Padding = Th '18,16,18,16'; $border.Margin = Th '0,0,0,16'
    $sp = New-Object Windows.Controls.StackPanel
    $head = New-Object Windows.Controls.DockPanel; $head.Margin = Th '0,0,0,12'
    if ($null -ne $Right) { [Windows.Controls.DockPanel]::SetDock($Right, 'Right'); [void]$head.Children.Add($Right) }
    $titles = New-Object Windows.Controls.StackPanel
    [void]$titles.Children.Add((New-Text $Title 14 '#E6EAF2' 'SemiBold'))
    if ($Subtitle) { [void]$titles.Children.Add((New-Text $Subtitle 11 '#7D879B' 'Normal' '0,3,0,0')) }
    [void]$head.Children.Add($titles)
    [void]$sp.Children.Add($head)
    if ($null -ne $Content) { [void]$sp.Children.Add($Content) }
    $border.Child = $sp
    $border
}
function New-Grid([int]$Columns = 2) {
    $g = New-Object Windows.Controls.Primitives.UniformGrid
    $g.Columns = $Columns; $g.Margin = Th '-5,0,-5,0'
    $g
}
function New-Card {
    $c = New-Object Windows.Controls.Border
    $c.Background = Br '#0E1424'; $c.BorderBrush = Br '#1A2236'; $c.BorderThickness = Th '1'
    $c.CornerRadius = [Windows.CornerRadius]::new(10); $c.Padding = Th '14,12,14,12'; $c.Margin = Th '5'
    $c
}
function New-StatTile([string]$Label, [string]$Value, [string]$Sub) {
    $c = New-Card
    $sp = New-Object Windows.Controls.StackPanel
    [void]$sp.Children.Add((New-Text $Label.ToUpper() 9.5 '#7D879B' 'SemiBold'))
    $v = New-Text $Value 22 '#FFFFFF' 'Bold' '0,6,0,2'
    $s = New-Text $Sub 10.5 '#6B7488'
    [void]$sp.Children.Add($v); [void]$sp.Children.Add($s)
    $c.Child = $sp
    @{ Card = $c; Value = $v; Sub = $s }
}
function Get-ImpactTag([string]$Impact) {
    switch ($Impact) {
        'HIGH'   { New-Tag 'IMPACT ÉLEVÉ' '#4ADE80' '#0D2A1B' }
        'MEDIUM' { New-Tag 'IMPACT MOYEN' '#60A5FA' '#0F2140' }
        default  { New-Tag 'IMPACT FAIBLE' '#9AA3B5' '#1A2030' }
    }
}

# --- Journal d'activité --------------------------------------------------------
$Log = New-Object System.Collections.ObjectModel.ObservableCollection[string]
function Add-Log([string]$Text) {
    $line = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $Text
    $Log.Insert(0, $line)
    while ($Log.Count -gt 300) { $Log.RemoveAt($Log.Count - 1) }
    try { Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd'), $line) -Encoding UTF8 } catch {}
}
$LogTemplate = [Windows.Markup.XamlReader]::Parse(@'
<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <DockPanel Margin="0,3">
    <Ellipse Width="6" Height="6" Fill="#F5B83D" Margin="0,0,10,0" VerticalAlignment="Center" DockPanel.Dock="Left"/>
    <TextBlock Text="{Binding}" Foreground="#AEB6C6" FontSize="11.5" TextWrapping="Wrap"/>
  </DockPanel>
</DataTemplate>
'@)
function New-ActivityPanel([string]$Title) {
    $ic = New-Object Windows.Controls.ItemsControl
    $ic.ItemsSource = $Log; $ic.ItemTemplate = $LogTemplate
    $sv = New-Object Windows.Controls.ScrollViewer
    $sv.MaxHeight = 190; $sv.VerticalScrollBarVisibility = 'Auto'; $sv.Content = $ic
    New-Panel $Title '' $sv
}

# --- Exécution des tâches en arrière-plan --------------------------------------
$script:Job = $null
$Prelude = "`$BackupRoot = '" + ($BackupRoot -replace "'", "''") + "'`n" + $Helpers

function Set-Busy([bool]$Busy, [string]$Text = '') {
    if ($Busy) {
        $BusyPill.Background = Br '#2A1F0A'; $BusyPill.BorderBrush = Br '#5A4210'
        $BusyText.Foreground = Br '#F5B83D'; $BusyText.Text = $Text
    } else {
        $BusyPill.Background = Br '#0F2A1C'; $BusyPill.BorderBrush = Br '#1D4D32'
        $BusyText.Foreground = Br '#4ADE80'; $BusyText.Text = 'Prêt'
    }
}

function Start-Task([string]$Title, [string]$Code, [bool]$Restart = $false, [scriptblock]$OnDone = $null) {
    if ($script:Job) {
        [void][Windows.MessageBox]::Show("Une tâche est déjà en cours : « $($script:Job.Title) ».`nAttends quʼelle se termine.", 'Velox Tweaks', 'OK', 'Information')
        return
    }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($Prelude + "`n" + $Code)
    $script:Job = @{ PS = $ps; Handle = $ps.BeginInvoke(); Title = $Title; Restart = $Restart; Start = Get-Date; OnDone = $OnDone }
    Set-Busy $true "$Title…"
    Add-Log "$Title : démarré"
}

function Update-Job {
    $j = $script:Job
    if (-not $j) { return }
    if (-not $j.Handle.IsCompleted) {
        $sec = [int]((Get-Date) - $j.Start).TotalSeconds
        $BusyText.Text = "$($j.Title)… ${sec}s"
        return
    }
    $ok = $true
    $lines = @()
    try {
        $out = $j.PS.EndInvoke($j.Handle)
        $lines = @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        foreach ($l in ($lines | Select-Object -First 25)) { Add-Log "   $l" }
        if ($lines.Count -gt 25) { Add-Log "   … ($($lines.Count - 25) lignes de plus)" }
    } catch {
        $ok = $false
        Add-Log "   Erreur : $($_.Exception.Message)"
    }
    $errs = @($j.PS.Streams.Error)
    foreach ($e in ($errs | Select-Object -First 4)) { Add-Log "   Avertissement : $($e.Exception.Message)" }
    $j.PS.Dispose()
    $script:Job = $null
    Set-Busy $false
    Add-Log ("{0} : {1}" -f $j.Title, $(if ($ok) { 'terminé' } else { 'échec' }))
    Update-Status
    try { if ($script:CheckupShown -and $Pages['tools'].Visibility -eq 'Visible') { Invoke-Checkup } else { Update-Score } } catch {}
    if ($j.OnDone) { try { & $j.OnDone $lines } catch {} }
    if ($j.Restart) {
        $r = [Windows.MessageBox]::Show("« $($j.Title) » nécessite un redémarrage pour être pris en compte.`n`nRedémarrer maintenant ?", 'Velox Tweaks', 'YesNo', 'Question')
        if ($r -eq 'Yes') { Restart-Computer -Force }
    }
}

function Confirm-Action([string]$Text) {
    ([Windows.MessageBox]::Show($Text, 'Velox Tweaks', 'YesNo', 'Warning')) -eq 'Yes'
}

function Invoke-Tweaks([array]$List, [bool]$Revert, [string]$Title, [bool]$WithRestorePoint, [string]$Extra = '', [bool]$ForceRestart = $false) {
    if (-not $List -or $List.Count -eq 0) { Add-Log 'Aucun tweak sélectionné.'; return }
    $sb = New-Object Text.StringBuilder
    if ($WithRestorePoint) { [void]$sb.AppendLine($RestoreCode) }
    foreach ($t in $List) {
        $code = if ($Revert) { $t.Revert } else { $t.Apply }
        $n = $t.Name -replace "'", "''"
        [void]$sb.AppendLine("try {`n`$ErrorActionPreference = 'Stop'`n$code`n'OK : $n' } catch { 'ÉCHEC : $n - ' + `$_.Exception.Message } finally { `$ErrorActionPreference = 'Continue' }")
    }
    if ($Extra) { [void]$sb.AppendLine($Extra) }
    $needRestart = $ForceRestart -or (@($List | Where-Object { $_.Restart }).Count -gt 0)
    Start-Task $Title $sb.ToString() $needRestart
}

# Bouton d'action générique : Tag = @{ Title; Code; Restart; Confirm; Local }
function Invoke-ActionTag($a) {
    if ($a.Confirm -and -not (Confirm-Action $a.Confirm)) { return }
    if ($a.Local) { & $a.Local; return }
    Start-Task $a.Title $a.Code ([bool]$a.Restart)
}
function New-ActionCard([string]$Title, [string]$Desc, [int]$Steps, [string]$BtnText, [hashtable]$Action, [bool]$Restart = $false) {
    $c = New-Card
    $g = New-Object Windows.Controls.Grid
    $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = [Windows.GridLength]::new(1, 'Star')
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = [Windows.GridLength]::Auto
    $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1)
    $sp = New-Object Windows.Controls.StackPanel; $sp.Margin = Th '0,0,14,0'
    [void]$sp.Children.Add((New-Text $Title 13 '#E6EAF2' 'SemiBold'))
    [void]$sp.Children.Add((New-Text $Desc 11.2 '#8A93A6' 'Normal' '0,4,0,8'))
    $tags = New-Object Windows.Controls.WrapPanel
    [void]$tags.Children.Add((New-Tag ("{0} ÉTAPE{1}" -f $Steps, $(if ($Steps -gt 1) { 'S' } else { '' })) '#9AA3B5' '#1A2030'))
    if ($Restart) { [void]$tags.Children.Add((New-Tag 'REDÉMARRAGE' '#F5B83D' '#2A1F0A')) }
    [void]$sp.Children.Add($tags)
    [void]$g.Children.Add($sp)
    $btn = New-Button $BtnText 'Primary'
    $btn.VerticalAlignment = 'Center'; $btn.MinWidth = 78
    $Action.Restart = $Restart
    $btn.Tag = $Action
    $btn.Add_Click({ Invoke-ActionTag $this.Tag })
    [Windows.Controls.Grid]::SetColumn($btn, 1)
    [void]$g.Children.Add($btn)
    $c.Child = $g
    $c
}

# --- Pages ---------------------------------------------------------------------
$Pages = @{}
function New-Page([string]$Key, [string]$Title, [string]$Subtitle) {
    $p = New-Object Windows.Controls.StackPanel
    [void]$p.Children.Add((New-Text $Title 24 '#FFFFFF' 'Bold'))
    [void]$p.Children.Add((New-Text $Subtitle 12 '#7D879B' 'Normal' '0,2,0,20'))
    $p.Visibility = 'Collapsed'
    [void]$PageHost.Children.Add($p)
    $Pages[$Key] = $p
    $p
}
function Show-Page([string]$Key) {
    foreach ($k in $Pages.Keys) { $Pages[$k].Visibility = $(if ($k -eq $Key) { 'Visible' } else { 'Collapsed' }) }
    (UI 'MainScroll').ScrollToTop()
    if ($Key -eq 'monitor') { Start-Monitor } elseif (Get-Command Stop-Monitor -ErrorAction SilentlyContinue) { Stop-Monitor }
    if ($Key -eq 'startup') { Show-StartupItems }
}

# ===== DASHBOARD =====
$pg = New-Page 'dashboard' 'Dashboard' 'Vue dʼensemble de ton PC et optimisation en un clic'
$stats = New-Grid 4
$TileActive = New-StatTile 'Tweaks actifs' '0' ''
$TileAvail  = New-StatTile 'Tweaks disponibles' "$($Tweaks.Count)" 'dans le catalogue'
$TileRam    = New-StatTile 'RAM libre' '…' ''
$TileUptime = New-StatTile 'Allumé depuis' '…' 'depuis le dernier démarrage'
foreach ($t in $TileActive, $TileAvail, $TileRam, $TileUptime) { [void]$stats.Children.Add($t.Card) }
$stats.Margin = Th '-5,0,-5,16'
[void]$pg.Children.Add($stats)

$oneRow = New-Object Windows.Controls.WrapPanel
$bOpt = New-Button '⚡  BOOSTER MON PC' 'Primary'; $bOpt.Padding = Th '22,10'; $bOpt.FontSize = 13.5; $bOpt.Margin = Th '0,0,10,0'
$bRp  = New-Button 'Créer un point de restauration' 'Ghost'; $bRp.Padding = Th '14,9'; $bRp.Margin = Th '0,0,10,0'
$bRev = New-Button 'Tout annuler' 'Danger'; $bRev.Padding = Th '14,9'
foreach ($b in $bOpt, $bRp, $bRev) { [void]$oneRow.Children.Add($b) }
$recNames = ($Tweaks | Where-Object { $_.Rec } | ForEach-Object { $_.Name }) -join "`n • "
$BoostIds = @('hags', 'nicpower', 'nagle', 'dynamictick')
function Invoke-Booster {
    $boost = @($Tweaks | Where-Object { $_.Rec -or ($BoostIds -contains $_.Id) })
    $names = ($boost | ForEach-Object { $_.Name }) -join "`n • "
    $msg = "Le BOOSTER va appliquer {0} réglages + le Velox Game Mode :`n`n • {1}`n`nUn point de restauration est créé avant. Un redémarrage est nécessaire à la fin.`nSur un portable, la batterie se videra plus vite." -f $boost.Count, $names
    if (Confirm-Action $msg) {
        Invoke-Tweaks $boost $false 'BOOSTER' $true $GameModeCode $true
    }
}
$bOpt.Add_Click({ Invoke-Booster })
$bRp.Add_Click({ Start-Task 'Point de restauration' $RestoreCode })
$bRev.Add_Click({ Invoke-RevertAll })
[void]$pg.Children.Add((New-Panel 'Booster en un clic' 'Applique tous les meilleurs réglages dʼun coup (FPS, latence, réseau, souris, clavier, plan performances), même ceux qui demandent un redémarrage.' $oneRow))

# Score d'optimisation
$scoreGrid = New-Object Windows.Controls.Grid
$sc0 = New-Object Windows.Controls.ColumnDefinition; $sc0.Width = [Windows.GridLength]::new(170)
$sc1 = New-Object Windows.Controls.ColumnDefinition; $sc1.Width = [Windows.GridLength]::new(1, 'Star')
$scoreGrid.ColumnDefinitions.Add($sc0); $scoreGrid.ColumnDefinitions.Add($sc1)
$scoreLeft = New-Object Windows.Controls.StackPanel
$ScoreBig = New-Text '…' 42 '#FFFFFF' 'Bold'
$ScoreLbl = New-Text 'Calcul en cours…' 12 '#7D879B'
[void]$scoreLeft.Children.Add($ScoreBig); [void]$scoreLeft.Children.Add($ScoreLbl)
[void]$scoreGrid.Children.Add($scoreLeft)
$ScoreMissing = New-Object Windows.Controls.StackPanel; $ScoreMissing.VerticalAlignment = 'Center'
[Windows.Controls.Grid]::SetColumn($ScoreMissing, 1); [void]$scoreGrid.Children.Add($ScoreMissing)
$bScoreGo = New-Button 'Voir le check-up' 'Ghost'
$bScoreGo.Add_Click({ (UI 'NavTools').IsChecked = $true; Invoke-Checkup })
[void]$pg.Children.Add((New-Panel 'Score dʼoptimisation' 'Note sur 100 : les réglages Velox + ce qui compte vraiment (écran, RAM, réseau, pilote, démarrage).' $scoreGrid $bScoreGo))

# Infos système
$sys = New-Grid 4; $sys.Margin = Th '-5,0,-5,16'
try {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Virtual|Remote' } | Select-Object -First 1
    $cs  = Get-CimInstance Win32_ComputerSystem
    $BootTime = $os.LastBootUpTime
    $TotalRamGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    $info = @(
        @('Processeur', $cpu.Name.Trim(), "$($cpu.NumberOfCores) cœurs · $($cpu.NumberOfLogicalProcessors) threads"),
        @('Carte graphique', $(if ($gpu) { $gpu.Name } else { 'Inconnue' }), $(if ($gpu) { "Pilote $($gpu.DriverVersion)" } else { '' })),
        @('Mémoire', "$TotalRamGB Go", 'RAM installée'),
        @('Système', ($os.Caption -replace 'Microsoft ', ''), "Build $($os.BuildNumber)")
    )
} catch {
    $BootTime = Get-Date; $TotalRamGB = 0
    $info = @(@('Système', 'Infos indisponibles', ''))
}
foreach ($i in $info) {
    $tile = New-StatTile $i[0] $i[1] $i[2]
    $tile.Value.FontSize = 13.5; $tile.Value.FontWeight = [Windows.FontWeights]::SemiBold
    [void]$sys.Children.Add($tile.Card)
}
[void]$pg.Children.Add($sys)
[void]$pg.Children.Add((New-ActivityPanel 'Activité'))

# ===== TWEAKS =====
$pg = New-Page 'tweaks' 'Tweaks' 'Tous les réglages au même endroit. Coche, puis applique.'
$TweakHeader = New-Text '' 11 '#7D879B'
$headRight = New-Object Windows.Controls.StackPanel; $headRight.Orientation = 'Horizontal'
$bAll = New-Button 'Tout sélectionner' 'Ghost'; $bAll.Margin = Th '0,0,6,0'
$bNone = New-Button 'Effacer' 'Ghost'; $bNone.Margin = Th '0,0,6,0'
$bRevSel = New-Button 'Annuler la sélection' 'Danger'; $bRevSel.Margin = Th '0,0,6,0'
$bApplySel = New-Button 'Appliquer la sélection' 'Primary'
foreach ($b in $bAll, $bNone, $bRevSel, $bApplySel) { [void]$headRight.Children.Add($b) }

$tweakBody = New-Object Windows.Controls.StackPanel
$filterRow = New-Object Windows.Controls.DockPanel; $filterRow.Margin = Th '0,0,0,10'
$RestoreCb = New-Object Windows.Controls.CheckBox
$RestoreCb.Content = 'Point de restauration avant dʼappliquer'; $RestoreCb.IsChecked = $true; $RestoreCb.FontSize = 11.5
[Windows.Controls.DockPanel]::SetDock($RestoreCb, 'Right')
[void]$filterRow.Children.Add($RestoreCb)
$filters = New-Object Windows.Controls.WrapPanel
$FilterButtons = @()
foreach ($cat in 'Tous', 'Gaming', 'Réseau', 'Système', 'Confidentialité', 'Interface') {
    $fb = New-Button $cat 'Ghost'; $fb.Padding = Th '12,5'; $fb.Margin = Th '0,0,6,0'; $fb.FontSize = 11.5; $fb.Tag = $cat
    $fb.Add_Click({ Set-Filter $this.Tag })
    [void]$filters.Children.Add($fb); $FilterButtons += $fb
}
[void]$filterRow.Children.Add($filters)
[void]$tweakBody.Children.Add($filterRow)

$TweakGrid = New-Grid 2
foreach ($t in $Tweaks) {
    $card = New-Card; $card.Cursor = [Windows.Input.Cursors]::Hand
    $g = New-Object Windows.Controls.Grid
    $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = [Windows.GridLength]::Auto
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = [Windows.GridLength]::new(1, 'Star')
    $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1)
    $cb = New-Object Windows.Controls.CheckBox; $cb.VerticalAlignment = 'Top'; $cb.Margin = Th '0,1,12,0'
    $cb.Tag = $t
    [void]$g.Children.Add($cb)
    $sp = New-Object Windows.Controls.StackPanel
    [void]$sp.Children.Add((New-Text $t.Name 13 '#E6EAF2' 'SemiBold'))
    [void]$sp.Children.Add((New-Text $t.Desc 11.2 '#8A93A6' 'Normal' '0,4,0,8'))
    $tags = New-Object Windows.Controls.WrapPanel
    $activeTag = New-Tag '● ACTIF' '#4ADE80' '#0D2A1B'; $activeTag.Visibility = 'Collapsed'
    [void]$tags.Children.Add($activeTag)
    [void]$tags.Children.Add((Get-ImpactTag $t.Impact))
    [void]$tags.Children.Add((New-Tag ("{0} ÉTAPE{1}" -f $t.Steps, $(if ($t.Steps -gt 1) { 'S' } else { '' })) '#9AA3B5' '#1A2030'))
    if ($t.Restart) { [void]$tags.Children.Add((New-Tag 'REDÉMARRAGE' '#F5B83D' '#2A1F0A')) }
    if ($t.Rec) { [void]$tags.Children.Add((New-Tag 'RECOMMANDÉ' '#A78BFA' '#1E1838')) }
    [void]$sp.Children.Add($tags)
    [Windows.Controls.Grid]::SetColumn($sp, 1)
    [void]$g.Children.Add($sp)
    $card.Child = $g
    $card.Tag = $cb
    $card.Add_MouseLeftButtonUp({ $this.Tag.IsChecked = -not $this.Tag.IsChecked })
    $cb.Add_Checked({ Update-CardLook $this.Tag; Update-TweakHeader })
    $cb.Add_Unchecked({ Update-CardLook $this.Tag; Update-TweakHeader })
    $t.Card = $card; $t.CheckBox = $cb; $t.ActiveTag = $activeTag
    [void]$TweakGrid.Children.Add($card)
}
[void]$tweakBody.Children.Add($TweakGrid)
$tweakPanel = New-Panel 'Tous les tweaks' '' $tweakBody $headRight
[void]$pg.Children.Add($tweakPanel)
$TweakHeader.Margin = Th '0,3,0,0'
[void]$tweakPanel.Child.Children[0].Children[1].Children.Add($TweakHeader)

function Update-CardLook($t) {
    if ($t.CheckBox.IsChecked) { $t.Card.Background = Br $AccentDark; $t.Card.BorderBrush = Br $AccentMid }
    else { $t.Card.Background = Br '#0E1424'; $t.Card.BorderBrush = Br '#1A2236' }
}
function Get-Selected { @($Tweaks | Where-Object { $_.CheckBox.IsChecked }) }
function Update-TweakHeader {
    $sel = (Get-Selected).Count
    $act = @($Tweaks | Where-Object { $_.Active }).Count
    $TweakHeader.Text = "$($Tweaks.Count) tweaks · $sel sélectionné(s) · $act actif(s)"
}
function Set-Filter([string]$Cat) {
    foreach ($fb in $FilterButtons) {
        if ($fb.Tag -eq $Cat) { $fb.Background = Br $AccentDark; $fb.BorderBrush = Br $Accent }
        else { $fb.Background = Br '#0E1424'; $fb.BorderBrush = Br '#262F45' }
    }
    foreach ($t in $Tweaks) { $t.Card.Visibility = $(if ($Cat -eq 'Tous' -or $t.Cat -eq $Cat) { 'Visible' } else { 'Collapsed' }) }
}
$bAll.Add_Click({ foreach ($t in $Tweaks) { if ($t.Card.Visibility -eq 'Visible') { $t.CheckBox.IsChecked = $true } } })
$bNone.Add_Click({ foreach ($t in $Tweaks) { $t.CheckBox.IsChecked = $false } })
$bApplySel.Add_Click({
    $sel = Get-Selected
    if ($sel.Count -eq 0) { Add-Log 'Aucun tweak sélectionné.'; return }
    Invoke-Tweaks $sel $false ("Application de {0} tweak(s)" -f $sel.Count) ([bool]$RestoreCb.IsChecked)
})
$bRevSel.Add_Click({
    $sel = Get-Selected
    if ($sel.Count -eq 0) { Add-Log 'Aucun tweak sélectionné.'; return }
    if (Confirm-Action ("Remettre les valeurs Windows par défaut pour {0} tweak(s) ?" -f $sel.Count)) {
        Invoke-Tweaks $sel $true ("Annulation de {0} tweak(s)" -f $sel.Count) $false
    }
})
function Invoke-RevertAll {
    $active = @($Tweaks | Where-Object { $_.Active })
    if ($active.Count -eq 0) { Add-Log 'Aucun tweak actif à annuler.'; return }
    if (Confirm-Action ("Annuler les {0} tweaks actifs et revenir aux réglages Windows par défaut ?" -f $active.Count)) {
        Invoke-Tweaks $active $true 'Annulation de tous les tweaks' $false
    }
}
# Profils : partager une sélection de tweaks
$profBody = New-Object Windows.Controls.StackPanel
$ProfBox = New-Input '' 0
$ProfBox.Width = [double]::NaN; $ProfBox.HorizontalAlignment = 'Stretch'; $ProfBox.Margin = Th '0,0,0,10'
[void]$profBody.Children.Add($ProfBox)
$profRow = New-Object Windows.Controls.WrapPanel
$bProfCopy = New-Button 'Copier ma sélection' 'Primary'; $bProfCopy.Margin = Th '0,0,8,0'
$bProfActive = New-Button 'Sélectionner mes tweaks actifs' 'Ghost'; $bProfActive.Margin = Th '0,0,8,0'
$bProfLoad = New-Button 'Charger le code' 'Ghost'
foreach ($b in $bProfCopy, $bProfActive, $bProfLoad) { [void]$profRow.Children.Add($b) }
[void]$profBody.Children.Add($profRow)
$bProfActive.Add_Click({ foreach ($t in $Tweaks) { $t.CheckBox.IsChecked = [bool]$t.Active } })
$bProfCopy.Add_Click({
    $ids = @(Get-Selected | ForEach-Object { $_.Id })
    if ($ids.Count -eq 0) { $ids = @($Tweaks | Where-Object { $_.Active } | ForEach-Object { $_.Id }) }
    if ($ids.Count -eq 0) { Add-Log 'Aucun tweak sélectionné ou actif à partager.'; return }
    $code = 'VELOX1:' + ($ids -join ',')
    $ProfBox.Text = $code
    try { [Windows.Clipboard]::SetText($code); Add-Log "Code de profil copié ($($ids.Count) tweaks) : colle-le à ton ami." } catch { Add-Log 'Code affiché : copie-le à la main.' }
})
$bProfLoad.Add_Click({
    $txt = ([string]$ProfBox.Text).Trim()
    if ($txt -notmatch '^VELOX1:') { Add-Log 'Code invalide : il doit commencer par VELOX1:'; return }
    $ids = @(($txt -replace '^VELOX1:', '') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $n = 0
    foreach ($t in $Tweaks) { $on = $ids -contains $t.Id; $t.CheckBox.IsChecked = $on; if ($on) { $n++ } }
    Set-Filter 'Tous'
    Add-Log "$n tweak(s) sélectionné(s) depuis le code. Clique sur « Appliquer la sélection »."
})
[void]$pg.Children.Add((New-Panel 'Profils' 'Partage ta sélection avec un ami : « Copier ma sélection » crée un code. Lui le colle ici, clique sur « Charger le code » puis applique.' $profBody))
[void]$pg.Children.Add((New-ActivityPanel 'Activité des tweaks'))

# ===== MAINTENANCE =====
$pg = New-Page 'maintenance' 'Maintenance' 'Nettoyage, DNS, TRIM et restauration'
$grid = New-Grid 2
[void]$grid.Children.Add((New-ActionCard 'Créer un point de restauration' 'Photo de Windows avant de modifier quoi que ce soit, pour revenir en arrière en un clic.' 3 'Créer' @{ Title = 'Point de restauration'; Code = $RestoreCode }))
[void]$grid.Children.Add((New-ActionCard 'Vider le DNS & réinitialiser Winsock' 'Efface le cache DNS et réinitialise le catalogue Winsock. Règle beaucoup de soucis de connexion.' 2 'Lancer' @{ Title = 'DNS & Winsock'; Code = 'ipconfig /flushdns | Out-Null; "Cache DNS vidé"; netsh winsock reset | Out-Null; "Winsock réinitialisé"' } $true))
[void]$grid.Children.Add((New-ActionCard 'Nettoyer temp & cache shaders' 'Supprime les fichiers temporaires et les caches de shaders NVIDIA / AMD / DirectX. Les jeux les recréent.' 3 'Nettoyer' @{ Title = 'Nettoyage'; Code = @'
$paths = @("$env:TEMP", "$env:windir\Temp", "$env:LOCALAPPDATA\D3DSCache", "$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\NVIDIA\GLCache",
           "$env:LOCALAPPDATA\AMD\DxCache", "$env:LOCALAPPDATA\AMD\DxcCache", "$env:LOCALAPPDATA\AMD\GLCache", "$env:ProgramData\NVIDIA Corporation\NV_Cache")
$freed = 0
foreach ($p in $paths) {
    if (-not (Test-Path $p)) { continue }
    Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
        $len = $_.Length
        try { Remove-Item $_.FullName -Force -ErrorAction Stop; $freed += $len } catch {}
    }
    Get-ChildItem $p -Directory -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
"{0:N0} Mo libérés" -f ($freed / 1MB)
'@ }))
[void]$grid.Children.Add((New-ActionCard 'Optimiser les disques (TRIM)' 'Lance TRIM sur les SSD et défragmente les disques durs. Windows choisit la bonne méthode par disque.' 1 'Optimiser' @{ Title = 'Optimisation des disques'; Code = 'Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq "Fixed" } | ForEach-Object { Optimize-Volume -DriveLetter $_.DriveLetter -ErrorAction SilentlyContinue; "Optimisé : $($_.DriveLetter):" }' }))
[void]$grid.Children.Add((New-ActionCard 'Vider la corbeille' 'Supprime définitivement le contenu de la corbeille sur tous les disques.' 1 'Vider' @{ Title = 'Corbeille'; Code = 'Clear-RecycleBin -Force -ErrorAction SilentlyContinue; "Corbeille vidée"'; Confirm = 'Vider définitivement la corbeille ?' }))
[void]$grid.Children.Add((New-ActionCard 'Nettoyer les composants Windows' 'Supprime les anciennes versions des mises à jour Windows (DISM). Peut prendre plusieurs minutes.' 1 'Nettoyer' @{ Title = 'Nettoyage des composants'; Code = 'DISM /Online /Cleanup-Image /StartComponentCleanup | Out-Null; "DISM terminé (code $LASTEXITCODE)"' }))
[void]$pg.Children.Add((New-Panel 'Maintenance' 'Tâches dʼentretien sans risque, à lancer quand tu veux.' $grid))
[void]$pg.Children.Add((New-ActivityPanel 'Activité de maintenance'))

# ===== SAUVEGARDE =====
$pg = New-Page 'backup' 'Sauvegarde' 'Points de restauration et exports avant de toucher à quoi que ce soit'
$grid = New-Grid 2
[void]$grid.Children.Add((New-ActionCard 'Point de restauration système' 'Point de restauration Windows complet, récupérable depuis les options de récupération.' 3 'Créer' @{ Title = 'Point de restauration'; Code = $RestoreCode }))
[void]$grid.Children.Add((New-ActionCard 'Exporter le registre' 'Exporte HKCU, HKLM\SOFTWARE et HKLM\SYSTEM en fichiers .reg dans Documents\VeloxTweaks\Backups.' 3 'Exporter' @{ Title = 'Export du registre'; Code = @'
$d = Join-Path $BackupRoot ("Registre_" + (Get-Date -Format "yyyy-MM-dd_HH-mm"))
New-Item -ItemType Directory -Path $d -Force | Out-Null
reg export HKCU "$d\HKCU.reg" /y | Out-Null; "HKCU exporté"
reg export HKLM\SOFTWARE "$d\HKLM_SOFTWARE.reg" /y | Out-Null; "HKLM\SOFTWARE exporté"
reg export HKLM\SYSTEM "$d\HKLM_SYSTEM.reg" /y | Out-Null; "HKLM\SYSTEM exporté"
"Dossier : $d"
'@ }))
[void]$grid.Children.Add((New-ActionCard 'Sauvegarder le plan dʼalimentation' 'Exporte ton plan dʼalimentation actuel (.pow) pour pouvoir le réimporter plus tard.' 1 'Sauvegarder' @{ Title = 'Sauvegarde du plan'; Code = @'
$g = [regex]::Match((powercfg /getactivescheme | Out-String), $GuidRx).Value
$f = Join-Path $BackupRoot ("Plan_" + (Get-Date -Format "yyyy-MM-dd_HH-mm") + ".pow")
powercfg /export "$f" $g | Out-Null
"Plan exporté : $f"
'@ }))
[void]$grid.Children.Add((New-ActionCard 'Sauvegarder les pilotes' 'Copie tous les pilotes tiers installés (carte graphique, réseau…) dans le dossier de sauvegarde.' 1 'Sauvegarder' @{ Title = 'Sauvegarde des pilotes'; Code = @'
$d = Join-Path $BackupRoot ("Pilotes_" + (Get-Date -Format "yyyy-MM-dd_HH-mm"))
New-Item -ItemType Directory -Path $d -Force | Out-Null
$n = @(Export-WindowsDriver -Online -Destination $d -ErrorAction Stop).Count
"$n pilotes exportés dans $d"
'@ }))
[void]$grid.Children.Add((New-ActionCard 'Instantané services & démarrage' 'Enregistre lʼétat de tous les services et programmes au démarrage (CSV) pour comparer plus tard.' 2 'Capturer' @{ Title = 'Instantané services'; Code = @'
$s = Get-Date -Format "yyyy-MM-dd_HH-mm"
Get-Service | Select-Object Name, DisplayName, Status, StartType | Export-Csv (Join-Path $BackupRoot "Services_$s.csv") -NoTypeInformation -Encoding UTF8
Get-CimInstance Win32_StartupCommand | Select-Object Name, Command, Location, User | Export-Csv (Join-Path $BackupRoot "Demarrage_$s.csv") -NoTypeInformation -Encoding UTF8
"Instantané enregistré ($s)"
'@ }))
[void]$grid.Children.Add((New-ActionCard 'Ouvrir le dossier de sauvegarde' 'Ouvre Documents\VeloxTweaks\Backups dans lʼexplorateur.' 1 'Ouvrir' @{ Title = 'Dossier'; Local = { Start-Process explorer.exe $BackupRoot } }))
[void]$pg.Children.Add((New-Panel 'Sauvegarde & récupération' 'Fais une sauvegarde avant de tweaker, au cas où.' $grid))
[void]$pg.Children.Add((New-ActivityPanel 'Activité de sauvegarde'))

# ===== RÉPARATIONS =====
$pg = New-Page 'fixes' 'Réparations' 'Correctifs en un clic pour les problèmes Windows courants'
$fixRight = New-Button 'Annuler tous les tweaks' 'Danger'
$fixRight.Add_Click({ Invoke-RevertAll })
$grid = New-Grid 2
[void]$grid.Children.Add((New-ActionCard 'Réparer les fichiers système' 'Lance DISM /RestoreHealth puis SFC /scannow pour réparer les fichiers Windows corrompus. 10 à 30 min.' 2 'Réparer' @{ Title = 'Réparation système'; Code = '"DISM en cours…"; DISM /Online /Cleanup-Image /RestoreHealth | Out-Null; "DISM terminé (code $LASTEXITCODE)"; sfc /scannow | Out-Null; "SFC terminé (code $LASTEXITCODE)"' }))
[void]$grid.Children.Add((New-ActionCard 'Réparer Internet' 'Réinitialise TCP/IP et Winsock, renouvelle lʼadresse IP et vide le DNS. Coupe Internet quelques secondes.' 5 'Réparer' @{ Title = 'Réparation réseau'; Code = 'netsh winsock reset | Out-Null; netsh int ip reset | Out-Null; ipconfig /release | Out-Null; ipconfig /renew | Out-Null; ipconfig /flushdns | Out-Null; "Pile réseau réinitialisée"'; Confirm = 'Internet va être coupé quelques secondes. Continuer ?' } $true))
[void]$grid.Children.Add((New-ActionCard 'Réparer le son' 'Redémarre les services audio Windows. Règle le son qui grésille ou qui a disparu.' 2 'Réparer' @{ Title = 'Réparation audio'; Code = 'Restart-Service AudioEndpointBuilder -Force -ErrorAction SilentlyContinue; Start-Service Audiosrv -ErrorAction SilentlyContinue; "Services audio redémarrés"' }))
[void]$grid.Children.Add((New-ActionCard 'Réparer la barre des tâches & icônes' 'Redémarre lʼexplorateur et reconstruit le cache des icônes et miniatures.' 3 'Réparer' @{ Title = 'Réparation explorateur'; Code = @'
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Remove-Item "$env:LOCALAPPDATA\IconCache.db" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db", "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
"Explorateur redémarré, cache des icônes reconstruit"
'@ }))
[void]$grid.Children.Add((New-ActionCard 'Réparer Windows Update' 'Arrête les services de mise à jour, réinitialise SoftwareDistribution et catroot2, puis relance tout.' 4 'Réparer' @{ Title = 'Réparation Windows Update'; Code = @'
$svcs = "wuauserv", "bits", "cryptsvc", "msiserver"
foreach ($s in $svcs) { Stop-Service $s -Force -ErrorAction SilentlyContinue }
$st = Get-Date -Format "yyyyMMddHHmm"
if (Test-Path "$env:windir\SoftwareDistribution") { Rename-Item "$env:windir\SoftwareDistribution" "SoftwareDistribution.old$st" -ErrorAction SilentlyContinue }
if (Test-Path "$env:windir\System32\catroot2") { Rename-Item "$env:windir\System32\catroot2" "catroot2.old$st" -ErrorAction SilentlyContinue }
foreach ($s in $svcs) { Start-Service $s -ErrorAction SilentlyContinue }
"Windows Update réinitialisé"
'@ } $true))
[void]$grid.Children.Add((New-ActionCard 'Réparer le Microsoft Store & Xbox' 'Réenregistre le Store et lʼappli Xbox, puis vide le cache du Store.' 3 'Réparer' @{ Title = 'Réparation Store & Xbox'; Code = @'
foreach ($n in "Microsoft.WindowsStore", "Microsoft.GamingApp", "Microsoft.XboxIdentityProvider", "Microsoft.XboxGamingOverlay") {
    Get-AppxPackage -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
        Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppxManifest.xml" -ErrorAction SilentlyContinue
        "Réenregistré : $n"
    }
}
Start-Process wsreset.exe
"Cache du Store vidé"
'@ }))
[void]$grid.Children.Add((New-ActionCard 'Plans dʼalimentation par défaut' 'Remet les plans dʼalimentation dʼorigine de Windows. Supprime les plans personnalisés (dont celui de Velox).' 1 'Restaurer' @{ Title = 'Plans par défaut'; Code = 'powercfg -restoredefaultschemes; "Plans dʼalimentation restaurés"'; Confirm = 'Tous les plans dʼalimentation personnalisés seront supprimés. Continuer ?' }))
[void]$grid.Children.Add((New-ActionCard 'Corriger saccades & lag dʼaffichage' 'Vide les caches de shaders et redémarre le pilote graphique. Lʼécran clignote quelques secondes.' 2 'Corriger' @{ Title = 'Correctif saccades'; Code = @'
foreach ($p in "$env:LOCALAPPDATA\D3DSCache", "$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\AMD\DxCache") {
    if (Test-Path $p) { Get-ChildItem $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
}
"Caches de shaders vidés"
Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue | ForEach-Object { pnputil /restart-device "$($_.InstanceId)" | Out-Null; "Pilote redémarré : $($_.FriendlyName)" }
'@; Confirm = 'Lʼécran va clignoter quelques secondes pendant le redémarrage du pilote graphique. Continuer ?' }))
[void]$pg.Children.Add((New-Panel 'Correctifs en un clic' 'Répare les problèmes Windows courants et annule les tweaks qui en causeraient.' $grid $fixRight))
[void]$pg.Children.Add((New-ActivityPanel 'Activité des réparations'))

# ===== VELOX GAME MODE =====
$pg = New-Page 'gamemode' 'Velox Game Mode' 'Plan dʼalimentation performances ultimes'
$gmBody = New-Object Windows.Controls.StackPanel
$gmRow = New-Object Windows.Controls.WrapPanel; $gmRow.Margin = Th '0,0,0,10'
$bGmOn = New-Button 'Activer le Velox Game Mode' 'Primary'; $bGmOn.Padding = Th '18,9'; $bGmOn.Margin = Th '0,0,10,0'
$bGmOff = New-Button 'Revenir à Utilisation normale' 'Ghost'; $bGmOff.Padding = Th '14,9'
[void]$gmRow.Children.Add($bGmOn); [void]$gmRow.Children.Add($bGmOff)
[void]$gmBody.Children.Add($gmRow)
$PlanText = New-Text 'Plan actif : …' 11 '#7D879B'
[void]$gmBody.Children.Add($PlanText)
$GameModeCode = @'
Enable-VeloxPlan
$g = Get-VeloxPlanGuid
powercfg -setacvalueindex $g 54533251-82be-4824-96c1-47b60b740d00 0cc5b647-c1df-4637-891a-dec35c318583 100 2>$null
powercfg -setacvalueindex $g 54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c 100 2>$null
powercfg -setacvalueindex $g 501a4d13-42af-4429-9fd1-a8139a2c71c7 ee12f906-d277-404b-b6da-e5fa1a576df5 0 2>$null
powercfg -setacvalueindex $g 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null
powercfg -setactive $g
"Parking des cœurs désactivé, CPU minimum 100 %, PCIe et USB sans mise en veille"
'@
$bGmOn.Add_Click({
    if (Confirm-Action "Activer le Velox Game Mode ?`n`nLe CPU restera à fond en permanence (sur secteur). Sur un portable, pense à revenir en Utilisation normale quand tu ne joues pas.") {
        Start-Task 'Velox Game Mode' $GameModeCode
    }
})
$bGmOff.Add_Click({ Start-Task 'Plan Utilisation normale' 'Set-BalancedPlan' })
[void]$pg.Children.Add((New-Panel 'Velox Game Mode' 'Crée le plan « Velox Ultimate Performance » : pas de parking des cœurs, CPU minimum 100 %, PCIe et USB jamais mis en veille.' $gmBody))

$grid = New-Grid 2
$codeOf = { param($ids) ($ids | ForEach-Object { (Get-Tweak $_).Apply }) -join "`n" }
[void]$grid.Children.Add((New-ActionCard 'Mode Jeu Windows + planification GPU' 'Active le Mode Jeu de Windows et la planification GPU accélérée (HAGS).' 3 'Activer' @{ Title = 'Mode Jeu + HAGS'; Code = (& $codeOf @('gamemode', 'hags')) } $true))
[void]$grid.Children.Add((New-ActionCard 'Prioriser les jeux' 'Donne aux jeux la priorité GPU et CPU la plus haute, et plus de temps processeur au premier plan.' 5 'Appliquer' @{ Title = 'Priorité aux jeux'; Code = (& $codeOf @('gamesprio', 'fgboost')) }))
[void]$grid.Children.Add((New-ActionCard 'Fermer les applis inutiles' 'Ferme OneDrive, Teams, Widgets et Lien avec le téléphone pour libérer de la RAM avant une partie.' 1 'Fermer' @{ Title = 'Fermeture des applis'; Code = @'
$found = 0
foreach ($n in "OneDrive", "ms-teams", "Teams", "Widgets", "WidgetService", "PhoneExperienceHost", "YourPhone") {
    $p = Get-Process -Name $n -ErrorAction SilentlyContinue
    if ($p) { $p | Stop-Process -Force -ErrorAction SilentlyContinue; "Fermé : $n"; $found++ }
}
if ($found -eq 0) { "Rien à fermer" }
'@ }))
[void]$grid.Children.Add((New-ActionCard 'Timer & réseau gaming' 'Timer système plus précis et suppression de la limitation réseau.' 3 'Appliquer' @{ Title = 'Timer & réseau'; Code = (& $codeOf @('dynamictick', 'netthrottle')) } $true))
[void]$pg.Children.Add((New-Panel 'Extras Game Mode' 'Boosts optionnels à activer quand tu veux.' $grid))
[void]$pg.Children.Add((New-ActivityPanel 'Activité Game Mode'))

# ===== OUTILS GAMING =====
$pg = New-Page 'tools' 'Outils gaming' 'Convertisseur de sensibilité, test de ping et check-up de ton PC'
$Inv = [Globalization.CultureInfo]::InvariantCulture

function New-Input([string]$Text, [double]$Width = 110) {
    $tb = New-Object Windows.Controls.TextBox
    $tb.Text = $Text; $tb.Width = $Width; $tb.Height = 32; $tb.FontSize = 13
    $tb.Background = Br '#0A0F1C'; $tb.Foreground = Br '#FFFFFF'; $tb.BorderBrush = Br '#262F45'
    $tb.CaretBrush = Br '#FFFFFF'; $tb.Padding = Th '6,5,6,5'; $tb.VerticalContentAlignment = 'Center'
    $tb
}
function New-Combo([string[]]$Items, [double]$Width = 200, [bool]$Editable = $false) {
    $cb = New-Object Windows.Controls.ComboBox
    foreach ($i in $Items) { [void]$cb.Items.Add($i) }
    $cb.Width = $Width; $cb.Height = 32; $cb.FontSize = 13; $cb.IsEditable = $Editable
    $cb.VerticalContentAlignment = 'Center'
    if ($cb.Items.Count) { $cb.SelectedIndex = 0 }
    $cb
}
function New-Field([string]$Label, $Control) {
    $sp = New-Object Windows.Controls.StackPanel; $sp.Margin = Th '0,0,14,10'
    [void]$sp.Children.Add((New-Text $Label.ToUpper() 9.5 '#7D879B' 'SemiBold' '0,0,0,5'))
    [void]$sp.Children.Add($Control)
    $sp
}
function ConvertTo-Num([string]$s) {
    $v = 0.0
    if ([double]::TryParse(($s.Trim() -replace ',', '.'), [Globalization.NumberStyles]::Float, $Inv, [ref]$v)) { $v } else { $null }
}

# --- Convertisseur de sensibilité -------------------------------------------
# Yaw = degrés tournés par "count" de souris pour une sensi de 1 (Fortnite : par 1 %).
$SensGames = [ordered]@{
    'Counter-Strike 2 / CS:GO'        = 0.022
    'Valorant'                        = 0.07
    'Apex Legends'                    = 0.022
    'Fortnite (sensi en %)'           = 0.005555
    'Overwatch 2'                     = 0.0066
    'Call of Duty (MW / Warzone / BO)' = 0.0066
    'Rust'                            = 0.1125
    'Team Fortress 2 / jeux Source'   = 0.022
}
$names = [string[]]@($SensGames.Keys)
$cbFrom = New-Combo $names 240; $cbTo = New-Combo $names 240; $cbTo.SelectedIndex = 1
$tbSens = New-Input '1.5'; $tbDpi = New-Input '800'
$row1 = New-Object Windows.Controls.WrapPanel
[void]$row1.Children.Add((New-Field 'Jeu de départ' $cbFrom))
[void]$row1.Children.Add((New-Field 'Ta sensi' $tbSens))
[void]$row1.Children.Add((New-Field 'DPI souris' $tbDpi))
[void]$row1.Children.Add((New-Field 'Jeu d''arrivée' $cbTo))

$resWrap = New-Grid 3; $resWrap.Margin = Th '-5,4,-5,0'
$ResSens = New-StatTile 'Sensi à mettre' '-' ''
$ResCm   = New-StatTile 'cm / 360°' '-' 'distance pour un tour complet'
$ResEdpi = New-StatTile 'eDPI' '-' 'sensi x DPI dans le jeu de départ'
foreach ($t in $ResSens, $ResCm, $ResEdpi) { [void]$resWrap.Children.Add($t.Card) }

$sensBody = New-Object Windows.Controls.StackPanel
[void]$sensBody.Children.Add($row1)
[void]$sensBody.Children.Add($resWrap)
[void]$sensBody.Children.Add((New-Text 'Conversion basée sur la même distance pour un tour à 360°. Garde les mêmes DPI dans les deux jeux et désactive l''accélération souris.' 10.5 '#6B7488' 'Normal' '0,10,0,0'))

function Update-Sens {
    $s = ConvertTo-Num $tbSens.Text; $d = ConvertTo-Num $tbDpi.Text
    $from = [string]$cbFrom.SelectedItem; $to = [string]$cbTo.SelectedItem
    if (-not $s -or -not $d -or -not $from -or -not $to -or $s -le 0 -or $d -le 0) {
        $ResSens.Value.Text = '-'; $ResCm.Value.Text = '-'; $ResEdpi.Value.Text = '-'; return
    }
    $deg = $s * $SensGames[$from]
    $new = $deg / $SensGames[$to]
    $cm = (360 / $deg) / $d * 2.54
    $ResSens.Value.Text = $new.ToString('0.###', $Inv)
    $ResSens.Sub.Text = "dans $to"
    $ResCm.Value.Text = $cm.ToString('0.0', $Inv) + ' cm'
    $ResEdpi.Value.Text = ($s * $d).ToString('0.#', $Inv)
}
$tbSens.Add_TextChanged({ Update-Sens }); $tbDpi.Add_TextChanged({ Update-Sens })
$cbFrom.Add_SelectionChanged({ Update-Sens }); $cbTo.Add_SelectionChanged({ Update-Sens })
$bSwap = New-Button 'Inverser' 'Ghost'
$bSwap.Add_Click({ $a = $cbFrom.SelectedIndex; $cbFrom.SelectedIndex = $cbTo.SelectedIndex; $cbTo.SelectedIndex = $a })
[void]$pg.Children.Add((New-Panel 'Convertisseur de sensibilité' 'Garde exactement la même visée en passant d''un jeu à l''autre.' $sensBody $bSwap))
Update-Sens

# --- Test de ping -------------------------------------------------------------
$cbHost = New-Combo @('1.1.1.1 (Cloudflare)', '8.8.8.8 (Google)', '9.9.9.9 (Quad9)') 240 $true
$bPing = New-Button 'Tester le ping' 'Primary'; $bPing.VerticalAlignment = 'Bottom'; $bPing.Margin = Th '0,0,0,10'; $bPing.Height = 32
$pingRow = New-Object Windows.Controls.WrapPanel
[void]$pingRow.Children.Add((New-Field 'Serveur (ou tape une adresse)' $cbHost))
[void]$pingRow.Children.Add($bPing)
$PingResult = New-Text 'Lance un test : 20 pings, avec moyenne, gigue (stabilité) et perte de paquets.' 12 '#AEB6C6' 'Normal' '0,4,0,0'
$pingBody = New-Object Windows.Controls.StackPanel
[void]$pingBody.Children.Add($pingRow); [void]$pingBody.Children.Add($PingResult)
[void]$pingBody.Children.Add((New-Text 'Repères : moins de 30 ms = excellent · gigue sous 5 ms = stable · toute perte de paquets = problème (souvent le Wi-Fi).' 10.5 '#6B7488' 'Normal' '0,8,0,0'))
$bPing.Add_Click({
    $h = ([string]$cbHost.Text).Trim().Split(' ')[0]
    if ($h -notmatch '^[A-Za-z0-9\.\-:]+$') { $PingResult.Text = 'Adresse invalide.'; return }
    $PingResult.Text = "Test en cours vers $h…"
    $code = @'
$h = '__HOST__'
$p = New-Object System.Net.NetworkInformation.Ping
$t = New-Object System.Collections.Generic.List[double]; $lost = 0
for ($i = 0; $i -lt 20; $i++) {
    try { $r = $p.Send($h, 1500); if ($r.Status -eq 'Success') { $t.Add($r.RoundtripTime) } else { $lost++ } } catch { $lost++ }
    Start-Sleep -Milliseconds 150
}
if ($t.Count -gt 0) {
    $jit = 0; for ($i = 1; $i -lt $t.Count; $i++) { $jit += [math]::Abs($t[$i] - $t[$i - 1]) }
    if ($t.Count -gt 1) { $jit = $jit / ($t.Count - 1) }
    $m = $t | Measure-Object -Average -Minimum -Maximum
    "Ping $h : moyenne {0:N0} ms · min {1} · max {2} · gigue {3:N1} ms · perte {4}/20" -f $m.Average, $m.Minimum, $m.Maximum, $jit, $lost
} else { "Ping $h : aucune réponse (perte 20/20)" }
'@
    Start-Task "Test de ping ($h)" ($code -replace '__HOST__', $h) $false { param($lines) if ($lines) { $PingResult.Text = $lines[-1]; $PingResult.Foreground = Br '#FFFFFF' } }
})
[void]$pg.Children.Add((New-Panel 'Test de ping' 'Mesure la qualité de ta connexion. Le ping en jeu dépend aussi de la distance jusqu''au serveur.' $pingBody))

# --- Check-up gaming + score -------------------------------------------------------
$CheckList = New-Object Windows.Controls.StackPanel
$bCheck = New-Button 'Analyser mon PC' 'Primary'
[void]$CheckList.Children.Add((New-Text 'Clique sur « Analyser mon PC » pour vérifier les réglages qui changent vraiment les FPS et la réactivité.' 12 '#AEB6C6'))
$script:CheckupShown = $false
$script:HwChecks = $null
$script:Hz = 0

function New-Check([string]$Kind, [string]$Title, [string]$Detail, [int]$Pts, [int]$Max, [string]$FixLabel = '', [scriptblock]$Fix = $null) {
    [pscustomobject]@{ Kind = $Kind; Title = $Title; Detail = $Detail; Pts = $Pts; Max = $Max; FixLabel = $FixLabel; Fix = $Fix }
}
function Get-HwChecks {
    $out = @()
    # Écran
    try {
        $vc = Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentRefreshRate -gt 0 -and $_.Name -notmatch 'Basic|Virtual|Remote' } | Select-Object -First 1
        $hz = [int]$vc.CurrentRefreshRate; $max = [int]$vc.MaxRefreshRate; $script:Hz = $hz
        $fx = { Start-Process 'ms-settings:display-advanced' }
        if ($hz -le 60 -and $max -gt 60) { $out += New-Check 'warn' "Écran à $hz Hz alors qu'il peut monter à $max Hz" 'Choisis la fréquence la plus haute dans Affichage avancé.' 0 15 'Ouvrir les réglages' $fx }
        elseif ($max -gt $hz + 1) { $out += New-Check 'warn' "Écran à $hz Hz (max détecté : $max Hz)" 'Vérifie la fréquence dans Affichage avancé.' 5 15 'Ouvrir les réglages' $fx }
        else { $out += New-Check 'ok' "Écran à $hz Hz" 'Ton écran tourne à sa fréquence maximale détectée.' 15 15 }
    } catch { $out += New-Check 'info' 'Écran' 'Impossible de lire la fréquence.' 8 15 }
    # RAM / XMP
    try {
        $mem = @(Get-CimInstance Win32_PhysicalMemory)
        $cfg = [int]($mem | Select-Object -First 1).ConfiguredClockSpeed
        $type = [int]($mem | Select-Object -First 1).SMBIOSMemoryType
        $gen = switch ($type) { 34 { 'DDR5' } 26 { 'DDR4' } default { 'RAM' } }
        $slow = ($type -eq 34 -and $cfg -le 4800) -or ($type -eq 26 -and $cfg -le 2666)
        $fx = {
            if (Confirm-Action "Ton PC va redémarrer directement dans le BIOS.`n`nLà-bas, cherche XMP (Intel) ou EXPO (AMD), choisis « Profil 1 », puis sauvegarde avec F10.`n`nEnregistre ton travail avant. Continuer ?") {
                try { Start-Process shutdown.exe -ArgumentList '/r /fw /t 3' -ErrorAction Stop } catch { [void][Windows.MessageBox]::Show('Impossible de redémarrer dans le BIOS automatiquement. Redémarre et appuie sur Suppr ou F2 au démarrage.', 'Velox Tweaks') }
            }
        }
        if ($slow) { $out += New-Check 'warn' "$gen à $cfg MT/s : XMP probablement désactivé" 'Active XMP (Intel) ou EXPO (AMD) dans le BIOS : ta RAM ira à sa vraie vitesse. Gros gain de FPS sur CPU Intel.' 0 15 'Redémarrer dans le BIOS' $fx }
        else { $out += New-Check 'ok' "$gen à $cfg MT/s · $($mem.Count) barrette(s)" 'La RAM semble tourner à une vitesse correcte (XMP/EXPO actif).' 15 15 }
    } catch { $out += New-Check 'info' 'RAM' 'Impossible de lire la vitesse de la RAM.' 8 15 }
    # Réseau
    try {
        $up = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
        $eth = @($up | Where-Object { $_.PhysicalMediaType -match '802\.3' -or ($_.Name -match 'Ethernet' -and $_.PhysicalMediaType -notmatch '802\.11') })
        $wifi = @($up | Where-Object { $_.PhysicalMediaType -match '802\.11' -or $_.Name -match 'Wi-?Fi|WLAN|Wireless' })
        if ($eth.Count) { $out += New-Check 'ok' "Connecté en câble Ethernet ($($eth[0].LinkSpeed))" 'Idéal pour un ping stable.' 10 10 }
        elseif ($wifi.Count) { $out += New-Check 'warn' 'Connecté en Wi-Fi' 'Un câble Ethernet donne un ping plus bas et sans pics de lag. C''est le plus gros gain possible pour le ping.' 3 10 }
        else { $out += New-Check 'info' 'Réseau' 'Aucune carte réseau active détectée.' 5 10 }
    } catch { $out += New-Check 'info' 'Réseau' 'Impossible de lire les cartes réseau.' 5 10 }
    # Pilote GPU
    try {
        $g = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA|AMD|Radeon|Intel\(R\) Arc' } | Select-Object -First 1
        if ($g -and $g.DriverDate) {
            $age = [int]((Get-Date) - $g.DriverDate).TotalDays
            $url = if ($g.Name -match 'NVIDIA') { 'https://www.nvidia.com/fr-fr/software/nvidia-app/' } elseif ($g.Name -match 'AMD|Radeon') { 'https://www.amd.com/fr/support/download/drivers.html' } else { 'https://www.intel.fr/content/www/fr/fr/download-center/home.html' }
            $fx = [scriptblock]::Create("Start-Process '$url'")
            if ($age -gt 120) { $out += New-Check 'warn' "Pilote graphique vieux de $age jours" 'Mets à jour ton pilote : les nouveaux jeux sont optimisés dans les pilotes récents.' 0 10 'Télécharger le pilote' $fx }
            else { $out += New-Check 'ok' "Pilote graphique récent ($age jours)" "$($g.Name) · version $($g.DriverVersion)" 10 10 }
        } else { $out += New-Check 'info' 'Pilote graphique' 'Carte graphique non reconnue.' 5 10 }
    } catch { $out += New-Check 'info' 'Pilote graphique' 'Impossible de lire le pilote.' 5 10 }
    # Disque
    try {
        $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
        $pct = [math]::Round($c.FreeSpace / $c.Size * 100)
        $free = [math]::Round($c.FreeSpace / 1GB)
        if ($pct -lt 15) { $out += New-Check 'warn' "Disque $env:SystemDrive presque plein ($free Go libres, $pct %)" 'Garde au moins 15 % de libre.' 0 5 'Ouvrir Maintenance' { (UI 'NavMaintenance').IsChecked = $true } }
        else { $out += New-Check 'ok' "Disque $env:SystemDrive : $free Go libres ($pct %)" 'Assez de place libre.' 5 5 }
    } catch { $out += New-Check 'info' 'Disque' 'Impossible de lire le disque.' 3 5 }
    $out
}
function Get-HealthChecks([switch]$Refresh) {
    if ($Refresh -or -not $script:HwChecks) { $script:HwChecks = @(Get-HwChecks) }
    $list = New-Object System.Collections.ArrayList
    foreach ($c in $script:HwChecks) { [void]$list.Add($c) }
    # Tweaks recommandés
    $rec = @($Tweaks | Where-Object { $_.Rec }); $recOn = @($rec | Where-Object { $_.Active }).Count
    $pts = [int][math]::Round(25 * $recOn / [math]::Max(1, $rec.Count))
    if ($recOn -ge $rec.Count) { [void]$list.Add((New-Check 'ok' "Tous les tweaks recommandés sont actifs ($recOn/$($rec.Count))" 'Windows est réglé pour le jeu.' 25 25)) }
    else { [void]$list.Add((New-Check 'warn' "Tweaks recommandés : $recOn/$($rec.Count) actifs" 'Le BOOSTER applique tous les meilleurs réglages en un clic.' $pts 25 'Lancer le BOOSTER' { Invoke-Booster })) }
    # HAGS
    if ((Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' HwSchMode) -eq 2) { [void]$list.Add((New-Check 'ok' 'Planification GPU accélérée activée' 'Nécessaire pour le DLSS Frame Generation sur les cartes RTX 40.' 5 5)) }
    else { [void]$list.Add((New-Check 'warn' 'Planification GPU accélérée désactivée' 'Obligatoire pour le DLSS Frame Generation sur RTX 40.' 0 5 'Activer (redémarrage)' { Invoke-Tweaks @(Get-Tweak 'hags') $false 'Activation HAGS' $false })) }
    # Souris
    if ((Get-Reg 'HKCU:\Control Panel\Mouse' MouseSpeed) -eq '0') { [void]$list.Add((New-Check 'ok' 'Accélération souris désactivée' 'Visée 1:1, indispensable pour une sensi constante.' 5 5)) }
    else { [void]$list.Add((New-Check 'warn' 'Accélération souris activée' 'Ta visée change selon la vitesse de ta main.' 0 5 'Désactiver' { Invoke-Tweaks @(Get-Tweak 'mouseaccel') $false 'Accélération souris' $false })) }
    $ptr = Get-Reg 'HKCU:\Control Panel\Mouse' MouseSensitivity
    if ($ptr -and $ptr -ne '10') { [void]$list.Add((New-Check 'info' "Vitesse du pointeur Windows : $ptr/20" 'La valeur neutre est 10/20. Les jeux en raw input l''ignorent, mais certains non.' 0 0 'Remettre à 10' { Set-Reg 'HKCU:\Control Panel\Mouse' MouseSensitivity '10' 'String'; Add-Log 'Vitesse du pointeur remise à 10/20 (actif après déconnexion)' })) }
    # Plan d'alimentation
    $plan = [regex]::Match((powercfg /getactivescheme | Out-String), '\((.+)\)').Groups[1].Value
    if ($plan -match 'Velox|Ultimate|Performance|performances') { [void]$list.Add((New-Check 'ok' "Plan dʼalimentation : $plan" 'Le CPU reste à pleine vitesse en jeu.' 5 5)) }
    else { [void]$list.Add((New-Check 'warn' "Plan dʼalimentation : $plan" 'Le plan performances garde ton CPU à fond en jeu.' 0 5 'Activer le plan Velox' { Start-Task 'Plan performances' 'Enable-VeloxPlan' })) }
    # Démarrage
    try {
        $on = @(Get-StartupItems | Where-Object { $_.Enabled }).Count
        $p = if ($on -le 8) { 5 } elseif ($on -le 15) { 2 } else { 0 }
        if ($p -eq 5) { [void]$list.Add((New-Check 'ok' "$on programme(s) au démarrage" 'Démarrage léger.' 5 5)) }
        else { [void]$list.Add((New-Check 'warn' "$on programmes lancés avec Windows" 'Décoche ceux dont tu nʼas pas besoin dès lʼallumage.' $p 5 'Gérer le démarrage' { (UI 'NavStartup').IsChecked = $true })) }
    } catch {}
    if ($script:Hz -gt 60) { [void]$list.Add((New-Check 'info' "Limite de FPS conseillée : $($script:Hz - 3) FPS (avec G-Sync / FreeSync)" "Avec G-Sync, limite tes FPS à $($script:Hz - 3) et active NVIDIA Reflex dans le jeu : image fluide et latence minimale." 0 0)) }
    $list
}
function Add-CheckRow($Chk) {
    $map = @{ ok = @('✔', '#4ADE80'); warn = @('⚠', '#F5B83D'); info = @('ℹ', '#60A5FA') }
    $g = New-Object Windows.Controls.Grid; $g.Margin = Th '0,0,0,10'
    $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = [Windows.GridLength]::new(28)
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = [Windows.GridLength]::new(1, 'Star')
    $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = [Windows.GridLength]::Auto
    $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
    [void]$g.Children.Add((New-Text $map[$Chk.Kind][0] 15 $map[$Chk.Kind][1] 'Bold'))
    $sp = New-Object Windows.Controls.StackPanel
    $title = $Chk.Title
    if ($Chk.Max -gt 0) { $title = "$title   ($($Chk.Pts)/$($Chk.Max) pts)" }
    [void]$sp.Children.Add((New-Text $title 12.5 '#E6EAF2' 'SemiBold'))
    [void]$sp.Children.Add((New-Text $Chk.Detail 11.2 '#8A93A6' 'Normal' '0,2,0,0'))
    [Windows.Controls.Grid]::SetColumn($sp, 1); [void]$g.Children.Add($sp)
    if ($Chk.Fix) {
        $b = New-Button $Chk.FixLabel 'Primary'; $b.VerticalAlignment = 'Center'; $b.Margin = Th '12,0,0,0'; $b.Padding = Th '12,6'
        $b.Tag = $Chk.Fix
        $b.Add_Click({ & $this.Tag; if (-not $script:Job) { Invoke-Checkup } })
        [Windows.Controls.Grid]::SetColumn($b, 2); [void]$g.Children.Add($b)
    }
    [void]$CheckList.Children.Add($g)
}
function Invoke-Checkup([switch]$Refresh) {
    $CheckList.Children.Clear()
    $checks = @(Get-HealthChecks -Refresh:$Refresh)
    foreach ($c in $checks) { Add-CheckRow $c }
    $script:CheckupShown = $true
    Update-Score $checks
}
function Update-Score($Checks = $null) {
    if (-not $Checks) { $Checks = @(Get-HealthChecks) }
    $score = [int](($Checks | Measure-Object -Property Pts -Sum).Sum)
    $ScoreBig.Text = "$score/100"
    $ScoreBig.Foreground = Br $(if ($score -ge 85) { '#4ADE80' } elseif ($score -ge 65) { '#F5B83D' } else { '#F87171' })
    $ScoreLbl.Text = $(if ($score -ge 85) { 'Excellent' } elseif ($score -ge 65) { 'Bien, mais peut mieux faire' } else { 'À améliorer' })
    $ScoreMissing.Children.Clear()
    $miss = @($Checks | Where-Object { $_.Max -gt $_.Pts } | Sort-Object { $_.Max - $_.Pts } -Descending | Select-Object -First 4)
    if ($miss.Count -eq 0) { [void]$ScoreMissing.Children.Add((New-Text 'Rien à améliorer : ton PC est au top ! 🏆' 12.5 '#4ADE80' 'SemiBold')) }
    foreach ($m in $miss) { [void]$ScoreMissing.Children.Add((New-Text ("• {0}   (+{1} pts)" -f $m.Title, ($m.Max - $m.Pts)) 12 '#AEB6C6' 'Normal' '0,2,0,2')) }
}
$bCheck.Add_Click({ Invoke-Checkup -Refresh; Add-Log 'Check-up gaming terminé' })
[void]$pg.Children.Add((New-Panel 'Check-up gaming' 'Les réglages qui comptent vraiment, avec un bouton pour corriger directement.' $CheckList $bCheck))

# --- Fonctions Windows natives (viseur + test de polling) -----------------------------
function Initialize-Native {
    if ('Velox.Native' -as [type]) { return }
    Add-Type -Namespace Velox -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
[StructLayout(LayoutKind.Sequential)] public struct RAWINPUTDEVICE { public ushort UsagePage; public ushort Usage; public uint Flags; public IntPtr Target; }
[DllImport("user32.dll", SetLastError = true)] public static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] devices, uint count, uint size);
'@
}

# --- Viseur personnalisé -----------------------------------------------------------------
$script:CrossWin = $null
function Get-CrossCanvas {
    if ($script:CrossWin) { return $script:CrossWin.Content }
    $w = New-Object Windows.Window
    $w.WindowStyle = 'None'; $w.AllowsTransparency = $true; $w.Background = [Windows.Media.Brushes]::Transparent
    $w.Topmost = $true; $w.ShowInTaskbar = $false; $w.ShowActivated = $false; $w.Focusable = $false
    $w.IsHitTestVisible = $false; $w.ResizeMode = 'NoResize'; $w.Width = 200; $w.Height = 200
    $w.Left = ([Windows.SystemParameters]::PrimaryScreenWidth - 200) / 2
    $w.Top = ([Windows.SystemParameters]::PrimaryScreenHeight - 200) / 2
    $cv = New-Object Windows.Controls.Canvas; $cv.IsHitTestVisible = $false; $w.Content = $cv
    $w.Add_SourceInitialized({
        try {
            Initialize-Native
            $h = (New-Object Windows.Interop.WindowInteropHelper $this).Handle
            $ex = [Velox.Native]::GetWindowLong($h, -20)
            [void][Velox.Native]::SetWindowLong($h, -20, ($ex -bor 0x20 -bor 0x80 -bor 0x80000 -bor 0x08000000))
        } catch {}
    })
    $script:CrossWin = $w
    $cv
}
function Add-CrossShape($Cv, $Shape, [double]$X, [double]$Y) {
    [Windows.Controls.Canvas]::SetLeft($Shape, $X); [Windows.Controls.Canvas]::SetTop($Shape, $Y); [void]$Cv.Children.Add($Shape)
}
function New-CrossRect([double]$W, [double]$H, $Fill) { $r = New-Object Windows.Shapes.Rectangle; $r.Width = $W; $r.Height = $H; $r.Fill = $Fill; $r }
function New-CrossEllipse([double]$D, $Fill, $Stroke, [double]$T) {
    $e = New-Object Windows.Shapes.Ellipse; $e.Width = $D; $e.Height = $D
    if ($Fill) { $e.Fill = $Fill }; if ($Stroke) { $e.Stroke = $Stroke; $e.StrokeThickness = $T }; $e
}
function Update-Cross {
    $cv = Get-CrossCanvas; $cv.Children.Clear()
    $col = Br ([string]$Settings.CrossColor); $blk = Br '#C8000000'
    $s = [double]$Settings.CrossSize; $t = [double]$Settings.CrossThick; $g = [double]$Settings.CrossGap; $c = 100.0
    $st = [string]$Settings.CrossStyle
    if ($st -eq 'Cercle') {
        Add-CrossShape $cv (New-CrossEllipse (2 * $s + 2) $null $blk ($t + 2)) ($c - $s - 1) ($c - $s - 1)
        Add-CrossShape $cv (New-CrossEllipse (2 * $s) $null $col $t) ($c - $s) ($c - $s)
    }
    if ($st -like 'Croix*') {
        $bars = @(@(($c - $g - $s), ($c - $t / 2), $s, $t), @(($c + $g), ($c - $t / 2), $s, $t), @(($c - $t / 2), ($c - $g - $s), $t, $s), @(($c - $t / 2), ($c + $g), $t, $s))
        foreach ($b in $bars) { Add-CrossShape $cv (New-CrossRect ($b[2] + 2) ($b[3] + 2) $blk) ($b[0] - 1) ($b[1] - 1) }
        foreach ($b in $bars) { Add-CrossShape $cv (New-CrossRect $b[2] $b[3] $col) $b[0] $b[1] }
    }
    if ($st -match 'point|Point|Cercle') {
        $d = [math]::Max(3, $t + 2)
        Add-CrossShape $cv (New-CrossEllipse ($d + 2) $blk $null 0) ($c - $d / 2 - 1) ($c - $d / 2 - 1)
        Add-CrossShape $cv (New-CrossEllipse $d $col $null 0) ($c - $d / 2) ($c - $d / 2)
    }
}
function Set-Cross([bool]$On) {
    if ($On) { Update-Cross; $script:CrossWin.Show() } elseif ($script:CrossWin) { $script:CrossWin.Hide() }
}
$CrossColors = [ordered]@{ 'Vert' = '#00FF66'; 'Rouge' = '#FF3B3B'; 'Cyan' = '#00E5FF'; 'Jaune' = '#FFE600'; 'Blanc' = '#FFFFFF'; 'Magenta' = '#FF3BFF' }
$CrossStyles = @('Croix', 'Croix + point', 'Point', 'Cercle')
$crossBody = New-Object Windows.Controls.StackPanel
$CrossCb = New-Object Windows.Controls.CheckBox
$CrossCb.Content = 'Afficher le viseur au centre de lʼécran'; $CrossCb.FontSize = 13; $CrossCb.Foreground = Br '#E6EAF2'
$CrossCb.IsChecked = [bool]$Settings.Cross; $CrossCb.Margin = Th '0,0,0,12'
[void]$crossBody.Children.Add($CrossCb)
$crossRow = New-Object Windows.Controls.WrapPanel
$cbStyle = New-Combo ([string[]]$CrossStyles) 150
$cbStyle.SelectedIndex = [math]::Max(0, [array]::IndexOf($CrossStyles, [string]$Settings.CrossStyle))
$colNames = [string[]]@($CrossColors.Keys)
$cbColor = New-Combo $colNames 130
$ci = 0; for ($i = 0; $i -lt $colNames.Count; $i++) { if ($CrossColors[$colNames[$i]] -eq [string]$Settings.CrossColor) { $ci = $i } }; $cbColor.SelectedIndex = $ci
function New-VSlider([double]$Min, [double]$Max, [double]$Val) {
    $sl = New-Object Windows.Controls.Slider
    $sl.Minimum = $Min; $sl.Maximum = $Max; $sl.Value = $Val; $sl.Width = 140; $sl.IsSnapToTickEnabled = $true; $sl.TickFrequency = 1
    $sl.VerticalAlignment = 'Center'; $sl.Margin = Th '0,6,0,0'
    $sl
}
$slSize = New-VSlider 2 40 ([double]$Settings.CrossSize)
$slThick = New-VSlider 1 6 ([double]$Settings.CrossThick)
$slGap = New-VSlider 0 15 ([double]$Settings.CrossGap)
foreach ($f in @(@('Style', $cbStyle), @('Couleur', $cbColor), @('Taille', $slSize), @('Épaisseur', $slThick), @('Écart', $slGap))) { [void]$crossRow.Children.Add((New-Field $f[0] $f[1])) }
[void]$crossBody.Children.Add($crossRow)
[void]$crossBody.Children.Add((New-Text 'Marche dans les jeux en mode « fenêtré sans bordure » (borderless). En plein écran exclusif, Windows le cache. Interdit dans certains jeux compétitifs : vérifie leurs règles.' 10.5 '#6B7488' 'Normal' '0,4,0,0'))
function Save-Cross {
    $Settings.CrossStyle = [string]$cbStyle.SelectedItem
    $Settings.CrossColor = $CrossColors[[string]$cbColor.SelectedItem]
    $Settings.CrossSize = [int]$slSize.Value; $Settings.CrossThick = [int]$slThick.Value; $Settings.CrossGap = [int]$slGap.Value
    Save-Settings
    if ($CrossCb.IsChecked) { Update-Cross }
}
$cbStyle.Add_SelectionChanged({ Save-Cross }); $cbColor.Add_SelectionChanged({ Save-Cross })
$slSize.Add_ValueChanged({ Save-Cross }); $slThick.Add_ValueChanged({ Save-Cross }); $slGap.Add_ValueChanged({ Save-Cross })
$CrossCb.Add_Checked({ $Settings.Cross = $true; Save-Settings; Set-Cross $true })
$CrossCb.Add_Unchecked({ $Settings.Cross = $false; Save-Settings; Set-Cross $false })
[void]$pg.Children.Add((New-Panel 'Viseur personnalisé' 'Un viseur par-dessus tes jeux, toujours au centre de lʼécran. Il ne bloque pas la souris.' $crossBody))

# --- Test du polling rate ------------------------------------------------------------------
$script:RawCount = 0; $script:RawHook = $null
function Set-RawMouse([bool]$On) {
    Initialize-Native
    $h = (New-Object Windows.Interop.WindowInteropHelper $Window).Handle
    if ($On -and -not $script:RawHook) {
        $src = [Windows.Interop.HwndSource]::FromHwnd($h)
        $script:RawHook = [Windows.Interop.HwndSourceHook] { param($hw, $msg, $wp, $lp, [ref]$handled) if ($msg -eq 0x00FF) { $script:RawCount++ }; return [IntPtr]::Zero }
        $src.AddHook($script:RawHook)
    }
    $d = New-Object 'Velox.Native+RAWINPUTDEVICE'
    $d.UsagePage = 1; $d.Usage = 2
    if ($On) { $d.Flags = 0; $d.Target = $h } else { $d.Flags = 1; $d.Target = [IntPtr]::Zero }
    $arr = New-Object 'Velox.Native+RAWINPUTDEVICE[]' 1; $arr[0] = $d
    [Velox.Native]::RegisterRawInputDevices($arr, 1, [uint32][Runtime.InteropServices.Marshal]::SizeOf([type]'Velox.Native+RAWINPUTDEVICE'))
}
$pollBody = New-Object Windows.Controls.StackPanel
$pollArea = New-Object Windows.Controls.Border
$pollArea.Height = 110; $pollArea.Background = Br '#0A0F1C'; $pollArea.BorderBrush = Br '#262F45'; $pollArea.BorderThickness = Th '1'
$pollArea.CornerRadius = [Windows.CornerRadius]::new(10); $pollArea.Margin = Th '0,0,0,10'
$PollLive = New-Text 'Clique sur « Lancer le test », puis bouge ta souris vite en cercles pendant 5 secondes.' 13 '#AEB6C6' 'SemiBold'
$PollLive.HorizontalAlignment = 'Center'; $PollLive.VerticalAlignment = 'Center'; $PollLive.TextAlignment = 'Center'
$pollArea.Child = $PollLive
[void]$pollBody.Children.Add($pollArea)
$PollResult = New-Text 'Repères : 125 Hz = vieille souris · 500 Hz = correct · 1000 Hz = idéal en jeu · 2000 Hz+ = souris haut de gamme.' 11 '#7D879B'
[void]$pollBody.Children.Add($PollResult)
$bPoll = New-Button 'Lancer le test' 'Primary'
$PollTimer = New-Object Windows.Threading.DispatcherTimer
$PollTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$PollTimer.Add_Tick({
    $n = $script:RawCount; $script:RawCount = 0; $script:PollTicks++
    $script:PollSamples.Add($n * 4)
    $PollLive.Text = "$($n * 4) Hz"
    if ($script:PollTicks -ge 20) {
        $PollTimer.Stop()
        try { [void](Set-RawMouse $false) } catch {}
        $bPoll.IsEnabled = $true
        $sorted = @($script:PollSamples | Sort-Object -Descending)
        $peak = if ($sorted.Count -ge 3) { $sorted[2] } else { $sorted[0] }
        if ($peak -lt 80) { $PollLive.Text = 'Pas assez de mouvement'; $PollResult.Text = 'Relance le test et bouge ta souris plus vite, sans tʼarrêter, pendant les 5 secondes.'; return }
        $std = @(125, 250, 500, 1000, 2000, 4000, 8000) | Sort-Object { [math]::Abs($_ - $peak) } | Select-Object -First 1
        $PollLive.Text = "≈ $std Hz"
        $PollResult.Text = if ($std -lt 1000) { "Polling rate mesuré : environ $std Hz (pic $peak Hz). Monte-le à 1000 Hz dans le logiciel de ta souris si elle le permet : moins de latence et un suivi plus fluide." } else { "Polling rate mesuré : environ $std Hz (pic $peak Hz). Parfait pour le jeu." }
        Add-Log "Test polling rate : environ $std Hz"
    }
})
$bPoll.Add_Click({
    try { if (-not (Set-RawMouse $true)) { throw 'Windows a refusé lʼaccès à la souris.' } } catch { $PollResult.Text = "Test impossible : $($_.Exception.Message)"; return }
    $script:RawCount = 0; $script:PollTicks = 0; $script:PollSamples = New-Object System.Collections.Generic.List[int]
    $bPoll.IsEnabled = $false; $PollLive.Text = 'Bouge ta souris vite en cercles…'
    $PollTimer.Start()
})
[void]$pg.Children.Add((New-Panel 'Test du polling rate' 'Mesure combien de fois par seconde ta souris envoie sa position à ton PC.' $pollBody $bPoll))
[void]$pg.Children.Add((New-ActivityPanel 'Activité'))

# ===== MONITEUR =====
$pg = New-Page 'monitor' 'Moniteur' 'Utilisation et températures en direct (mise à jour toutes les 1,5 s)'
$MonData = [hashtable]::Synchronized(@{ Run = $false; Alive = $false })
$script:MonPS = $null
$MonCode = @'
$smi = Join-Path $env:WINDIR 'System32\nvidia-smi.exe'
if (-not (Test-Path $smi)) { $c = Get-Command nvidia-smi -ErrorAction SilentlyContinue; $smi = if ($c) { $c.Source } else { $null } }
$D.HasSmi = [bool]$smi
$cores = [Environment]::ProcessorCount
while ($D.Run) {
    try { $D.Cpu = [int](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime } catch {}
    try { $os = Get-CimInstance Win32_OperatingSystem; $D.RamUsed = ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB; $D.RamTotal = $os.TotalVisibleMemorySize / 1MB } catch {}
    if ($smi) {
        try {
            $l = & $smi --query-gpu=name,temperature.gpu,utilization.gpu,clocks.gr,memory.used,memory.total,power.draw,fan.speed --format=csv,noheader,nounits 2>$null | Select-Object -First 1
            if ($l) { $D.Gpu = [string]$l }
        } catch {}
    }
    try {
        $D.Top = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
            Where-Object { $_.Name -ne '_Total' -and $_.Name -ne 'Idle' } |
            Sort-Object PercentProcessorTime -Descending | Select-Object -First 6 |
            ForEach-Object { '{0}|{1}|{2}' -f ($_.Name -replace '#\d+$', ''), [math]::Round($_.PercentProcessorTime / $cores, 1), [math]::Round($_.WorkingSetPrivate / 1MB) })
    } catch {}
    $D.Stamp = Get-Date
    Start-Sleep -Milliseconds 1500
}
$D.Alive = $false
'@
function Start-Monitor {
    $MonData.Run = $true
    if ($MonData.Alive) { return }
    $MonData.Alive = $true
    $rs = [RunspaceFactory]::CreateRunspace(); $rs.Open()
    $rs.SessionStateProxy.SetVariable('D', $MonData)
    $script:MonPS = [PowerShell]::Create(); $script:MonPS.Runspace = $rs
    [void]$script:MonPS.AddScript($MonCode)
    [void]$script:MonPS.BeginInvoke()
}
function Stop-Monitor { $MonData.Run = $false }

$monA = New-Grid 4; $monA.Margin = Th '-5,0,-5,6'
$MCpu = New-StatTile 'Processeur' '…' 'utilisation totale'
$MRam = New-StatTile 'Mémoire' '…' ''
$MGpu = New-StatTile 'Carte graphique' '…' 'utilisation'
$MTemp = New-StatTile 'Température GPU' '…' ''
foreach ($t in $MCpu, $MRam, $MGpu, $MTemp) { [void]$monA.Children.Add($t.Card) }
$monB = New-Grid 4; $monB.Margin = Th '-5,0,-5,16'
$MVram = New-StatTile 'Mémoire vidéo' '…' ''
$MClock = New-StatTile 'Fréquence GPU' '…' ''
$MPower = New-StatTile 'Consommation GPU' '…' ''
$MFan = New-StatTile 'Ventilateurs GPU' '…' ''
foreach ($t in $MVram, $MClock, $MPower, $MFan) { [void]$monB.Children.Add($t.Card) }
[void]$pg.Children.Add($monA); [void]$pg.Children.Add($monB)
$MGpuName = New-Text '' 11 '#7D879B' 'Normal' '0,-8,0,14'
[void]$pg.Children.Add($MGpuName)
$TopList = New-Object Windows.Controls.StackPanel
[void]$pg.Children.Add((New-Panel 'Ce qui utilise ton PC' 'Les 6 programmes qui utilisent le plus le processeur en ce moment.' $TopList))
[void]$pg.Children.Add((New-Text 'Repères GPU : sous 75 °C = parfait · 75 à 83 °C = normal en jeu · plus de 83 °C = vérifie la ventilation et la poussière.' 10.5 '#6B7488'))

function Set-TileColor($Tile, [double]$Val, [double]$Warn, [double]$Hot) {
    $Tile.Value.Foreground = Br $(if ($Val -ge $Hot) { '#F87171' } elseif ($Val -ge $Warn) { '#F5B83D' } else { '#FFFFFF' })
}
function Update-MonitorUI {
    if (-not $MonData.Stamp) { return }
    if ($null -ne $MonData.Cpu) { $MCpu.Value.Text = "$($MonData.Cpu) %"; Set-TileColor $MCpu $MonData.Cpu 80 95 }
    if ($MonData.RamTotal) {
        $pct = [math]::Round($MonData.RamUsed / $MonData.RamTotal * 100)
        $MRam.Value.Text = "$pct %"; $MRam.Sub.Text = ('{0:N1} / {1:N1} Go utilisés' -f $MonData.RamUsed, $MonData.RamTotal)
        Set-TileColor $MRam $pct 80 92
    }
    if ($MonData.Gpu) {
        $f = @($MonData.Gpu -split ',\s*')
        $num = { param($s) $v = 0.0; if ([double]::TryParse(([string]$s).Trim(), [Globalization.NumberStyles]::Float, $Inv, [ref]$v)) { $v } else { $null } }
        $MGpuName.Text = "$($f[0]) · données du pilote NVIDIA"
        $u = & $num $f[2]; if ($null -ne $u) { $MGpu.Value.Text = "$u %"; Set-TileColor $MGpu $u 101 101 }
        $tc = & $num $f[1]; if ($null -ne $tc) { $MTemp.Value.Text = "$tc °C"; $MTemp.Sub.Text = $(if ($tc -ge 83) { 'chaud !' } elseif ($tc -ge 75) { 'normal en jeu' } else { 'parfait' }); Set-TileColor $MTemp $tc 75 83 }
        $mu = & $num $f[4]; $mt = & $num $f[5]
        if ($null -ne $mu -and $mt) { $MVram.Value.Text = ('{0:N1} Go' -f ($mu / 1024)); $MVram.Sub.Text = ('sur {0:N0} Go' -f ($mt / 1024)) }
        $ck = & $num $f[3]; if ($null -ne $ck) { $MClock.Value.Text = "$ck MHz"; $MClock.Sub.Text = 'cœur graphique' }
        $pw = & $num $f[6]; $MPower.Value.Text = $(if ($null -ne $pw) { "$([math]::Round($pw)) W" } else { 'N/A' })
        $fn = & $num $f[7]; $MFan.Value.Text = $(if ($null -ne $fn) { "$fn %" } else { 'N/A' }); $MFan.Sub.Text = $(if ($fn -eq 0) { 'à lʼarrêt (normal au repos)' } else { '' })
    } elseif ($MonData.HasSmi -eq $false) {
        $MGpuName.Text = 'Infos GPU détaillées disponibles seulement avec une carte NVIDIA.'
        foreach ($t in $MGpu, $MTemp, $MVram, $MClock, $MPower, $MFan) { $t.Value.Text = 'N/A' }
    }
    if ($MonData.Top) {
        $TopList.Children.Clear()
        foreach ($row in $MonData.Top) {
            $p = $row -split '\|'
            $dp = New-Object Windows.Controls.DockPanel; $dp.Margin = Th '0,2,0,2'
            $r = New-Text ("{0} % CPU · {1} Mo" -f $p[1], $p[2]) 11.5 '#8A93A6'
            [Windows.Controls.DockPanel]::SetDock($r, 'Right'); [void]$dp.Children.Add($r)
            [void]$dp.Children.Add((New-Text $p[0] 12 '#E6EAF2' 'SemiBold'))
            [void]$TopList.Children.Add($dp)
        }
    }
}

# ===== DÉMARRAGE =====
$pg = New-Page 'startup' 'Démarrage' 'Les programmes qui se lancent tout seuls avec Windows'
$StartupList = New-Object Windows.Controls.StackPanel
$StartupInfo = New-Text '' 11 '#7D879B' 'Normal' '0,0,0,10'
$suBody = New-Object Windows.Controls.StackPanel
[void]$suBody.Children.Add($StartupInfo); [void]$suBody.Children.Add($StartupList)
$bSuRefresh = New-Button 'Actualiser' 'Ghost'
[void]$pg.Children.Add((New-Panel 'Applis au démarrage' 'Décoche ce dont tu nʼas pas besoin dès lʼallumage : le PC démarre plus vite et moins de choses tournent en fond. Rien nʼest supprimé, tu peux recocher quand tu veux.' $suBody $bSuRefresh))
[void]$pg.Children.Add((New-Text 'À garder en général : pilotes audio (Realtek), logiciel de ta souris/clavier, ton antivirus. Sans risque à décocher : Discord, Steam, Epic, Spotify, OneDrive, Teams, Edge… (ils se lancent quand tu les ouvres).' 10.5 '#6B7488'))

$StartupSources = @(
    @{ Kind = 'Reg'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Appr = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Scope = 'Ton compte' }
    @{ Kind = 'Reg'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Appr = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Scope = 'Tous les comptes' }
    @{ Kind = 'Reg'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Appr = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; Scope = 'Tous les comptes' }
    @{ Kind = 'Dir'; Path = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'); Appr = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Scope = 'Dossier Démarrage' }
    @{ Kind = 'Dir'; Path = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'); Appr = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'; Scope = 'Dossier Démarrage (tous)' }
)
function Test-StartupEnabled([string]$Appr, [string]$Name) {
    $v = Get-Reg $Appr $Name
    if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] % 2) -eq 0) }
    $true
}
function Get-StartupItems {
    $items = @()
    foreach ($s in $StartupSources) {
        if (-not (Test-Path $s.Path)) { continue }
        if ($s.Kind -eq 'Reg') {
            $k = Get-Item $s.Path
            foreach ($n in $k.GetValueNames()) {
                if (-not $n) { continue }
                $items += [pscustomobject]@{ Name = $n; Command = [string]$k.GetValue($n); Appr = $s.Appr; Scope = $s.Scope; Enabled = (Test-StartupEnabled $s.Appr $n) }
            }
        } else {
            foreach ($f in Get-ChildItem $s.Path -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }) {
                $items += [pscustomobject]@{ Name = $f.Name; Command = $f.FullName; Appr = $s.Appr; Scope = $s.Scope; Enabled = (Test-StartupEnabled $s.Appr $f.Name) }
            }
        }
    }
    $items | Sort-Object Name
}
function Set-StartupState($Item, [bool]$On) {
    try {
        if ($On) { $bytes = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
        else { $bytes = [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::Now.ToFileTime())) }
        Set-Reg $Item.Appr $Item.Name $bytes 'Binary'
        $Item.Enabled = $On
        Add-Log ("Démarrage : {0} {1}" -f $Item.Name, $(if ($On) { 'activé' } else { 'désactivé' }))
        Update-StartupInfo
    } catch { Add-Log "Démarrage : impossible de modifier $($Item.Name) ($($_.Exception.Message))" }
}
$script:StartupItems = @()
function Update-StartupInfo {
    $on = @($script:StartupItems | Where-Object { $_.Enabled }).Count
    $StartupInfo.Text = "$($script:StartupItems.Count) programme(s) trouvé(s) · $on lancé(s) au démarrage"
}
function Show-StartupItems {
    $StartupList.Children.Clear()
    $script:StartupItems = @(Get-StartupItems)
    foreach ($it in $script:StartupItems) {
        $card = New-Card; $card.Margin = Th '0,0,0,8'
        $g = New-Object Windows.Controls.Grid
        $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = [Windows.GridLength]::Auto
        $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = [Windows.GridLength]::new(1, 'Star')
        $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = [Windows.GridLength]::Auto
        $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
        $cb = New-Object Windows.Controls.CheckBox; $cb.Margin = Th '0,0,12,0'; $cb.VerticalAlignment = 'Center'
        $cb.IsChecked = $it.Enabled; $cb.Tag = $it
        [void]$g.Children.Add($cb)
        $sp = New-Object Windows.Controls.StackPanel
        [void]$sp.Children.Add((New-Text $it.Name 12.5 '#E6EAF2' 'SemiBold'))
        $cmd = New-Text $it.Command 10.5 '#6B7488'; $cmd.TextWrapping = 'NoWrap'; $cmd.TextTrimming = 'CharacterEllipsis'
        [void]$sp.Children.Add($cmd)
        [Windows.Controls.Grid]::SetColumn($sp, 1); [void]$g.Children.Add($sp)
        $tag = New-Tag $it.Scope.ToUpper() '#9AA3B5' '#1A2030'; $tag.VerticalAlignment = 'Center'; $tag.Margin = Th '10,0,0,0'
        [Windows.Controls.Grid]::SetColumn($tag, 2); [void]$g.Children.Add($tag)
        $card.Child = $g
        $cb.Add_Checked({ Set-StartupState $this.Tag $true })
        $cb.Add_Unchecked({ Set-StartupState $this.Tag $false })
        [void]$StartupList.Children.Add($card)
    }
    if ($script:StartupItems.Count -eq 0) { [void]$StartupList.Children.Add((New-Text 'Aucun programme au démarrage trouvé.' 12 '#AEB6C6')) }
    Update-StartupInfo
}
$bSuRefresh.Add_Click({ Show-StartupItems })

# ===== MODE JEU AUTOMATIQUE (dans la page Velox Game Mode) =====

$agBody = New-Object Windows.Controls.StackPanel
$AutoCb = New-Object Windows.Controls.CheckBox
$AutoCb.Content = 'Activer le mode jeu automatique'; $AutoCb.FontSize = 13; $AutoCb.Foreground = Br '#E6EAF2'
$AutoCb.IsChecked = [bool]$Settings.AutoGame; $AutoCb.Margin = Th '0,0,0,12'
[void]$agBody.Children.Add($AutoCb)
[void]$agBody.Children.Add((New-Text 'NOMS DES JEUX (nom du programme, sans .exe, séparés par des virgules)' 9.5 '#7D879B' 'SemiBold' '0,0,0,5'))
$GamesBox = New-Input ([string]$Settings.Games) 0
$GamesBox.Width = [double]::NaN; $GamesBox.HorizontalAlignment = 'Stretch'; $GamesBox.Height = 56
$GamesBox.TextWrapping = 'Wrap'; $GamesBox.AcceptsReturn = $false; $GamesBox.VerticalContentAlignment = 'Top'
[void]$agBody.Children.Add($GamesBox)
$AutoStatus = New-Text 'En attente…' 12 '#AEB6C6' 'Normal' '0,10,0,0'
[void]$agBody.Children.Add($AutoStatus)
[void]$agBody.Children.Add((New-Text 'Quand un de ces jeux se lance : plan performances Velox + fermeture de OneDrive, Teams, Widgets… Quand tu le quittes : ton plan dʼalimentation dʼavant revient. Velox doit rester ouvert (tu peux le réduire).' 10.5 '#6B7488' 'Normal' '0,8,0,0'))
$AutoCb.Add_Checked({ $Settings.AutoGame = $true; Save-Settings; Add-Log 'Mode jeu automatique activé' })
$AutoCb.Add_Unchecked({ $Settings.AutoGame = $false; Save-Settings; Add-Log 'Mode jeu automatique désactivé'; $AutoStatus.Text = 'Désactivé.' })
$GamesBox.Add_LostFocus({ $Settings.Games = $GamesBox.Text; Save-Settings })
[void]$Pages['gamemode'].Children.Insert(2, (New-Panel 'Mode jeu automatique' 'Velox détecte quand tu lances un jeu et se met en mode performances tout seul.' $agBody))

$script:AutoActive = $null; $script:AutoPrevPlan = $null
$ClutterCode = @'
foreach ($n in "OneDrive", "ms-teams", "Teams", "Widgets", "WidgetService", "PhoneExperienceHost", "YourPhone") {
    $p = Get-Process -Name $n -ErrorAction SilentlyContinue
    if ($p) { $p | Stop-Process -Force -ErrorAction SilentlyContinue; "Fermé : $n" }
}
'@
function Update-AutoGame {
    if (-not $AutoCb.IsChecked) { return }
    $names = @(([string]$GamesBox.Text) -split '[,;\s]+' | ForEach-Object { $_.Trim() -replace '\.exe$', '' } | Where-Object { $_ })
    $running = $null
    if ($names.Count) { $running = Get-Process -Name $names -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($running -and -not $script:AutoActive) {
        if ($script:Job) { return }
        $script:AutoPrevPlan = [regex]::Match((powercfg /getactivescheme | Out-String), $GuidRx).Value
        $script:AutoActive = $running.ProcessName
        $AutoStatus.Text = "🎮 $($running.ProcessName) détecté : mode performances actif."; $AutoStatus.Foreground = Br '#4ADE80'
        Start-Task "Mode jeu auto ($($running.ProcessName))" ("Enable-VeloxPlan`n" + $ClutterCode)
    } elseif (-not $running -and $script:AutoActive) {
        if ($script:Job) { return }
        $prev = $script:AutoPrevPlan
        $AutoStatus.Text = "Jeu fermé : plan dʼalimentation dʼavant rétabli."; $AutoStatus.Foreground = Br '#AEB6C6'
        $script:AutoActive = $null
        if ($prev) { Start-Task 'Fin du mode jeu auto' "powercfg -setactive $prev; 'Plan dʼalimentation dʼavant rétabli'" }
    } elseif (-not $running) {
        $AutoStatus.Text = 'En attente dʼun jeu…'; $AutoStatus.Foreground = Br '#AEB6C6'
    }
}

# --- Mises à jour automatiques (GitHub) -----------------------------------------
$RepoSlug = 'forpakK/velox-tweaks'
$UpdData = [hashtable]::Synchronized(@{ Done = $false })
$UpdCode = @'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $raw = "https://raw.githubusercontent.com/$Slug/main"
    $r = Invoke-RestMethod -Uri "$raw/version.json?t=$([DateTime]::UtcNow.Ticks)" -Headers @{ 'User-Agent' = 'VeloxTweaks' } -TimeoutSec 10
    $U.Tag = [string]$r.version
    $U.Notes = [string]$r.notes
    $U.Url = "$raw/VeloxTweaks.ps1"
} catch { $U.Error = $_.Exception.Message }
$U.Done = $true
'@
$UpdRs = [RunspaceFactory]::CreateRunspace(); $UpdRs.Open()
$UpdRs.SessionStateProxy.SetVariable('U', $UpdData); $UpdRs.SessionStateProxy.SetVariable('Slug', $RepoSlug)
$UpdPS = [PowerShell]::Create(); $UpdPS.Runspace = $UpdRs; [void]$UpdPS.AddScript($UpdCode); [void]$UpdPS.BeginInvoke()
$script:UpdHandled = $false

$UpdBanner = New-Object Windows.Controls.Border
$UpdBanner.Background = Br $AccentDark; $UpdBanner.BorderBrush = Br $Accent; $UpdBanner.BorderThickness = Th '1'
$UpdBanner.CornerRadius = [Windows.CornerRadius]::new(12); $UpdBanner.Padding = Th '18,14,18,14'; $UpdBanner.Margin = Th '0,0,0,16'
$UpdBanner.Visibility = 'Collapsed'
$ubDock = New-Object Windows.Controls.DockPanel
$bUpd = New-Button 'Mettre à jour' 'Primary'; $bUpd.Padding = Th '18,9'; $bUpd.VerticalAlignment = 'Center'
[Windows.Controls.DockPanel]::SetDock($bUpd, 'Right'); [void]$ubDock.Children.Add($bUpd)
$ubText = New-Object Windows.Controls.StackPanel
$UpdTitle = New-Text '' 14 '#FFFFFF' 'SemiBold'
$UpdNotes = New-Text '' 11 '#AEB6C6' 'Normal' '0,4,12,0'
[void]$ubText.Children.Add($UpdTitle); [void]$ubText.Children.Add($UpdNotes)
[void]$ubDock.Children.Add($ubText)
$UpdBanner.Child = $ubDock
[void]$Pages['dashboard'].Children.Insert(2, $UpdBanner)

function Update-UpdateCheck {
    if ($script:UpdHandled -or -not $UpdData.Done) { return }
    $script:UpdHandled = $true
    try { $UpdPS.Dispose(); $UpdRs.Dispose() } catch {}
    if ($UpdData.Error -or -not $UpdData.Tag) { return }
    $remote = $null; $local = $null
    [void][version]::TryParse(($UpdData.Tag -replace '^[vV]', ''), [ref]$remote)
    [void][version]::TryParse($AppVersion, [ref]$local)
    if ($remote -and $local -and $remote -gt $local -and $UpdData.Url) {
        $UpdTitle.Text = "Nouvelle version disponible : Velox Tweaks $($UpdData.Tag -replace '^[vV]', '') (tu as la $AppVersion)"
        $notes = ($UpdData.Notes -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' · '
        $UpdNotes.Text = $notes
        $UpdBanner.Visibility = 'Visible'
        Add-Log "Mise à jour disponible : $($UpdData.Tag)"
    }
}
$bUpd.Add_Click({
    if ($script:Job) { [void][Windows.MessageBox]::Show('Attends la fin de la tâche en cours avant de mettre à jour.', 'Velox Tweaks', 'OK', 'Information'); return }
    if (-not (Confirm-Action "Télécharger et installer Velox Tweaks $($UpdData.Tag) ?`n`nVelox va redémarrer tout seul. Tes tweaks restent appliqués.")) { return }
    $bUpd.IsEnabled = $false; $bUpd.Content = 'Téléchargement…'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $self = $PSCommandPath
        $tmp = "$self.new"
        Invoke-WebRequest -Uri $UpdData.Url -OutFile $tmp -UseBasicParsing -Headers @{ 'User-Agent' = 'VeloxTweaks' } -TimeoutSec 60
        $txt = Get-Content $tmp -Raw -Encoding UTF8
        if ($txt -notmatch 'Velox Tweaks' -or $txt -notmatch '\$AppVersion') { throw 'Le fichier téléchargé ne ressemble pas à Velox Tweaks.' }
        Copy-Item $self "$self.bak" -Force
        Move-Item $tmp $self -Force
        Add-Log "Mise à jour installée ($($UpdData.Tag)). Redémarrage de Velox…"
        $script:Job = $null
        Restart-Velox
    } catch {
        Remove-Item "$PSCommandPath.new" -Force -ErrorAction SilentlyContinue
        $bUpd.IsEnabled = $true; $bUpd.Content = 'Mettre à jour'
        [void][Windows.MessageBox]::Show("La mise à jour a échoué :`n`n$($_.Exception.Message)`n`nTu peux la télécharger à la main sur github.com/$RepoSlug", 'Velox Tweaks', 'OK', 'Warning')
    }
})

# ===== PARAMÈTRES + ICÔNE PRÈS DE L'HORLOGE + LANCEMENT AVEC WINDOWS =====
$TaskName = 'Velox Tweaks'
function Test-Autostart { [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) }
function Set-Autostart([bool]$On) {
    try {
        if ($On) {
            $user = "$env:USERDOMAIN\$env:USERNAME"
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$ScriptPath`" -Tray" -WorkingDirectory $ScriptDir
            $trg = New-ScheduledTaskTrigger -AtLogOn -User $user
            $prn = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
            $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Principal $prn -Settings $set -Force -ErrorAction Stop | Out-Null
            Add-Log 'Velox se lancera avec Windows (près de lʼhorloge).'
        } else {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Add-Log 'Velox ne se lancera plus avec Windows.'
        }
    } catch { Add-Log "Lancement avec Windows : impossible ($($_.Exception.Message))" }
}

# Icône près de l'horloge
$TrayIcon = New-Object System.Windows.Forms.NotifyIcon
$icoPath = Join-Path $ScriptDir 'build\velox.ico'
try { $TrayIcon.Icon = if (Test-Path $icoPath) { New-Object System.Drawing.Icon $icoPath } else { [System.Drawing.SystemIcons]::Application } } catch { $TrayIcon.Icon = [System.Drawing.SystemIcons]::Application }
$TrayIcon.Text = 'Velox Tweaks'
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $trayMenu.Items.Add('Ouvrir Velox')
$miBoost = $trayMenu.Items.Add('⚡ BOOSTER mon PC')
$miAuto = New-Object System.Windows.Forms.ToolStripMenuItem 'Mode jeu automatique'
$miAuto.Checked = [bool]$AutoCb.IsChecked
[void]$trayMenu.Items.Add($miAuto)
$miCross = New-Object System.Windows.Forms.ToolStripMenuItem 'Viseur'
$miCross.Checked = [bool]$CrossCb.IsChecked
[void]$trayMenu.Items.Add($miCross)
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miQuit = $trayMenu.Items.Add('Quitter Velox')
$TrayIcon.ContextMenuStrip = $trayMenu
function Show-MainWindow {
    $Window.Show()
    if ($Window.WindowState -eq 'Minimized') { $Window.WindowState = 'Normal' }
    [void]$Window.Activate()
    if ($Pages['monitor'].Visibility -eq 'Visible') { Start-Monitor }
}
$miOpen.Add_Click({ Show-MainWindow })
$miBoost.Add_Click({ Show-MainWindow; Invoke-Booster })
$miAuto.Add_Click({ $AutoCb.IsChecked = -not $AutoCb.IsChecked })
$miCross.Add_Click({ $CrossCb.IsChecked = -not $CrossCb.IsChecked })
$trayMenu.Add_Opening({ $miAuto.Checked = [bool]$AutoCb.IsChecked; $miCross.Checked = [bool]$CrossCb.IsChecked })
$miQuit.Add_Click({ Exit-Velox })
$TrayIcon.Add_DoubleClick({ Show-MainWindow })
$TrayIcon.Visible = $true

$script:ReallyExit = $false
function Exit-Velox([bool]$Force = $false) {
    if (-not $Force -and $script:Job) {
        if (-not (Confirm-Action "Une tâche est encore en cours (« $($script:Job.Title) »).`nQuitter quand même ?")) { return }
    }
    $script:ReallyExit = $true
    try { $Timer.Stop() } catch {}
    $MonData.Run = $false
    try { if ($script:CrossWin) { $script:CrossWin.Close() } } catch {}
    try { $TrayIcon.Visible = $false; $TrayIcon.Dispose() } catch {}
    try { $script:Mutex.ReleaseMutex() } catch {}
    try { $Window.Close() } catch {}
    $App.Shutdown()
}
function Restart-Velox {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$ScriptPath`" -Updated"
    Exit-Velox $true
}

$pg = New-Page 'settings' 'Paramètres' 'Comportement de Velox, lancement avec Windows et couleur'
$bgBody = New-Object Windows.Controls.StackPanel
$cbTrayOpt = New-Object Windows.Controls.CheckBox
$cbTrayOpt.Content = 'Quand je ferme la fenêtre, garder Velox près de lʼhorloge (le mode jeu auto et le viseur continuent)'
$cbTrayOpt.FontSize = 12.5; $cbTrayOpt.Foreground = Br '#E6EAF2'; $cbTrayOpt.Margin = Th '0,0,0,12'
$cbTrayOpt.IsChecked = [bool]$Settings.TrayOnClose
$cbTrayOpt.Add_Checked({ $Settings.TrayOnClose = $true; Save-Settings })
$cbTrayOpt.Add_Unchecked({ $Settings.TrayOnClose = $false; Save-Settings })
[void]$bgBody.Children.Add($cbTrayOpt)
$cbAutoStart = New-Object Windows.Controls.CheckBox
$cbAutoStart.Content = 'Lancer Velox avec Windows (discrètement, près de lʼhorloge)'
$cbAutoStart.FontSize = 12.5; $cbAutoStart.Foreground = Br '#E6EAF2'
$cbAutoStart.IsChecked = (Test-Autostart)
$cbAutoStart.Add_Checked({ Set-Autostart $true })
$cbAutoStart.Add_Unchecked({ Set-Autostart $false })
[void]$bgBody.Children.Add($cbAutoStart)
[void]$bgBody.Children.Add((New-Text 'Le lancement avec Windows utilise une tâche planifiée (pour éviter la demande administrateur à chaque démarrage). Ton antivirus peut la signaler : cʼest normal.' 10.5 '#6B7488' 'Normal' '0,10,0,0'))
[void]$pg.Children.Add((New-Panel 'Arrière-plan' 'Pour que le mode jeu automatique marche sans garder la fenêtre ouverte.' $bgBody))

$colBody = New-Object Windows.Controls.StackPanel
$swRow = New-Object Windows.Controls.WrapPanel
$AccentChoices = [ordered]@{ 'Bleu' = '#2D7BFF'; 'Violet' = '#8B5CF6'; 'Rouge' = '#EF4444'; 'Vert' = '#22C55E'; 'Orange' = '#F97316'; 'Rose' = '#EC4899'; 'Cyan' = '#06B6D4' }
foreach ($k in $AccentChoices.Keys) {
    $hex = $AccentChoices[$k]
    $sw = New-Button '' 'Primary'
    $sw.Width = 46; $sw.Height = 34; $sw.Margin = Th '0,0,8,8'; $sw.Background = Br $hex; $sw.ToolTip = $k; $sw.Tag = $hex
    $sw.BorderBrush = Br $(if ($hex -eq $Accent) { '#FFFFFF' } else { $hex })
    $sw.BorderThickness = Th $(if ($hex -eq $Accent) { '2' } else { '1' })
    $sw.Add_Click({
        if ($this.Tag -eq $Accent) { return }
        $Settings.Accent = $this.Tag; Save-Settings
        if (Confirm-Action 'Couleur enregistrée. Redémarrer Velox maintenant pour lʼappliquer ?') { Restart-Velox }
    })
    [void]$swRow.Children.Add($sw)
}
[void]$colBody.Children.Add($swRow)
[void]$pg.Children.Add((New-Panel 'Couleur' 'Choisis la couleur de Velox (redémarrage de Velox nécessaire).' $colBody))

$aboutBody = New-Object Windows.Controls.StackPanel
[void]$aboutBody.Children.Add((New-Text "Velox Tweaks $AppVersion · github.com/$RepoSlug" 12.5 '#E6EAF2' 'SemiBold' '0,0,0,10'))
$aboutRow = New-Object Windows.Controls.WrapPanel
$bGit = New-Button 'Page GitHub' 'Ghost'; $bGit.Margin = Th '0,0,8,0'
$bDir = New-Button 'Dossier de Velox' 'Ghost'; $bDir.Margin = Th '0,0,8,0'
$bLog = New-Button 'Ouvrir le journal' 'Ghost'
$bGit.Add_Click({ Start-Process "https://github.com/$RepoSlug" })
$bDir.Add_Click({ Start-Process explorer.exe $ScriptDir })
$bLog.Add_Click({ if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile } })
foreach ($b in $bGit, $bDir, $bLog) { [void]$aboutRow.Children.Add($b) }
[void]$aboutBody.Children.Add($aboutRow)
[void]$pg.Children.Add((New-Panel 'À propos' 'Velox vérifie les nouvelles versions sur GitHub à chaque démarrage.' $aboutBody))

# --- État & rafraîchissement ----------------------------------------------------
function Update-Status {
    foreach ($t in $Tweaks) {
        $t.Active = try { [bool](& $t.CheckSb) } catch { $false }
        $t.ActiveTag.Visibility = $(if ($t.Active) { 'Visible' } else { 'Collapsed' })
    }
    $act = @($Tweaks | Where-Object { $_.Active }).Count
    $TileActive.Value.Text = "$act"
    $TileActive.Sub.Text = "sur $($Tweaks.Count) disponibles"
    Update-TweakHeader
    try {
        $name = [regex]::Match((powercfg /getactivescheme | Out-String), '\((.+)\)').Groups[1].Value
        $PlanText.Text = "Plan actif : $name"
    } catch {}
}
function Update-Live {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $TileRam.Value.Text = "{0:N1} Go" -f ($os.FreePhysicalMemory / 1MB)
        $TileRam.Sub.Text = "sur $TotalRamGB Go au total"
    } catch {}
    $up = (Get-Date) - $BootTime
    $TileUptime.Value.Text = if ($up.Days -gt 0) { "{0}j {1}h" -f $up.Days, $up.Hours } else { "{0}h {1:00}m" -f $up.Hours, $up.Minutes }
}

# --- Navigation & démarrage ----------------------------------------------------
foreach ($n in 'NavDashboard', 'NavTweaks', 'NavMaintenance', 'NavBackup', 'NavFixes', 'NavMonitor', 'NavStartup', 'NavTools', 'NavGame', 'NavSettings') {
    (UI $n).Add_Checked({ Show-Page $this.Tag })
}
(UI 'NavDashboard').IsChecked = $true
Show-Page 'dashboard'
Set-Filter 'Tous'
Update-Status
Update-Live
Add-Log "Velox Tweaks $AppVersion démarré · sauvegardes dans $BackupRoot"

$script:Tick = 0
$Timer = New-Object Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromMilliseconds(400)
$Timer.Add_Tick({
    Update-Job
    $script:Tick++
    if ($script:Tick % 12 -eq 0) { Update-Live }
    if ($script:Tick % 3 -eq 0 -and $Pages['monitor'].Visibility -eq 'Visible') { Update-MonitorUI }
    if ($script:Tick % 12 -eq 6) { Update-AutoGame }
    if (-not $script:UpdHandled) { Update-UpdateCheck }
    if ($script:Tick -eq 5) { try { Update-Score } catch {} }
})
$Timer.Start()

$Window.Add_Closing({
    param($s, $e)
    if ($script:ReallyExit) { return }
    $e.Cancel = $true
    if ($Settings.TrayOnClose) {
        $Window.Hide(); Stop-Monitor
        if (-not $script:BalloonShown) {
            $script:BalloonShown = $true
            $TrayIcon.ShowBalloonTip(4000, 'Velox Tweaks', 'Velox continue en arrière-plan. Double-clique sur lʼicône ⚡ pour le rouvrir, clic droit > Quitter pour le fermer.', [System.Windows.Forms.ToolTipIcon]::Info)
        }
    } else { Exit-Velox }
})

$App = New-Object Windows.Application
$App.ShutdownMode = 'OnExplicitShutdown'
if ($Settings.Cross) { try { Set-Cross $true } catch {} }
if ($Tray) { Add-Log 'Velox démarré en arrière-plan (lancement avec Windows)' } else { $Window.Show() }
[void]$App.Run()
