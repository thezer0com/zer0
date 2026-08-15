import Foundation
import Security
import Testing
import WebKit
@testable import Zer0Shell
import Zer0Core

/// Real certificates, from the servers the design was measured against.
///
/// DER rather than a description of one, because the thing under test is
/// whether `CertificateFacts` reads a real chain correctly, and a fixture
/// written from the same reasoning as the code would agree with it for the
/// same wrong reasons. Each of these was served by a live TLS server on
/// loopback while a `WKWebView` loaded it.
enum Certificates {
    /// selfsigned
    static let selfsigned: String =
        "MIIDPDCCAiSgAwIBAgIUSE1M+TB3aDWyGXPZfVGl449vd/gwDQYJKoZIhvcNAQELBQAwFDESMBAG" +
        "A1UEAwwJbG9jYWxob3N0MB4XDTI2MDgxMDE4MjAzNFoXDTI3MDgxMDE4MjAzNFowFDESMBAGA1UE" +
        "AwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA1Hl/3Hd9CoSKq5EW" +
        "Fpy+FsXMKvqBayK45GtMpefaXGJUFogFUxI7xI7YPcCSHhIJfd7TEBLP8CRhf4sBrbSTAreRjo1K" +
        "1hI3/JcAfeC4qWGliX3I4+QjaM5Sxl+s1tjyKqoSQMwJlS7+XL1eGhARv7RthMiMRyNfosXIgr+M" +
        "o25sktbXdYPMh/NwVYpPVkNe1Gs8tRfJ2L3PJLg+4o0QWGrZXtWbwPZnFn1DkOUXEBzQ6XEcqaVK" +
        "m0O8RM6j28J7MTlMttUKmuA3Jsz76mpmgjlTu/TyiHykvAY1Im4c7PzpWHPOSZyTozrpVZlKxTkF" +
        "YUsoiDdlZyj8bp6s1j8TIwIDAQABo4GFMIGCMB0GA1UdDgQWBBS8zm2jN82n1rPYmrOoA5c5X6Qo" +
        "NTAfBgNVHSMEGDAWgBS8zm2jN82n1rPYmrOoA5c5X6QoNTAaBgNVHREEEzARgglsb2NhbGhvc3SH" +
        "BH8AAAEwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsF" +
        "AAOCAQEAvJMYqR6e/bSwDl/qnZZvyH1MBh/k4q8mZA4icfZGPvC4OLqY40IIgGlmTak9cNdzXHwU" +
        "63hLRPtQagvK0ow2QLmLp0c3I5vggnOIdFwdGSjmj0r4r8ve0/ztAqg0TB1+4AFv2MLq9j2bKnT1" +
        "yfE+mAGMamq4j3ippLz4/rhpSQlYsGIkTocGhAPItGl767qIKuFfDrPnxVrYTX3dv1SPqNUk2a9D" +
        "qJbixfK0EVC9H5BcFsPNWJMPlRynCJCaHQeI87ztKoSqWpmUWbkwmCKQUUVcbZ1bK2OQqiwwH5Z4" +
        "JsMxenF7lC3kF7GZeEq6CFK9XMYS7hRoFVtC/LmpXSIBPA=="

    /// wronghost
    static let wronghost: String =
        "MIIDVzCCAj+gAwIBAgIUVueSDd6J6KwQFPc+nbfU5jnM/uowDQYJKoZIhvcNAQELBQAwHzEdMBsG" +
        "A1UEAwwUbm90LXRoZS1ob3N0LmV4YW1wbGUwHhcNMjYwODEwMTgyMDM0WhcNMjcwODEwMTgyMDM0" +
        "WjAfMR0wGwYDVQQDDBRub3QtdGhlLWhvc3QuZXhhbXBsZTCCASIwDQYJKoZIhvcNAQEBBQADggEP" +
        "ADCCAQoCggEBAKwDVWwrxZDQBQYif9Xuok42XpiKogTO9v/gU/DfGTvfMRUHg4Z6j8Fih/EzOA0n" +
        "VNhmpKmbg/TsZU2t0U3apumpjbyWbnYjgF8EIH/12vKOcT0QajCjTuK76HSuEIWqjs22yVO4hGFJ" +
        "fo0Oa8SzhQ5gRvow06NndS4VqXfy8/4u9JIBHEHucWmm1xik5x+eozFwb+6kiaE7kYf7IuOel+SS" +
        "NTv7OxseZHMelL9FSY5fsdGsy4ruPx8D1cwtO0KVBsdzvT8c6RzdSOcijJ1QIyq+vB2cA3pm9/Ln" +
        "phFGrFFqqY/StQLrmO8Uxeo36T9+c7xa15lrGFKg8jiaH/gS6ysCAwEAAaOBijCBhzAdBgNVHQ4E" +
        "FgQU5vRFf1ZA09v5xYMd/txi01r7lrEwHwYDVR0jBBgwFoAU5vRFf1ZA09v5xYMd/txi01r7lrEw" +
        "HwYDVR0RBBgwFoIUbm90LXRoZS1ob3N0LmV4YW1wbGUwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDwYD" +
        "VR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAjz1CJrWk5IHtEUyd7vVfnrlwn+CMwpFJ" +
        "u8BSnFWFV1sVR60r9sANEymam2GxRaTyGbqwo2PQiJ+fRu5PooSxaywEXWbmxvnlCA0Ccv3ENTqo" +
        "xIMabSe6+kOuE87sHRK8XxValA0VRnRaFpOyxIZrEFEJWl2lHIz2Kj8uYB1xVnkdX2f0qCwKOUYb" +
        "oHIrz5kzKfS7crdKGWRMJoOERqtHOX/RgJbZG1BsxMchvQz2ESy33PEn6fpLuI3LElgvON+4ZlAt" +
        "p/zDF9pGP0g7b9EJZPXu6ExTKHuIfteIZ8EwTD+ahun8H89fFxdgqtH+p0SpfTcVjqVGL3ZrIBGi" +
        "khGwkQ=="

