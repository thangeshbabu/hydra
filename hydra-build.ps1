#!/usr/bin/env pwsh

param (
[Parameter(Mandatory = $true)]
$Branch,
[Parameter(Mandatory = $true)]
$Environment
)


function load-config{

	write-Logger -Message "entering Loadconfig"
	$config_dict=$(get-content ~/.hydra/config.json -raw )   | ConvertFrom-Json -Depth 10  -AsHashtable

	# userdefined
	$global:AZURE_DEVOPS_BASE_URL=$config_dict.userdefined.azure_devops_build_url
	$global:CI_PIPELINES=$($config_dict.userdefined.ci_pipelines) 

	# Defaults
	if("$env:DEVOPS_PAT" -eq $null -or "$env:DEVOPS_PAT"  -eq ""){ write-Logger -Debug ERROR -Message "Environment Variable 'DEVOPS_PAT' either empty or not set"; exit 3; }
	$PAT=[System.Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(":$env:DEVOPS_PAT"))
	$global:token="Basic $PAT"

	$global:LOGPATH=$($config_dict.defaults.logpath) 
	$global:PSStyle.Progress.View=$($config_dict.defaults."psstyle.progress.view") 
	$global:ErrorActionPreference =$($config_dict.defaults.erroractionpreference) 

}


# This function uses recieves array of CI_PIPELINES.id and triggers build for all of them parallely
function _Trigger_build {

	param (
	[Parameter(Mandatory = $true)]
	$Array,
	[Parameter(Mandatory = $true)]
	$Branch
	)
	write-Logger -Message "entering trigger_build"

	# stores all the response files in this array to create a array of object which will then be passed to _get_stastus to know about their recent status
	[array]$tmp_array_of_hashtable=@()

	$final_array_of_hashtable = $Array | ForEach-Object -Parallel {
		
		# ${function:write-logger} = $using:funcdef_logger

		$Build_definition_name=$PSItem
		# $Build_definition_id=($using:CI_PIPELINES).$Build_definition_name
		$Build_definition_id=( ($using:CI_PIPELINES) | where { $_.name -eq "$Build_definition_name" } ).id
		$tmp=@{ "Build_definition_id"=$Build_definition_id; "Build_definition_name"="$Build_definition_name";"Build_queue_error"="null"; "Time_initiated"="$null"; "Status"="null"; "Outcome"="null"; "Build_number"="null";"Build_id"="null" }

		$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
		$headers.Add("Authorization", "$using:token")
		$headers.Add("Content-Type", "application/json")	

		$body = @{ "definition"= @{"id"= "$Build_definition_id" }; "sourceBranch"="refs/heads/$($using:Branch)"} | ConvertTo-Json

		$url="$Using:AZURE_DEVOPS_BASE_URL/build/builds?definitionId=$Build_definition_id`&api-version=7.1-preview.7"

		try{

			$response = Invoke-RestMethod  -Uri $url -Method 'POST' -Headers $headers -Body $body

		}
		catch [Exception]{

				write-host "An error occurred:" #| Tee-Object -FilePath $($LogFile) -Append
				write-host "$_.Exception.GetType().FullName, $_.Exception.Message , $_.Exception" #| Tee-Object -FilePath $($LogFile) -Append      
				Write-Host "$response"
				$tmp["Status"]="completed"
				$tmp["Outcome"]="build_failed"
				$tmp["Build_queue_error"]=$true
				$tmp_array_of_hashtable += $tmp
				$tmp_array_of_hashtable
				continue

		}
		$tmp["Status"]="queued"
			$tmp["Time_initiated"]=$response.queueTime.tostring('o')
			$tmp["Build_number"]=$response.buildNumber
			$tmp["Build_id"]=$response.id

			$tmp_array_of_hashtable += $tmp
			$tmp_array_of_hashtable

	}

# $final_array_of_hashtable | ConvertTo-Json
	write-Logger -Message "exiting trigger_build"
	_Get_status -array_of_hashtable $final_array_of_hashtable
}

