<#
.SYNOPSIS
    Retrieves VM vCPU and App Service Plan quota consumption across all subscriptions
    in an Azure tenant and generates an interactive HTML report.

.DESCRIPTION
    Iterates through every accessible subscription in the tenant (optionally a subset),
    collects VM compute quotas and App Service Plan worker SKU quotas for one or more
    regions, and produces a tenant-wide HTML report with expandable per-subscription
    detail. Optionally exports the raw data to CSV/JSON and can fail (non-zero exit)
    when any SKU exceeds a usage threshold, for use in CI pipelines.

.PARAMETER Location
    One or more Azure regions to query. Defaults to 'uksouth'. Multiple regions are
    aggregated per SKU and per region in the report.

.PARAMETER OutputPath
    Path of the HTML report to write. Defaults to 'QuotaReport.html' in the current
    directory.

.PARAMETER Threshold
    Usage percentage (1-100) at which a SKU is treated as high usage / critical.
    Defaults to 80.

.PARAMETER SubscriptionId
    Optional list of subscription IDs to restrict the scan to. Defaults to all
    accessible subscriptions.

.PARAMETER ExportCsv
    Also export the raw per-subscription results to CSV alongside the HTML report.

.PARAMETER ExportJson
    Also export the aggregated summaries to JSON alongside the HTML report.

.PARAMETER PassThru
    Emit the aggregated VM and App Service summaries to the pipeline.

.PARAMETER FailOnThreshold
    Return a non-zero exit code if any SKU is at or above the threshold. Useful for CI.

.PARAMETER ThrottleLimit
    Number of subscriptions to scan in parallel. 1 (the default) scans sequentially
    with a progress bar. Higher values speed up large tenants; each parallel call is
    scoped to its own Azure context, so results are not affected by ordering.

.EXAMPLE
    ./quotafinder.ps1
    Scans all subscriptions for UK South and writes QuotaReport.html.

.EXAMPLE
    ./quotafinder.ps1 -Location uksouth,ukwest -Threshold 90 -ExportCsv
    Scans two regions, flags SKUs at 90%+, and also writes CSV exports.

.EXAMPLE
    ./quotafinder.ps1 -ThrottleLimit 8
    Scans all subscriptions 8 at a time - much faster on large tenants.

.NOTES
    Version: 1.2.0
    Requires the Az.Accounts and Az.Compute modules. Needs Reader on the target
    subscriptions; App Service quotas additionally require the Microsoft.Quota
    resource provider to be registered.
#>
[CmdletBinding()]
param(
    [string[]]$Location = @('uksouth'),

    [string]$OutputPath = (Join-Path -Path (Get-Location) -ChildPath 'QuotaReport.html'),

    [ValidateRange(1, 100)]
    [int]$Threshold = 80,

    [string[]]$SubscriptionId,

    [ValidateRange(1, 50)]
    [int]$ThrottleLimit = 1,

    [switch]$ExportCsv,

    [switch]$ExportJson,

    [switch]$PassThru,

    [switch]$FailOnThreshold
)

# ----------------------------------------------------------------------------
# Pure helper functions (no Azure dependency - unit tested via Pester)
# ----------------------------------------------------------------------------

