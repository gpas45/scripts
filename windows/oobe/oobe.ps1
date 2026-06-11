# Automating OOBE by downloading an answer file from the internet
# https://www.outsidethebox.ms/22491/#internet
# # # # # # # # # # # # # # # # # # # # ################
 
# # # # # # # # # # # # # # # # # # # # ################ 
# Pre-checks: if not in OOBE, exit out
# https://oofhours.com/2023/09/15/detecting-when-you-are-in-oobe/
 
$TypeDef = @" 
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
   
namespace Api
{
 public class Kernel32
 {
   [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
   public static extern int OOBEComplete(ref int bIsOOBEComplete);
 }
}
"@ 
Add-Type -TypeDefinition $TypeDef -Language CSharp
   
$IsOOBEComplete = $false
$hr = [Api.Kernel32]::OOBEComplete([ref] $IsOOBEComplete)
if ($IsOOBEComplete) {
  Write-Host "Not in OOBE, nothing to do."
  exit 0
}
 
# # # # # # # # # # # # # # # # # # # # ################ 
# Download the answer file and point sysprep to it
Write-Host "Your username and password will be: Admin/Admin" -ForegroundColor DarkGreen
$uri = "https://bit.ly/491HWxy"
$answer = "$env:temp\UnattendOOBE.xml"
(Invoke-RestMethod -Uri $uri).OuterXml | Out-File -FilePath $answer -Encoding utf8 -Force
foreach ($letter in $((Get-Volume).DriveLetter)) {
    if (Test-Path "$($letter):\Windows\System32\Sysprep\sysprep.exe") {
        Invoke-Expression "$($letter):\Windows\System32\Sysprep\sysprep.exe /reboot /oobe /unattend:$answer"
        break
    }
}