    /// expired
    static let expired: String =
        "MIIDPDCCAiSgAwIBAgIUSuVHiAC5B7aJsEmwgbJLtMs+LG0wDQYJKoZIhvcNAQELBQAwFDESMBAG" +
        "A1UEAwwJbG9jYWxob3N0MB4XDTIwMDEwMTAwMDAwMFoXDTIwMDEwMjAwMDAwMFowFDESMBAGA1UE" +
        "AwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuOXY2gnv1wKPdQiR" +
        "m6ZfSMfwwm+VU084/RVilz3YujYDHhnfn6QTrTHUhHRz/+MS/QluWu4ER+I0HaFPljmqzV4OG+Cp" +
        "Qdv2tII+OrHUThsiTz1s3dLiHyPcumkJxQ01zRcKEigTZrriuTP63lWSfKHPldZzTVAOC9q5Bc1N" +
        "NPDu8H0PRqMRmUxOFncLfClLvsLrSXAcTmcIvBfFLmJJuUxC3Llcu02wJGcIah/CdiaS8nYxVHOZ" +
        "Ct+nFWT0rS8A+G0ld5MmSalCpl6zRM8uaFF9w23kQb2cwYytXBkAgL7kxQuwWt74uc1PFP2VsFSj" +
        "+KUNGbFFkjs/zBay0C0dtwIDAQABo4GFMIGCMB0GA1UdDgQWBBQQvsC4bJ4mudhHD+U0p3PoLnI1" +
        "fDAfBgNVHSMEGDAWgBQQvsC4bJ4mudhHD+U0p3PoLnI1fDAaBgNVHREEEzARgglsb2NhbGhvc3SH" +
        "BH8AAAEwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsF" +
        "AAOCAQEAeuuWuOdEIpzVnj+MFvGmvwW68UTNZJsLXzJ4ddRejL+qJLNhhIoYYNYOLWXm2aQG2YAk" +
        "pah+/DCw8HcRYFYTGIZk1NNhm8iHoodJ1oeor/xvFHaGiwSxcSw7AXGDgJ4XundcSHAqQ5dajjam" +
        "voQK/KGVZJ9opCTVlfp4GCG6dg8D4JqQFBsCzgMjQu8ZVTpR1qForefUQ6+oulb2aEotHiVCY1O8" +
        "CnBFzhRMBh8qLJJWGCzq+fWnRDzwExe3Lj96q38S24pIZNvKBhGcNDoCLTH9VWRtwrVcdhk0wBng" +
        "fhku0b3p8NfFj34os3FD0PutDBv05dcgJXphQPGQrH+DbA=="

