<# ###########################################################################

NAME: Accounts Onboard Utility

AUTHOR:  Assaf Miron, Brian Bors

COMMENT:
This script will onboard all accounts from a CSV file using REST API

SUPPORTED VERSIONS:
CyberArk PVWA v10.4 and above
CyberArk Privilege Cloud

Change Notes
2021-07-29 -	Added CreateOnUpdate and applied formatting via VSCode
2021-09-27 -	Added BypassAccountSearch and BypassSafeSearch
Added concurrentLogon switch
2022-04-21 -	Fixed Account update and added more logging
2022-07-22 -	Made CPM_Name a varable able to be set at runtime
2022-08-19 -	Fixed accounts not adding new platform properties
Fixed updating automatic management of password
2022-08-23 -	Verification latest version published
2023-04-19 -    Added Separate log file for errors, added output of CSV files for bad and good files
2023-04-20 -    Suppressed error about unable to delete bad and good csv when they don't exist
Updated error output
2023-06-20 -    Added more information in error logs
2023-06-23 - 	Updated to prevent duplicate bad records
2023-06-25 -	Updated to add WideAccountsSearch, NarrowSearch, ignoreAccountName
2025-01-07 -    Updated to allow automatically not create duplicates, fix bad record handling, formating update
2025-03-17 -    Updated to allow for verbose output to a file
2025-04-30 -    Updated to check and correct URL scheme and path for Privilege Cloud
=======


########################################################################### #>
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true, HelpMessage = 'Please enter your PVWA address (For example: https://pvwa.mydomain.com/PasswordVault)')]
	#[ValidateScript({Invoke-WebRequest -UseBasicParsing -DisableKeepAlive -Uri $_ -Method 'Head' -ErrorAction 'stop' -TimeoutSec 30})]
	[Alias('url')]
	[String]$PVWAURL,

	[Parameter(Mandatory = $false, HelpMessage = 'Enter the Authentication type (Default:CyberArk)')]
	[ValidateSet('cyberark', 'ldap', 'radius')]
	[String]$AuthType = 'cyberark',

	[Parameter(Mandatory = $false, HelpMessage = 'Enter the RADIUS OTP')]
	[ValidateScript({ $AuthType -eq 'radius' })]
	[String]$OTP,

	[Parameter(ParameterSetName = 'Create', Mandatory = $false, HelpMessage = 'Please enter Safe Template Name')]
	[Alias('safe')]
	[String]$TemplateSafe,

	[Parameter(Mandatory = $false, ValueFromPipeline = $false, ValueFromPipelineByPropertyName = $true)]
	[ValidateScript( { Test-Path -Path $_ -PathType Leaf -IsValid })]
	[Alias('path')]
	[String]$CsvPath,

	[Parameter(Mandatory = $false, ValueFromPipeline = $false, ValueFromPipelineByPropertyName = $true)]
	[ValidateSet('Comma', 'Tab')]
	[String]$CsvDelimiter = 'Comma',

	# Use this switch to Disable SSL verification (NOT RECOMMENDED)
	[Parameter(Mandatory = $false)]
	[Switch]$DisableSSLVerify,

	# Use this switch to Create accounts and Safes (no update)
	[Parameter(ParameterSetName = 'Create', Mandatory = $true)]
	[Parameter(ParameterSetName = 'Update', Mandatory = $false)]
	[Switch]$Create,

	# Use this switch to Create and Update accounts and Safes
	[Parameter(ParameterSetName = 'Update', Mandatory = $true)]
	[Parameter(ParameterSetName = 'Create', Mandatory = $false)]
	[Switch]$Update,

	[Parameter(ParameterSetName = 'Create', Mandatory = $false)]
	[Parameter(ParameterSetName = 'Update', Mandatory = $false)]
	[String]$CPM_NAME = 'PasswordManager',

	# Use this switch to Delete accounts
	[Parameter(ParameterSetName = 'Delete', Mandatory = $true)]
	[Switch]$Delete,

	# Use this switch to disable Safes creation
	[Parameter(ParameterSetName = 'Create', Mandatory = $false)]
	[Parameter(ParameterSetName = 'Update', Mandatory = $false)]
	[Switch]$NoSafeCreation,

	# Use this switch to disable Auto-Update
	[Parameter(Mandatory = $false)]
	[Switch]$DisableAutoUpdate,

	[Parameter(Mandatory = $false)]
	[Switch]$concurrentSession,

	#Use this switch when "WideAccountsSearch" is enabled use to quicken searches via name"
	[Parameter(ParameterSetName = 'Update', Mandatory = $false)]
	[Switch]$WideAccountsSearch,

	#Use this switch to search by username, address, and platform when name is populated
	[Parameter(ParameterSetName = 'Update', Mandatory = $false)]
	[Switch]$NarrowSearch,

	#Use this switch to ignore Account Name in searches
	[Parameter(ParameterSetName = 'Update', Mandatory = $false)]
	[Switch]$ignoreAccountName,

	[Parameter(ParameterSetName = 'Update', Mandatory = $false)]
	[Switch]$CreateOnUpdate,

	[Parameter(ParameterSetName = 'Create', Mandatory = $false)]
	[Parameter(ParameterSetName = 'Update', Mandatory = $false)]
	[Switch]$BypassSafeSearch,

	[Parameter(ParameterSetName = 'Create', Mandatory = $false)]
	[Switch]$BypassAccountSearch,

	[Parameter(Mandatory = $false, HelpMessage = 'Vault Stored Credentials')]
	[PSCredential]$PVWACredentials,

	# Use this parameter to pass a pre-existing authorization token. If passed the token is NOT logged off
	[Parameter(Mandatory = $false)]
	$logonToken,

	# Use this switch to automatically not create duplicates
	[Parameter(ParameterSetName = 'Create', Mandatory = $false)]
	[Switch]$SkipDuplicates,

	[Parameter(Mandatory = $false, DontShow, HelpMessage = 'Include Call Stack in Verbose output')]
	[switch]$IncludeCallStack,

	[Parameter(Mandatory = $false, DontShow)]
	[switch]$UseVerboseFile
)

# Get Script Location
$ScriptFullPath = $MyInvocation.MyCommand.Path
$ScriptLocation = Split-Path -Parent $ScriptFullPath
$ScriptParameters = @()
$PSBoundParameters.GetEnumerator() | ForEach-Object { $ScriptParameters += ("-{0} '{1}'" -f $_.Key, $_.Value) }
$global:g_ScriptCommand = '{0} {1}' -f $ScriptFullPath, $($ScriptParameters -join ' ')

# Script Version
$ScriptVersion = '2.6.1'

# Set Log file path
$global:LOG_DATE = $(Get-Date -Format yyyyMMdd) + '-' + $(Get-Date -Format HHmmss)
$global:LOG_FILE_PATH = "$ScriptLocation\Account_Onboarding_Utility_$LOG_DATE.log"

$InDebug = $PSBoundParameters.Debug.IsPresent
$InVerbose = $PSBoundParameters.Verbose.IsPresent
$global:IncludeCallStack = $IncludeCallStack.IsPresent
$global:UseVerboseFile = $UseVerboseFile.IsPresent

[hashtable]$Global:BadAccountHashTable = @{}


#region Helper Functions
function Format-PVWAURL {
	param (
		[Parameter()]
		[string]
		$PVWAURL
	)
	#check url scheme to ensure it's secure and add https if not present
	IF ($PVWAURL -match '^(?<scheme>https:\/\/|http:\/\/|).*$') {
		if ('http://' -eq $matches['scheme'] -and $AllowInsecureURL -eq $false) {
			$PVWAURL = $PVWAURL.Replace('http://', 'https://')
			Write-LogMessage -type Warning -MSG "Detected inscure scheme in URL `nThe URL was automaticly updated to: $PVWAURL `nPlease ensure you are using the correct scheme in the url"
		}
		elseif ([string]::IsNullOrEmpty($matches['scheme'])) {
			$PVWAURL = "https://$PVWAURL"
			Write-LogMessage -type Warning -MSG "Detected no scheme in URL `nThe URL was automaticly updated to: $PVWAURL `nPlease ensure you are using the correct scheme in the url"
		}
	}

	#check url for improper Privilege Cloud URL and add /PasswordVault/ if not present
	if ($PVWAURL -match '^(?:https|http):\/\/(?<sub>.*).cyberark.(?<top>cloud|com)\/privilegecloud.*$') {
		$PVWAURL = "https://$($matches['sub']).privilegecloud.cyberark.$($matches['top'])/PasswordVault/"
		Write-LogMessage -type Warning -MSG "Detected improperly formated Privilege Cloud URL `nThe URL was automaticly updated to: $PVWAURL `nPlease ensure you are using the correct URL. Pausing for 10 seconds to allow you to copy correct url.`n"
		Start-Sleep 10
	}
	elseif ($PVWAURL -notmatch '^.*PasswordVault(?:\/|)$') {
		$PVWAURL = "$PVWAURL/PasswordVault/"
		Write-LogMessage -type Warning -MSG "Detected improperly formated Privileged Access Manager URL `nThe URL was automaticly updated to: $PVWAURL `nPlease ensure you are using the correct URL. Pausing for 10 seconds to allow you to copy correct url.`n"
		Start-Sleep 10
	}
	return $PVWAURL
}

# @FUNCTION@ ======================================================================================================================
# Name...........: Test-CommandExists
# Description....: Tests if a command exists
# Parameters.....: Command
# Return Values..: True / False
# =================================================================================================================================
Function Test-CommandExists {
	<#
.SYNOPSIS
Tests if a command exists
.DESCRIPTION
Tests if a command exists
.PARAMETER Command
The command to test
#>
	Param ($command)
	$oldPreference = $ErrorActionPreference
	$ErrorActionPreference = 'stop'
	try {
		if (Get-Command $command) {
			RETURN $true
		}
	}
	catch {
		Write-Host "$command does not exist"; RETURN $false
	}
	Finally {
		$ErrorActionPreference = $oldPreference
	}
} #end function test-CommandExists

# @FUNCTION@ ======================================================================================================================
# Name...........: ConvertTo-URL
# Description....: HTTP Encode test in URL
# Parameters.....: Text to encode
# Return Values..: Encoded HTML URL text
# =================================================================================================================================
Function ConvertTo-URL($sText) {
	<#
.SYNOPSIS
HTTP Encode test in URL
.DESCRIPTION
HTTP Encode test in URL
.PARAMETER sText
The text to encode
#>
	if ($sText.Trim() -ne '') {
		Write-LogMessage -type Debug -MSG "Returning URL Encode of $sText"
		return [URI]::EscapeDataString($sText)
	}
	else {
		return $sText
	}
}