function ConvertTo-SafeHtml {
    <#
    .SYNOPSIS
        HTML-encodes a string so user-controlled values (e.g. subscription names)
        cannot inject markup or script into the generated report.
    #>
    param([string]$Text)

    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Get-UsagePercentage {
    <#
    .SYNOPSIS
        Returns usage as a percentage of limit, rounded to 2 dp. Zero when limit <= 0.
    #>
    param(
        [double]$Used,
        [double]$Limit
    )

    if ($Limit -gt 0) {
        return [math]::Round(($Used / $Limit) * 100, 2)
    }
    return 0
}

function Get-UsageClass {
    <#
    .SYNOPSIS
        Maps a usage percentage to a CSS class for the usage badge.
    #>
    param(
        [double]$Percentage,
        [int]$Threshold = 80
    )

    if ($Percentage -ge $Threshold) { return 'usage-critical' }
    elseif ($Percentage -ge 50) { return 'usage-high' }
    elseif ($Percentage -ge 25) { return 'usage-medium' }
    else { return 'usage-low' }
}

function Get-ProgressClass {
    <#
    .SYNOPSIS
        Maps a usage percentage to a CSS class for the progress bar fill.
    #>
    param(
        [double]$Percentage,
        [int]$Threshold = 80
    )

    if ($Percentage -ge $Threshold) { return 'progress-critical' }
    elseif ($Percentage -ge 50) { return 'progress-high' }
    elseif ($Percentage -ge 25) { return 'progress-medium' }
    else { return 'progress-low' }
}

function Get-QuotaSkuSummary {
    <#
    .SYNOPSIS
        Groups raw per-subscription quota results by resource type and region,
        producing tenant-wide totals with per-subscription detail.
    #>
    param(
        [array]$Results
    )

    if (-not $Results) { return @() }

    $Results | Group-Object -Property ResourceType, Location | ForEach-Object {
        $group = $_.Group
        $first = $group[0]
        $totalUsage = [double](($group | Measure-Object -Property CurrentUsage -Sum).Sum)
        $totalLimit = [double](($group | Measure-Object -Property Limit -Sum).Sum)

        $subscriptionDetails = $group |
            Where-Object { $_.CurrentUsage -gt 0 -or $_.Limit -gt 0 } |
            Sort-Object -Property @{ Expression = 'CurrentUsage'; Descending = $true }, @{ Expression = 'SubscriptionName'; Descending = $false } |
            Select-Object SubscriptionName, SubscriptionId, CurrentUsage, Limit, UsagePercentage

        [PSCustomObject]@{
            ResourceType        = $first.ResourceType
            Location            = $first.Location
            TotalUsage          = $totalUsage
            TotalLimit          = $totalLimit
            UsagePercentage     = Get-UsagePercentage -Used $totalUsage -Limit $totalLimit
            SubscriptionCount   = $group.Count
            SubscriptionDetails = $subscriptionDetails
        }
    } | Sort-Object -Property @{ Expression = 'UsagePercentage'; Descending = $true }, @{ Expression = 'ResourceType'; Descending = $false }, @{ Expression = 'Location'; Descending = $false }
}

function ConvertTo-QuotaTableHtml {
    <#
    .SYNOPSIS
        Builds the HTML table body rows for a set of SKU summaries, including the
        expandable per-subscription detail rows. All dynamic values are HTML-encoded.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$SkuSummary,

        [int]$Threshold = 80
    )

    $html = ''
    foreach ($sku in $SkuSummary) {
        $progressClass = Get-ProgressClass -Percentage $sku.UsagePercentage -Threshold $Threshold
        $usageClass = Get-UsageClass -Percentage $sku.UsagePercentage -Threshold $Threshold
        $progressWidth = [math]::Min($sku.UsagePercentage, 100)
        $hasDetails = $sku.SubscriptionDetails -and $sku.SubscriptionDetails.Count -gt 0
        $rowId = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)

        $rtSafe = ConvertTo-SafeHtml $sku.ResourceType
        $locSafe = ConvertTo-SafeHtml $sku.Location
        $totalUsageF = ([double]$sku.TotalUsage).ToString('N0')
        $totalLimitF = ([double]$sku.TotalLimit).ToString('N0')

        if ($hasDetails) {
            $html += @"
                    <tr class="expandable-row" onclick="toggleDetails('$rowId')">
                        <td>$locSafe</td>
                        <td><span class="expand-icon" id="icon-$rowId">&#9654;</span><strong>$rtSafe</strong></td>
                        <td>$totalUsageF</td>
                        <td>$totalLimitF</td>
                        <td><span class="usage-text $usageClass">$($sku.UsagePercentage)%</span></td>
                        <td>
                            <div class="progress-bar">
                                <div class="progress-fill $progressClass" style="width: $progressWidth%"></div>
                            </div>
                        </td>
                        <td>$($sku.SubscriptionCount)</td>
                    </tr>
                    <tr class="subscription-details" id="details-$rowId">
                        <td colspan="7">
                            <table class="sub-table">
                                <thead>
                                    <tr>
                                        <th>Subscription Name</th>
                                        <th>Subscription ID</th>
                                        <th>Usage</th>
                                        <th>Limit</th>
                                        <th>Usage %</th>
                                    </tr>
                                </thead>
                                <tbody>
"@
            foreach ($sub in $sku.SubscriptionDetails) {
                $subUsageClass = Get-UsageClass -Percentage $sub.UsagePercentage -Threshold $Threshold
                $subNameSafe = ConvertTo-SafeHtml $sub.SubscriptionName
                $subIdSafe = ConvertTo-SafeHtml $sub.SubscriptionId
                $subUsageF = ([double]$sub.CurrentUsage).ToString('N0')
                $subLimitF = ([double]$sub.Limit).ToString('N0')

                $html += @"
                                    <tr>
                                        <td>$subNameSafe</td>
                                        <td style="font-family: monospace; font-size: 11px;">$subIdSafe</td>
                                        <td>$subUsageF</td>
                                        <td>$subLimitF</td>
                                        <td><span class="usage-text $subUsageClass">$($sub.UsagePercentage)%</span></td>
                                    </tr>
"@
            }
            $html += @"
                                </tbody>
                            </table>
                        </td>
                    </tr>
"@
        }
        else {
            $html += @"
                    <tr>
                        <td>$locSafe</td>
                        <td><span class="expand-icon no-expand">-</span><strong>$rtSafe</strong></td>
                        <td>$totalUsageF</td>
                        <td>$totalLimitF</td>
                        <td><span class="usage-text $usageClass">$($sku.UsagePercentage)%</span></td>
                        <td>
                            <div class="progress-bar">
                                <div class="progress-fill $progressClass" style="width: $progressWidth%"></div>
                            </div>
                        </td>
                        <td>$($sku.SubscriptionCount)</td>
                    </tr>
"@
        }
    }
    return $html
}

