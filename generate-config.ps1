param (
    [string]$environment
)

# Ensure PowerShell-YAML and AWS Tools are installed and imported
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Install-Module -Name powershell-yaml -Force -Scope CurrentUser
}
if (-not (Get-Module -ListAvailable -Name AWSPowerShell)) {
    Install-Module -Name AWSPowerShell -Force -Scope CurrentUser
}
Import-Module powershell-yaml
Import-Module AWSPowerShell

# Load and parse the YAML file
$yamlPath = ".\variables.yaml"
$yamlContent = Get-Content -Raw -Path $yamlPath
$variables = (ConvertFrom-Yaml $yamlContent).library_sets

# Function to fetch values from AWS Parameter Store
function Get-AwsParameterValue {
    param (
        [string]$parameterName
    )
    try {
        $response = Get-SSMParameter -Name $parameterName -WithDecryption $true
        return $response.Value
    } catch {
        Write-Output "Error fetching parameter '$parameterName': $_"
        return $null
    }
}

# Replace placeholders with values from AWS Parameter Store
foreach ($key in $variables.Keys) {
    if ($variables[$key] -is [System.Collections.Hashtable]) {
        if ($variables[$key].ContainsKey("environments")) {
            foreach ($envKey in $variables[$key].environments.Keys) {
                if ($envKey -eq $environment) {
                    $value = $variables[$key].environments[$envKey]["value"]
                    if ($value -match '^\{\{AWS:([^}]+)\}\}$') {
                        $parameterName = $matches[1]
                        $awsValue = Get-AwsParameterValue -parameterName $parameterName
                        if ($awsValue) {
                            $variables[$key].environments[$envKey]["value"] = $awsValue
                        } else {
                            Write-Output "Failed to fetch value for parameter '$parameterName'. Keeping placeholder."
                        }
                    }
                }
            }
        } elseif ($variables[$key].ContainsKey("value") -and $variables[$key]["value"] -match '^\{\{AWS:([^}]+)\}\}$') {
            $parameterName = $matches[1]
            $awsValue = Get-AwsParameterValue -parameterName $parameterName
            if ($awsValue) {
                $variables[$key]["value"] = $awsValue
            } else {
                Write-Output "Failed to fetch value for parameter '$parameterName'. Keeping placeholder."
            }
        }
    }
}

# Consolidate environment-specific and global variables
$consolidatedVars = @{}
foreach ($key in $variables.Keys) {
    $value = $null
    if ($variables[$key] -is [System.Collections.Hashtable]) {
        if ($variables[$key].ContainsKey("environments") -and $variables[$key].environments.ContainsKey($environment)) {
            $value = $variables[$key].environments[$environment]["value"]
        } elseif ($variables[$key].ContainsKey("value") -and -not $variables[$key].ContainsKey("environments")) {
            $value = $variables[$key]["value"]
        }
    }
    if (![string]::IsNullOrWhiteSpace($key) -and (![string]::IsNullOrWhiteSpace($value))) {
        $consolidatedVars[$key] = $value
    }
}

# Exit if no variables were consolidated
if ($consolidatedVars.Count -eq 0) {
    Write-Output "No variables found for environment '$environment'. Exiting."
    exit 1
}

# Write the consolidated variables to a PowerShell script
$configFilePath = ".\config.ps1"
$consolidatedVars.GetEnumerator() | ForEach-Object {
    $key = $_.Key
    $value = $_.Value
    if (![string]::IsNullOrWhiteSpace($key) -and (![string]::IsNullOrWhiteSpace($value))) {
        "Set-Variable -Name '${key}' -Value '${value}'"
    } else {
        Write-Output "Skipping invalid entry: Key='${key}', Value='${value}'"
    }
} | Out-File -FilePath $configFilePath -Encoding UTF8

Write-Output "Variables successfully written to ${configFilePath}."