# @FUNCTION@ ======================================================================================================================
# Name...........: Convert-ToBool
# Description....: Converts text to Bool
# Parameters.....: Text
# Return Values..: Boolean value of the text
# =================================================================================================================================
Function Convert-ToBool {
	<#
.SYNOPSIS
Converts text to Bool
.DESCRIPTION
Converts text to Bool
.PARAMETER txt
The text to convert to bool (True / False)
#>
	param (
		[string]$txt
	)
	$retBool = $false

	if ($txt -match '^y$|^yes$') {
		$retBool = $true
	}
	elseif ($txt -match '^n$|^no$') {
		$retBool = $false
	}
	else {
		[bool]::TryParse($txt, [ref]$retBool) | Out-Null
	}

	return $retBool
}

# @FUNCTION@ ======================================================================================================================
# Name...........: Get-TrimmedString
# Description....: Returns the trimmed text from a string
# Parameters.....: Text
# Return Values..: Trimmed text
# =================================================================================================================================
Function Get-TrimmedString($sText) {
	<#
.SYNOPSIS
Returns the trimmed text from a string
.DESCRIPTION
Returns the trimmed text from a string
.PARAMETER txt
The text to handle
#>
	if ($null -ne $sText) {
		return $sText.Trim()
	}
	#else
	return $sText
}

# @FUNCTION@ ======================================================================================================================
# Name...........: New-AccountObject
# Description....: Creates a new Account object
# Parameters.....: Account line read from CSV
# Return Values..: Account Object for onboarding
# =================================================================================================================================
Function New-AccountObject {
	<#
.SYNOPSIS
Creates a new Account Object
.DESCRIPTION
Creates a new Account Object
.PARAMETER AccountLine
(Optional) Account Object Name
#>
	param (
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[PSObject]$AccountLine
	)
	try {
		# Set the Account Log name for further logging and troubleshooting
		$logFormat = ''
		If (([string]::IsNullOrEmpty($AccountLine.userName) -or [string]::IsNullOrEmpty($AccountLine.Address)) -and (![string]::IsNullOrEmpty($AccountLine.name))) {
			$logFormat = (Get-TrimmedString $AccountLine.name)
		}
		Else {
			$logFormat = ('{0}@{1}' -f $(Get-TrimmedString $AccountLine.userName), $(Get-TrimmedString $AccountLine.address))
		}
		Set-Variable -Scope Global -Name g_LogAccountName -Value $logFormat

		# Check mandatory fields
		If ([string]::IsNullOrEmpty($AccountLine.safe)) {
			Write-LogMessage -type Error -MSG 'Missing mandatory field for REST: Safe'
			Write-LogMessage -type Error -MSG "CSV Line: $global:csvLine"
			throw
		}
		if ($Create) {
			# Check mandatory fields for account creation
			If ([string]::IsNullOrEmpty($AccountLine.userName)) {
				Write-LogMessage -type Error -MSG "CSV Line: $global:csvLine"
				Write-LogMessage -type Error -MSG 'Missing mandatory field for REST: Username'
				throw
			}
			If ([string]::IsNullOrEmpty($AccountLine.address)) {
				Write-LogMessage -type Error -MSG "CSV Line: $global:csvLine"
				Write-LogMessage -type Error -MSG 'Missing mandatory field for REST: Address'
				throw
			}
			If ([string]::IsNullOrEmpty($AccountLine.platformId)) {
				Write-LogMessage -type Error -MSG "CSV Line: $global:csvLine"
				Write-LogMessage -type Error -MSG 'Missing mandatory field for REST: PlatfromID'
				throw
			}
		}

		# Check if there are custom properties
		$excludedProperties = @('name', 'username', 'address', 'safe', 'platformid', 'password', 'key', 'enableautomgmt', 'manualmgmtreason', 'groupname', 'groupplatformid', 'remotemachineaddresses', 'restrictmachineaccesstolist', 'sshkey')
		$customProps = $($AccountLine.PSObject.Properties | Where-Object { $_.Name.ToLower() -NotIn $excludedProperties })
		#region [Account object mapping]
		# Convert Account from CSV to Account Object (properties mapping)
		$_Account = '' | Select-Object 'name', 'address', 'userName', 'platformId', 'safeName', 'secretType', 'secret', 'platformAccountProperties', 'secretManagement', 'remoteMachinesAccess'
		$_Account.platformAccountProperties = $null
		$_Account.name = (Get-TrimmedString $AccountLine.name)
		$_Account.address = (Get-TrimmedString $AccountLine.address)
		$_Account.userName = (Get-TrimmedString $AccountLine.userName)
		$_Account.platformId = (Get-TrimmedString $AccountLine.platformID)
		$_Account.safeName = (Get-TrimmedString $AccountLine.safe)
		if ((![string]::IsNullOrEmpty($AccountLine.password)) -and ([string]::IsNullOrEmpty($AccountLine.SSHKey))) {
			$_Account.secretType = 'password'
			$_Account.secret = $AccountLine.password
		}
		elseif (![string]::IsNullOrEmpty($AccountLine.SSHKey)) {
			$_Account.secretType = 'key'
			$_Account.secret = $AccountLine.SSHKey
		}
		else {
			# Empty password
			$_Account.secretType = 'password'
			$_Account.secret = $AccountLine.password
		}
		if (![string]::IsNullOrEmpty($customProps)) {
			# Convert any non-default property in the CSV as a new platform account property
			if ($null -eq $_Account.platformAccountProperties) {
				$_Account.platformAccountProperties = New-Object PSObject
			}
			For ($i = 0; $i -lt $customProps.count; $i++) {
				$prop = $customProps[$i]
				If (![string]::IsNullOrEmpty($prop.Value)) {
					$_Account.platformAccountProperties | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value
				}
			}
		}
		If (![String]::IsNullOrEmpty($AccountLine.enableAutoMgmt)) {
			$_Account.secretManagement = '' | Select-Object 'automaticManagementEnabled', 'manualManagementReason'
			$_Account.secretManagement.automaticManagementEnabled = Convert-ToBool $AccountLine.enableAutoMgmt
			if ($_Account.secretManagement.automaticManagementEnabled -eq $false) {
				$_Account.secretManagement.manualManagementReason = $AccountLine.manualMgmtReason
			}
		}
		if ($AccountLine.PSobject.Properties.Name -contains 'remoteMachineAddresses') {
			if ($null -eq $_Account.remoteMachinesAccess) {
				$_Account.remoteMachinesAccess = New-Object PSObject
			}
			$_Account.remoteMachinesAccess | Add-Member -MemberType NoteProperty -Name 'remoteMachines' -Value $AccountLine.remoteMachineAddresses
		}
		if ($AccountLine.PSobject.Properties.Name -contains 'restrictMachineAccessToList') {
			if ($null -eq $_Account.remoteMachinesAccess) {
				$_Account.remoteMachinesAccess = New-Object PSObject
			}
			$_Account.remoteMachinesAccess | Add-Member -MemberType NoteProperty -Name 'accessRestrictedToRemoteMachines' -Value $AccountLine.restrictMachineAccessToList
		}
		#endregion [Account object mapping]

		return $_Account
	}
	catch {
		Throw $(New-Object System.Exception ('New-AccountObject: There was an error creating a new account object.', $_.Exception))
	}
}

# @FUNCTION@ ======================================================================================================================
# Name...........: Open-FileDialog
# Description....: Opens a new "Open File" Dialog
# Parameters.....: LocationPath
# Return Values..: Selected file path
# =================================================================================================================================
Function Open-FileDialog {
	<#
.SYNOPSIS
Opens a new "Open File" Dialog
.DESCRIPTION
Opens a new "Open File" Dialog
.PARAMETER LocationPath
The Location to open the dialog in
#>
	param (
		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, Position = 0)]
		[ValidateNotNullOrEmpty()]
		[string]$LocationPath
	)
	Begin {
		[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
		$OpenFileDialog = New-Object System.Windows.Forms.OpenFileDialog
	}
	Process {
		$OpenFileDialog.initialDirectory = $LocationPath
		$OpenFileDialog.filter = 'CSV (*.csv)| *.csv'
		$OpenFileDialog.ShowDialog() | Out-Null
	}
	End {
		return $OpenFileDialog.filename
	}
}
#endregion