function _Get_status{

	[CmdletBinding()]
		param (
			[Parameter(Mandatory = $true)]
			$array_of_hashtable
		      )

		write-Logger -Message "entering Status"

		$Is_everything_completed_flag=@{"flag"=$array_of_hashtable.length;"Completed_items"=@{};}
		$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
		$headers.Add("Authorization", "$token")

		while($Is_everything_completed_flag["Completed_items"].Count -ne $array_of_hashtable.length ){

			$final_output=$array_of_hashtable | ForEach-Object -parallel {

				# ${function:write-logger} = $using:funcdef_logger

					$curr_time=(Get-Date (Get-Date).ToUniversalTime() -UFormat '+%Y-%m-%dT%H:%M:%S.000Z')
					$Iterator_hashtable=$PSItem
					$Start_time=$Iterator_hashtable["Time_initiated"]
					$BuildId=$Iterator_hashtable["Build_id"]
					$BuildNumber=$Iterator_hashtable["Build_number"]
					$Build_definition_name=$Iterator_hashtable["Build_definition_name"]

					if($Iterator_hashtable["Status"] -eq  "completed" ) {

						if(  -not ( $Build_definition_name -in (($using:Is_everything_completed_flag)["Completed_items"].Keys) ) ) {

							($using:Is_everything_completed_flag)["Completed_items"]["$Build_definition_name"] = "$Build_definition_name -- $($Iterator_hashtable.Status) -- $($Iterator_hashtable.Outcome)"
						}

						Write-Output ($using:Is_everything_completed_flag)["Completed_items"]["$Build_definition_name"]#, "not in completed dic_list"
							continue 
					}


				# Api call to get the current status of the Build
				try{
					$response = Invoke-RestMethod "$using:AZURE_DEVOPS_BASE_URL/build/builds/$BuildId`?api-version=7.1-preview.7" -Method 'GET' -Headers $Using:headers
				}
				catch [Exception]{
					# write-host "An error occurred:" #| Tee-Object -FilePath $($LogFile) -Append
					write-host "An error occurred: $_.Exception.GetType().FullName, $_.Exception.Message , $_.Exception"  #| Tee-Object -FilePath $($LogFile) -Append      
					continue
				}

				$time_established=(New-TimeSpan -end $curr_time -start $Start_time ).tostring()
					$Iterator_hashtable["status"]=$response.status
					$Iterator_hashtable["Outcome"]=$response.result

					"$($Build_definition_name) -- $($BuildNumber) -- $($Iterator_hashtable.Status) -- $($Iterator_hashtable.Outcome) `: $($time_established)"

			}
			$tmp_str=( $($final_output) -join "`n" )
				Clear-Host && Write-host "`e[3J"
				Write-Host "[ CI Build Status ] :"
				Write-Host $tmp_str 
				Start-Sleep 3
		} 
		Write-Output (@{"Deployment_environment"="$Environment"; "Array_of_builds"=$array_of_hashtable} | ConvertTo-Json -Depth 20) | Tee-Object -FilePath "$LOGPATH/build/lastbuild.json"
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

    $Stamp = "[{0:MM/dd/yy} {0:HH:mm:ss}]" -f (Get-Date)
    $Line = "$Stamp $Level $Message"

    If($logfile) {
        Add-Content $logfile -Value $Line
    }
    Else {
        Write-host $Line
    }

}


function main {
        
	write-Logger -Message "entering Main"

	if( Test-Path -Path $LOGPATH/build -IsValid ) { New-Item -ItemType Directory -Force -Path $LOGPATH/build | Out-Null }

	$user_selected = ( $CI_PIPELINES.name | Invoke-Fzf -Multi )
	
	if( $user_selected.length -eq 0 -or $Environment -eq '' -or $Branch -eq '' ) { exit 0 }

	_Trigger_build -Array $user_selected -Branch $Branch
}

load-config
# $funcdef_logger = ${function:write-logger}.ToString()
main
