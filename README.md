# Tenant Quota Finder

A PowerShell script to retrieve VM vCPU and App Service Plan quota consumption across all subscriptions in an Azure tenant, with an interactive HTML report.

## Overview

This script iterates through every subscription in your Azure tenant and retrieves the current VM quota usage and App Service Plan worker SKU quotas for a specified region (default: UK South). It generates a comprehensive HTML report showing tenant-wide aggregated usage with expandable subscription-level details.

## Features

- ✅ **Automatic Authentication** - Detects existing Az PowerShell session, reuses active Azure CLI session, or prompts for device code authentication
- ✅ **Tenant-Wide Scanning** - Iterates through all accessible subscriptions
- ✅ **VM vCPU Quotas** - Filters to compute-related quotas (vCPUs, Virtual Machines, Availability Sets, etc.)
- ✅ **App Service Plan Quotas** - Retrieves worker SKU quotas (F1, B1, P1v4, EP3, WS1, etc.) via the Microsoft.Quota resource provider
- ✅ **HTML Report** - Generates an interactive HTML report with:
  - Tenant name and ID display
  - Tabbed interface switching between VM and App Service views
  - Aggregated SKU usage across all subscriptions
  - Helpful empty-state messages when no data is returned (e.g. Microsoft.Quota provider not registered)
  - Visual progress bars with colour-coded usage levels
  - Expandable dropdowns showing per-subscription breakdown
  - Independent search/filter for each section
- ✅ **High Usage Alerts** - Highlights quotas at 80%+ usage in both console and report
- ✅ **Graceful Degradation** - App Service quotas are skipped for subscriptions where the Microsoft.Quota provider is not registered, without blocking execution
- ✅ **Error Handling** - Comprehensive try-catch blocks with informative error messages

## Prerequisites

- **PowerShell Core 7+** (recommended) or **PowerShell 5.1+**
- **Azure PowerShell Modules**:
  - `Az.Accounts`
  - `Az.Compute`

### Install Azure PowerShell Modules

```powershell
Install-Module -Name Az.Accounts -Scope CurrentUser -Repository PSGallery -Force
Install-Module -Name Az.Compute -Scope CurrentUser -Repository PSGallery -Force
```

### App Service Quotas - Additional Prerequisite

App Service Plan quotas use the **Microsoft.Quota** resource provider. This provider must be registered on each subscription you want App Service data for. If it is not registered, VM quotas will still be collected and the App Service section will simply be empty for those subscriptions.

To register (requires Contributor or Owner on the subscription):

```powershell
Register-AzResourceProvider -ProviderNamespace Microsoft.Quota
```

Or via Azure CLI:

```bash
az provider register --namespace Microsoft.Quota
```

Registration takes a few minutes to propagate. The script itself only requires **Reader** access and does not attempt registration.

## Usage

```powershell
# Run the script
./quotafinder.ps1

# Or with PowerShell Core explicitly
pwsh -File ./quotafinder.ps1
```

The script will:
1. Check for an existing Azure session (Az PowerShell context, Azure CLI session, or device code authentication)
2. Retrieve all subscriptions in your tenant
3. Query VM quotas for UK South region across all subscriptions
4. Query App Service Plan quotas via the Microsoft.Quota RP (where registered)
5. Display results in the console
6. Generate `QuotaReport.html` in the script directory

## Configuration

To change the target region, modify the `$targetLocation` variable in the script:

```powershell
$targetLocation = "uksouth"  # Change to your desired region
```

## Output

### Console Output

```
SubscriptionName    SubscriptionId                       Location  ResourceType                CurrentUsage  Limit  UsagePercentage
----------------    --------------                       --------  ------------                ------------  -----  ---------------
Production-Sub-001  xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx uksouth   Total Regional vCPUs        442           475    93.05
Production-Sub-002  yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy uksouth   Standard FSv2 Family vCPUs  512           520    98.46

Quotas with usage over 80%:
...
```

### HTML Report

The HTML report (`QuotaReport.html`) includes:

| Section | Description |
|---------|-------------|
| **Header** | Tenant name, tenant ID, region, report generation timestamp |
| **VM Quota Summary** | All VM SKU families aggregated across subscriptions |
| **App Service Plan Quota Summary** | All App Service worker SKU quotas aggregated across subscriptions |
| **Progress Bars** | Visual usage indicators (green < 50%, yellow 50-80%, red ≥ 80%) |
| **Expandable Rows** | Click any row to see which subscriptions contribute to that SKU's usage |
| **Search Boxes** | Independent search/filter for each section |

## Report Fields

| Field | Description |
|-------|-------------|
| SKU Name | VM family quota type (e.g., "Standard DSv5 Family vCPUs") |
| Total Used | Sum of current usage across all subscriptions |
| Total Limit | Sum of quota limits across all subscriptions |
| Usage % | Percentage of total quota consumed |
| Subscriptions | Number of subscriptions with this quota allocated |

## Quota Types Included

The script collects two categories of quotas:

### VM Quotas (Microsoft.Compute)

Filtered to include only compute-related quotas:
- Total Regional vCPUs
- Total Regional Low-priority vCPUs
- Virtual Machines
- Availability Sets
- Dedicated vCPUs
- All VM Family vCPUs (DSv5, FSv2, NCASv3_T4, etc.)

### App Service Plan Quotas (Microsoft.Quota / Microsoft.Web)

All App Service worker SKU types, including:
- Free / Shared tier (F1, D1)
- Basic tier (B1, B2, B3)
- Standard tier (S1, S2, S3)
- Premium v3/v4 tier (P1mv3, P2mv3, P0v4, P1v4, etc.)
- Isolated tier (I1, I2, I3, I1v2, etc.)
- Elastic Premium (EP1, EP2, EP3)
- Workflow Standard (WS1, WS2, WS3)

## Permissions Required

The account running this script needs:

- **Reader** role on all subscriptions to be queried
- Or specifically:
  - `Microsoft.Compute/locations/usages/read` for VM quotas
  - `Microsoft.Quota/usages/read` and `Microsoft.Quota/quotas/read` for App Service quotas

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "No subscriptions found" | Ensure you're authenticated and have access to subscriptions |
| "Failed to import Az modules" | Run the Install-Module commands above |
| Device code not appearing | Check the terminal output for the authentication URL and code |
| Some subscriptions skipped | Check you have Reader access to those subscriptions |
| Report shows 0 for some SKUs | Those SKU families have no quota allocated in the region |
| App Service section is empty | The Microsoft.Quota provider is not registered on the subscriptions — see [prerequisites](#app-service-quotas---additional-prerequisite) |
| "Selected subscription is in 'Disabled' state" | Expected warning for disabled subscriptions — they are skipped automatically |

## Customisation

### Change Threshold for High Usage Alerts

Find and modify this line in the script:

```powershell
$highUsage = $quotaResults | Where-Object { $_.UsagePercentage -ge 80 }
```

### Add Additional Regions

Modify the script to loop through multiple regions or accept a parameter.

## License

Copyright (c) Microsoft Corporation.
Licensed under the MIT License.