#region Log Functions
Function Write-LogMessage {
	<#
.SYNOPSIS
Method to log a message on screen and in a log file

.DESCRIPTION
Logging The input Message to the Screen and the Log File.
The Message Type is presented in colours on the screen based on the type

.PARAMETER LogFile
The Log File to write to. By default using the LOG_FILE_PATH
.PARAMETER MSG
The message to log
.PARAMETER Header
Adding a header line before the message
.PARAMETER SubHeader
Adding a Sub header line before the message
.PARAMETER Footer
Adding a footer line after the message
.PARAMETER Type
The type of the message to log (Info, Warning, Error, Debug)
#>
	param(
		[Parameter(Mandatory = $true)]
		[AllowEmptyString()]
		[String]$MSG,
		[Parameter(Mandatory = $false)]
		[Switch]$Header,
		[Parameter(Mandatory = $false)]
		[Switch]$SubHeader,
		[Parameter(Mandatory = $false)]
		[Switch]$Footer,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Info', 'Warning', 'Error', 'Debug', 'Verbose')]
		[String]$type = 'Info',
		[Parameter(Mandatory = $false)]
		[String]$LogFile = $LOG_FILE_PATH,
		[Parameter(Mandatory = $false)]
		[int]$pad = 20
	)

	$verboseFile = $($LOG_FILE_PATH.replace('.log', '_Verbose.log'))
	try {
		If ($Header) {
			'=======================================' | Out-File -Append -FilePath $LOG_FILE_PATH
			Write-Host '======================================='
		}
		ElseIf ($SubHeader) {
			'------------------------------------' | Out-File -Append -FilePath $LOG_FILE_PATH
			Write-Host '------------------------------------'
		}

		$LogTime = "[$(Get-Date -Format 'yyyy-MM-dd hh:mm:ss')]`t"
		$msgToWrite += "$LogTime"
		$writeToFile = $true
		# Replace empty message with 'N/A'
		if ([string]::IsNullOrEmpty($Msg)) {
			$Msg = 'N/A'
		}
		# Mask Passwords
		if ($Msg -match '((?:"password"|"secret"|"NewCredentials")\s{0,}["\:=]{1,}\s{0,}["]{0,})(?=([\w!@#$%^&*()-\\\/]+))') {
			$Msg = $Msg.Replace($Matches[2], '****')
		}
		# Check the message type
		switch ($type) {
			'Info' {
				Write-Host $MSG.ToString()
				$msgToWrite += "[INFO]`t`t$Msg"
			}
			'Warning' {
				Write-Host $MSG.ToString() -ForegroundColor DarkYellow
				$msgToWrite += "[WARNING]`t$Msg"
				if ($UseVerboseFile) {
					$msgToWrite | Out-File -Append -FilePath $verboseFile
				}
			}
			'Error' {
				Write-Host $MSG.ToString() -ForegroundColor Red
				$msgToWrite += "[ERROR]`t`t$Msg"
				if ($UseVerboseFile) {
					$msgToWrite | Out-File -Append -FilePath $verboseFile
				}
			}
			'Debug' {
				if ($InDebug -or $InVerbose) {
					Write-Debug $MSG
					$writeToFile = $true
					$msgToWrite += "[DEBUG]`t`t$Msg"
				}
				else {
					$writeToFile = $False
				}
			}
			'Verbose' {
				if ($InVerbose -or $VerboseFile) {
					$arrMsg = $msg.split(":`t", 2)
					if ($arrMsg.Count -gt 1) {
						$msg = $arrMsg[0].PadRight($pad) + $arrMsg[1]
					}
					$msgToWrite += "[VERBOSE]`t$Msg"
					if ($global:IncludeCallStack) {
						function Get-CallStack {
							$stack = ''
							$excludeItems = @('Write-LogMessage', 'Get-CallStack', '<ScriptBlock>')
							Get-PSCallStack | ForEach-Object {
								If ($PSItem.Command -notin $excludeItems) {
									$command = $PSitem.Command
									If ($command -eq $Global:scriptName) {
										$command = 'Base'
									}
									elseif ([string]::IsNullOrEmpty($command)) {
										$command = '**Blank**'
									}
									$Location = $PSItem.Location
									$stack = $stack + "$command $Location; "
								}
							}
							return $stack
						}
						$stack = Get-CallStack
						$stackMsg = "CallStack:`t$stack"
						$arrstackMsg = $stackMsg.split(":`t", 2)
						if ($arrMsg.Count -gt 1) {
							$stackMsg = $arrstackMsg[0].PadRight($pad) + $arrstackMsg[1].trim()
						}
						Write-Verbose $stackMsg
						$msgToWrite += "`n$LogTime"
						$msgToWrite += "[STACK]`t`t$stackMsg"
					}
					if ($InVerbose) {
						Write-Verbose $MSG
					}
					else {
						$writeToFile = $False
					}
					if ($UseVerboseFile) {
						$msgToWrite | Out-File -Append -FilePath $verboseFile
					}
				}
				else {
					$writeToFile = $False
				}
			}
		}
		If ($writeToFile) {
			$msgToWrite | Out-File -Append -FilePath $LOG_FILE_PATH
		}
		If ($Footer) {
			'=======================================' | Out-File -Append -FilePath $LOG_FILE_PATH
			Write-Host '======================================='
		}
	}
	catch {
		Write-Error "Error in writing log: $($_.Exception.Message)"
	}
}

# @FUNCTION@ ======================================================================================================================
# Name...........: Join-ExceptionMessage
# Description....: Formats exception messages
# Parameters.....: Exception
# Return Values..: Formatted String of Exception messages
# =================================================================================================================================
Function Join-ExceptionMessage {
	<#
.SYNOPSIS
Formats exception messages
.DESCRIPTION
Formats exception messages
.PARAMETER Exception
The Exception object to format
#>
	param(
		[Exception]$e
	)

	Begin {
	}
	Process {
		$msg = 'Source:{0}; Message: {1}' -f $e.Source, $e.Message
		while ($e.InnerException) {
			$e = $e.InnerException
			$msg += "`n`t->Source:{0}; Message: {1}" -f $e.Source, $e.Message
		}
		return $msg
	}
	End {
	}
}
#endregion

#region REST Functions
# @FUNCTION@ ======================================================================================================================
# Name...........: Invoke-Rest
# Description....: Invoke REST Method
# Parameters.....: Command method, URI, Header, Body
# Return Values..: REST response
# =================================================================================================================================
Function Invoke-Rest {
	<#
.SYNOPSIS
Invoke REST Method
.DESCRIPTION
Invoke REST Method
.PARAMETER Command
The REST Command method to run (GET, POST, PATCH, DELETE)
.PARAMETER URI
The URI to use as REST API
.PARAMETER Header
The Header as Dictionary object
.PARAMETER Body
(Optional) The REST Body
.PARAMETER ErrAction
(Optional) The Error Action to perform in case of error. By default "Continue"
#>
	param (
		[Parameter(Mandatory = $true)]
		[ValidateSet('GET', 'POST', 'DELETE', 'PATCH', 'PUT')]
		[Alias('Method')]
		[String]$Command,
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[String]$URI,
		[Parameter(Mandatory = $false)]
		[Alias('Headers')]
		$Header,
		[Parameter(Mandatory = $false)]
		$Body,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Continue', 'Ignore', 'Inquire', 'SilentlyContinue', 'Stop', 'Suspend')]
		[String]$ErrAction = 'Continue',
		[Parameter(Mandatory = $false)]
		[int]$TimeoutSec = 2700,
		[Parameter(Mandatory = $false)]
		[string]$ContentType = 'application/json'

	)
	Write-LogMessage -type Verbose -MSG "Invoke-Rest:`tStart"
	$restResponse = ''
	try {
		if ([string]::IsNullOrEmpty($Body)) {
			Write-LogMessage -type Verbose -MSG "Invoke-Rest:`tInvoke-RestMethod -Uri $URI -Method $Command -Header $($Header|ConvertTo-Json -Compress) -ContentType $ContentType -TimeoutSec $TimeoutSec"
			$restResponse = Invoke-RestMethod -Uri $URI -Method $Command -Header $Header -ContentType $ContentType -TimeoutSec $TimeoutSec -ErrorAction $ErrAction -Verbose:$false -Debug:$false
		}
		else {
			Write-LogMessage -type Verbose -MSG "Invoke-Rest:`tInvoke-RestMethod -Uri $URI -Method $Command -Header $($Header|ConvertTo-Json -Compress) -ContentType $ContentType -Body $($Body|ConvertTo-Json -Compress) -TimeoutSec $TimeoutSec"
			$restResponse = Invoke-RestMethod -Uri $URI -Method $Command -Header $Header -ContentType $ContentType -Body $Body -TimeoutSec $TimeoutSec -ErrorAction $ErrAction -Verbose:$false -Debug:$false
		}
		Write-LogMessage -type Verbose -MSG "Invoke-Rest:`tInvoke-RestMethod completed without error"
	}
	catch [System.Net.WebException] {
		Write-LogMessage -type Verbose -MSG "Invoke-Rest:`tCaught WebException"
		if ($ErrAction -match ('\bContinue\b|\bInquire\b|\bStop\b|\bSuspend\b')) {
			Write-LogMessage -type Error -MSG "Error Message: $_"
			Write-LogMessage -type Error -MSG "Exception Message: $($_.Exception.Message)"
			Write-LogMessage -type Error -MSG "Status Code: $($_.Exception.Response.StatusCode.value__)"
			Write-LogMessage -type Error -MSG "Status Description: $($_.Exception.Response.StatusDescription)"
			$restResponse = $null
			Throw
		}
		Else {
			Throw $PSItem
		}
	}

	catch [Microsoft.PowerShell.Commands.HttpResponseException] {
		Write-LogMessage -type Verbose -MSG "Invoke-Rest:`tCaught HttpResponseException"
		$Details = ($PSItem.ErrorDetails.Message | ConvertFrom-Json)
		If ('SFWS0007' -eq $Details.ErrorCode) {
			Write-LogMessage -type Verbose -MSG "Invoke-Rest:`t$($Details.ErrorMessage)"
			Throw $PSItem
		}
		elseif ('PASWS013E' -eq $Details.ErrorCode) {
			Write-LogMessage -type Error -MSG "$($Details.ErrorMessage)" -Header -Footer
			Throw "$($Details.ErrorMessage)"
		}
		elseif ('SFWS0002' -eq $Details.ErrorCode) {
			Write-LogMessage -type Warning -MSG "$($Details.ErrorMessage)"
			Throw "$($Details.ErrorMessage)"
		}
		elseif ('SFWS0012' -eq $Details.ErrorCode) {
			Write-LogMessage -type Verbose -MSG "Invoke-Rest:`t$($Details.ErrorMessage)"
			Throw $PSItem
		}
		elseif ('PASWS011E' -eq $Details.Details.Errorcode) {
			Write-LogMessage -type Verbose -MSG "Invoke-Rest:`t$($Details.Details.ErrorMessage)"
			Throw $PSItem
		}
		IF ($null -eq $Details.Details.Errorcode) {
			Write-LogMessage -type Verbose -MSG "Invoke-Rest:`tError in running $Command on '$URI', $_.Exception"
			Write-LogMessage -type Verbose -MSG "Invoke-Rest:`t$($Details.ErrorMessage)"
			Throw $PSItem.Exception
		}
		Else {
			Write-LogMessage -type Verbose -MSG "Invoke-Rest:`tError in running $Command on '$URI', $($($Details.Details.ErrorMessage) -Join ';')"
			Write-LogMessage -type Verbose -MSG "Invoke-Rest:`t$($Details.Details.ErrorMessage)"
			Throw $($Details.Details.ErrorMessage)
		}
	}
	catch {
		Write-LogMessage -type Verbose -MSG "Invoke-Rest:`tCaught Exception"
		Write-LogMessage -type Error -MSG "Error in running $Command on '$URI', $_.Exception"
		Throw $(New-Object System.Exception ("Error in running $Command on '$URI'", $_.Exception))
	}
	Write-LogMessage -type Verbose -MSG "Invoke-Rest:`tResponse: $restResponse"
	return $restResponse
}

# @FUNCTION@ ======================================================================================================================
# Name...........: Get-Safe
# Description....: Returns an existing Safe object
# Parameters.....: Safe Name
# Return Values..: Safe object
# =================================================================================================================================
Function Get-Safe {
	<#
.SYNOPSIS
Returns an existing Safe object
.DESCRIPTION
Returns an existing Safe object
.PARAMETER SafeName
The Safe Name to return
#>
	param (
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[String]$safeName,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Continue', 'Ignore', 'Inquire', 'SilentlyContinue', 'Stop', 'Suspend')]
		[String]$ErrAction = 'Continue'
	)
	$_safe = $null
	try {
		$accSafeURL = $URL_SafeDetails -f $(ConvertTo-URL $safeName)
		$_safe = $(Invoke-Rest -Uri $accSafeURL -Header $g_LogonHeader -Command 'Get' -ErrAction $ErrAction)
	}
	catch {
		Write-LogMessage -type Error -MSG "Error getting Safe '$safeName' details. Error: $($($($_.ErrorDetails.Message) |ConvertFrom-Json).ErrorMessage)"
	}

	return $_safe
}

