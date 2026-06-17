@{
    # Run the default rule set...
    IncludeDefaultRules = $true

    # ...except rules that don't fit an interactive, single-file reporting script.
    ExcludeRules = @(
        # The script intentionally uses Write-Host for coloured, user-facing console
        # output (progress, status, the report path). This is appropriate for an
        # interactive tool rather than a library.
        'PSAvoidUsingWriteHost'
    )
}