    /// leaf
    static let leaf: String =
        "MIIDPzCCAiegAwIBAgIUKEPtnuJS7o2G4hVsTEUlPUaJOoYwDQYJKoZIhvcNAQELBQAwGzEZMBcG" +
        "A1UEAwwQQWNtZSBJbnRlcm5hbCBDQTAeFw0yNjA4MTAxODIwNDJaFw0yNzA4MTAxODIwNDJaMBQx" +
        "EjAQBgNVBAMMCWxvY2FsaG9zdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAMvVEZwg" +
        "gjmfvIT90ThSbn+FW7s7P+IUaPEJGgcFDDPz8yvPLr/gwJ+8j/BRsA/IxCG1mBZu63nWjLI3PvMQ" +
        "xGK+cIbpEWeNnvSe5gRFxTrXiuAndyGJdY5YgOS0blOhbFLgZqeye0X98uyJO6KSVpzeX6jFAozU" +
        "2KJKDVEf5AY/T4MZ/zWw3pJOMvzKjMtvpk8BgAVaFBnVSSkrXHf/9LbR6YGa1zggVip9WwTGS3z1" +
        "oBCQ4dbCF5if8SzqZQJkgBQcQyy/DPnSCQ5Sh3wb/rXmDPuFmo2/VGBubRIkzTd40V89yzXzUurj" +
        "Nberd6FAwdZ718UOfu8bT92VXDoxh50CAwEAAaOBgTB/MBoGA1UdEQQTMBGCCWxvY2FsaG9zdIcE" +
        "fwAAATATBgNVHSUEDDAKBggrBgEFBQcDATAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBTZiGJk7HZ2" +
        "h3tpzKV3cPEetcjz8zAfBgNVHSMEGDAWgBQOjnXyT6CCXabZax9AtF7YdizWyDANBgkqhkiG9w0B" +
        "AQsFAAOCAQEAbdx1yjWizyUhlVH8RDvwqwJwP+LK3yhZ2CERjN2/fj+CeLY8aAE/ccdtW2JuqrBn" +
        "Xzou5jkRnj7M8uWEwl6Qs4UJoptS5Qd/vA3IioEn8E8WnW6sl7kS7setxi7YGY73WiDAmclEiejM" +
        "Eh9AKn7jBxOAoklcjiXZyIHUhsZVzK3heKr7A7Lwvw0jupvvzHRP1woLGhlfY583aq9vnE+SPKZE" +
        "jRzBY/qm1yMW8KrW4t8SyXFvsgrYwNcMhY+kkDHX2XtzIgKxcWpm1oGL9ljmUkf8P1q+0CJ7aUDE" +
        "ZJHrOYSoo15jSfSbtuHg0OfVm4Y8pUGpBFrvNJ8m0XkWwM3mOw=="

    /// ca
    static let ca: String =
        "MIIDJzCCAg+gAwIBAgIUEHXe7NNcsFujuOv+wiCXNduxhAIwDQYJKoZIhvcNAQELBQAwGzEZMBcG" +
        "A1UEAwwQQWNtZSBJbnRlcm5hbCBDQTAeFw0yNjA4MTAxODIwNDJaFw0yNzA4MTAxODIwNDJaMBsx" +
        "GTAXBgNVBAMMEEFjbWUgSW50ZXJuYWwgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB" +
        "AQC/yCFORX7Ck85DCF3bW776rQwnEmPkMnBaAGnwyOXK4CIxJH3yDC11x19PXdQfIBAYSr4cHOA/" +
        "+RqZlGr6YmqGG9KUnV6LKJuAKAH04m0GE0hB0NYU7ATjmPQ5O3VKVUolIv9iIbJdO5dzY5ZqdZsw" +
        "ctQVM524T7/s8Xp3+FrfpaoH/DVP6u+a9hsWErM3OXOyxYJypzxkPx59An8BaNK8IB9kfkQ3zcjC" +
        "iDYCqbmAU9tXPq058jTyGKojz35tQNvXaQbHwUpsVrxJMMPqZjlchUIkTV3M8oTLfOPILuPj9pkH" +
        "XUaeuNXZF+1juycRUViFme2CapgPV/+dTDT3vIn7AgMBAAGjYzBhMB0GA1UdDgQWBBQOjnXyT6CC" +
        "XabZax9AtF7YdizWyDAfBgNVHSMEGDAWgBQOjnXyT6CCXabZax9AtF7YdizWyDAPBgNVHRMBAf8E" +
        "BTADAQH/MA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQsFAAOCAQEAU4mHCHdXHslcYk7dnLE0" +
        "XoLML17WvYbzKjLMFCrmZE9p6Mrdo3qBugLn1EYLai4JfWflnGD7YluwZUplXmnTWOYCu7XHljQ1" +
        "SfUCYtMHPM2UxzDULCRXsdB7cBTXzkatjpLtytiup08SGaRiieEQjX3dHqCge5NBTdsTEASCtMdl" +
        "5eE3viySBmBVkwgIkJOXPJkUKfh9DueBmdlPhZmKvi7Dd+DTL6dGRf983WpxSrD3JJR9mgPzKeOo" +
        "Z8Uzt5M4k1JWc04UgQE7UVSZspgOr0CelIJpQp0l5V3MBl7bvTaZQS//RFCT9cFZcpNCOoKS/vVi" +
        "E+0yV1kneYa8cvsiNw=="

    static func certificate(_ base64: String) -> SecCertificate {
        let der = Data(base64Encoded: base64)!
        return SecCertificateCreateWithData(nil, der as CFData)!
    }

    /// A `SecTrust` over a chain, the way one arrives from a challenge.
    static func trust(_ chain: [String], host: String) -> SecTrust {
        var trust: SecTrust?
        SecTrustCreateWithCertificates(
            chain.map(certificate) as CFArray,
            SecPolicyCreateSSL(true, host as CFString),
            &trust
        )
        return trust!
    }
}
