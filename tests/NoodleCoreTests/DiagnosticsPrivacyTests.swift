import Foundation
import Testing
@testable import NoodleCore

@Suite struct DiagnosticsPrivacyTests {
    @Test(arguments: [
        "AKIA0123456789ABCDEF", "AIza0123456789abcdefghijklmnopqrstuvwxyzA",
        "ya29.abcdefghijklmnopqrstuvwxyz0123456789", "xapp-1234567890-abcdefghijklmnop",
        "eyJhIjoi0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", "glpat-abcdefghijklmnopqrst",
        "ghp_abcdefghijklmnopqrstuvwxyz0123456789", "github_pat_abcdefghijklmnopqrstuvwxyz",
        "npm_abcdefghijklmnopqrstuvwxyz", "xoxb-1234567890-abcdefghijklmnop",
        "sk_live_abcdefghijklmnopqrstuv", "sk-proj-abcdefghijklmnopqrstuvwxyz",
        "sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmaXh0dXJlIn0.signature123",
    ]) func providerTokens(token: String) {
        #expect(!Redactor(home: nil).redact("received \(token)").contains(token))
    }

    @Test(arguments: ["KEY", "TOKEN", "SECRET", "PASS", "AUTH", "AWS_SECRET_ACCESS_KEY", "AZURE_CLIENT_SECRET", "GCP_PRIVATE_KEY", "TUNNEL_TOKEN"])
    func secretAssignments(name: String) {
        for input in ["\(name)=fixture-value", "\(name)=\"fixture value\"", "{\"\(name)\":\"fixture value\"}"] {
            #expect(!Redactor(home: nil).redact(input).contains("fixture"))
        }
    }

    @Test func structuredAndMultilineSecrets() {
        let input = """
        -----BEGIN CERTIFICATE-----
        fixture-certificate
        -----END CERTIFICATE-----
        https://fixture-user:fixture-password@registry.example/v2
        cloudflared tunnel run --token fixture-tunnel
        https://storage.example/blob?sv=2025&sig=fixture-sas-signature
        PRIVATE_KEY=-----BEGIN PRIVATE KEY-----
        fixture-assigned-pem
        -----END PRIVATE KEY-----
        {"client_email":"fixture-account@example.com","private_key_id":"fixture-key-id","AccountName":"fixture-storage","AccountKey":"fixture-storage-key"}
        """
        #expect(!Redactor(home: nil).redact(input).contains("fixture"))
    }

    @Test func accountDetailsArePrivateInBundleText() {
        let input = "username=fixture-account --username fixture-login -u fixture-short fixture-mail@example.com"
        let output = Redactor(home: nil, anonymizeIdentities: true).redact(input)
        #expect(!output.contains("fixture"))
        #expect(output.contains("username="))
    }

    @Test func identitiesAreStableWithinBundleAndSaltedAcrossBundles() {
        let first = Redactor(home: "/Users/fixture-person", identities: ["private-image:latest", "private-container", "compose-project"], anonymizeIdentities: true)
        let input = "private-image:latest private-container compose-project fixture-person workstation.example 203.0.113.42 2001:db8::1234 172.18.0.2"
        let result = first.redact(input)
        for value in input.split(separator: " ").dropLast() { #expect(!result.contains(value)) }
        #expect(result.contains("172.18.0.2"))
        #expect(first.redact(input) == result)
        #expect(first.redact("container private-container") == "container " + first.redact("private-container"))
        #expect(first.redact("hostname workstation.example") == "hostname " + first.redact("workstation.example"))
        #expect(Redactor(home: nil, identities: ["private-container"], anonymizeIdentities: true).redact("private-container") != first.redact("private-container"))
    }
}
