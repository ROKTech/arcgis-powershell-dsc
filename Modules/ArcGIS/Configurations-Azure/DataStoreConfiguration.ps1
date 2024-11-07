﻿Configuration DataStoreConfiguration
{
	param(
        [Parameter(Mandatory=$false)]
        [System.String]
        $Version = 11.4

        ,[Parameter(Mandatory=$true)]
        [ValidateNotNullorEmpty()]
        [System.Management.Automation.PSCredential]
        $ServiceCredential

        ,[Parameter(Mandatory=$false)]
        [System.Boolean]
        $ServiceCredentialIsDomainAccount

        ,[Parameter(Mandatory=$true)]
        [ValidateNotNullorEmpty()]
        [System.Management.Automation.PSCredential]
        $SiteAdministratorCredential
        
        ,[Parameter(Mandatory=$true)]
        [System.String]
        $DataStoreMachineNames

        ,[Parameter(Mandatory=$true)]
        [System.String]
        $ServerMachineNames

        ,[Parameter(Mandatory=$true)]
        [System.String]
        $ExternalDNSHostName    

        ,[Parameter(Mandatory=$true)]
        [System.Boolean]
        $UseExistingFileShare

        ,[Parameter(Mandatory=$true)]
        [System.String]
        $FileShareMachineName
        
        ,[Parameter(Mandatory=$false)]
        [System.String]
        $FileShareName = 'fileshare'

        ,[Parameter(Mandatory=$false)]
        [System.String]
        $FileSharePath
        
        ,[Parameter(Mandatory=$false)]
        [System.Boolean]
        $DebugMode
    )
    
    Import-DscResource -ModuleName PSDesiredStateConfiguration 
    Import-DSCResource -ModuleName ArcGIS
	Import-DscResource -Name ArcGIS_DataStore
    Import-DscResource -Name ArcGIS_Service_Account
    Import-DscResource -name ArcGIS_WindowsService
    Import-DscResource -Name ArcGIS_xFirewall
    Import-DscResource -Name ArcGIS_Disk
    
    $DataStoreHostNames = ($DataStoreMachineNames -split ',')
    $DataStoreHostName = $DataStoreHostNames | Select-Object -First 1
    $ServerHostNames = ($ServerMachineNames -split ',')
    $ServerMachineName = $ServerHostNames | Select-Object -First 1
    $FolderName = $ExternalDNSHostName.Substring(0, $ExternalDNSHostName.IndexOf('.')).ToLower()
    $DataStoreBackupLocation = "\\$($FileShareMachineName)\$FileShareName\$FolderName\datastore\dbbackups"            
    $IsStandBy = ($env:ComputerName -ine $DataStoreHostName)
    $PeerMachineName = $null
    if($DataStoreHostNames.Length -gt 1) {
      $PeerMachineName = $DataStoreHostNames | Select-Object -Last 1
    }
  
    $IsDataStoreWithStandby = ($DataStoreHostName -ine $PeerMachineName) -and ($PeerMachineName)
    $DataStoreContentDirectory = "$($env:SystemDrive)\\arcgis\\datastore\\content"

    
	Node localhost
	{
        $DataStoreDependsOn = @()

        LocalConfigurationManager
        {
			ActionAfterReboot = 'ContinueConfiguration'            
            ConfigurationMode = 'ApplyOnly'    
            RebootNodeIfNeeded = $true
        }
        
        ArcGIS_Disk DiskSizeCheck
        {
            HostName = $env:ComputerName
        }

        $HasValidServiceCredential = ($ServiceCredential -and ($ServiceCredential.GetNetworkCredential().Password -ine 'Placeholder'))
        if($HasValidServiceCredential) 
        {
            if(-Not($ServiceCredentialIsDomainAccount)){
                User ArcGIS_RunAsAccount
                {
                    UserName       = $ServiceCredential.UserName
                    Password       = $ServiceCredential
                    FullName       = 'ArcGIS Service Account'
                    Ensure         = 'Present'
                    PasswordChangeRequired = $false
                    PasswordNeverExpires = $true
                }
            }

            ArcGIS_WindowsService ArcGIS_DataStore_Service
            {
                Name            = 'ArcGIS Data Store'
                Credential      = $ServiceCredential
                StartupType     = 'Automatic'
                State           = 'Running' 
                DependsOn       = if(-Not($ServiceCredentialIsDomainAccount)){ @('[User]ArcGIS_RunAsAccount')}else{ @()}
            }
                
            ArcGIS_Service_Account DataStore_Service_Account
		    {
			    Name            = 'ArcGIS Data Store'
                RunAsAccount    = $ServiceCredential
                Ensure          = 'Present'
			    DependsOn       = if(-Not($ServiceCredentialIsDomainAccount)){ @('[User]ArcGIS_RunAsAccount','[ArcGIS_WindowsService]ArcGIS_DataStore_Service')}else{ @('[ArcGIS_WindowsService]ArcGIS_DataStore_Service')}
                DataDir         = $DataStoreContentDirectory  
                IsDomainAccount = $ServiceCredentialIsDomainAccount
            }
            $DataStoreDependsOn +=  @('[ArcGIS_Service_Account]DataStore_Service_Account')
            
            ArcGIS_xFirewall DataStore_FirewallRules
		    {
                Name                  = "ArcGISDataStore" 
                DisplayName           = "ArcGIS Data Store" 
                DisplayGroup          = "ArcGIS Data Store" 
                Ensure                = 'Present' 
                Access                = "Allow" 
                State                 = "Enabled" 
                Profile               = ("Domain","Private","Public")
                LocalPort             = ("2443", "9876")                        
                Protocol              = "TCP" 
            }
            $DataStoreDependsOn += @('[ArcGIS_xFirewall]DataStore_FirewallRules')

            ArcGIS_xFirewall Queue_DataStore_FirewallRules_OutBound
            {
                Name                  = "ArcGISQueueDataStore-Out" 
                DisplayName           = "ArcGIS Queue Data Store Out" 
                DisplayGroup          = "ArcGIS Data Store" 
                Ensure                = 'Present'  
                Access                = "Allow" 
                State                 = "Enabled" 
                Profile               = ("Domain","Private","Public")
                LocalPort             = ("45671","45672")                      
                Protocol              = "TCP"
            }
            $DataStoreDependsOn += '[ArcGIS_xFirewall]Queue_DataStore_FirewallRules_OutBound'

            if($IsDataStoreWithStandby) 
            {
                ArcGIS_xFirewall DataStore_FirewallRules_OutBound
			    {
                    Name                  = "ArcGISDataStore-Out" 
                    DisplayName           = "ArcGIS Data Store Out" 
                    DisplayGroup          = "ArcGIS Data Store" 
                    Ensure                = 'Present'
                    Access                = "Allow" 
                    State                 = "Enabled" 
                    Profile               = ("Domain","Private","Public")
                    LocalPort             = ("9876")       
                    Direction             = "Outbound"                        
                    Protocol              = "TCP" 
			    } 

			    $DataStoreDependsOn += @('[ArcGIS_xFirewall]DataStore_FirewallRules_OutBound')
            }

            ArcGIS_DataStore DataStore
		    {
			    Ensure                     = 'Present'
                Version                    = $Version
			    SiteAdministrator          = $SiteAdministratorCredential
			    ServerHostName             = $ServerMachineName
			    ContentDirectory           = $DataStoreContentDirectory
			    IsStandby                  = $IsStandBy
                DataStoreTypes             = @('Relational')
                EnableFailoverOnPrimaryStop= $true
			    DependsOn                  = $DataStoreDependsOn
		    } 

		    foreach($ServiceToStop in  @('ArcGIS Server', 'Portal for ArcGIS', 'ArcGISGeoEvent', 'ArcGISGeoEventGateway', 'ArcGIS Notebook Server', 'ArcGIS Mission Server', 'WorkflowManager'))
		    {
			    if(Get-Service $ServiceToStop -ErrorAction Ignore) 
			    {
				    Service "$($ServiceToStop.Replace(' ','_'))_Service"
				    {
					    Name			= $ServiceToStop
					    Credential		= $ServiceCredential
					    StartupType		= 'Manual'
					    State			= 'Stopped'
					    DependsOn		= if(-Not($ServiceCredentialIsDomainAccount)){ @('[User]ArcGIS_RunAsAccount')}else{ @()}
				    }
			    }
		    }
        }
	}
}
