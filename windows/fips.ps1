# Проверить и отключить FIPS (на сервере, PowerShell от администратора)
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy" -Name Enabled

#Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy" -Name Enabled -Value 0
#Restart-Computer
