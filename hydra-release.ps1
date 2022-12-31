#!/usr/bin/env pwsh

[CmdletBinding()]
 param(  

    [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
    [string]$jsoninput,

    [Parameter(Mandatory=$false, ValueFromPipeline=$false)]
    [alias('r')]
    [string]$Release_environment,

    [Parameter(Mandatory=$false, ValueFromPipeline=$false)]
    [Alias("i")]
    [switch]$interactive,

    [Parameter(Mandatory=$false, ValueFromPipeline=$false)]
    [switch]$gen_json,

    [Parameter(Mandatory=$false, ValueFromPipeline=$false)]
    [switch]$Auto_approve,

    [Parameter(Mandatory=$false, ValueFromPipeline=$false)]
    [switch]$dbg=$false

)


function load-config{

	if( $dbg -eq $true  ) { write-Logger -Message "entering Loadconfig" }
	$config_dict=$(get-content ~/.hydra/config.json -raw )   | ConvertFrom-Json -Depth 10  -AsHashtable

	# userdefined
	$global:AZURE_DEVOPS_BASE_URL=$config_dict.userdefined.azure_devops_release_url
	$global:CD_PIPELINES=$($config_dict.userdefined.cd_pipelines) 
	$global:CD_ENVIRONMENTS=$($config_dict.userdefined.cd_environments)
	$global:manual_trigger=$($config_dict.userdefined.manual_trigger)

	# Defaults
	if("$env:DEVOPS_PAT" -eq $null -or "$env:DEVOPS_PAT"  -eq ""){ write-Logger -Debug ERROR -Message "Environment Variable 'DEVOPS_PAT' either empty or not set"; exit 3; }
	$PAT=[System.Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(":$env:DEVOPS_PAT"))
	$global:token="Basic $PAT"
	
	$global:LOGPATH=$($config_dict.defaults.logpath) 
	$global:PSStyle.Progress.View=$($config_dict.defaults."psstyle.progress.view") 
	$global:ErrorActionPreference =$($config_dict.defaults.erroractionpreference) 
}

function create-release{

	param($Array_of_builds)

	if ($dbg -eq $true) {  write-Logger -Level DEBUG -Message "enter create-release" }


	# headers
	$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
	$headers.Add("Authorization", "$token")
	$headers.Add("Content-Type", "application/json")

	$Array_of_response = $Array_of_builds | ForEach-Object -ThrottleLimit 4 -Parallel {

		

		${function:artifacts} = $using:funcdef_artifacts

		#check if the json/hashmap has Alias if not assume that _+Build_definition_name is the alias (which is default)
		if($PSItem.Build_artifact_alias -ne $null ) { $Alias= $PSItem.Build_artifact_alias } 
		else{ 
			write-host "artifact_Alias is empty, assuming it to be '_'+'Build_definition_name'"
			$Alias='_'+$PSItem.Build_definition_name  
		}

		#check if the json/hashmap has Release_definition_id if not get it from config.json using alias
		if($PSItem.Release_definition_name -ne $null ) { $Release_definition_name= $PSItem.Release_definition_name}
		else{ 
			$Release_definition_name=( ($using:CD_PIPELINES) | where{ $_.alias -eq $Alias } ).name
		}
		

		$Release_definition_id=( ($using:CD_PIPELINES) | where{ $_.alias -eq $Alias } ).id
		$Build_id=$PSItem.Build_id
		$Build_number=$PSItem.Build_number

		If ($Build_id -eq $null ) { 
			# write-host "create-release : Release definition id is $($Release_definition_id)"
			$response_from_artifact =  artifacts -release_definition_id $Release_definition_id -token_within_runspace $using:token
			$build_id= ($response_from_artifact.artifactVersions.versions | where {$_.name -eq  $build_number } ).id

		}


		# Body
		$body=@{ 
		"definitionId"= $Release_definition_id;  
		"description"= "Generated through Deployment script"; 
		"manualEnvironments"= $using:manual_trigger
		"artifacts"= @( @{  "alias"= "$alias";  "instanceReference"= @{ "id"= "$Build_id"}  } ); 
		} | ConvertTo-Json -Depth 10
		

		try {
			$response = Invoke-RestMethod "$using:AZURE_DEVOPS_BASE_URL/Release/releases?api-version=7.1-preview.8" -Method 'POST' -Headers $using:headers -Body $body
		
		}
		catch [Exception] {

			write-host "An error occurred:" #| Tee-Object -FilePath $($LogFile) -Append
			write-host  "$_.Exception.GetType().FullName, $_.Exception.Message , $_.Exception" #| Tee-Object -FilePath $($LogFile) -Append      
			write-host  $response
			write-output @{"Release_definition_name"=$Release_definition_name;"Build_artifact_alias"=$Alias;"Status"="completed";"release_id"=$Release_id;"environment_id"=$environment_id;"outcome"="failed";"error"="error while creating release"}
			return
		}
		 
		$Release_id= $response.id
		$environment_id= ($response.environments | where { $_.name -eq "$using:Release_environment" }).id
		
		write-output @{"Release_definition_name"=$Release_definition_name;"Build_artifact_alias"=$Alias;"Status"="release-created";"Build_name"=$Build_number;"release_id"=$Release_id;"environment_id"=$environment_id;"outcome"="succesful";"error"=$null}

	}
	return $Array_of_response
}


function deploy_release {

	param ($array_of_output_from_create_release)

	if ($dbg -eq $true) {  write-Logger -Level DEBUG -Message "entering Deploy-release" }


	$output_array=$array_of_output_from_create_release | foreach-object -throttlelimit 4 -parallel {

		
		$curr_iter_obj=$psitem
		if ($PSItem.outcome -ne "succesful") { Write-Output $curr_iter_obj  ; return}
		
		$release_id= $curr_iter_obj.release_id
		$environment_id=$curr_iter_obj.environment_id

		$headers = new-object "system.collections.generic.dictionary[[string],[string]]"
		$headers.add("authorization", "$using:token")
		$headers.add("content-type", "application/json")

		$body = @{ "status"= "inprogress"; "comment"= "triggered from automation script"} | convertto-json -depth 5

		
		try {
			$response = invoke-restmethod "$using:AZURE_DEVOPS_BASE_URL/release/releases/$($release_id)/environments/$($environment_id)?api-version=7.1-preview.7" -method 'patch' -headers $headers -body $body
		}
		catch [exception] {

			write-Logger -Level ERROR -Message "an error occurred:" #| tee-object -filepath $($logfile) -append
			write-Logger -Level ERROR -Message "$_.exception.gettype().fullname, $_.exception.message , $_.exception" #| tee-object -filepath $($logfile) -append      
			write-Logger -Level ERROR -Message $response
			$curr_iter_obj["error"]="error while deploying created release"
			$curr_iter_obj["Status"]="completed";
			$curr_iter_obj["outcome"]="failed"
			write-output $curr_iter_obj
			return;
		}
		$curr_iter_obj["outcome"]="succesful"
		$curr_iter_obj["Status"]="Deploying_release";
		write-output $curr_iter_obj

	}
	return $output_array
}


function approve_release{
	param($array_of_hashmap_deploy_release)
	# write-host $array_of_hashmap_deploy_release
	if ($dbg -eq $true) {  write-Logger -Level DEBUG -Message "entering approve_release" } 


	$array_of_hashmap_deploy_release | foreach {

		$curr_iter_obj = $PSItem

		if ($curr_iter_obj.outcome -ne "succesful") { Write-Output $curr_iter_obj  ; continue}
		if ($curr_iter_obj.approval_id -eq "" -or $curr_iter_obj.approval_id -eq $null) { $curr_iter_obj.error="approval_id is null, please check if someone else is deploying the same service or not" ; $curr_iter_obj.outcome="failed"; Write-Output $curr_iter_obj  ;continue}

		$approval_id=$curr_iter_obj.approval_id 


		$headers = new-object "system.collections.generic.dictionary[[string],[string]]"
		$headers.add("authorization", "$token")
		$headers.add("content-type", "application/json")

		# $user_input= Read-Host -Prompt "$($curr_iter_obj.Build_definition_name) $($curr_iter_obj.release_id) [y/n]"
		if( $Auto_approve  -eq $false )	{$user_input= Read-Host -Prompt "$($curr_iter_obj.Release_definition_name) | $($curr_iter_obj.Build_name) | $($Release_environment)  [y/n] "} 
		else{ $user_input = "y" }

		if( $user_input -eq "y" ) {$approval="approved"} 
		else {$approval="rejected"; write-Logger -Level INFO -Message "Rejecting ...." }

		$body= @{"status"= "$approval";"comments"= "Approved/Rejected through automation"} | convertto-json

		try {
			$response = invoke-restmethod "$AZURE_DEVOPS_BASE_URL/Release/approvals/$approval_id`?api-version=7.1-preview.3" -method 'PATCH' -headers $headers -Body $body
			# Write-Host "$response"
		}
		catch [exception] {

			write-Logger -Level ERROR -Message "an error occurred:" #| tee-object -filepath $($logfile) -append
			write-logger -Level ERROR -Message "$_.exception.gettype().fullname, $_.exception.message , $_.exception" #| tee-object -filepath $($logfile) -append      
			write-logger -Level ERROR -Message $response
			$curr_iter_obj["error"]="error while approving created release"
			$curr_iter_obj["outcome"]="failed"
			$curr_iter_obj["Status"]="completed"
			write-output $curr_iter_obj
			return;
		}
		$curr_iter_obj["modifiedOn"]=$response.modifiedOn.tostring('o')
		$curr_iter_obj["Status"]="Approving/Rejecting Release"
		$curr_iter_obj["Approval"]="$approval"
		$curr_iter_obj["outcome"]="succesful"
		write-output $curr_iter_obj
	}
}


function _parallel_artifacts {

	param($release_definition_id,$token_within_runspace )

	if ($dbg -eq $true) {  write-logger -Level DEBUG -Message "entering _parallel_artifacts" }

	if($token -eq '' -or $token -eq $null){$token=$token_within_runspace }

	
	$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
	$headers.Add("Authorization", "$token")


		try {
			$response = Invoke-RestMethod "$Using:AZURE_DEVOPS_BASE_URL/Release/artifacts/versions?releaseDefinitionId=$($release_definition_id)" -Method 'GET' -Headers $headers

		}
		catch [Exception] {

			write-logger -Level ERROR -Message "Artifact | An error occurred: " #| Tee-Object -FilePath $($LogFile) -Append
			write-logger -Level ERROR -Message "$_.Exception.GetType().FullName, $_.Exception.Message , $_.Exception" #| Tee-Object -FilePath $($LogFile) -Append      
			write-logger -Level ERROR -Message $response

		}
	# Write-Host ($response | convertto-json)
	if ($dbg -eq $true) {  write-logger -Level DEBUG -Message "exiting artifact" }
	return $response
}


# helper function
function artifacts {

	param($release_definition_id,$token_within_runspace )

	if ($dbg -eq $true) {  write-logger -Level DEBUG -Message "entering artifacts" }

	# if($token -eq '' -or $token -eq $null){write-host "$($using:token)"}
	if($token -eq '' -or $token -eq $null){$token=$token_within_runspace }

	
	$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
	$headers.Add("Authorization", "$token")


		try {

			$response = Invoke-RestMethod "$AZURE_DEVOPS_BASE_URL/Release/artifacts/versions?releaseDefinitionId=$($release_definition_id)" -Method 'GET' -Headers $headers

		}
		catch [Exception] {

			write-logger -Level ERROR -Message "Artifact | An error occurred: " 
			write-logger -Level ERROR -Message "$_.Exception.GetType().FullName, $_.Exception.Message , $_.Exception" 
			write-logger -Level ERROR -Message "$response"

		}
	# Write-Host ($response | convertto-json)
	if ($dbg -eq $true) {  write-logger -Level DEBUG -Message "exiting artifact" }
	return $response
}



function get_approval_id{

	param( $array_of_hashmap_deploy_release)

	if ($dbg -eq $true) {  write-logger -Level DEBUG -Message "entering get_approval_id" }
	
	$output_array= $array_of_hashmap_deploy_release | ForEach-Object -ThrottleLimit 4 -Parallel {
		
		$curr_iter_obj=$PSItem
		$release_id=$curr_iter_obj.release_id

		if ($curr_iter_obj.outcome -ne "succesful") { Write-Output $curr_iter_obj; return}

		$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
		$headers.Add("Authorization", "$using:token")

		try {
			$response = Invoke-RestMethod "$using:AZURE_DEVOPS_BASE_URL/Release/approvals?releaseIdsFilter=$release_id`&api-version=7.1-preview.3" -Method 'GET' -Headers $headers
		}
		catch [Exception] {

			write-logger -Level ERROR -Message "An error occurred:" #| Tee-Object -FilePath $($LogFile) -Append
			write-logger -Level ERROR -Message "$_.Exception.GetType().FullName, $_.Exception.Message , $_.Exception" #| Tee-Object -FilePath $($LogFile) -Append      
			write-logger -Level ERROR -Message $response
			# Write-Output @{"Build_definition_name"=$PSItem.Build_definition_name;"release_id"=$Release_id;"approval_id"=$null;"environment_id"=$environment_id;"outcome"="failed";"error"="error while trying to get approval id";}
			$curr_iter_obj["approval_id"]=$null
			$curr_iter_obj["error"]="error while trying to get approval id"
			# $curr_iter_obj["Status"]="completed"
			$curr_iter_obj["outcome"]="succesful"
			Write-Output $curr_iter_obj
			return 
		}

		$curr_iter_obj["approval_id"]=$response.value[0].id
		$curr_iter_obj["Status"]="obtaining Approval id"
		
		Write-Output $curr_iter_obj
	
	}

	return $output_array
}


function serialized_function_call{

	write-Logger -Message "making serialized_function_call"
	if($jsoninput -eq '') { write-logger -Level ERROR -Message "Json string should be passed to pipeline as input `n"; exit 1}
	
	try {
		$Deserialized_json = ( $jsoninput | ConvertFrom-Json  -Depth 10 )
	}
	catch [Exception]{
		write-logger -Level ERROR -Message "An error occurred:" #| Tee-Object -FilePath $($LogFile) -Append
		write-logger -Level ERROR -Message "$_.Exception.GetType().FullName, $_.Exception.Message , $_.Exception" #| Tee-Object -FilePath $($LogFile) -Append      
		write-logger -Level ERROR -Message "unable to convert below pipeline supplied json string into powershell object"
		write-logger -Level ERROR -Message "$jsoninput"
		exit 2
	}

	$Release_environment=$Deserialized_json.Deployment_environment
	$Array_of_builds=$Deserialized_json.Array_of_builds


	$Array_of_envid_releaseid=create-release -Array_of_builds $Array_of_builds

	$Array_of_Deploy_release= deploy_release -Array_of_output_from_create_release $Array_of_envid_releaseid

	$array_of_releases_with_approvalid = get_approval_id -array_of_hashmap_deploy_release $Array_of_Deploy_release

	$array_of_approved_releases = approve_release  -array_of_hashmap_deploy_release $array_of_releases_with_approvalid

	_Get_status -array_of_hashtable $array_of_approved_releases

}


function prepare-json {

	param($array_of_user_selection) 	

	write-Logger -Message "Preparing Json"


		if( $array_of_user_selection -eq '' -or $array_of_user_selection -eq $null  ) { exit 5 }

		$envir=$( $CD_ENVIRONMENTS | Invoke-Fzf )
		if( $envir -eq '' -or $envir -eq $null ) { exit 6 } else {  $tmp_json=@{ "Deployment_environment"= $envir } }

		$foreach_output=@()
		 foreach($item in $array_of_user_selection) {
			
			# $response_from_artifact=artifacts -release_definition_id ($CD_PIPELINES.id | where {$_ -eq "$item"}) 
 			# write-host ($CD_PIPELINES | where { $psitem.name -eq "$item" }).id
			$tmp_pipeline_hash=($CD_PIPELINES | where { $psitem.name -eq "$item" })
			$build_artifact_alias=$tmp_pipeline_hash.alias

			$response_from_artifact= artifacts -release_definition_id $tmp_pipeline_hash.id
			$array_of_buildnames= ( $response_from_artifact.artifactVersions[0].versions ).name
			$user_selected_build=$array_of_buildnames | Invoke-Fzf -Prompt "Select build for $item `: "

			$tmp_artifact_response_hash= ($response_from_artifact.artifactVersions.versions | where {$_.name -eq  $user_selected_build } )
			$build_id= $tmp_artifact_response_hash.id

			if( $user_selected_build -eq '' -or  $user_selected_build -eq $null  ) { write-logger -Level DEBUG -Message "Aborting...";  exit 5 } 
			# $foreach_output += @{"Build_definition_name"= "$item"; "Build_number"="$user_selected_build" ; "Build_id"="$build_id" }  
			$foreach_output += @{"Release_definition_name"= "$item"; "Build_artifact_alias"="$build_artifact_alias" ;"Build_number"="$user_selected_build" ; "Build_id"="$build_id" }  

		}
		$tmp_json["Array_of_builds"] = $foreach_output

		return ($tmp_json | convertto-json -depth 13)


}


function interactive_deploy {

	if ($dbg -eq $true) {  write-Logger -Level  "DEBUG" -Message "Entering Interactive_deploy" }

	$user_selected=($CD_PIPELINES.name | Invoke-Fzf -Multi ) 

	if( $user_selected.length -eq 0 -or $Environment -eq '' -or $Branch -eq '' ) { write-Logger -Level DEBUG -Message "Exiting..."; exit 0 }

	$output_json_prepare_json= prepare-json -array_of_user_selection $user_selected
	
	if($gen_json){ write-output $output_json_prepare_json; exit 0 }
	$jsoninput= $output_json_prepare_json 
	$interactive= $false
	main 
}


function _Get_status{

	[CmdletBinding()]
	param (
	[Parameter(Mandatory = $true)]
	$array_of_hashtable
	)
		# box which hold all the completed releases
		$Is_everything_completed_flag=@{"flag"=$array_of_hashtable.length;"Completed_items"=@{};}

		# Headers
		$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
		$headers.Add("Authorization", "$token")

		while( $Is_everything_completed_flag["Completed_items"].Count -ne $array_of_hashtable.length ){

			
			$final_output=$array_of_hashtable | ForEach-Object -parallel {
					
				$curr_time=(Get-Date (Get-Date).ToUniversalTime() -UFormat '+%Y-%m-%dT%H:%M:%S.000Z')
				$Iterator_hashtable=$PSItem
				$Start_time=$Iterator_hashtable["modifiedOn"]
				$RealeseId=$Iterator_hashtable["release_id"]
				$Build_name=$Iterator_hashtable["Build_name"]
				$Release_definition_name=$Iterator_hashtable["Release_definition_name"]
				$Environment_id=$Iterator_hashtable["environment_id"]

				if($Iterator_hashtable["Status"] -eq  "completed" ) {

					if(  -not ( $Release_definition_name -in (($using:Is_everything_completed_flag)["Completed_items"].Keys) ) ) {
						
						($using:Is_everything_completed_flag)["Completed_items"]["$Release_definition_name"] = "$Release_definition_name -- $($Iterator_hashtable.Status) -- $($Iterator_hashtable.Outcome)"
					}

					Write-Output ($using:Is_everything_completed_flag)["Completed_items"]["$Release_definition_name"]#, "not in completed dic_list"
					continue 
				}

				
				# making api call to get the current status of the Build
				try{

					$response = Invoke-RestMethod "$using:AZURE_DEVOPS_BASE_URL/Release/releases/$RealeseId/environments/$Environment_id" -Method 'GET' -Headers $Using:headers
				
				}
				catch [Exception]{

					write-Logger -Level ERROR -Message "An error occurred: $_.Exception.GetType().FullName, $_.Exception.Message , $_.Exception"  #| Tee-Object -FilePath $($LogFile) -Append      
					continue

				}

				$time_established=(New-TimeSpan -end $curr_time -start $Start_time ).tostring()
				if( $response.status  -ne "inProgress" ) {  $Iterator_hashtable["Status"]="completed" } else { $Iterator_hashtable["Status"]= $response.status }
				"$($Release_definition_name) -- release-$($RealeseId) -- $($Iterator_hashtable.Status) `: $($time_established)"

			}

		$tmp_str=( $($final_output) -join "`n" )
		Clear-Host && Write-host "`e[3J"
		Write-Host "[ Deployment Status - $Release_environment] :"
		Write-Host $tmp_str 
		Start-Sleep 3

		} 
		
		 Write-Output (@{"Deployment_environment"="$Release_environment"; "Array_of_builds"=$array_of_hashtable} | ConvertTo-Json -Depth 20) 
	}  



Function write-Logger {

	[CmdletBinding()]
	Param (

		[Parameter(Mandatory=$False)]
		[ValidateSet("INFO","WARN","ERROR","FATAL","DEBUG")]
		$Level = "INFO",

		[Parameter(Mandatory=$True)]
		$Message,

		[Parameter(Mandatory=$False)]
	    	$logfile
	 )

    $Stamp = "{0:MM/dd/yy} {0:HH:mm:ss}" -f (Get-Date)
    $Line = "[$Stamp] [$Level] $Message"

    If($loggerfile) {
        Add-Content $loggerfile -Value $Line
    }
    Else {
        Write-host $Line
    }

}

function main{

	if ($dbg) {  write-Logger -Level  "DEBUG" -Message "entering main" }

	if( -not ( Test-Path -Path $LOGPATH)  ) { New-Item -ItemType Directory -Force -Path $LOGPATH | Out-Null }

	# Decides where control should be passed next for based on the flag $interactive_deploy
	switch($interactive){    
		$true {interactive_deploy}    
		$false {serialized_function_call}
	}
}


# create-release
# converting a function into string for execution within parallel for each.
load-config
$funcdef_artifacts = ${function:_parallel_artifacts}.ToString()

main