# @FUNCTION@ ======================================================================================================================
# Name...........: Convert-PermissionName
# Description....: Converts a permission key name from List Safe member permission to Add Safe member permission
# Parameters.....: Permission name
# Return Values..: The converted name of the permission
# =================================================================================================================================
Function Convert-PermissionName {
	<#
.SYNOPSIS
Returns an existing Safe object
.DESCRIPTION
Safe Member List Permissions returns a specific set of permissions name
The required names for Add/Update Safe Member is different
This function will convert from "List Permissions name set" to "Add Permission name set"
.PARAMETER PermName
The Permission name to convert
#>

	param (
		[Parameter(Mandatory = $true)]
		[String]$permName
	)
	$retPermName = ''
	Switch ($permName) {
		'ListContent' {
			$retPermName = 'ListAccounts'; break
		}
		'Retrieve' {
			$retPermName = 'RetrieveAccounts'; break
		}
		'Add' {
			$retPermName = 'AddAccounts'; break
		}
		'Update' {
			$retPermName = 'UpdateAccountContent'; break
		}
		'UpdateMetadata' {
			$retPermName = 'UpdateAccountProperties'; break
		}
		'Rename' {
			$retPermName = 'RenameAccounts'; break
		}
		'Delete' {
			$retPermName = 'DeleteAccounts'; break
		}
		'ViewAudit' {
			$retPermName = 'ViewAuditLog'; break
		}
		'ViewMembers' {
			$retPermName = 'ViewSafeMembers'; break
		}
		'RestrictedRetrieve' {
			$retPermName = 'UseAccounts'; break
		}
		'AddRenameFolder' {
			$retPermName = 'CreateFolders'; break
		}
		'DeleteFolder' {
			$retPermName = 'DeleteFolders'; break
		}
		'Unlock' {
			$retPermName = 'UnlockAccounts'; break
		}
		'MoveFilesAndFolders' {
			$retPermName = 'MoveAccountsAndFolders'; break
		}
		'ManageSafe' {
			$retPermName = 'ManageSafe'; break
		}
		'ManageSafeMembers' {
			$retPermName = 'ManageSafeMembers'; break
		}
		'ValidateSafeContent' {
			$retPermName = ''; break
		}
		'BackupSafe' {
			$retPermName = 'BackupSafe'; break
		}
		Default {
			$retPermName = ''; break
		}
	}
	return $retPermName
}

# @FUNCTION@ ======================================================================================================================
# Name...........: Get-SafeMembers
# Description....: Returns the Safe members
# Parameters.....: Safe name
# Return Values..: The Members of the input safe
# =================================================================================================================================
Function Get-SafeMembers {
	<#
.SYNOPSIS
Returns the Safe members
.DESCRIPTION
Returns the Safe members
.PARAMETER SafeName
The Safe Name to return its Members
#>
	param (
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[String]$safeName
	)
	$_safeMembers = $null
	$_safeOwners = $null
	try {
		$_defaultUsers = @('Master', 'Batch', 'Backup Users', 'Auditors', 'Operators', 'DR Users', 'Notification Engines', 'PVWAGWAccounts', 'PasswordManager')
		$accSafeMembersURL = $URL_SafeMembers -f $(ConvertTo-URL $safeName)
		$_safeMembers = $(Invoke-Rest -Uri $accSafeMembersURL -Header $g_LogonHeader -Command 'Get')
		# Remove default users and change UserName to MemberName
		$_safeOwners = $_safeMembers.members | Where-Object { $_.UserName -NotIn $_defaultUsers } | Select-Object -Property @{Name = 'MemberName'; Expression = { $_.UserName } }, Permissions
		$_retSafeOwners = @()
		# Converting Permissions output object to Dictionary for later use
		ForEach ($item in $_safeOwners) {
			$arrPermissions = @()
			# Adding Missing Permissions that are required for Add/Update Safe Member
			$arrPermissions += @{'Key' = 'InitiateCPMAccountManagementOperations'; 'Value' = $false }
			$arrPermissions += @{'Key' = 'SpecifyNextAccountContent'; 'Value' = $false }
			$arrPermissions += @{'Key' = 'AccessWithoutConfirmation'; 'Value' = $false }
			$arrPermissions += @{'Key' = 'RequestsAuthorizationLevel'; 'Value' = 1 }
			ForEach ($perm in $item.Permissions.PSObject.Properties) {
				$keyName = Convert-PermissionName -permName $perm.Name
				If (![string]::IsNullOrEmpty($keyName)) {
					$arrPermissions += @{'Key' = $keyName; 'Value' = $perm.Value }
				}
			}
			$item.Permissions = $arrPermissions
			$item | Add-Member -NotePropertyName 'SearchIn' -NotePropertyValue 'Vault'
			$item | Add-Member -NotePropertyName 'MembershipExpirationDate' -NotePropertyValue $null
			$_retSafeOwners += $item
		}
	}
	catch {
		Write-LogMessage -type Error -MSG "Error getting Safe '$safeName' members. Error: $(Join-ExceptionMessage $_.Exception)"
	}

	return $_retSafeOwners
}

# @FUNCTION@ ======================================================================================================================
# Name...........: Test-Safe
# Description....: Check if the safe exists
# Parameters.....: Safe name
# Return Values..: Bool
# =================================================================================================================================
Function Test-Safe {
	<#
.SYNOPSIS
Returns the Safe members
.DESCRIPTION
Returns the Safe members
.PARAMETER SafeName
The Safe Name check if exists
#>
	param (
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[String]$safeName
	)

	try {
		If ($null -eq $(Get-Safe -SafeName $safeName -ErrAction 'SilentlyContinue')) {
			# Safe does not exist
			Write-LogMessage -type Warning -MSG "Safe $safeName does not exist"
			return $false
		}
		else {
			# Safe exists
			Write-LogMessage -type Info -MSG "Safe $safeName exists"
			return $true
		}
	}
	catch {
		Write-LogMessage -type Error -MSG "Error testing safe '$safeName' existence. Error: $(Join-ExceptionMessage $_.Exception)" -ErrorAction 'SilentlyContinue'
	}
}

# @FUNCTION@ ======================================================================================================================
# Name...........: New-Safe
# Description....: Creates a new Safe
# Parameters.....: Safe name, (optional) CPM name, (optional) Template Safe
# Return Values..: Bool
# =================================================================================================================================
Function New-Safe {
	<#
.SYNOPSIS
Creates a new Safe
.DESCRIPTION
Creates a new Safe
.PARAMETER SafeName
The Safe Name to create
.PARAMETER CPMName
The CPM Name to add to the safe. if not entered, the default (first) CPM will be chosen
.PARAMETER TemplateSafeObject
The Template Safe object (returned from the Get-Safe method). If entered the new safe will be created based on this safe (including members)
#>
	param (
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[String]$safeName,
		[Parameter(Mandatory = $false)]
		[String]$cpmName = $CPM_NAME,
		[Parameter(Mandatory = $false)]
		[PSObject]$templateSafeObject
	)

	# Check if Template Safe is in used
	If ($null -ne $templateSafeObject) {
		# Using Template Safe
		Write-LogMessage -type Info -MSG "Creating Safe $safeName according to Template"
		# Update the safe name in the Safe Template Object
		$templateSafeObject.SafeName = $safeName
		$restBody = $templateSafeObject | ConvertTo-Json -Depth 3 -Compress
	}
	else {
		# Create the Target Safe
		Write-LogMessage -type Info -MSG "Creating Safe $safeName"
		$bodySafe = @{ SafeName = $safeName; Description = "$safeName - Created using Accounts Onboard Utility"; OLACEnabled = $false; ManagingCPM = $cpmName; NumberOfDaysRetention = $NumberOfDaysRetention }
		$restBody = $bodySafe | ConvertTo-Json -Depth 3 -Compress
	}
	try {
		$createSafeResult = $(Invoke-Rest -Uri $URL_Safes -Header $g_LogonHeader -Command 'Post' -Body $restBody)
		if ($createSafeResult) {
			Write-LogMessage -type Debug -MSG "Safe $safeName created"
			return $false
		}
		else {
			# Safe creation failed
			Write-LogMessage -type Error -MSG 'Safe Creation failed - Should Skip Account Creation'
			return $true
		}
	}
	catch {
		if ($null -eq $PSitem.ErrorDetails.Message) {
			Write-LogMessage -type Error -MSG "Failed to create safe $safeName with error: $($PSitem.Exception.Message)"
		}
		else {
			Write-LogMessage -type Error -MSG "Failed to create safe $safeName with error: $($($PSitem.ErrorDetails.Message| ConvertFrom-Json).Details.ErrorMessage)"
		}
	}
}
# @FUNCTION@ ======================================================================================================================
# Name...........: New-BadRecord
# Description....: Records accounts that have errors
# Parameters.....: None
# Return Values..: Bool
# =================================================================================================================================
Function New-BadRecord {
	<#
.SYNOPSIS
Outputs the bad record to a CSV file for correction and processing
.DESCRIPTION
Outputs the bad record to a CSV file for correction and processing
#>
	[CmdletBinding()]
	param (
		[Parameter()]
		[string]
		$ErrorMessage
	)
	Try {

		If ($null -ne $ErrorMessage) {
			$global:workAccount | Add-Member -MemberType NoteProperty -Name 'ErrorMessage' -Value $ErrorMessage -Force
		}
		if ($null -ne $global:workAccount.name) {
			$recordID = $global:workAccount.name
		}
		else {
			$recordID = $global:workAccount.userName + '@' + $global:workAccount.address + '#' + $global:workAccount.PlatfromID
		}
		If ($Global:BadAccountHashTable[$recordID].count -eq 0) {
			$Global:BadAccountHashTable.add($recordID, $global:workAccount)
			try {
				$global:workAccount | Export-Csv -Append -NoTypeInformation $csvPathBad -Force
				Write-LogMessage -type Debug -MSG 'Outputted Bad record to CSV'
				Write-LogMessage -type Verbose -MSG "Bad Record:`t$global:workAccount"
			}
			catch {
				Write-LogMessage -type Error -MSG "Unable to outout bad record to file: $csvPathBad"
				Write-LogMessage -type Verbose -MSG "Bad Record:`t$global:workAccount"
			}
		}
		else {
			Write-LogMessage -type Debug -MSG 'Bad record was already output before. Skipping adding to bad CSV'
		}
	}
	catch {
		Write-LogMessage -type Error -MSG "Unable to outout bad record to file using standard recordID csvLine used as record ID: $csvPathBad"
		Write-LogMessage -type Verbose -MSG "Bad Record:`t$global:workAccount"
		$Global:BadAccountHashTable.add($global:csvLine, $global:workAccount)

	}

}

