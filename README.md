# Introduction 
Configuring and deploying GeoCall Azure Environments

# Getting Started
1. Install PowerShell Modules from PowerShellGallery: Az, SimplySql, SimplyCredential
``` ps
Install-Module Az
```
2. Install the Azure CLI MSI package (needed for some actions that are not yet in the AzureRM PowerShell Module): 
[Azure CLI on Windows](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-windows?view=azure-cli-latest)

# Project Descriptions

## AzureDeploy

## CertRenew
this script handles renewing the *.geocall.* wildcard certificate from letsencrypt.org.  Running with a '-production' switch will renew the production certificate and upload it to the Azure Blob Storage -- to deploy to systems, remotely logon, import GCPosh and run 'Invoke-GCPDeploySSL'.

## GeoCallDeploy

## LocalDeploy