function ConvertTo-QuotaHtmlReport {
    <#
    .SYNOPSIS
        Assembles the full HTML report document from the aggregated summaries.
    #>
    param(
        [string]$TenantName,
        [string]$TenantId,
        [string[]]$Location,
        [string]$ReportDate,
        [int]$SubscriptionCount,
        [array]$VmSummary,
        [array]$AspSummary,
        [int]$Threshold = 80
    )

    $tenantNameSafe = ConvertTo-SafeHtml $TenantName
    $tenantIdSafe = ConvertTo-SafeHtml $TenantId
    $locationSafe = ConvertTo-SafeHtml ($Location -join ', ')
    $vmHighCount = @($VmSummary | Where-Object { $_.UsagePercentage -ge $Threshold }).Count
    $aspHighCount = @($AspSummary | Where-Object { $_.UsagePercentage -ge $Threshold }).Count

    $head = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure Quota Report - Tenant Wide Summary</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        .container { max-width: 1400px; margin: 0 auto; }
        .header { background: white; border-radius: 10px; padding: 30px; margin-bottom: 20px; box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1); }
        .header h1 { color: #333; margin-bottom: 10px; }
        .header-info { display: flex; gap: 30px; flex-wrap: wrap; margin-top: 15px; }
        .header-info-item { background: #f8f9fa; padding: 10px 20px; border-radius: 5px; border-left: 4px solid #667eea; }
        .header-info-item label { font-size: 12px; color: #666; display: block; }
        .header-info-item span { font-size: 14px; font-weight: 600; color: #333; }
        .summary-cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 20px; margin-bottom: 20px; }
        .card { background: white; border-radius: 10px; padding: 25px; box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1); text-align: center; }
        .card-value { font-size: 36px; font-weight: 700; color: #667eea; }
        .card-label { color: #666; margin-top: 5px; }
        .table-container { background: white; border-radius: 10px; padding: 25px; box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1); overflow-x: auto; }
        .table-container h2 { margin-bottom: 20px; color: #333; }
        table { width: 100%; border-collapse: collapse; }
        th { background: #667eea; color: white; padding: 15px 12px; text-align: left; font-weight: 600; }
        td { padding: 12px; border-bottom: 1px solid #eee; }
        tr:hover { background: #f8f9fa; }
        .progress-bar { width: 100%; height: 20px; background: #e9ecef; border-radius: 10px; overflow: hidden; }
        .progress-fill { height: 100%; border-radius: 10px; transition: width 0.3s ease; }
        .progress-low { background: linear-gradient(90deg, #28a745, #34ce57); }
        .progress-medium { background: linear-gradient(90deg, #ffc107, #ffda6a); }
        .progress-high { background: linear-gradient(90deg, #fd7e14, #ff922b); }
        .progress-critical { background: linear-gradient(90deg, #dc3545, #e35d6a); }
        .usage-text { font-weight: 600; padding: 4px 8px; border-radius: 4px; display: inline-block; min-width: 60px; text-align: center; }
        .usage-low { background: #d4edda; color: #155724; }
        .usage-medium { background: #fff3cd; color: #856404; }
        .usage-high { background: #ffe5d0; color: #8a4500; }
        .usage-critical { background: #f8d7da; color: #721c24; }
        .search-box { margin-bottom: 20px; }
        .search-box input { width: 100%; padding: 12px 20px; border: 2px solid #e9ecef; border-radius: 8px; font-size: 16px; transition: border-color 0.3s; }
        .search-box input:focus { outline: none; border-color: #667eea; }
        .expandable-row { cursor: pointer; }
        .expandable-row:hover { background: #e8f4f8; }
        .expand-icon { display: inline-block; width: 20px; height: 20px; text-align: center; background: #667eea; color: white; border-radius: 4px; margin-right: 8px; font-weight: bold; font-size: 14px; line-height: 20px; transition: transform 0.2s; }
        .expand-icon.expanded { transform: rotate(90deg); }
        .subscription-details { display: none; background: #f8f9fa; }
        .subscription-details.show { display: table-row; }
        .subscription-details td { padding: 0; }
        .sub-table { width: 100%; margin: 0; border-collapse: collapse; }
        .sub-table th { background: #8b9dc3; padding: 10px 12px; font-size: 12px; }
        .sub-table td { padding: 8px 12px; font-size: 13px; border-bottom: 1px solid #e0e0e0; }
        .sub-table tr:last-child td { border-bottom: none; }
        .sub-table tr:hover { background: #eef2f7; }
        .no-expand { opacity: 0.5; }
        .tabs { display: flex; gap: 0; margin-bottom: 0; }
        .tab-btn { padding: 15px 30px; border: none; background: rgba(255,255,255,0.3); color: white; font-size: 16px; font-weight: 600; cursor: pointer; border-radius: 10px 10px 0 0; transition: background 0.3s; }
        .tab-btn:hover { background: rgba(255,255,255,0.5); }
        .tab-btn.active { background: white; color: #333; }
        .tab-content { display: none; }
        .tab-content.active { display: block; }
        .tab-panel .table-container { border-radius: 0 10px 10px 10px; margin-bottom: 0; }
        .empty-state { text-align: center; padding: 60px 20px; color: #666; }
        .empty-state h3 { font-size: 20px; margin-bottom: 10px; color: #333; }
        .empty-state p { font-size: 14px; max-width: 600px; margin: 0 auto 10px; line-height: 1.6; }
        .empty-state code { background: #f0f0f0; padding: 2px 8px; border-radius: 4px; font-size: 13px; }
        .footer { text-align: center; color: white; margin-top: 20px; padding: 20px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>&#128269; Azure Quota Report</h1>
            <p>Tenant-wide VM &amp; App Service quota consumption summary</p>
            <div class="header-info">
                <div class="header-info-item"><label>Tenant Name</label><span>$tenantNameSafe</span></div>
                <div class="header-info-item"><label>Tenant ID</label><span>$tenantIdSafe</span></div>
                <div class="header-info-item"><label>Region(s)</label><span>$locationSafe</span></div>
                <div class="header-info-item"><label>Report Generated</label><span>$ReportDate</span></div>
                <div class="header-info-item"><label>Subscriptions Scanned</label><span>$SubscriptionCount</span></div>
            </div>
        </div>

        <div class="summary-cards">
            <div class="card"><div class="card-value">$($VmSummary.Count)</div><div class="card-label">VM SKU Types</div></div>
            <div class="card"><div class="card-value">$vmHighCount</div><div class="card-label">VM SKUs at $Threshold%+</div></div>
            <div class="card"><div class="card-value">$($AspSummary.Count)</div><div class="card-label">App Service SKU Types</div></div>
            <div class="card"><div class="card-value">$aspHighCount</div><div class="card-label">App Service SKUs at $Threshold%+</div></div>
        </div>

        <div class="tab-panel">
            <div class="tabs">
                <button class="tab-btn active" onclick="switchTab(event, 'vm')">&#128202; VM Quotas</button>
                <button class="tab-btn" onclick="switchTab(event, 'asp')">&#127760; App Service Quotas</button>
            </div>

            <div id="tab-vm" class="tab-content active">
                <div class="table-container">
                    <h2>VM Quota Summary</h2>
                    <div class="search-box">
                        <input type="text" id="searchInput" onkeyup="filterTable('quotaTable', 'searchInput')" placeholder="Search VM SKU types...">
                    </div>
                    <table id="quotaTable">
                <thead>
                    <tr>
                        <th>Region</th>
                        <th>SKU / Resource Type</th>
                        <th>Total Usage</th>
                        <th>Total Limit</th>
                        <th>Usage %</th>
                        <th>Usage Bar</th>
                        <th>Subscriptions</th>
                    </tr>
                </thead>
                <tbody>
"@

    if (-not $VmSummary -or $VmSummary.Count -eq 0) {
        $vmBody = @"
                    <tr><td colspan="7">
                        <div class="empty-state">
                            <h3>No VM Quota Data Found</h3>
                            <p>No VM quota usage was returned for any subscription in the <strong>$locationSafe</strong> region(s). Ensure the account running this script has <strong>Reader</strong> access to the target subscriptions.</p>
                        </div>
                    </td></tr>
"@
    }
    else {
        $vmBody = ConvertTo-QuotaTableHtml -SkuSummary $VmSummary -Threshold $Threshold
    }

    $mid = @"
                </tbody>
            </table>
                </div>
            </div>

            <div id="tab-asp" class="tab-content">
                <div class="table-container">
                    <h2>App Service Plan Quota Summary</h2>
                    <div class="search-box">
                        <input type="text" id="aspSearchInput" onkeyup="filterTable('aspQuotaTable', 'aspSearchInput')" placeholder="Search App Service SKU types...">
                    </div>
                    <table id="aspQuotaTable">
                <thead>
                    <tr>
                        <th>Region</th>
                        <th>SKU / Resource Type</th>
                        <th>Total Usage</th>
                        <th>Total Limit</th>
                        <th>Usage %</th>
                        <th>Usage Bar</th>
                        <th>Subscriptions</th>
                    </tr>
                </thead>
                <tbody>
"@

    if (-not $AspSummary -or $AspSummary.Count -eq 0) {
        $aspBody = @"
                    <tr><td colspan="7">
                        <div class="empty-state">
                            <h3>No App Service Quota Data Found</h3>
                            <p>No App Service Plan quota data was returned. This is most likely because the <strong>Microsoft.Quota</strong> resource provider is not registered on your subscriptions.</p>
                            <p>To register it (requires Contributor or Owner role), run:</p>
                            <p><code>az provider register --namespace Microsoft.Quota</code></p>
                            <p>Registration takes a few minutes to propagate. Once registered, re-run this report to see App Service quota data.</p>
                        </div>
                    </td></tr>
"@
    }
    else {
        $aspBody = ConvertTo-QuotaTableHtml -SkuSummary $AspSummary -Threshold $Threshold
    }

    $tail = @"
                </tbody>
            </table>
                </div>
            </div>
        </div>

        <div class="footer">
            <p>Generated by Azure Quota Finder | PowerShell Script</p>
        </div>
    </div>

    <script>
        function switchTab(evt, tabName) {
            document.querySelectorAll('.tab-content').forEach(el => el.classList.remove('active'));
            document.querySelectorAll('.tab-btn').forEach(el => el.classList.remove('active'));
            document.getElementById('tab-' + tabName).classList.add('active');
            evt.currentTarget.classList.add('active');
        }

        function toggleDetails(rowId) {
            const detailsRow = document.getElementById('details-' + rowId);
            const icon = document.getElementById('icon-' + rowId);
            if (detailsRow.classList.contains('show')) {
                detailsRow.classList.remove('show');
                icon.classList.remove('expanded');
                icon.textContent = '\u25B6';
            } else {
                detailsRow.classList.add('show');
                icon.classList.add('expanded');
                icon.textContent = '\u25BC';
            }
        }

        function filterTable(tableId, inputId) {
            const input = document.getElementById(inputId);
            const filter = input.value.toLowerCase();
            const table = document.getElementById(tableId);
            const rows = table.getElementsByTagName('tr');
            for (let i = 1; i < rows.length; i++) {
                const row = rows[i];
                if (row.classList.contains('subscription-details')) { continue; }
                const cells = row.getElementsByTagName('td');
                let found = false;
                for (let j = 0; j < cells.length; j++) {
                    if (cells[j].textContent.toLowerCase().includes(filter)) { found = true; break; }
                }
                row.style.display = found ? '' : 'none';
                const nextRow = rows[i + 1];
                if (nextRow && nextRow.classList.contains('subscription-details')) {
                    nextRow.style.display = found ? '' : 'none';
                    if (!found) { nextRow.classList.remove('show'); }
                }
            }
        }
    </script>
</body>
</html>
"@

    return $head + $vmBody + $mid + $aspBody + $tail
}

# ----------------------------------------------------------------------------
# Azure-dependent functions
# ----------------------------------------------------------------------------

function Connect-ToAzure {
    <#
    .SYNOPSIS
        Ensures an Az PowerShell context exists, reusing an existing context
        otherwise authenticating via device code.
    .NOTES
        Bridging an Azure CLI access token into Az PowerShell (Connect-AzAccount
        -AccessToken) proved unreliable on Az.Accounts 5.x: the token is accepted
        for the connection but rejected during subscription enumeration
        ("The access token is invalid"). Native device code authentication is used
        instead for reliability. An existing Az PowerShell session is still reused.
    #>
    [CmdletBinding()]
    param()

    $context = Get-AzContext -ErrorAction SilentlyContinue
    if ($context) {
        return $context
    }

    Write-Host 'No existing Azure PowerShell session found. Initiating device code authentication...' -ForegroundColor Yellow
    Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop | Out-Null
    return Get-AzContext
}

function Get-TenantQuotaData {
    <#
    .SYNOPSIS
        Collects raw VM and App Service Plan quota results for the given subscriptions
        and regions, sequentially or in parallel.
    .NOTES
        Each subscription is scanned against its own Azure context, passed explicitly
        via -DefaultProfile, so parallel execution does not race on the shared global
        context.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Subscriptions,

        [Parameter(Mandatory)]
        [string[]]$Location,

        [int]$ThrottleLimit = 1
    )

    # Self-contained per-subscription scan (no external function dependencies, so it
    # can run unchanged inside parallel runspaces).
    $scanBlock = {
        param([object]$Subscription, [string[]]$Locations)

        $vm = [System.Collections.Generic.List[object]]::new()
        $asp = [System.Collections.Generic.List[object]]::new()

        try {
            $ctx = Set-AzContext -SubscriptionId $Subscription.Id -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not set context for subscription $($Subscription.Name): $_"
            return [PSCustomObject]@{ Vm = $vm.ToArray(); Asp = $asp.ToArray() }
        }

        foreach ($loc in $Locations) {
            # VM quota usage
            try {
                $vmUsage = Get-AzVMUsage -Location $loc -DefaultProfile $ctx -ErrorAction Stop
                foreach ($usage in $vmUsage) {
                    $resourceName = $usage.Name.LocalizedValue
                    if ($resourceName -match 'vCPU|Virtual Machine|Availability Sets|Dedicated|Low-priority') {
                        $limit = [double]$usage.Limit
                        $used = [double]$usage.CurrentValue
                        $pct = if ($limit -gt 0) { [math]::Round(($used / $limit) * 100, 2) } else { 0 }
                        $vm.Add([PSCustomObject]@{
                                SubscriptionName = $Subscription.Name
                                SubscriptionId   = $Subscription.Id
                                Location         = $loc
                                ResourceType     = $resourceName
                                CurrentUsage     = $usage.CurrentValue
                                Limit            = $usage.Limit
                                UsagePercentage  = $pct
                            })
                    }
                }
            }
            catch {
                Write-Warning "Could not retrieve VM quota for $loc in subscription $($Subscription.Name): $_"
            }

            # App Service Plan quota usage via the Microsoft.Quota RP
            try {
                $aspBasePath = "/subscriptions/$($Subscription.Id)/providers/Microsoft.Web/locations/$loc/providers/Microsoft.Quota"
                $usagesResponse = Invoke-AzRestMethod -Path "$aspBasePath/usages?api-version=2023-06-01-preview" -Method GET -DefaultProfile $ctx -ErrorAction Stop
                $quotasResponse = Invoke-AzRestMethod -Path "$aspBasePath/quotas?api-version=2023-06-01-preview" -Method GET -DefaultProfile $ctx -ErrorAction Stop

                if ($usagesResponse.StatusCode -eq 200 -and $quotasResponse.StatusCode -eq 200) {
                    $aspUsages = ($usagesResponse.Content | ConvertFrom-Json).value
                    $aspQuotas = ($quotasResponse.Content | ConvertFrom-Json).value

                    $limitLookup = @{}
                    foreach ($quota in $aspQuotas) {
                        $limitLookup[$quota.name] = $quota.properties.limit.value
                    }

                    foreach ($usage in $aspUsages) {
                        $skuName = $usage.name
                        $resourceName = $usage.properties.name.localizedValue
                        if (-not $resourceName) { $resourceName = $skuName }

                        $rawUsage = $usage.properties.usages.value
                        if ($null -eq $rawUsage) { $rawUsage = 0 }
                        $currentUsage = [math]::Max([double]$rawUsage, 0)
                        $limit = if ($limitLookup.ContainsKey($skuName)) { [double]$limitLookup[$skuName] } else { 0 }
                        $pct = if ($limit -gt 0) { [math]::Round(($currentUsage / $limit) * 100, 2) } else { 0 }

                        $asp.Add([PSCustomObject]@{
                                SubscriptionName = $Subscription.Name
                                SubscriptionId   = $Subscription.Id
                                Location         = $loc
                                ResourceType     = $resourceName
                                CurrentUsage     = $currentUsage
                                Limit            = $limit
                                UsagePercentage  = $pct
                            })
                    }
                }
            }
            catch {
                Write-Warning "Could not retrieve App Service quota for $loc in subscription $($Subscription.Name): $_"
            }
        }

        return [PSCustomObject]@{ Vm = $vm.ToArray(); Asp = $asp.ToArray() }
    }

    $vmResults = [System.Collections.Generic.List[object]]::new()
    $aspResults = [System.Collections.Generic.List[object]]::new()
    $total = @($Subscriptions).Count

    if ($ThrottleLimit -gt 1) {
        Write-Host "Scanning $total subscription(s) in parallel (throttle: $ThrottleLimit)..." -ForegroundColor Cyan
        $scanText = $scanBlock.ToString()
        $partials = $Subscriptions | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            Import-Module Az.Accounts -ErrorAction SilentlyContinue
            Import-Module Az.Compute -ErrorAction SilentlyContinue
            # Avoid contention on the shared on-disk context cache between runspaces.
            Disable-AzContextAutosave -Scope Process -ErrorAction SilentlyContinue | Out-Null
            $sb = [scriptblock]::Create($using:scanText)
            & $sb $_ $using:Location
        }
        foreach ($p in $partials) {
            if ($p.Vm) { $vmResults.AddRange([object[]]$p.Vm) }
            if ($p.Asp) { $aspResults.AddRange([object[]]$p.Asp) }
        }
    }
    else {
        $i = 0
        foreach ($subscription in $Subscriptions) {
            $i++
            Write-Progress -Activity 'Scanning subscriptions' -Status "$i of $total : $($subscription.Name)" -PercentComplete (($i / $total) * 100)
            Write-Host "Processing subscription: $($subscription.Name) ($($subscription.Id))" -ForegroundColor Cyan
            $p = & $scanBlock $subscription $Location
            if ($p.Vm) { $vmResults.AddRange([object[]]$p.Vm) }
            if ($p.Asp) { $aspResults.AddRange([object[]]$p.Asp) }
        }
        Write-Progress -Activity 'Scanning subscriptions' -Completed
    }

    return @{ Vm = $vmResults.ToArray(); Asp = $aspResults.ToArray() }
}

# ----------------------------------------------------------------------------
# Main entry point (skipped when the script is dot-sourced, e.g. by Pester)
# ----------------------------------------------------------------------------

function Invoke-QuotaReport {
    [CmdletBinding()]
    param(
        [string[]]$Location,
        [string]$OutputPath,
        [int]$Threshold,
        [string[]]$SubscriptionId,
        [int]$ThrottleLimit = 1,
        [switch]$ExportCsv,
        [switch]$ExportJson
    )

    # `pwsh -File` passes comma-separated values as a single string rather than an
    # array; normalise so both `-File` and call-operator invocations behave the same.
    $Location = @($Location | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    if ($SubscriptionId) {
        $SubscriptionId = @($SubscriptionId | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    }

    # Import required Azure modules
    try {
        Import-Module Az.Accounts -ErrorAction Stop
        Import-Module Az.Compute -ErrorAction Stop
    }
    catch {
        throw 'Failed to import required Az modules. Install with: Install-Module -Name Az.Accounts, Az.Compute -Scope CurrentUser'
    }

    # Authenticate
    try {
        $context = Connect-ToAzure
        Write-Host "Connected to Azure as: $($context.Account.Id)" -ForegroundColor Green
        Write-Host "Tenant: $($context.Tenant.Id)" -ForegroundColor Green
    }
    catch {
        throw "Failed to authenticate to Azure: $_"
    }

    # Resolve subscriptions
    try {
        $subscriptions = Get-AzSubscription -ErrorAction Stop
        if ($SubscriptionId) {
            $subscriptions = $subscriptions | Where-Object { $_.Id -in $SubscriptionId }
        }
        if (-not $subscriptions) {
            Write-Warning 'No subscriptions found (or none matched the supplied -SubscriptionId).'
            return
        }
        Write-Host "Found $(@($subscriptions).Count) subscription(s) to process." -ForegroundColor Green
    }
    catch {
        throw "Failed to retrieve subscriptions: $_"
    }

    # Collect quota data
    $data = Get-TenantQuotaData -Subscriptions $subscriptions -Location $Location -ThrottleLimit $ThrottleLimit
    $vmResults = $data.Vm
    $aspResults = $data.Asp

    # Console output
    Write-Host "`nVM Quota Results:" -ForegroundColor Cyan
    $vmResults | Format-Table -AutoSize | Out-Host
    Write-Host "`nApp Service Plan Quota Results:" -ForegroundColor Cyan
    $aspResults | Format-Table -AutoSize | Out-Host

    Write-Host "`nVM Quotas with usage over $Threshold%:" -ForegroundColor Yellow
    $vmResults | Where-Object { $_.UsagePercentage -ge $Threshold } | Format-Table -AutoSize | Out-Host
    Write-Host "`nApp Service Quotas with usage over $Threshold%:" -ForegroundColor Yellow
    $aspResults | Where-Object { $_.UsagePercentage -ge $Threshold } | Format-Table -AutoSize | Out-Host

    # Aggregate
    $vmSummary = @(Get-QuotaSkuSummary -Results $vmResults)
    $aspSummary = @(Get-QuotaSkuSummary -Results $aspResults)

    # Tenant info
    $tenantId = $context.Tenant.Id
    $tenantInfo = Get-AzTenant -TenantId $tenantId -ErrorAction SilentlyContinue
    $tenantName = if ($tenantInfo.Name) { $tenantInfo.Name } else { 'Unknown' }
    $reportDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    # HTML report
    Write-Host "`nGenerating HTML report..." -ForegroundColor Cyan
    $htmlContent = ConvertTo-QuotaHtmlReport -TenantName $tenantName -TenantId $tenantId -Location $Location `
        -ReportDate $reportDate -SubscriptionCount (@($subscriptions).Count) `
        -VmSummary $vmSummary -AspSummary $aspSummary -Threshold $Threshold
    $htmlContent | Out-File -FilePath $OutputPath -Encoding UTF8
    Write-Host "HTML report generated: $OutputPath" -ForegroundColor Green

    # Optional exports
    $outDir = Split-Path -Parent $OutputPath
    if (-not $outDir) { $outDir = Get-Location }
    $outBase = [System.IO.Path]::GetFileNameWithoutExtension($OutputPath)

    if ($ExportCsv) {
        $vmCsv = Join-Path -Path $outDir -ChildPath "$outBase-vm.csv"
        $aspCsv = Join-Path -Path $outDir -ChildPath "$outBase-appservice.csv"
        $vmResults | Export-Csv -Path $vmCsv -NoTypeInformation
        $aspResults | Export-Csv -Path $aspCsv -NoTypeInformation
        Write-Host "CSV exported: $vmCsv, $aspCsv" -ForegroundColor Green
    }

    if ($ExportJson) {
        $jsonPath = Join-Path -Path $outDir -ChildPath "$outBase.json"
        [PSCustomObject]@{
            GeneratedAt = $reportDate
            TenantId    = $tenantId
            TenantName  = $tenantName
            Locations   = $Location
            Threshold   = $Threshold
            Vm          = $vmSummary
            AppService  = $aspSummary
        } | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8
        Write-Host "JSON exported: $jsonPath" -ForegroundColor Green
    }

    $breaches = @(($vmSummary + $aspSummary) | Where-Object { $_.UsagePercentage -ge $Threshold })
    return [PSCustomObject]@{
        Vm                = $vmSummary
        AppService        = $aspSummary
        ThresholdBreached = ($breaches.Count -gt 0)
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-QuotaReport -Location $Location -OutputPath $OutputPath -Threshold $Threshold `
            -SubscriptionId $SubscriptionId -ThrottleLimit $ThrottleLimit `
            -ExportCsv:$ExportCsv -ExportJson:$ExportJson

        if ($PassThru -and $result) {
            [PSCustomObject]@{ Vm = $result.Vm; AppService = $result.AppService }
        }

        if ($FailOnThreshold -and $result -and $result.ThresholdBreached) {
            Write-Warning 'One or more SKUs are at or above the threshold.'
            [Console]::Out.Flush()
            exit 1
        }
    }
    catch {
        Write-Error $_
        [Console]::Out.Flush()
        exit 1
    }
}