# @FUNCTION@ ======================================================================================================================
# Name...........: New-GoodRecord
# Description....: Records accounts that have errors
# Parameters.....: Safe name, (optional) CPM name, (optional) Template Safe
# Return Values..: Bool
# =================================================================================================================================
Function New-GoodRecord {
	<#
.SYNOPSIS
Outputs the Good record to a CSV file for correction and processing
.DESCRIPTION
Outputs the Good record to a CSV file for correction and processing
.PARAMETER BadRecord
The Good record to output
#>

	try {
		If ($null -ne $global:workAccount.Password) {
			$global:workAccount.Password = $null
		}
		$global:workAccount | Export-Csv -Append -NoTypeInformation $csvPathGood
		Write-LogMessage -type Debug -MSG 'Outputted good record to CSV'
		Write-LogMessage -type Verbose -MSG "Good Record:`t$global:workAccount"
	}
	catch {
		Write-LogMessage -type Error -MSG "Unable to output good record to file: $csvPathGood"
		Write-LogMessage -type Verbose -MSG "Good Record:`t$global:workAccount"

	}
}


# @FUNCTION@ ======================================================================================================================
# Name...........: Add-Owner
# Description....: Add a new owner to an existing safe
# Parameters.....: Safe name, Member to add
# Return Values..: The Member object after added to the safe
# =================================================================================================================================
Function Add-Owner {
	<#
.SYNOPSIS
Add a new owner to an existing safe
.DESCRIPTION
Add a new owner to an existing safe
.PARAMETER SafeName
The Safe Name to add a member to
.PARAMETER Members
A List of members to add to the safe
#>
	param (
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[String]$safeName,
		[Parameter(Mandatory = $true)]
		$members
	)

	$restResponse = $null
	ForEach ($bodyMember in $members) {
		$restBody = @{ member = $bodyMember } | ConvertTo-Json -Depth 5 -Compress
		# Add the Safe Owner
		try {
			Write-LogMessage -type Verbose -MSG "Add-Owner:`tAdding owner '$($bodyMember.MemberName)' to safe '$safeName'..."
			# Add the Safe Owner
			$restResponse = Invoke-Rest -Uri $($URL_SafeMembers -f $(ConvertTo-URL $safeName)) -Header $g_LogonHeader -Command 'Post' -Body $restBody
			if ($null -ne $restResponse) {
				Write-LogMessage -type Verbose -MSG "Add-Owner:`tOwner '$($bodyMember.MemberName)' was successfully added to safe '$safeName'"
			}
		}
		catch {
			Write-LogMessage -type Error -MSG "Failed to add Owner to safe $safeName with error: $($_.Exception.Response.StatusDescription)"
		}
	}

	return $restResponse
}

# @FUNCTION@ ======================================================================================================================
# Name...........: Get-Account
# Description....: Returns a list of accounts based on a filter
# Parameters.....: Account name, Account address, Account Safe Name
# Return Values..: List of accounts
# =================================================================================================================================
Function Get-Account {
	<#
.SYNOPSIS
Returns accounts based on filters
.DESCRIPTION
Creates a new Account Object
.PARAMETER AccountName
Account user name
.PARAMETER AccountAddress
Account address
.PARAMETER SafeName
The Account Safe Name to search in
#>
	param (
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[String]$safeName,
		[Parameter(Mandatory = $false)]
		[String]$accountName,
		[Parameter(Mandatory = $false)]
		[String]$accountAddress,
		[Parameter(Mandatory = $false)]
		[String]$accountPlatformID,
		[Parameter(Mandatory = $false)]
		[String]$accountObjectName,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Continue', 'Ignore', 'Inquire', 'SilentlyContinue', 'Stop', 'Suspend')]
		[String]$ErrAction = 'Continue'
	)
	$_retAccount = $null
	$GetAccountsList = @()

	try {
		# Create a dynamic filter array
		$WhereArray = @()
		# Search only by Account Object Name
		If (-not [string]::IsNullOrEmpty($accountObjectName) -and ($WideAccountsSearch)) {
			Write-LogMessage -type Debug -MSG 'Searching accounts by Account name with WideAccountsSearch enabled'
			$urlSearchAccount = $URL_Accounts + "?filter=safename eq $(ConvertTo-URL $safeName)&search=$(ConvertTo-URL $accountObjectName)"
			$WhereArray += '$_.name -eq $accountObjectName'
		}
		elseIf (-not [string]::IsNullOrEmpty($accountObjectName) -and -not ($narrowSearch)) {
			Write-LogMessage -type Debug -MSG 'Searching accounts by Account name'
			$urlSearchAccount = $URL_Accounts + "?filter=safename eq $(ConvertTo-URL $safeName)"
			$WhereArray += '$_.name -eq $accountObjectName'
		}
		else {
			# Search according to other parameters (User name, address, platform)
			Write-LogMessage -type Debug -MSG 'Searching accounts by Account details (user name, address, platform)'
			$urlSearchAccount = $URL_Accounts + "?filter=safename eq $(ConvertTo-URL $safeName)&search=$(ConvertTo-URL $accountName) $(ConvertTo-URL $accountAddress)"
			If (-not [string]::IsNullOrEmpty($accountName)) {
				$WhereArray += '$_.userName -eq $accountName'
			}
			If (-not [string]::IsNullOrEmpty($accountAddress)) {
				$WhereArray += '$_.address -eq $accountAddress'
			}
			If (-not [string]::IsNullOrEmpty($accountPlatformID)) {
				$WhereArray += '$_.platformId -eq $accountPlatformID'
			}
			if (-not $ignoreAccountName) {
				If (-not [string]::IsNullOrEmpty($accountObjectName)) {
					$WhereArray += '$_.name -eq $accountObjectName'
				}
			}
		}
		try {
			# Search for accounts
			$GetAccountsResponse = $(Invoke-Rest -Uri $urlSearchAccount -Header $g_LogonHeader -Command 'Get' -ErrAction $ErrAction)
			$GetAccountsList += $GetAccountsResponse.value
			Write-LogMessage -type Debug -MSG "Found $($GetAccountsList.count) accounts so far..."
			# Get all accounts in case the search filter is too general
			$nextLink = $GetAccountsResponse.nextLink
			Write-LogMessage -type Debug -MSG "Getting accounts next link: $nextLink"

			While (-not [string]::IsNullOrEmpty($nextLink)) {
				$GetAccountsResponse = Invoke-Rest -Command Get -Uri $("$PVWAURL/$nextLink") -Header $g_LogonHeader
				$nextLink = $GetAccountsResponse.nextLink
				Write-LogMessage -type Debug -MSG "Getting accounts next link: $nextLink"
				$GetAccountsList += $GetAccountsResponse.value
				Write-LogMessage -type Debug -MSG "Found $($GetAccountsList.count) accounts so far..."
			}
		}
		catch [System.Net.WebException] {
			Throw $(New-Object System.Exception ("Get-Account: Error getting Account. Error: $($_.Exception.Response.StatusDescription)", $_.Exception))
		}
		Write-LogMessage -type Debug -MSG "Found $($GetAccountsList.count) accounts, filtering accounts..."

		# Filter Accounts based on input properties
		$WhereFilter = [scriptblock]::Create( ($WhereArray -join ' -and ') )
		$_retAccount = ( $GetAccountsList | Where-Object $WhereFilter )
		# Verify that we have only one result
		If ($_retAccount.count -gt 1) {
			Write-LogMessage -type Debug -MSG 'Found too many accounts'
			$_retAccount = $null
			throw "Found $($_retAccount.count) accounts in search - fix duplications"
		}
	}
	catch {
		Throw $(New-Object System.Exception ('Get-Account: Error getting Account.', $_.Exception))
	}

	return $_retAccount
}

# @FUNCTION@ ======================================================================================================================
# Name...........: Test-Account
# Description....: Checks if an account exists
# Parameters.....: Account name, Account address, Account Safe Name
# Return Values..: True / False
# =================================================================================================================================
Function Test-Account {
	<#
.SYNOPSIS
Test if an account exists (Search based on filters)
.DESCRIPTION
Test if an account exists (Search based on filters)
.PARAMETER AccountName
Account user name
.PARAMETER AccountAddress
Account address
.PARAMETER SafeName
The Account Safe Name to search in
#>
	param (
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[String]$safeName,
		[Parameter(Mandatory = $false)]
		[String]$accountName,
		[Parameter(Mandatory = $false)]
		[String]$accountAddress,
		[Parameter(Mandatory = $false)]
		[String]$accountPlatformID,
		[Parameter(Mandatory = $false)]
		[String]$accountObjectName
	)
	try {
		$accResult = $(Get-Account -accountName $accountName -accountAddress $accountAddress -accountPlatformID $accountPlatformID -accountObjectName $accountObjectName -safeName $safeName -ErrAction 'SilentlyContinue')
		If (($null -eq $accResult) -or ($accResult.count -eq 0)) {
			# No accounts found
			Write-LogMessage -type Debug -MSG "Account $g_LogAccountName does not exist"
			return $false
		}
		else {
			# Account Exists
			Write-LogMessage -type Info -MSG "Account $g_LogAccountName exist"
			return $true
		}
	}
	catch {
		Write-LogMessage -type Error -MSG "Error testing Account '$g_LogAccountName' existence. Error: $(Join-ExceptionMessage $_.Exception)" -ErrorAction 'SilentlyContinue'
	}
}

