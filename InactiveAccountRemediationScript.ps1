#Connect to azure account through automatic connection
Write-Output "-----------------------"
$connectionName = "AzureRunAsConnection"
try
{
    # Get the connection "AzureRunAsConnection "
    $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName         

    Connect-AzAccount `
        -ServicePrincipal `
        -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
}
catch {
    if (!$servicePrincipalConnection)
    {
        $ErrorMessage = "Connection $connectionName not found."
        throw $ErrorMessage
    } else{
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}
Write-Output "-----------------------"


#Connect to AzureAD through service principal
$servicePrincipalConnection=Get-AutomationConnection -Name $connectionName 
$B = Connect-AzureAD -TenantId $servicePrincipalConnection.TenantId -ApplicationId $servicePrincipalConnection.ApplicationId -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint
Write-Output "-----------------------"
Write-Output "Connect-AzureAD:"
Write-Output $B
Write-Output "-----------------------"


#Set subscription ID
#put subscription id in ''
Set-AzContext -Subscription ''
$something = Get-AzContext
Write-Output "-----------------------"
Write-Output "AzContext:"
Write-Output $something
Write-Output "-----------------------"


#Provide your Office 365 Tenant Id or Tenant Domain Name in ""
$TenantId = ""
  
#Provide Azure AD Application (client) Id of your app in "".
#You should have granted Admin consent for this app to use the application permissions "AuditLog.Read.All and User.Read.All" in your tenant.
$AppClientId=""


#Provide Application client secret key in ""
$ClientSecret = ""
$RequestBody = @{client_id=$AppClientId;client_secret=$ClientSecret;grant_type="client_credentials";scope="https://graph.microsoft.com/.default";}
$OAuthResponse = Invoke-RestMethod -Method Post -Uri https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token -Body $RequestBody –UseBasicParsing
$AccessToken = $OAuthResponse.access_token


#Form request headers with the acquired $AccessToken
$headers = @{'Content-Type'="application\json";'Authorization'="Bearer $AccessToken"}
 
#This request get users list with signInActivity.
$ApiUrl = "https://graph.microsoft.com/beta/users?`$select=displayName,userPrincipalName,signInActivity,userType,assignedLicenses,accountEnabled,createdDateTime&`$top=999"
 
#create variables to use in loops
$Result = @()
$Roles = ""
$RolesParsed = ""
$allAZADUserWithRoleMapping = @()


While ($ApiUrl -ne $Null) #Perform pagination if next page link (odata.nextlink) returned.
{
	$Response = Invoke-WebRequest -Method GET -Uri $ApiUrl -ContentType "application\json" –UseBasicParsing -Headers $headers | ConvertFrom-Json
	if($Response.value)
	{
		#go through all users
		$Users = $Response.value
		ForEach($User in $Users)
		{
		#check if account is enabled so not to check accounts that were previously disabled
		if ($User.accountEnabled -eq $true) {
			#all roles of current user in loop
			$Roles = Get-AzRoleAssignment -SignInName $User.userPrincipalName
			#role names of current users
			$lclc = $Roles | Measure-Object -Property RoleDefinitionName
			#clear variable so that it does not store last loop/user information
			Clear-Variable -Name "RolesParsed"
			#for number of roles current user in loop has
			For ($i=0; $i -lt $lclc.Count; $i++)
			{
				#if user has 1 role store it else store the current i value role
				if ($i -eq 0 -and $lclc.Count -eq 1){
					$RolesParsed += $Roles.Scope + " - " + $Roles.RoleDefinitionName
				}
				else{
					$RolesParsed += $Roles.Scope[$i] + " - " + $Roles.RoleDefinitionName[$i] +"`n"
				}
			}
			#set variable to null so that it does not store last loop/user information 
			$allAZADUserWithRoleMapping = @()

			#get all active directory roles of current user in loop and store them in $allAZADUserWithRoleMapping
			Get-AzureADDirectoryRoleTemplate | ForEach-Object{
    		$roleName = $_.DisplayName
    		Get-AzureADDirectoryRole | Where-Object {$_.displayName -eq $roleName} | ForEach-Object{
        		Get-AzureADDirectoryRoleMember -ObjectId $_.ObjectId | ForEach-Object{
            		$extProp = $_.ExtensionProperty
            		$objUser = New-Object psObject
            
					if ($_.DisplayName -eq $User.displayName)
					{
						$allAZADUserWithRoleMapping += New-Object psObject -property $([ordered]@{
						RoleName = $roleName
						})
					}
        	}
    		}
		} 
			#store all values that have been retrieved in readable format
			$Result += New-Object PSObject -property $([ordered]@{ 
				DisplayName = $User.displayName
				UserPrincipalName = $User.userPrincipalName
				LastSignInDateTime = if($User.signInActivity.lastSignInDateTime) { [DateTime]$User.signInActivity.lastSignInDateTime } Else {$null}
				createdDateTime = [DateTime]$User.createdDateTime
				IsLicensed  = if ($User.assignedLicenses.Count -ne 0) { $true } else { $false }
				IsGuestUser  = if ($User.userType -eq 'Guest') { $true } else { $false }
				serviceRoles = $RolesParsed
				RoleName = $allAZADUserWithRoleMapping.RoleName
		})		
		}
		}
	}
	$ApiUrl=$Response.'@odata.nextlink'
}
#variables for inactivity to calculate date
$DaysInactive = 14
$DaysSinceCreation = 7
$dateTime = (Get-Date).Adddays(-($DaysInactive))
$dateCreatedthreshold = (Get-Date).Adddays(-($DaysSinceCreation))


Write-Output "-----------------------"
#users not logged in before $dateTime
$MCQ = $Result | Where-Object { $_.LastSignInDateTime -le $dateTime }
#users never logged in and account created after $dateCreatedthreshold
$LMQ = $Result | Where-Object { $_.LastSignInDateTime -eq $Null -and $_.createdDateTime -le $dateCreatedthreshold }
#users never logged in and account created before $dateCreatedthreshold
$QMF = $Result | Where-Object { $_.LastSignInDateTime -eq $Null -and $_.createdDateTime -gt $dateCreatedthreshold }


#print results
Write-Output "-----------------------"
Write-Output "Users that have not logged in the last 14 days:"
Write-Output $MCQ
Write-Output "-----------------------"
Write-Output "-----------------------"
Write-Output "Users that have not logged in at all:"
Write-Output $LMQ
Write-Output "-----------------------"
Write-Output "-----------------------"
Write-Output "Users that have not logged in at all and account was created less than 7 days ago:"
Write-Output $QMF
Write-Output "-----------------------"
Write-Output "-----------------------"



# Disable Inactive Users
ForEach ($Item in $LMQ){
  $DistName = $Item.UserPrincipalName
  Set-AzureADUser -ObjectID $DistName -AccountEnabled $false
}
#print enabled users
Write-Output "-----------------------"
Write-Output "Enabled Users:"
Get-AzureADUser -Filter "AccountEnabled eq true" | Select-Object DisplayName
Write-Output "-----------------------"

