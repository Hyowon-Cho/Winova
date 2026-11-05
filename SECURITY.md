# Security

Winova launches Windows applications with the permissions of the current macOS
user. Its separate Windows environments organize application data, but they are
not a security sandbox. A launched application may access the network and files
that macOS allows the selected runtime to access.

Only run installers and applications from sources you trust. Do not use Winova
to analyze unknown or suspicious executables.

The downloadable archives are development builds. They are ad-hoc signed and
are not Apple-notarized. A production release should use Developer ID signing,
Hardened Runtime, and Apple notarization.

Winova itself does not include telemetry. This does not prevent applications
launched through Winova from collecting or transmitting data.

Please report security issues through GitHub private vulnerability reporting
instead of posting exploit details in a public issue.
