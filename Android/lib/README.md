# Bouncy Castle 1.86

Official Maven Central artifacts: bcprov-jdk15to18, bcpkix-jdk15to18 and bcutil-jdk15to18, version 1.86.

Source: https://www.bouncycastle.org/download/bouncy-castle-java/
Artifacts: https://repo.maven.apache.org/maven2/org/bouncycastle/
SHA-256 hashes: SHA256SUMS (paths relative to the project root).

Used only to generate an ephemeral self-signed session certificate on TV firmware where AndroidKeyStore key generation fails. Transport encryption remains platform TLS; private fallback keys stay in RAM and are not embedded in the APK or written to disk. The licence is bundled in Android/assets/BouncyCastle-LICENSE.html.
