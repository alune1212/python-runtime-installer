@{
    Severity = @('Error', 'Warning')
    # These functions are internal transactional primitives, never interactive
    # user cmdlets. Confirmation belongs to the Inno wizard, not nested helpers.
    # signtool accepts the ephemeral PFX password only as a process argument;
    # the workflow masks it and destroys the certificate in a finally block.
    ExcludeRules = @(
        'PSUseShouldProcessForStateChangingFunctions',
        'PSAvoidUsingPlainTextForPassword'
    )
}
