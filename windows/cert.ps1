$cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My `
    -KeyAlgorithm RSA -KeyLength 2048 -KeyUsage KeyEncipherment,DigitalSignature `
    -Provider "Microsoft RSA SChannel Cryptographic Provider" -Type SSLServerAuthentication

$obj = Get-WmiObject -Class "Win32_TSGeneralSetting" -Namespace root\cimv2\terminalservices -Filter "TerminalName='RDP-tcp'"
Set-WmiInstance -Path $obj.__PATH -Argument @{SSLCertificateSHA1Hash = $cert.Thumbprint}

Restart-Service TermService -Force
