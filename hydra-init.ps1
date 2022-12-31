#!/usr/bin/env pwsh

[CmdletBinding()]
 param(  
    [Parameter(Mandatory=$false, ValueFromPipeline=$false)]
    [string]$config_path="$HOME/.hydra",
    [Parameter(Mandatory=$true, ValueFromPipeline=$false)]
    [string]$organisation,
    [Parameter(Mandatory=$true, ValueFromPipeline=$false)]
    [string]$project,
    [Parameter(Mandatory=$true, ValueFromPipeline=$false)]
    [string[]]$environment,
    [Parameter(Mandatory=$true, ValueFromPipeline=$false)]
    [string[]]$manual_trigger
)


function get-release-definitionid(){

	param(
	[array]
	$array_of_path)

	write-logger -Message "entering get-release-definitionid"

	$headers=@{}
	$headers.Add("Authorization", "$token" )

	$output=$array_of_path | foreach -ThrottleLimit 4 -Parallel  {

		$url=[uri]::EscapeUriString("$Using:azure_devops_release_url/release/definitions?path=$PSItem&api-version=7.1-preview.4" )
		try{
			$response = Invoke-RestMethod -Uri $url -Method GET -Headers $using:headers 
		}
		catch [Exception]{

			write-host "An error occurred:" #| Tee-Object -FilePath $($LogFile) -Append
			write-host "$_.Exception.GetType().FullName, $_.Exception.Message , $_.Exception" #| Tee-Object -FilePath $($LogFile) -Append      
			Write-Host "$response"
			exit 1
		}
		write-output $($response.value).id
	}
	return $output
}

function get-build-definition(){

	param(
	[array]
	$array_of_path
	)
	write-logger -Message "entering get-build-definition"
	

	$headers=@{}
	$headers.Add("Authorization", "$token" )

	$output= $array_of_path | foreach -ThrottleLimit 4 -Parallel  {

		$url=[uri]::EscapeUriString("$using:azure_devops_build_url/build/definitions?path=$PSItem&api-version=7.1-preview.4" )

		try{
			$response = Invoke-RestMethod -Uri $url -Method GET -Headers $using:headers 
		}
		catch [Exception]{

			write-host "An error occurred:" #| Tee-Object -FilePath $($LogFile) -Append
			write-host "$_.Exception.GetType().FullName, $_.Exception.Message , $_.Exception" #| Tee-Object -FilePath $($LogFile) -Append      
			Write-Host "$response"
			exit 2
		}

		foreach ( $iter in $response.value )   {

			write-output @{ "name"=$iter.name; "id"=$iter.id }
			
		}
	}
	return $output
}

function get-release-definition() {
	param($array) 
	write-logger -Message "entering get-release-definitionid"

	$headers=@{}
	$headers.Add("Authorization", "$token" )

	$array | foreach -ThrottleLimit 4 -Parallel {
		
		try{
			$response = Invoke-RestMethod -Uri "$using:azure_devops_release_url/release/definitions/$($PSItem)?api-version=7.1-preview.4" -Method GET -Headers $using:headers 
		}
		catch [Exception]{

			write-host "An error occurred:" #| Tee-Object -FilePath $($LogFile) -Append
			write-host "$_.Exception.GetType().FullName, $_.Exception.Message , $_.Exception" #| Tee-Object -FilePath $($LogFile) -Append      
			Write-Host "$response"
			exit 2
		}

		[array]$alias=($response.artifacts).alias
		$name=$response.name
		@{"alias"="$alias";"id"=$PSItem;"name"="$name"}
	}
}


function get-release-folders() {

	write-logger -Message "get release-folders"

	$headers=@{}
	$headers.Add("Authorization", "$token" )

	try{
		$response = Invoke-RestMethod -Uri "$azure_devops_release_url/release/folders?api-version=7.0" -Method GET -Headers $headers 
	}
	catch [Exception]{

		write-host "An error occurred:" #| Tee-Object -FilePath $($LogFile) -Append
		write-host "$_.Exception.GetType().FullName, $_.Exception.Message , $_.Exception" #| Tee-Object -FilePath $($LogFile) -Append      
		Write-Host "$response"
		exit 4
	}
	return ($response.value).path

}

