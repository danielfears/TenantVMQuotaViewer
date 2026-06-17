#Requires -Modules Pester

<#
    Unit tests for the pure (Azure-independent) helper functions in quotafinder.ps1.

    The script is dot-sourced so its functions are available; its main entry point
    is guarded by `if ($MyInvocation.InvocationName -ne '.')`, so dot-sourcing does
    not require the Az modules or attempt any Azure calls.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'quotafinder.ps1')
}

Describe 'ConvertTo-SafeHtml' {
    It 'encodes angle brackets and ampersands' {
        ConvertTo-SafeHtml '<script>alert(1)</script> & "x"' |
            Should -Be '&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;x&quot;'
    }

    It 'returns an empty string for null input' {
        ConvertTo-SafeHtml $null | Should -Be ''
    }

    It 'leaves a plain string untouched' {
        ConvertTo-SafeHtml 'Standard DSv5 Family vCPUs' |
            Should -Be 'Standard DSv5 Family vCPUs'
    }
}

Describe 'Get-UsagePercentage' {
    It 'computes a normal percentage rounded to 2dp' {
        Get-UsagePercentage -Used 50 -Limit 200 | Should -Be 25
    }

    It 'returns 0 when the limit is zero (no divide-by-zero)' {
        Get-UsagePercentage -Used 42 -Limit 0 | Should -Be 0
    }

    It 'returns 0 when the limit is negative' {
        Get-UsagePercentage -Used 10 -Limit -5 | Should -Be 0
    }

    It 'rounds to two decimal places' {
        Get-UsagePercentage -Used 1 -Limit 3 | Should -Be 33.33
    }
}

Describe 'Get-UsageClass' {
    It 'returns critical at or above the threshold' {
        Get-UsageClass -Percentage 80 -Threshold 80 | Should -Be 'usage-critical'
        Get-UsageClass -Percentage 95 -Threshold 80 | Should -Be 'usage-critical'
    }

    It 'honours a custom threshold' {
        Get-UsageClass -Percentage 91 -Threshold 90 | Should -Be 'usage-critical'
        Get-UsageClass -Percentage 89 -Threshold 90 | Should -Be 'usage-high'
    }

    It 'returns high / medium / low for the lower bands' {
        Get-UsageClass -Percentage 60 -Threshold 80 | Should -Be 'usage-high'
        Get-UsageClass -Percentage 30 -Threshold 80 | Should -Be 'usage-medium'
        Get-UsageClass -Percentage 5  -Threshold 80 | Should -Be 'usage-low'
    }
}

Describe 'Get-ProgressClass' {
    It 'maps to the matching progress classes' {
        Get-ProgressClass -Percentage 85 -Threshold 80 | Should -Be 'progress-critical'
        Get-ProgressClass -Percentage 55 -Threshold 80 | Should -Be 'progress-high'
        Get-ProgressClass -Percentage 25 -Threshold 80 | Should -Be 'progress-medium'
        Get-ProgressClass -Percentage 1  -Threshold 80 | Should -Be 'progress-low'
    }
}

Describe 'Get-QuotaSkuSummary' {
    It 'aggregates usage and limit across subscriptions per SKU and region' {
        $raw = @(
            [PSCustomObject]@{ SubscriptionName = 'A'; SubscriptionId = '1'; Location = 'uksouth'; ResourceType = 'Total Regional vCPUs'; CurrentUsage = 10; Limit = 100; UsagePercentage = 10 }
            [PSCustomObject]@{ SubscriptionName = 'B'; SubscriptionId = '2'; Location = 'uksouth'; ResourceType = 'Total Regional vCPUs'; CurrentUsage = 30; Limit = 100; UsagePercentage = 30 }
        )
        $summary = Get-QuotaSkuSummary -Results $raw
        $summary | Should -HaveCount 1
        $summary[0].TotalUsage | Should -Be 40
        $summary[0].TotalLimit | Should -Be 200
        $summary[0].UsagePercentage | Should -Be 20
        $summary[0].SubscriptionCount | Should -Be 2
    }

    It 'separates the same SKU across different regions' {
        $raw = @(
            [PSCustomObject]@{ SubscriptionName = 'A'; SubscriptionId = '1'; Location = 'uksouth'; ResourceType = 'Total Regional vCPUs'; CurrentUsage = 10; Limit = 100; UsagePercentage = 10 }
            [PSCustomObject]@{ SubscriptionName = 'A'; SubscriptionId = '1'; Location = 'ukwest';  ResourceType = 'Total Regional vCPUs'; CurrentUsage = 50; Limit = 100; UsagePercentage = 50 }
        )
        $summary = Get-QuotaSkuSummary -Results $raw
        $summary | Should -HaveCount 2
    }

    It 'returns an empty array for no input' {
        Get-QuotaSkuSummary -Results @() | Should -HaveCount 0
    }
}

Describe 'ConvertTo-QuotaTableHtml' {
    It 'HTML-encodes a malicious subscription name (no injection)' {
        $sku = [PSCustomObject]@{
            ResourceType        = 'Total Regional vCPUs'
            Location            = 'uksouth'
            TotalUsage          = 10
            TotalLimit          = 20
            UsagePercentage     = 50
            SubscriptionCount   = 1
            SubscriptionDetails = @(
                [PSCustomObject]@{ SubscriptionName = '<img src=x onerror=alert(1)>'; SubscriptionId = '0000'; CurrentUsage = 10; Limit = 20; UsagePercentage = 50 }
            )
        }
        $html = ConvertTo-QuotaTableHtml -SkuSummary @($sku) -Threshold 80
        $html | Should -Not -Match '<img src=x'
        $html | Should -Match '&lt;img src=x'
    }

    It 'returns an empty string for an empty summary' {
        ConvertTo-QuotaTableHtml -SkuSummary @() -Threshold 80 | Should -Be ''
    }

    It 'renders a region cell and the resource type' {
        $sku = [PSCustomObject]@{
            ResourceType = 'Total Regional vCPUs'; Location = 'uksouth'
            TotalUsage = 5; TotalLimit = 10; UsagePercentage = 50
            SubscriptionCount = 1; SubscriptionDetails = @()
        }
        $html = ConvertTo-QuotaTableHtml -SkuSummary @($sku) -Threshold 80
        $html | Should -Match 'uksouth'
        $html | Should -Match 'Total Regional vCPUs'
    }
}

Describe 'ConvertTo-QuotaHtmlReport' {
    It 'produces a complete HTML document' {
        $html = ConvertTo-QuotaHtmlReport -TenantName 'Contoso' -TenantId 'tid' -Location @('uksouth') `
            -ReportDate '2026-01-01 00:00:00' -SubscriptionCount 1 -VmSummary @() -AspSummary @() -Threshold 80
        $html | Should -Match '<!DOCTYPE html>'
        $html | Should -Match '</html>'
        $html | Should -Match 'No VM Quota Data Found'
    }

    It 'encodes a malicious tenant name' {
        $html = ConvertTo-QuotaHtmlReport -TenantName '<b>evil</b>' -TenantId 'tid' -Location @('uksouth') `
            -ReportDate '2026-01-01 00:00:00' -SubscriptionCount 1 -VmSummary @() -AspSummary @() -Threshold 80
        $html | Should -Match '&lt;b&gt;evil&lt;/b&gt;'
    }
}