# @FUNCTION@ ======================================================================================================================
# Name...........: Test-PlatformProperty
# Description....: Checks if a property exists as part of the platform
# Parameters.....: Platform ID, Platform property
# Return Values..: True / False
# =================================================================================================================================
Function Test-PlatformProperty {
	<#
.SYNOPSIS
Returns accounts based on filters
.DESCRIPTION
Checks if a property exists as part of the platform
.PARAMETER PlatformID
The platform ID
.PARAMETER PlatfromProperty
The property to check in the platform
#>
	param(
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[String]$platformId,
		[Parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[String]$platformProperty,
		[Parameter(Mandatory = $false)]
		[ValidateSet('Continue', 'Ignore', 'Inquire', 'SilentlyContinue', 'Stop', 'Suspend')]
		[String]$ErrAction = 'Continue'
	)
	$_retResult = $false
	try {
		# Get the Platform details
		$GetPlatformDetails = $(Invoke-Rest -Uri $($URL_PlatformDetails -f $platformId) -Header $g_LogonHeader -Command 'Get' -ErrAction $ErrAction)
		If ($GetPlatformDetails) {
			Write-LogMessage -type Verbose -MSG "Found Platform id $platformId, checking if platform contains '$platformProperty'..."
			$_retResult = [bool]($GetPlatformDetails.Details.PSObject.Properties.name -match $platformProperty)
		}
		Else {
			Throw 'Platform does not exist or we had an issue'
		}
	}
	catch {
		Write-LogMessage -type Error -MSG "Error checking platform properties. Error: $(Join-ExceptionMessage $_.Exception)"
	}

	return $_retResult
}

# @FUNCTION@ ======================================================================================================================
# Name...........: Get-LogonHeader
# Description....: Invoke REST Method
# Parameters.....: Credentials
# Return Values..: Logon Header
# =================================================================================================================================
Function Get-LogonHeader {
	<#
.SYNOPSIS
Get-LogonHeader
.DESCRIPTION
Get-LogonHeader
.PARAMETER Credentials
The REST API Credentials to authenticate
#>
	param(
		[Parameter(Mandatory = $true)]
		[PSCredential]$Credentials,
		[Parameter(Mandatory = $false)]
		[bool]$concurrentSession,
		[Parameter(Mandatory = $false)]
		[string]$RadiusOTP
	)
	# Create the POST Body for the Logon
	# ----------------------------------
	If ($concurrentSession) {
		$logonBody = @{ username = $Credentials.username.Replace('\', ''); password = $Credentials.GetNetworkCredential().password; concurrentSession = 'true' } | ConvertTo-Json -Compress
	}
	else {
		$logonBody = @{ username = $Credentials.username.Replace('\', ''); password = $Credentials.GetNetworkCredential().password } | ConvertTo-Json -Compress
	}
	If (![string]::IsNullOrEmpty($RadiusOTP)) {
		$logonBody.Password += ",$RadiusOTP"
	}

	try {
		# Logon
		$logonToken = Invoke-Rest -Command Post -Uri $URL_Logon -Body $logonBody
		# Clear logon body
		$logonBody = ''
	}
	catch {
		Throw $(New-Object System.Exception ("Get-LogonHeader: $($_.Exception.Response.StatusDescription)", $_.Exception))
	}

	$logonHeader = $null
	If ([string]::IsNullOrEmpty($logonToken)) {
		Throw 'Get-LogonHeader: Logon Token is Empty - Cannot login'
	}

	# Create a Logon Token Header (This will be used through out all the script)
	# ---------------------------
	$logonHeader = @{Authorization = $logonToken }

	return $logonHeader
}
#endregion

#region Auto Update
# @FUNCTION@ ======================================================================================================================
# Name...........: Test-LatestVersion
# Description....: Tests if the script is running the latest version
# Parameters.....: NONE
# Return Values..: True / False
# =================================================================================================================================
Function Test-LatestVersion {
	<#
.SYNOPSIS
Tests if the script is running the latest version
.DESCRIPTION
Tests if the script is running the latest version
#>
	$githubURL = 'https://raw.githubusercontent.com/cyberark/epv-api-scripts/master'
	$scriptFolderPath = 'Account%20Onboard%20Utility'
	$scriptName = 'Accounts_Onboard_Utility.ps1'
	$scriptURL = "$githubURL/$scriptFolderPath/$scriptName"
	$getScriptContent = ''
	$retLatestVersion = $true
	# Remove any certificate validation callback (usually called when using DisableSSLVerify switch)
	[System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
	try {
		$getScriptContent = (Invoke-WebRequest -UseBasicParsing -Uri $scriptURL).Content
	}
	catch {
		Throw $(New-Object System.Exception ("Test-LatestVersion: Couldn't download and check for latest version", $_.Exception))
	}
	If ($($getScriptContent -match 'ScriptVersion\s{0,1}=\s{0,1}\"([\d\.]{1,5})\"')) {
		$gitHubScriptVersion = $Matches[1]
		If ([version]$gitHubScriptVersion -gt [version]$ScriptVersion) {
			$retLatestVersion = $false
			Write-LogMessage -type Info -MSG "Found new version: $gitHubScriptVersion - Updating..."
			$getScriptContent | Out-File "$ScriptFullPath.NEW"
			If (Test-Path -Path "$ScriptFullPath.NEW") {
				Rename-Item -Path $ScriptFullPath -NewName "$ScriptFullPath.OLD"
				Rename-Item -Path "$ScriptFullPath.NEW" -NewName $ScriptFullPath
				Remove-Item -Path "$ScriptFullPath.OLD"
			}
			Else {
				Write-LogMessage -type Error -MSG "Can't find the new script at location '$ScriptFullPath.NEW'."
				# Revert to current version in case of error
				$retLatestVersion = $true
			}
		}
		Else {
			Write-LogMessage -type Info -MSG "Current version ($ScriptVersion) is the latest!"
		}
	}

	return $retLatestVersion
}

#endregion


# Global URLS
# -----------
$URL_PVWAURL = Format-PVWAURL($PVWAURL)
$URL_PVWAAPI = $URL_PVWAURL + '/api'
$URL_Authentication = $URL_PVWAAPI + '/auth'
$URL_Logon = $URL_Authentication + "/$AuthType/Logon"
$URL_Logoff = $URL_Authentication + '/Logoff'

# URL Methods
# -----------
$URL_Safes = $URL_PVWAAPI + '/Safes'
$URL_SafeDetails = $URL_Safes + '/{0}'
$URL_SafeMembers = $URL_SafeDetails + '/Members'
$URL_Accounts = $URL_PVWAAPI + '/Accounts'
$URL_AccountsDetails = $URL_Accounts + '/{0}'
$URL_AccountsPassword = $URL_AccountsDetails + '/Password/Update'
$URL_PlatformDetails = $URL_PVWAAPI + '/Platforms/{0}'

# Script Defaults
# ---------------
$global:g_CsvDefaultPath = $Env:CSIDL_DEFAULT_DOWNLOADS

# Safe Defaults
# --------------
$NumberOfDaysRetention = 7
#$NumberOfVersionsRetention = 0

# Template Safe parameters
# ------------------------
$TemplateSafeDetails = ''
$TemplateSafeMembers = ''

# Initialize Script Variables
# ---------------------------
$global:g_LogonHeader = ''
$global:g_LogAccountName = ''

# Write the entire script command when running in Verbose mode
Write-LogMessage -type Verbose -MSG "Base:`t$g_ScriptCommand"
# Header
Write-LogMessage -type Info -MSG 'Welcome to Accounts Onboard Utility' -Header
Write-LogMessage -type Info -MSG "Starting script (v$ScriptVersion)" -SubHeader

# Check if to disable SSL verification
If ($DisableSSLVerify) {
	try {
		Write-Warning 'It is not Recommended to disable SSL verification' -WarningAction Inquire
		# Using Proxy Default credentials if the Server needs Proxy credentials
		[System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
		# Using TLS 1.2 as security protocol verification
		[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11
		# Disable SSL Verification
		[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $DisableSSLVerify }
	}
	catch {
		Write-LogMessage -type Error -MSG 'Could not change SSL validation'
		Write-LogMessage -type Error -MSG (Join-ExceptionMessage $_.Exception) -ErrorAction 'SilentlyContinue'
		return
	}
}
Else {
	try {
		Write-LogMessage -type Debug -MSG 'Setting script to use TLS 1.2'
		[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
	}
	catch {
		Write-LogMessage -type Error -MSG 'Could not change SSL settings to use TLS 1.2'
		Write-LogMessage -type Error -MSG (Join-ExceptionMessage $_.Exception) -ErrorAction 'SilentlyContinue'
	}
}

#Verify to skip searches
If ($BypassSafeSearch) {
	Write-Warning '
It is not Recommended to bypass searching for existing safes. This will also disable the ability to create new safes.' -WarningAction Inquire
}

If ($BypassAccountSearch) {
	Write-Warning "
It is not Recommended to bypass searching for existing accounts.
This may result in the creation of duplicate accounts.

If 'name' property is not populated, no protection against duplicate accounts exist.
Bypassing Account Searching should be used only on unpopulated vaults" -WarningAction Inquire
}

# Check that the PVWA URL is OK
If (![string]::IsNullOrEmpty($PVWAURL)) {
	If ($PVWAURL.Substring($PVWAURL.Length - 1) -eq '/') {
		$PVWAURL = $PVWAURL.Substring(0, $PVWAURL.Length - 1)
	}

	try {
		# Validate PVWA URL is OK
		Write-LogMessage -type Debug -MSG "Trying to validate URL: $PVWAURL"
		Invoke-WebRequest -UseBasicParsing -DisableKeepAlive -Uri $PVWAURL -Method 'Head' -TimeoutSec 30 | Out-Null
	}
	catch [System.Net.WebException] {
		If (![string]::IsNullOrEmpty($_.Exception.Response.StatusCode.Value__)) {
			Write-LogMessage -type Error -MSG "Received error $($_.Exception.Response.StatusCode.Value__) when trying to validate PVWA URL"
			Write-LogMessage -type Error -MSG 'Check your connection to PVWA and the PVWA URL'
			Throw

		}
	}
	catch {
		Write-LogMessage -type Error -MSG 'PVWA URL could not be validated'
		Write-LogMessage -type Error -MSG (Join-ExceptionMessage $_.Exception) -ErrorAction 'SilentlyContinue'
		Throw
	}

}
else {
	Write-LogMessage -type Error -MSG 'PVWA URL can not be empty'
	return
}

Write-LogMessage -type Info -MSG 'Getting PVWA Credentials to start Onboarding Accounts' -SubHeader


#region [Logon]
# Get Credentials to Login
# ------------------------
$caption = 'Accounts Onboard Utility'
If (![string]::IsNullOrEmpty($logonToken)) {
	if ($logonToken.GetType().name -eq 'String') {
		$logonHeader = @{Authorization = $logonToken }
		Set-Variable -Scope Global -Name g_LogonHeader -Value $logonHeader
	}
	else {
		Set-Variable -Scope Global -Name g_LogonHeader -Value $logonToken
	}
}
else {
	If (![string]::IsNullOrEmpty($PVWACredentials)) {
		$creds = $PVWACredentials
	}
	else {
		$msg = "Enter your $AuthType User name and Password"
		$creds = $Host.UI.PromptForCredential($caption, $msg, '', '')
	}
	if ($AuthType -eq 'radius' -and ![string]::IsNullOrEmpty($OTP)) {
		Set-Variable -Scope Global -Name g_LogonHeader -Value $(Get-LogonHeader -Credentials $creds -concurrentSession $concurrentSession -RadiusOTP $OTP )
	}
	else {
		Set-Variable -Scope Global -Name g_LogonHeader -Value $(Get-LogonHeader -Credentials $creds -concurrentSession $concurrentSession)
	}
	# Verify that we successfully logged on
	If ($null -eq $g_LogonHeader) {
		return # No logon header, end script
	}
}
#endregion

#region Template Safe
$TemplateSafeDetails = $null
If (![string]::IsNullOrEmpty($TemplateSafe) -and !$NoSafeCreation) {
	Write-LogMessage -type Info -MSG 'Checking Template Safe...'
	# Using Template Safe to create any new safe
	If ((Test-Safe -safeName $TemplateSafe)) {
		# Safe Exists
		$TemplateSafeDetails = (Get-Safe -SafeName $TemplateSafe)
		$TemplateSafeDetails.Description = 'Template Safe Created using Accounts Onboard Utility'
		$TemplateSafeMembers = (Get-SafeMembers -safeName $TemplateSafe)
		Write-LogMessage -type Debug -MSG "Template safe ($TemplateSafe) members ($($TemplateSafeMembers.Count)): $($TemplateSafeMembers.MemberName -join ';')"
		# If the logged in user exists as a specific member of the template safe - remove it to spare later errors
		If ($TemplateSafeMembers.MemberName.Contains($creds.UserName)) {
			$_updatedMembers = $TemplateSafeMembers | Where-Object { $_.MemberName -ne $creds.UserName }
			$TemplateSafeMembers = $_updatedMembers
		}
	}
	else {
		Write-LogMessage -type Error -MSG 'Template Safe does not exist' -Footer
		return
	}
}
#endregion

#region Check Create on Update

if ($CreateOnUpdate) {
	$Create = $CreateOnUpdate
}

#endregion

#region [Read Accounts CSV file and Create Accounts]
If ([string]::IsNullOrEmpty($CsvPath)) {
	$CsvPath = Open-FileDialog($g_CsvDefaultPath)
}
$delimiter = $(If ($CsvDelimiter -eq 'Comma') {
		','
	}
	else {
		"`t"
	} )
Write-LogMessage -type Info -MSG "Reading CSV from :$CsvPath"
$csvPathGood = "$csvPath.good.csv"
Remove-Item $csvPathGood -Force -ErrorAction SilentlyContinue
$csvPathBad = "$csvPath.bad.csv"
Remove-Item $csvPathBad -Force -ErrorAction SilentlyContinue

$accountsCSV = Import-Csv $csvPath -Delimiter $delimiter
$accountsCSV = $accountsCSV | Select-Object -ExcludeProperty ErrorMessage
$rowCount = $($accountsCSV.Safe.Count)
$counter = 0

$global:workAccount = $null
$global:csvLine = 1 # First line is the headers line
Write-LogMessage -type Info -MSG "Starting to Onboard $rowCount accounts" -SubHeader
ForEach ($account in $accountsCSV) {
	if ($null -ne $account) {
		# Increment the CSV line
		$global:csvLine++
		$global:workAccount = $account
		try {
			# Create some internal variables
			$shouldSkip = $false
			$safeExists = $false
			$createAccount = $false

			# Create the account object
			$objAccount = (New-AccountObject -AccountLine $account)

			# Check if bypass safe search is set to $true
			If (!$BypassSafeSearch) {
				# Check if the Safe Exists
				$safeExists = $(Test-Safe -safeName $objAccount.safeName)
			}
			else {
				#Bypass set to true, assuming safe does exist
				Write-LogMessage -type Warning -MSG 'Safe Search Bypassed'
				Write-LogMessage -type Warning -MSG "Assuming safe `"$($objAccount.safeName)`" already exists"
				$safeExists = $true
			}
			# Check if we can create safes or not
			If (($NoSafeCreation -eq $False) -and ($safeExists -eq $false)) {
				try {
					If ($Create) {
						# The target safe does not exist
						# The user chose to create safes during this process
						$shouldSkip = New-Safe -TemplateSafe $TemplateSafeDetails -Safe $account.Safe
						if (($shouldSkip -eq $false) -and ($null -ne $TemplateSafeDetails) -and ($TemplateSafeMembers -ne $null)) {
							$addOwnerResult = Add-Owner -Safe $account.Safe -Members $TemplateSafeMembers
							if ($null -eq $addOwnerResult) {
								throw
							}
							else {
								Write-LogMessage -type Debug -MSG "Template Safe members were added successfully to safe $($account.Safe)"
							}
						}
					}
				}
				catch {
					New-BadRecord $global:workAccount
					Write-LogMessage -type Debug -MSG "There was an error creating Safe $($account.Safe)"
				}
			}
			elseif (($NoSafeCreation -eq $True) -and ($safeExists -eq $false)) {
				# The target safe does not exist
				# The user chose not to create safes during this process
				Write-LogMessage -type Info -MSG 'Target Safe does not exist, No Safe creation requested - Will Skip account Creation'
				$shouldSkip = $true
			}
			If ($shouldSkip -eq $False) {
				# Check if bypass account search is set to $true
				if (!$BypassAccountSearch) {
					# Check if the Account exists
					$accExists = $(Test-Account -safeName $objAccount.safeName -accountName $objAccount.userName -accountAddress $objAccount.Address -accountObjectName $objAccount.name)
				}
				else {
					#Bypass set to true, assuming account does not exist
					Write-LogMessage -type Warning -MSG 'Account Search Bypassed'
					Write-LogMessage -type Warning -MSG "Assuming Account with username `"$($objAccount.userName)`" at address `"$($objAccount.address)`" does not exists"
					$accExists = $false
				}
				try {
					If ($accExists) {
						Write-LogMessage -type Verbose -MSG "Base:`tAccount '$g_LogAccountName' exists"
						# Get Existing Account Details
						Write-LogMessage -type Verbose -MSG "Base:`tRetrived $($objAccount.userName) from the CSV"
						Write-LogMessage -type Verbose -MSG "Base:`tOutput of  $($objAccount.userName) from the CSV in JSON: $($objAccount|ConvertTo-Json -Depth 5)"
						$s_Account = $(Get-Account -safeName $objAccount.safeName -accountName $objAccount.userName -accountAddress $objAccount.Address -accountObjectName $objAccount.name)
						If ($s_Account.Count -gt 1) {
							Throw "Too many accounts for '$g_LogAccountName' in safe $($objAccount.safeName)"
						}
						Write-LogMessage -type Verbose -MSG "Base:`tRetrived $($objAccount.userName) from Safe $($objAccount.safeName)"
						Write-LogMessage -type Verbose -MSG "Base:`tRAW format: $s_Account"
						Write-LogMessage -type Verbose -MSG "Base:`tConverted to JSON: $($s_Account|ConvertTo-Json -Depth 5)"
						If ($Update) {
							$updateChange = $false
							$s_AccountBody = @()
							$s_ExcludeProperties = @('id', 'secret', 'lastModifiedTime', 'createdTime', 'categoryModificationTime')
							# Check for existing properties needed update
							Foreach ($sProp in ($s_Account.PSObject.Properties | Where-Object { $_.Name -NotIn $s_ExcludeProperties })) {
								Write-LogMessage -type Verbose -MSG "Base:`tInspecting Account Property $($sProp.Name)"
								if ((![string]::IsNullOrEmpty($sprop.value)) -and ($sprop.Name -ne 'platformAccountProperties') ) {
									$s_ExcludeProperties += $sProp.Name
								}
								If ($sProp.TypeNameOfValue -eq 'System.Management.Automation.PSCustomObject') {
									# A Nested object
									ForEach ($subProp in $s_Account.($sProp.Name).PSObject.Properties) {
										Write-LogMessage -type Verbose -MSG "Base:`tInspecting Account Property $($subProp.Name)"
										$s_ExcludeProperties += $subProp.Name
										If (($null -ne $objAccount.$($sProp.Value)) -or ($null -ne $objAccount.$($sProp.Name).$($subProp.Name)) -and ($objAccount.$($sProp.Name).$($subProp.Name) -ne $subProp.Value)) {
											Write-LogMessage -type Verbose -MSG "Base:`tUpdating Account Property $($subProp.Name) value from: '$($subProp.Value)' to: '$($objAccount.$($sProp.Name).$($subProp.Name))'"
											$_bodyOp = '' | Select-Object 'op', 'path', 'value'
											$_bodyOp.op = 'replace'
											$_bodyOp.path = '/' + $sProp.Name + '/' + $subProp.Name
											$_bodyOp.value = $objAccount.$($sProp.Name).$($subProp.Name)
											If ($_bodyOp.value -eq $true) {
												$_bodyOp.value = 'true'
											}
											elseif ($_bodyOp.value -eq $false) {
												$_bodyOp.value = 'false'
											}
											$s_AccountBody += $_bodyOp
											# Adding a specific case for "/secretManagement/automaticManagementEnabled"
											If ('/secretManagement/automaticManagementEnabled' -eq ('/' + $sProp.Name + '/' + $subProp.Name)) {
												If ($objAccount.secretManagement.automaticManagementEnabled -eq $false) {
													# Need to add the manualManagementReason
													Write-LogMessage -type Verbose -MSG "Base:`tSince Account Automatic management is off, adding the Manual management reason"
													$_bodyOp = '' | Select-Object 'op', 'path', 'value'
													$_bodyOp.op = 'add'
													$_bodyOp.path = '/secretManagement/manualManagementReason'
													if ([string]::IsNullOrEmpty($objAccount.secretManagement.manualManagementReason)) {
														$_bodyOp.value = '[No Reason]'
													}
													else {
														$_bodyOp.value = $objAccount.secretManagement.manualManagementReason
													}
													$s_AccountBody += $_bodyOp
												}
											}
										}
									}
								}
								else {
									If (($null -ne $objAccount.$($sProp.Name)) -and ($objAccount.$($sProp.Name) -ne $sProp.Value)) {
										Write-LogMessage -type Verbose -MSG "Base:`tUpdating Account Property $($sProp.Name) value from: '$($sProp.Value)' to: '$($objAccount.$($sProp.Name))'"
										$_bodyOp = '' | Select-Object 'op', 'path', 'value'
										$_bodyOp.op = 'replace'
										$_bodyOp.path = '/' + $sProp.Name
										$_bodyOp.value = $objAccount.$($sProp.Name)
										$s_AccountBody += $_bodyOp
									}
								}
							} # [End] Check for existing properties
							# Check for new Account Properties
							ForEach ($sProp in ($objAccount.PSObject.Properties | Where-Object { $_.Name -NotIn $s_ExcludeProperties })) {
								$s_ExcludeProperties += $sProp.Name
								Write-LogMessage -type Verbose -MSG "Base:`tInspecting for New Property $($sProp.Name)"
								If ($sProp.Name -eq 'remoteMachinesAccess') {
									ForEach ($sSubProp in $objAccount.remoteMachinesAccess.PSObject.Properties) {
										Write-LogMessage -type Verbose -MSG "Base:`tUpdating Account Remote Machine Access Properties $($sSubProp.Name) value to: '$($objAccount.remoteMachinesAccess.$($sSubProp.Name))'"
										If ($sSubProp.Name -in ('remotemachineaddresses', 'restrictmachineaccesstolist', 'remoteMachines', 'accessRestrictedToRemoteMachines')) {
											# Handle Remote Machine properties
											$_bodyOp = '' | Select-Object 'op', 'path', 'value'
											if ($sSubProp.Name -in ('remotemachineaddresses', 'remoteMachines')) {
												$_bodyOp.path = '/remoteMachinesAccess/remoteMachines'
											}
											if ($sSubProp.Name -in ('restrictmachineaccesstolist', 'accessRestrictedToRemoteMachines')) {
												$_bodyOp.path = '/remoteMachinesAccess/accessRestrictedToRemoteMachines'
											}
											If ([string]::IsNullOrEmpty($objAccount.remoteMachinesAccess.$($sSubProp.Name))) {
												$_bodyOp.op = 'remove'
												#$_bodyOp.value = $null
												# Remove the Value property
												$_bodyOp = ($_bodyOp | Select-Object op, path)
											}
											else {
												$_bodyOp.op = 'replace'
												$_bodyOp.value = $objAccount.remoteMachinesAccess.$($sSubProp.Name) -join ';'
											}
											$s_AccountBody += $_bodyOp
										}
									}
								}
								ElseIf ($sProp.Name -eq 'platformAccountProperties') {
									ForEach ($sSubProp in $objAccount.platformAccountProperties.PSObject.Properties) {
										If (($null -ne $objAccount.$($sProp.Name).$($sSubProp.Name)) -and ($s_Account.$($sProp.Name).$($sSubProp.Name) -ne $sSubProp.Value)) {
											Write-LogMessage -type Verbose -MSG "Base:`tAdding Platform Account Properties $($sSubProp.Name) value to: '$($objAccount.platformAccountProperties.$($sSubProp.Name))'"
											# Handle new Account Platform properties
											$_bodyOp = '' | Select-Object 'op', 'path', 'value'
											$_bodyOp.op = 'add'
											$_bodyOp.path = '/platformAccountProperties/' + $sSubProp.Name
											$_bodyOp.value = $objAccount.platformAccountProperties.$($sSubProp.Name)
											$s_AccountBody += $_bodyOp
										}
									}
								}
								else {
									Write-LogMessage -type Verbose -MSG "Base:`tObject name to inspect is $($sProp.Name) with a value of $($sProp.Value)"
									If (($null -ne $objAccount.$($sProp.Name)) -and ($objAccount.$($sProp.Name) -ne $s_Account.$($sProp.Name))) {
										Write-LogMessage -type Verbose -MSG "Base:`tUpdating Account Property '$($sProp.Name)' value from: '$($s_Account.$($sProp.Name))' to: '$($objAccount.$($sProp.Name))'"

										$_bodyOp = '' | Select-Object 'op', 'path', 'value'
										$_bodyOp.op = 'replace'
										$_bodyOp.path = '/' + $sProp.Name
										$_bodyOp.value = $objAccount.$($sProp.Name)
										$s_AccountBody += $_bodyOp
									}
								}
							}

							If ($s_AccountBody.count -eq 0) {
								Write-LogMessage -type Info -MSG 'No Account updates detected - Skipping'
							}
							else {
								# Update the existing account
								$restBody = ConvertTo-Json $s_AccountBody -Depth 5 -Compress
								$urlUpdateAccount = $URL_AccountsDetails -f $s_Account.id
								$UpdateAccountResult = $(Invoke-Rest -Uri $urlUpdateAccount -Header $g_LogonHeader -Body $restBody -Command 'PATCH')
								if ($null -ne $UpdateAccountResult) {
									Write-LogMessage -type Info -MSG 'Account properties Updated Successfully'
									$updateChange = $true
								}
							}

							# Check if Secret update is needed
							If (![string]::IsNullOrEmpty($objAccount.secret)) {
								# Verify that the secret type is a Password (Only type that is currently supported to update
								if ($objAccount.secretType -eq 'password') {
									Write-LogMessage -type Debug -MSG 'Updating Account Secret...'
									# This account has a password and we are going to update item
									$_passBody = '' | Select-Object 'NewCredentials'
									# $_passBody.ChangeEntireGroup = $false
									$_passBody.NewCredentials = $objAccount.secret
									# Update secret
									$restBody = ConvertTo-Json $_passBody -Compress
									$urlUpdateAccount = $URL_AccountsPassword -f $s_Account.id
									$UpdateAccountResult = $(Invoke-Rest -Uri $urlUpdateAccount -Header $g_LogonHeader -Body $restBody -Command 'POST')
									if ($null -ne $UpdateAccountResult) {
										Write-LogMessage -type Info -MSG 'Account Secret Updated Successfully'
										$updateChange = $true
									}
								}
								else {

									New-BadRecord $global:workAccount
									Write-LogMessage -type Warning -MSG 'Account Secret Type is not a password, no support for updating the secret - skipping'
								}
							}
							If ($updateChange) {
								# Increment counter
								$counter++
								New-GoodRecord
								Write-LogMessage -type Info -MSG "[$global:csvLine] Updated $g_LogAccountName successfully."
							}
						}
						ElseIf ($Create) {
							try {
								# Account Exists, Creating the same account again will cause duplications - Verify with user
								if ($SkipDuplicates) {
									$createAccount = $false
									$counter++
									New-GoodRecord
									Write-LogMessage -type Info -MSG "[$global:csvLine] Skipped $g_LogAccountName successfully."
								}
								else {
									Write-Warning 'The Account Exists, Creating the same account twice will cause duplications' -WarningAction Inquire
									# If the user clicked yes, the account will be created
									Write-LogMessage -type Warning -MSG "Account '$g_LogAccountName' exists, User chose to create the same account twice"
									$createAccount = $true
								}
							}
							catch {
								# User probably chose to Halt/Stop the action and not create a duplicate account

								New-BadRecord $global:workAccount
								Write-LogMessage -type Info -MSG "[$global:csvLine] Skipping onboarding account '$g_LogAccountName' to avoid duplication."
								$createAccount = $false
							}
						}
						ElseIf ($Delete) {
							# Single account found for deletion
							$urlDeleteAccount = $URL_AccountsDetails -f $s_account.id
							$DeleteAccountResult = $(Invoke-Rest -Uri $urlDeleteAccount -Header $g_LogonHeader -Command 'DELETE')
							if ($null -ne $DeleteAccountResult) {
								# Increment counter
								$counter++
								New-GoodRecord
								Write-LogMessage -type Info -MSG "[$global:csvLine)] Deleted $g_LogAccountName successfully."
							}
						}
					}
					else {
						If ($Create) {
							$createAccount = $true
						}
						Else {
							New-BadRecord $global:workAccount
							Write-LogMessage -type Error -MSG "[$global:csvLine] You requested to Update/Delete an account $g_LogAccountName that does not exist"
							$createAccount = $false
						}
					}

					if ($createAccount) {
						try {
							# Create the Account
							$restBody = $objAccount | ConvertTo-Json -Depth 5 -Compress
							Write-LogMessage -type Debug -MSG $restBody
							$addAccountResult = $(Invoke-Rest -Uri $URL_Accounts -Header $g_LogonHeader -Body $restBody -Command 'Post')
							if ($null -ne $addAccountResult) {
								Write-LogMessage -type Info -MSG "[$global:csvLine] Account Onboarded Successfully"
								# Increment counter
								$counter++
								New-GoodRecord
								Write-LogMessage -type Info -MSG "[$global:csvLine] Added $g_LogAccountName successfully."
							}
						}
						catch {
							New-BadRecord -ErrorMessage $PSItem.Exception.Message
							Throw $($PSitem.Exception.Message)
						}
					}
				}
				catch {
					New-BadRecord -ErrorMessage $PSItem.Exception.Message
					Write-LogMessage -type Error -MSG "CSV Line: $($global:csvLine): $PSItem"
					Write-LogMessage -type Verbose -MSG "Base:`tError: $PSItem`tCSV Line: $($global:csvLine)`tSafeName: `"$($global:workAccount.safe)`" `tUsername: `"$($global:workAccount.userName)`" `tAddress: `"$($global:workAccount.Address)`" `tObject: `"$($global:workAccount.name)`""
				}
			}
			else {
				New-BadRecord -ErrorMessage $PSItem.Exception.Message
				Write-LogMessage -type Info -MSG "CSV Line: $global:csvLine"
				Write-LogMessage -type Info -MSG "Skipping onboarding account $g_LogAccountName into the Password Vault since safe does not exist and safe creation is disabled."
			}
		}
		catch {
			New-BadRecord -ErrorMessage $PSItem.Exception.Message
			Write-LogMessage -type Error -MSG "CSV Line: $global:csvLine"
			Write-LogMessage -type Error -MSG "Skipping onboarding account $g_LogAccountName into the Password Vault. Error: $(Join-ExceptionMessage $_.Exception)"
		}
	}
}
#endregion

#region [Logoff]
# Logoff the session
# ------------------
If (![string]::IsNullOrEmpty($logonToken)) {
	Write-Host 'LogonToken passed, session NOT logged off'
}
else {
	Write-Host 'Logoff Session...'
	Invoke-Rest -Uri $URL_Logoff -Header $g_LogonHeader -Command 'Post'
}
# Footer
Write-LogMessage -type Info -MSG "Completed processing $counter out of $rowCount accounts successfully." -Footer
#endregion