function get-build-folders() {
	write-logger -Message "get build-folders"

	$headers=@{}
	$headers.Add("Authorization", "$token" )
	try {
		$response = Invoke-RestMethod -Uri "$azure_devops_build_url/build/folders?api-version=7.1-preview.2" -Method GET -Headers $headers
	}
	catch [Exception]{

		write-host "An error occurred:" #| Tee-Object -FilePath $($LogFile) -Append
		write-host "$_.Exception.GetType().FullName, $_.Exception.Message , $_.Exception" #| Tee-Object -FilePath $($LogFile) -Append      
		Write-Host "$response"
		exit 5
	}
	return ($response.value).path

}


function load-config{


	write-Logger -Message "entering Loadconfig"

	if ( -not ( Get-Module -ListAvailable -Name psfzf ) ) { write-host "psfzf not found,installing ..."; install-module psfzf -confirm:$false -force } 
	
	if("$env:DEVOPS_PAT" -eq $null -or "$env:DEVOPS_PAT"  -eq ""){ write-Logger -Debug ERROR -Message "Environment Variable 'DEVOPS_PAT' either empty or not set"; exit 3; }
	$PAT=[System.Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(":$env:DEVOPS_PAT"))
	$global:token="Basic $PAT"

	$global:azure_devops_release_url="https://vsrm.dev.azure.com/$organisation/$project/_apis"
	$global:azure_devops_build_url="https://dev.azure.com/$organisation/$project/_apis"
	$global:ci_pipelines
	$global:cd_pipelines

}

function config_gen(){

	write-Logger -Message "generating json"	
	$tmp_dict=[ordered] @{ 

		"userdefined"= @{  
			"cd_environments"=$environment;
			"manual_trigger"=$manual_trigger;
			"azure_devops_build_url"="$azure_devops_build_url"; 
			"azure_devops_release_url"="$azure_devops_release_url";
			"ci_pipelines"= $ci_pipelines ;
			"cd_pipelines"= $cd_pipelines
		};
		"defaults"=@{
			"logpath"="$config_path";
			"psstyle.progress.view"="Classic";
			"erroractionpreference" = "Stop"
		}
			
	}

	return ($tmp_dict | convertto-json -Depth 55)

}

function main(  ) {

	write-Logger -Message "entering main"

	$release_folders=get-release-folders
	$build_folders=get-build-folders

		# _mkdir -path $config_path
	if( -not ( Test-Path -Path $config_path)  ) { 
		try
		{	
			New-Item -ItemType Directory -Force -Path $config_path #| Out-Null 
		}
		catch [Exception] {
			write-Logger -Level ERROR -Message "Error Creating config folder [$config_path]"
			write-host "$_.Exception.GetType().FullName, $_.Exception.Message , $_.Exception" #| Tee-Object -FilePath $($LogFile) -Append      
			exit 1
		}
	}
	else{
		if( Test-Path -Path "$config_path/config.json" ) { 
			$user_choice=Read-Host -Prompt " <$config_path/config.json> Already exits, Do you want to overwrite ? [y/n] "
			if($user_choice -ne "y"){ write-Logger -Message "exiting..."; exit 0 }
			write-logger -Message "Overwritting ..."
		}
	}

	[array]$user_selected_build_folders= $build_folders | Invoke-Fzf -Multi -Prompt "Select Build Definition path"
	if ( $user_selected_build_folders -eq $null -or $user_selected_build_folders.Count -eq 0 ) { write-logger -Message "exiting.."; exit 2 }
	$ci_pipelines= get-build-definition -array_of_path $user_selected_build_folders
	

	[array]$user_selected_release_folders= $release_folders | Invoke-Fzf -Multi -Prompt "Select Release Definition path"
	if ( $user_selected_release_folders -eq $null -or $user_selected_release_folders.Count -eq 0 ) { write-logger -Message "exiting.."; exit 2 }
	$array_of_release_definitionid= get-release-definitionid -array_of_path $user_selected_release_folders
	$cd_pipelines= get-release-definition -array $array_of_release_definitionid
	
	write-Logger -Message "generating Configuration"
	$config_json_string=config_gen 

	write-logger -Message "wrtting to $config_path/config.json"
	write-output $config_json_string | Out-File -FilePath "$config_path/config.json"

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

load-config
main 

