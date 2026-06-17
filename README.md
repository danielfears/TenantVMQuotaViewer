# Tenant Quota Finder

![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?style=flat-square&logo=powershell&logoColor=white)
![Azure](https://img.shields.io/badge/Azure-0078D4?style=flat-square&logo=microsoftazure&logoColor=white)
![Release](https://img.shields.io/github/v/release/danielfears/TenantVMQuotaViewer?style=flat-square&logo=github)
![Stars](https://img.shields.io/github/stars/danielfears/TenantVMQuotaViewer?style=flat-square&logo=github)
![Forks](https://img.shields.io/github/forks/danielfears/TenantVMQuotaViewer?style=flat-square&logo=github)
![Last commit](https://img.shields.io/github/last-commit/danielfears/TenantVMQuotaViewer?style=flat-square)
![Lint & Test](https://img.shields.io/github/actions/workflow/status/danielfears/TenantVMQuotaViewer/lint.yml?style=flat-square&logo=github&label=lint%20%26%20test)

A PowerShell script to retrieve VM vCPU and App Service Plan quota consumption across all subscriptions in an Azure tenant, with an interactive HTML report.

## Overview

This script iterates through every subscription in your Azure tenant and retrieves the current VM quota usage and App Service Plan worker SKU quotas for one or more regions (default: UK South). It generates a comprehensive HTML report showing tenant-wide aggregated usage with expandable subscription-level details, and can optionally export the raw data to CSV/JSON.

## Features

- ✅ **Automatic Authentication** - Reuses an existing Az PowerShell session, or prompts for device code authentication
- ✅ **Parameterised** - Region(s), output path, usage threshold and subscription scope are all command-line parameters; no need to edit the script
- ✅ **Multi-Region** - Scan one or many regions in a single run; results are aggregated per SKU and per region
- ✅ **Parallel Scanning** - Optional `-ThrottleLimit` scans many subscriptions concurrently for large tenants, with deterministic results
- ✅ **Tenant-Wide Scanning** - Iterates through all accessible subscriptions (or a supplied subset)
- ✅ **VM vCPU Quotas** - Filters to compute-related quotas (vCPUs, Virtual Machines, Availability Sets, etc.)
- ✅ **App Service Plan Quotas** - Retrieves worker SKU quotas (F1, B1, P1v4, EP3, WS1, etc.) via the Microsoft.Quota resource provider
- ✅ **HTML Report** - Generates an interactive HTML report with:
  - Tenant name and ID display
  - Tabbed interface switching between VM and App Service views
  - Aggregated SKU usage across all subscriptions, broken down by region
  - Helpful empty-state messages when no data is returned (e.g. Microsoft.Quota provider not registered)
  - Visual progress bars with colour-coded usage levels
  - Expandable dropdowns showing per-subscription breakdown
  - Independent search/filter for each section
- ✅ **CSV / JSON Export** - Optional `-ExportCsv` / `-ExportJson` for automation and trend tracking
- ✅ **CI-Friendly** - `-FailOnThreshold` returns a non-zero exit code when any SKU is over the threshold; `-PassThru` emits objects to the pipeline
- ✅ **High Usage Alerts** - Highlights quotas at or above a configurable threshold (default 80%) in both console and report
- ✅ **Safe HTML** - All dynamic values (subscription names, SKU names, tenant name) are HTML-encoded to prevent markup/script injection into the report
- ✅ **Graceful Degradation** - App Service quotas are skipped for subscriptions where the Microsoft.Quota provider is not registered, without blocking execution
- ✅ **Error Handling** - Comprehensive try-catch blocks with informative error messages
- ✅ **Tested** - Pester unit tests and PSScriptAnalyzer linting run in CI on every push and pull request

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
# Scan all subscriptions for UK South, write QuotaReport.html
./quotafinder.ps1

# Or with PowerShell Core explicitly
pwsh -File ./quotafinder.ps1
```

### Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-Location` | One or more Azure regions to query | `uksouth` |
| `-OutputPath` | Path of the HTML report to write | `QuotaReport.html` (current dir) |
| `-Threshold` | Usage % (1-100) treated as high/critical | `80` |
| `-SubscriptionId` | Restrict the scan to specific subscription IDs | all accessible |
| `-ThrottleLimit` | Number of subscriptions to scan in parallel (1 = sequential) | `1` |
| `-ExportCsv` | Also export raw per-subscription results to CSV | off |
| `-ExportJson` | Also export the aggregated summaries to JSON | off |
| `-PassThru` | Emit the VM and App Service summaries to the pipeline | off |
| `-FailOnThreshold` | Return a non-zero exit code if any SKU is over the threshold | off |

### Examples

```powershell
# Multiple regions, custom threshold, plus CSV export
./quotafinder.ps1 -Location uksouth,ukwest -Threshold 90 -ExportCsv

# Scope to two subscriptions and write to a specific path
./quotafinder.ps1 -SubscriptionId 1111-..., 2222-... -OutputPath ./reports/quota.html

# Large tenant: scan 8 subscriptions at a time (much faster)
./quotafinder.ps1 -ThrottleLimit 8

# CI gate: fail the pipeline if anything is at 85%+
./quotafinder.ps1 -Threshold 85 -FailOnThreshold

# Capture summaries as objects for further processing
$summary = ./quotafinder.ps1 -PassThru
$summary.Vm | Where-Object UsagePercentage -ge 80
```

> **Performance:** by default subscriptions are scanned sequentially (with a progress bar). On large tenants, `-ThrottleLimit` scans several at once — each in its own isolated Azure context, so results are identical to a sequential run. Requires PowerShell 7+.

The script will:
1. Check for an existing Az PowerShell session, otherwise prompt for device code authentication
2. Retrieve all subscriptions in your tenant (or those passed via `-SubscriptionId`)
3. Query VM quotas for the requested region(s) across all subscriptions
4. Query App Service Plan quotas via the Microsoft.Quota RP (where registered)
5. Display results in the console
6. Generate the HTML report (and any requested CSV/JSON exports)

## Configuration

All configuration is via the parameters above — no need to edit the script. For example, to change the target region(s):

```powershell
./quotafinder.ps1 -Location westeurope,northeurope
```

> **Note:** the generated report and exports embed tenant and subscription IDs (and names). Treat them as you would any inventory of your environment and avoid committing them to public repositories.

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
| **Header** | Tenant name, tenant ID, region(s), report generation timestamp |
| **VM Quota Summary** | All VM SKU families aggregated across subscriptions, per region |
| **App Service Plan Quota Summary** | All App Service worker SKU quotas aggregated across subscriptions, per region |
| **Progress Bars** | Visual usage indicators (green < 50%, yellow 50-80%, red ≥ threshold) |
| **Expandable Rows** | Click any row to see which subscriptions contribute to that SKU's usage |
| **Search Boxes** | Independent search/filter for each section |

## Report Fields

| Field | Description |
|-------|-------------|
| Region | The Azure region the quota applies to |
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

### Change the high-usage threshold

Pass the `-Threshold` parameter (no need to edit the script):

```powershell
./quotafinder.ps1 -Threshold 90
```

### Scan additional regions

Pass multiple regions to `-Location`:

```powershell
./quotafinder.ps1 -Location uksouth,ukwest,westeurope
```

## Development

Unit tests (Pester) and linting (PSScriptAnalyzer) run automatically in CI. To run them locally:

```powershell
Install-Module Pester, PSScriptAnalyzer -Scope CurrentUser -Force

# Lint
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1

# Test
Invoke-Pester -Path ./tests
```

The pure helper functions are unit-tested; the script's main entry point is guarded so dot-sourcing it for tests does not require the Az modules or attempt any Azure calls.

## License

Copyright (c) Microsoft Corporation.
Licensed under the MIT License.
