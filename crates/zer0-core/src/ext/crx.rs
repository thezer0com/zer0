//! Reading a `.crx` package.
//!
//! A CRX3 file is a small header followed by an ordinary ZIP. The header is a
//! protobuf carrying the signatures and the extension id. We parse only the
//! fields we need rather than pulling in a protobuf runtime, because the two
//! messages involved have four fields between them.
//!
//! Layout:
//! ```text
//! "Cr24" | version: u32le | header_size: u32le | header: CrxFileHeader | zip
//! ```
//!
//! Every signature in the header covers the same byte string: the domain
//! separator `"CRX3 SignedData\0"`, the length of the signed header data as a
//! little-endian `u32`, the signed header data itself, and then the **entire
//! ZIP payload**. That last part is easy to miss and this file did miss it
//! first: measured against real store packages (and read off Chromium's
//! `crx_verifier.cc`, which spells the same concatenation out), a signature
//! binds the archive too. A header copied wholesale from a genuine package and
//! laid over a swapped ZIP therefore fails verification, not just the id check.
//!
//! The field named `sha256_with_rsa` is RSA PKCS#1 v1.5 with SHA-256 — not
//! PSS, whatever the name suggests. The store signs that way and Chrome
//! verifies that way.

use sha2::{Digest, Sha256};

use super::ExtError;

const MAGIC: &[u8; 4] = b"Cr24";

/// What every CRX3 signature is prefixed with (Chromium `crx_file.h`,
/// `kSignatureContext`).
const SIGNATURE_CONTEXT: &[u8; 16] = b"CRX3 SignedData\x00";

/// The `DigestInfo` DER prefix in front of the digest inside an RSA PKCS#1
/// v1.5 SHA-256 signature (RFC 8017 §9.2). Spelled out rather than borrowed
/// from the `rsa` crate's helper, which expects the `sha2` version it was
/// built against; ours is newer and the bytes are the same either way.
const SHA256_DIGEST_INFO: &[u8; 19] = &[
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
    0x00, 0x04, 0x20,
];

/// Field 2 of `CrxFileHeader`: repeated AsymmetricKeyProof sha256_with_rsa.
const FIELD_SHA256_WITH_RSA: u64 = 2;
/// Field 3: repeated AsymmetricKeyProof sha256_with_ecdsa.
const FIELD_SHA256_WITH_ECDSA: u64 = 3;
/// Field 10000: the signed header data, itself a protobuf.
const FIELD_SIGNED_HEADER_DATA: u64 = 10000;
/// Field 1 of `AsymmetricKeyProof`: the SubjectPublicKeyInfo.
const FIELD_PUBLIC_KEY: u64 = 1;
/// Field 2 of `AsymmetricKeyProof`: the signature over the payload described
/// in the module docs.
const FIELD_SIGNATURE: u64 = 2;
/// Field 1 of `SignedData`: the 16-byte extension id.
const FIELD_CRX_ID: u64 = 1;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Crx {
    /// The 32-character extension id, as it appears in a store URL.
    pub id: String,
    /// The ZIP payload.
    pub archive: Vec<u8>,
}

/// Parse a CRX3 package and check that it is the extension it claims to be.
///
/// Two things must hold. The id declared in the signed header data must be
/// derivable from one of the header's public keys — one, because a package
/// from the store carries several and the author's is not the first — which
/// stops a swapped response from installing a different extension under the id
/// you asked for. And every signature in the header must verify over the
/// signed data and the archive, which stops a package that reuses a real
/// extension's id from installing at all: whoever built it does not hold the
/// key that id was derived from, so there is no way for them to produce a
/// signature that passes.
///
/// Fail-closed: a header whose signatures do not verify — or that carries
/// none — refuses the package rather than installing it on the id check alone
/// (ADR-0113).
pub fn parse(bytes: &[u8]) -> Result<Crx, ExtError> {
    if bytes.len() < 16 || &bytes[0..4] != MAGIC {
        return Err(ExtError::NotACrx);
    }
    let version = u32::from_le_bytes(bytes[4..8].try_into().unwrap());
    if version != 3 {
        return Err(ExtError::UnsupportedCrxVersion { version });
    }
    let header_size = u32::from_le_bytes(bytes[8..12].try_into().unwrap()) as usize;

    let header_start = 12usize;
    let header_end = header_start
        .checked_add(header_size)
        .filter(|end| *end <= bytes.len())
        .ok_or(ExtError::Truncated)?;
    let header = &bytes[header_start..header_end];
    let archive = &bytes[header_end..];

    if archive.is_empty() {
        return Err(ExtError::Truncated);
    }

    let signed = signed_header_data(header)?;
    let declared = declared_id(signed)?;
    let proofs = proofs(header);

    if proofs.is_empty() {
        return Err(ExtError::MalformedHeader);
    }
    let derived: Vec<String> = proofs
        .iter()
        .map(|p| id_from_public_key(p.public_key))
        .collect();
    if !derived.contains(&declared) {
        return Err(ExtError::IdMismatch {
            declared,
            derived: derived.join(", "),
        });
    }

    verify_crx3_signatures(&proofs, signed, archive)?;

    Ok(Crx {
        id: declared,
        archive: archive.to_vec(),
    })
}

/// The id stored in `signed_header_data`, rendered in Chrome's encoding.
fn declared_id(signed: &[u8]) -> Result<String, ExtError> {
    let raw = fields(signed)
        .find(|(number, _)| *number == FIELD_CRX_ID)
        .map(|(_, value)| value)
        .ok_or(ExtError::MalformedHeader)?;

    if raw.len() != 16 {
        return Err(ExtError::MalformedHeader);
    }
    Ok(encode_id(raw))
}

/// Field 10000 of the header, raw: the serialized `SignedData` message. This
/// exact byte string is part of what every signature covers, so it is handed
/// around as bytes rather than re-parsed into an id and rebuilt, which would
/// risk verifying against something other than what was signed.
fn signed_header_data(header: &[u8]) -> Result<&[u8], ExtError> {
    fields(header)
        .find(|(number, _)| *number == FIELD_SIGNED_HEADER_DATA)
        .map(|(_, value)| value)
        .ok_or(ExtError::MalformedHeader)
}

/// Every `AsymmetricKeyProof` in the header that carries a public key, in the
/// order they appear.
///
/// **All of them, and not the first one.** A package straight from the store
/// carries more than one proof, and the extension's own key is not the one in
/// front. uBlock Origin Lite as served today has two `sha256_with_rsa` proofs:
/// Google's Web Store publisher key first, then the author's. Reading only the
/// first derives `lfoeajgcchlidpicbabpmckkejpckcfb` for a package that declares
/// `ddkjiahejlhfcafbddmgiahcphecmpfh`, so the id check refused a package that
/// was entirely genuine — and refused every real extension, every time.
///
/// This is measured from the real download rather than reasoned about, and it
/// is what Chrome does: the declared id has to be backed by *a* key in the
/// header, not by a particular one.
fn proofs(header: &[u8]) -> Vec<Proof<'_>> {
    fields(header)
        .filter_map(|(number, value)| {
            let algorithm = match number {
                FIELD_SHA256_WITH_RSA => ProofAlgorithm::RsaPkcs1Sha256,
                FIELD_SHA256_WITH_ECDSA => ProofAlgorithm::EcdsaP256Sha256,
                _ => return None,
            };
            let public_key = fields(value)
                .find(|(number, _)| *number == FIELD_PUBLIC_KEY)
                .map(|(_, key)| key)?;
            // A proof that carries no signature is kept rather than skipped:
            // skipping it would let a package dodge verification by leaving
            // the field out, and failing closed on an empty signature is the
            // same refusal with no special case to keep true.
            let signature = fields(value)
                .find(|(number, _)| *number == FIELD_SIGNATURE)
                .map(|(_, sig)| sig)
                .unwrap_or(&[]);
            Some(Proof {
                algorithm,
                public_key,
                signature,
            })
        })
        .collect()
}

/// Chrome derives an extension id from the first 16 bytes of the SHA-256 of
/// the public key, then maps each nibble onto 'a'..'p'.
pub fn id_from_public_key(key: &[u8]) -> String {
    let digest = Sha256::digest(key);
    encode_id(&digest[..16])
}

/// Verify every proof in the header, the way Chrome treats a package: one
/// broken proof refuses the whole file.
///
/// Strict on purpose (ADR-0113). "Some signature verifies" would also keep a
/// forger out — they cannot produce even one without the author's key — but
/// it would accept packages Chrome refuses, and a store package has never
/// been observed with a proof that does not verify. When the format grows a
/// proof kind we do not read, this is the line that goes red rather than the
/// install quietly weakening.
fn verify_crx3_signatures(
    proofs: &[Proof<'_>],
    signed_header_data: &[u8],
    archive: &[u8],
) -> Result<(), ExtError> {
    let digest = signature_payload_digest(signed_header_data, archive);
    for proof in proofs {
        let verified = match proof.algorithm {
            ProofAlgorithm::RsaPkcs1Sha256 => verify_rsa(&digest, proof),
            ProofAlgorithm::EcdsaP256Sha256 => verify_ecdsa(&digest, proof),
        };
        if !verified {
            return Err(ExtError::CrxSignatureInvalid);
        }
    }
    Ok(())
}

/// The SHA-256 of everything a CRX3 signature covers. See module docs for the
/// layout; the length prefix is a `u32` in little-endian, which is not an
/// accident of the format to normalize away.
fn signature_payload_digest(signed_header_data: &[u8], archive: &[u8]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(SIGNATURE_CONTEXT);
    hasher.update((signed_header_data.len() as u32).to_le_bytes());
    hasher.update(signed_header_data);
    hasher.update(archive);
    hasher.finalize().into()
}

/// One hash of the payload serves every proof, so this and `verify_ecdsa`
/// take the digest rather than the message.
fn verify_rsa(digest: &[u8; 32], proof: &Proof<'_>) -> bool {
    // The trait is named and imported here rather than at the module top: the
    // `rsa` and `p256` trees each carry their own `pkcs8`, and two traits
    // called `DecodePublicKey` in one scope resolve against the wrong one.
    use rsa::pkcs8::DecodePublicKey as RsaDecodePublicKey;

    let Ok(key) = rsa::RsaPublicKey::from_public_key_der(proof.public_key) else {
        return false;
    };
    let mut digest_info = [0u8; 51];
    digest_info[..SHA256_DIGEST_INFO.len()].copy_from_slice(SHA256_DIGEST_INFO);
    digest_info[SHA256_DIGEST_INFO.len()..].copy_from_slice(digest);
    key.verify(
        rsa::Pkcs1v15Sign::new_unprefixed(),
        &digest_info,
        proof.signature,
    )
    .is_ok()
}

fn verify_ecdsa(digest: &[u8; 32], proof: &Proof<'_>) -> bool {
    // Local for the same reason as in `verify_rsa`: the namesake trait from
    // the `rsa` tree must not be in scope here.
    use p256::ecdsa::signature::hazmat::PrehashVerifier;
    use p256::pkcs8::DecodePublicKey as EcdsaDecodePublicKey;

    let key = p256::ecdsa::VerifyingKey::from_public_key_der(proof.public_key);
    let signature = p256::ecdsa::Signature::from_der(proof.signature);
    match (key, signature) {
        (Ok(key), Ok(signature)) => key.verify_prehash(digest, &signature).is_ok(),
        _ => false,
    }
}

struct Proof<'a> {
    algorithm: ProofAlgorithm,
    public_key: &'a [u8],
    signature: &'a [u8],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProofAlgorithm {
    /// Field 2. Named for PSS, defined as PKCS#1 v1.5 — see module docs.
    RsaPkcs1Sha256,
    /// Field 3: ECDSA over P-256 with SHA-256.
    EcdsaP256Sha256,
}

fn encode_id(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(nibble(byte >> 4));
        out.push(nibble(byte & 0x0f));
    }
    out
}

fn nibble(value: u8) -> char {
    (b'a' + value) as char
}

/// Iterate length-delimited protobuf fields, skipping everything else.
///
/// Every field we care about is length-delimited (wire type 2). Other wire
/// types are stepped over rather than decoded.
fn fields(mut buf: &[u8]) -> impl Iterator<Item = (u64, &[u8])> {
    std::iter::from_fn(move || {
        loop {
            let (tag, rest) = varint(buf)?;
            let number = tag >> 3;
            let wire_type = tag & 0x07;
            buf = rest;

            match wire_type {
                // Length-delimited: the only kind we read.
                2 => {
                    let (len, rest) = varint(buf)?;
                    let len = usize::try_from(len).ok()?;
                    if rest.len() < len {
                        return None;
                    }
                    let (value, rest) = rest.split_at(len);
                    buf = rest;
                    return Some((number, value));
                }
                0 => buf = varint(buf)?.1,
                1 => buf = buf.get(8..)?,
                5 => buf = buf.get(4..)?,
                // Groups are long gone from proto3, and anything else is
                // corruption. Either way there is nothing sensible to skip.
                _ => return None,
            }
        }
    })
}

fn varint(buf: &[u8]) -> Option<(u64, &[u8])> {
    let mut value = 0u64;
    for (i, byte) in buf.iter().take(10).enumerate() {
        value |= u64::from(byte & 0x7f) << (7 * i);
        if byte & 0x80 == 0 {
            return Some((value, &buf[i + 1..]));
        }
    }
    None
}

/// Building packages that pass verification, for tests.
///
/// [`parse`] now refuses a package whose proofs do not verify, so a synthetic
/// CRX is only a valid test input if it is genuinely signed. Signing here is
/// ECDSA P-256 — the fast one to do in a test — with a key chosen
/// deterministically from seed material, and RFC 6979 makes the signature
/// deterministic too, so a package built by this module is byte-stable.
///
/// Real RSA and ECDSA verification is exercised by the store fixtures in
/// `testdata/`; this exists so the negative cases can be built to order.
#[cfg(test)]
pub(crate) mod test_support {
    use p256::ecdsa::signature::Signer;
    use p256::ecdsa::{Signature, SigningKey};
    use sha2::{Digest, Sha256};

    use super::{
        FIELD_CRX_ID, FIELD_PUBLIC_KEY, FIELD_SHA256_WITH_ECDSA, FIELD_SIGNATURE,
        FIELD_SIGNED_HEADER_DATA, MAGIC, encode_id, fields,
    };

    /// The DER header of a P-256 `SubjectPublicKeyInfo`: one SEQUENCE around
    /// the algorithm identifiers and the uncompressed-point BIT STRING. Every
    /// P-256 SPKI the store carries starts with these 26 bytes; the remaining
    /// 65 are the key.
    const P256_SPKI_PREFIX: &[u8; 26] = &[
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08,
        0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ];

    pub(crate) struct TestSigner {
        signing: SigningKey,
    }

    impl TestSigner {
        /// A key derived deterministically from `seed`, so a test that names
        /// its key by bytes gets a stable id back.
        ///
        /// The first byte of the SHA-256 is zeroed rather than used: a scalar
        /// this size is always below P-256's order, so no seed can produce a
        /// key that fails to construct.
        pub(crate) fn from_seed(seed: &[u8]) -> Self {
            let digest = Sha256::digest(seed);
            // By hand rather than `.into()` because the digest comes from our
            // `sha2` and the field expects the `p256` tree's array type.
            let mut secret = [0u8; 32];
            secret.copy_from_slice(&digest);
            secret[0] = 0;
            Self {
                signing: SigningKey::from_bytes(&p256::FieldBytes::from(secret)).unwrap(),
            }
        }

        /// The `SubjectPublicKeyInfo` DER, the form a proof carries.
        pub(crate) fn spki(&self) -> Vec<u8> {
            let point = self.signing.verifying_key().to_encoded_point(false);
            let mut spki = Vec::with_capacity(91);
            spki.extend_from_slice(P256_SPKI_PREFIX);
            spki.extend_from_slice(point.as_bytes());
            spki
        }

        /// The extension id this key derives, the same way Chrome derives it.
        pub(crate) fn id(&self) -> String {
            super::id_from_public_key(&self.spki())
        }

        /// A DER signature over `payload` with this key.
        pub(crate) fn sign_for_test(&self, payload: &[u8]) -> Vec<u8> {
            let signature: Signature = self.signing.sign(payload);
            signature.to_der().as_bytes().to_vec()
        }
    }

    /// A CRX3 whose proofs are genuinely signed by `signers`, declaring `id`
    /// (raw id bytes) in its signed data. `None` declares the id of the last
    /// signer, which is the shape a store package has: the author's key is the
    /// one the id comes from.
    pub(crate) fn crx_signed_by(
        signers: &[&TestSigner],
        id: Option<&[u8]>,
        archive: &[u8],
    ) -> Vec<u8> {
        let author = signers.last().expect("a package has at least one signer");
        let author_id = Sha256::digest(author.spki());
        let declared = id.unwrap_or(&author_id[..16]);
        let signed = field(FIELD_CRX_ID, declared);
        let payload = signature_payload(&signed, archive);

        let mut header = Vec::new();
        for signer in signers {
            let mut proof = field(FIELD_PUBLIC_KEY, &signer.spki());
            proof.extend(field(FIELD_SIGNATURE, &signer.sign_for_test(&payload)));
            header.extend(field(FIELD_SHA256_WITH_ECDSA, &proof));
        }
        header.extend(field(FIELD_SIGNED_HEADER_DATA, &signed));

        let mut out = Vec::new();
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&3u32.to_le_bytes());
        out.extend_from_slice(&(header.len() as u32).to_le_bytes());
        out.extend_from_slice(&header);
        out.extend_from_slice(archive);
        out
    }

    /// Everything a signature must cover — public twin of what `parse`
    /// verifies, so tests cannot drift from the verifier by rebuilding the
    /// payload from a stale copy of its layout.
    pub(crate) fn signature_payload(signed_header_data: &[u8], archive: &[u8]) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(super::SIGNATURE_CONTEXT);
        payload.extend_from_slice(&(signed_header_data.len() as u32).to_le_bytes());
        payload.extend_from_slice(signed_header_data);
        payload.extend_from_slice(archive);
        payload
    }

    /// The raw id bytes a CRX built here will declare for `signer`.
    pub(crate) fn raw_id(signer: &TestSigner) -> Vec<u8> {
        Sha256::digest(signer.spki())[..16].to_vec()
    }

    pub(crate) fn field(number: u64, value: &[u8]) -> Vec<u8> {
        let mut out = varint_bytes((number << 3) | 2);
        out.extend(varint_bytes(value.len() as u64));
        out.extend_from_slice(value);
        out
    }

    fn varint_bytes(mut value: u64) -> Vec<u8> {
        let mut out = Vec::new();
        loop {
            let byte = (value & 0x7f) as u8;
            value >>= 7;
            if value == 0 {
                out.push(byte);
                return out;
            }
            out.push(byte | 0x80);
        }
    }

    /// Reads `testdata/` — a fixture kept in the repository.
    pub(crate) fn fixture(name: &str) -> Vec<u8> {
        let path = format!("{}/testdata/{}", env!("CARGO_MANIFEST_DIR"), name);
        std::fs::read(path).unwrap_or_else(|e| panic!("fixture {name}: {e}"))
    }

    /// The declared id of a parsed fixture header, for assertions.
    pub(crate) fn declared_id_of(bytes: &[u8]) -> String {
        let header_size = u32::from_le_bytes(bytes[8..12].try_into().unwrap()) as usize;
        let header = &bytes[12..12 + header_size];
        let signed = fields(header)
            .find(|(number, _)| *number == FIELD_SIGNED_HEADER_DATA)
            .map(|(_, value)| value)
            .unwrap();
        let raw = fields(signed)
            .find(|(number, _)| *number == FIELD_CRX_ID)
            .map(|(_, value)| value)
            .unwrap();
        encode_id(raw)
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::{TestSigner, crx_signed_by, fixture, raw_id};
    use super::*;

    fn signed_package(archive: &[u8]) -> Vec<u8> {
        crx_signed_by(&[&TestSigner::from_seed(b"a-public-key")], None, archive)
    }

    #[test]
    fn a_well_formed_package_parses() {
        let bytes = signed_package(b"PK\x03\x04zipdata");

        let parsed = parse(&bytes).unwrap();

        assert_eq!(parsed.archive, b"PK\x03\x04zipdata");
        assert_eq!(parsed.id.len(), 32);
        assert!(parsed.id.chars().all(|c| ('a'..='p').contains(&c)));
    }

    #[test]
    fn the_id_is_derived_the_way_chrome_derives_it() {
        // All-zero key: the digest's first nibbles map straight onto letters,
        // so this pins the encoding rather than just its shape.
        let key = b"";
        let digest = Sha256::digest(key);
        let expected: String = digest[..16]
            .iter()
            .flat_map(|b| [nibble(b >> 4), nibble(b & 0x0f)])
            .collect();

        assert_eq!(id_from_public_key(key), expected);
    }

    #[test]
    fn a_real_store_package_is_signed_by_more_than_one_key_and_still_installs() {
        // The shape of every extension the Chrome Web Store actually serves,
        // and the reason nothing could be installed before: Google's publisher
        // key is proof number one and the author's key — the one the id is
        // derived from — is proof number two. Reading only the first refuses
        // every genuine package in the store.
        let publisher = TestSigner::from_seed(b"googles-web-store-publisher-key");
        let author = TestSigner::from_seed(b"the-extensions-own-key");

        let bytes = crx_signed_by(&[&publisher, &author], None, b"PK\x03\x04zip");

        let parsed = parse(&bytes).unwrap();
        assert_eq!(parsed.id, author.id());
        assert_ne!(parsed.id, publisher.id());
    }

    #[test]
    fn a_package_none_of_whose_keys_derive_its_id_is_still_rejected() {
        // Widening "the first key" to "any key" must not widen it to "no key".
        let one = TestSigner::from_seed(b"one");
        let two = TestSigner::from_seed(b"two");
        let three = TestSigner::from_seed(b"three");

        let bytes = crx_signed_by(&[&one, &two, &three], Some(&[0x11; 16]), b"zip");
        assert!(matches!(parse(&bytes), Err(ExtError::IdMismatch { .. })));
    }

    #[test]
    fn a_package_claiming_someone_elses_id_is_rejected() {
        // The attack this stops: serving extension B under the id of A.
        let bytes = crx_signed_by(
            &[&TestSigner::from_seed(b"a-public-key")],
            Some(&[0x11; 16]),
            b"zip",
        );

        assert!(matches!(parse(&bytes), Err(ExtError::IdMismatch { .. })));
    }

    #[test]
    fn a_proof_without_a_signature_is_refused() {
        // Fail-closed: a header that carries keys but no signatures at all
        // used to install on the id check alone. Now the empty signature is
        // verified like any other, and empty never verifies.
        let signer = TestSigner::from_seed(b"a-public-key");
        let signed = test_support::field(FIELD_CRX_ID, &raw_id(&signer));
        let proof = test_support::field(FIELD_PUBLIC_KEY, &signer.spki());

        let mut header = test_support::field(FIELD_SHA256_WITH_ECDSA, &proof);
        header.extend(test_support::field(FIELD_SIGNED_HEADER_DATA, &signed));

        let mut bytes = Vec::new();
        bytes.extend_from_slice(MAGIC);
        bytes.extend_from_slice(&3u32.to_le_bytes());
        bytes.extend_from_slice(&(header.len() as u32).to_le_bytes());
        bytes.extend_from_slice(&header);
        bytes.extend_from_slice(b"zip");

        assert!(matches!(parse(&bytes), Err(ExtError::CrxSignatureInvalid)));
    }

    #[test]
    fn a_broken_extra_proof_refuses_an_otherwise_valid_package() {
        // Chrome refuses a package if any proof fails, not just the one the id
        // came from. This pins that strictness: the author's proof is genuine,
        // the publisher-shaped one beside it is garbage, and the answer is no.
        let author = TestSigner::from_seed(b"the-extensions-own-key");
        let signed = test_support::field(FIELD_CRX_ID, &raw_id(&author));
        let payload = test_support::signature_payload(&signed, b"zip");

        let mut good = test_support::field(FIELD_PUBLIC_KEY, &author.spki());
        good.extend(test_support::field(
            FIELD_SIGNATURE,
            &author.sign_for_test(&payload),
        ));

        let broken_key = TestSigner::from_seed(b"broken");
        let mut broken = test_support::field(FIELD_PUBLIC_KEY, &broken_key.spki());
        let mut broken_sig = broken_key.sign_for_test(&payload);
        broken_sig[0] ^= 0xff;
        broken.extend(test_support::field(FIELD_SIGNATURE, &broken_sig));

        let mut header = test_support::field(FIELD_SHA256_WITH_ECDSA, &good);
        header.extend(test_support::field(FIELD_SHA256_WITH_ECDSA, &broken));
        header.extend(test_support::field(FIELD_SIGNED_HEADER_DATA, &signed));

        let mut bytes = Vec::new();
        bytes.extend_from_slice(MAGIC);
        bytes.extend_from_slice(&3u32.to_le_bytes());
        bytes.extend_from_slice(&(header.len() as u32).to_le_bytes());
        bytes.extend_from_slice(&header);
        bytes.extend_from_slice(b"zip");

        assert!(matches!(parse(&bytes), Err(ExtError::CrxSignatureInvalid)));
    }

    #[test]
    fn a_real_store_package_verifies_violentmonkey() {
        let bytes = fixture("violentmonkey.crx");

        let parsed = parse(&bytes).unwrap();

        // The id the download URL asked for, derived from the signing key of
        // the package that arrived.
        assert_eq!(parsed.id, "jinjaccalgkegednnccohejagnlnfdag");
    }

    #[test]
    fn a_real_store_package_verifies_dark_reader() {
        let bytes = fixture("darkreader.crx");

        let parsed = parse(&bytes).unwrap();

        assert_eq!(parsed.id, "eimadpbcbfnmbkopoojfekhnkhdbieeh");
    }

    #[test]
    fn a_real_signature_with_a_flipped_byte_refuses_the_package() {
        // Break-on-purpose for the whole verification: this is the test that
        // goes green if you delete the verify call, and red because one byte
        // of one signature changed.
        let mut bytes = fixture("violentmonkey.crx");

        let signature = author_signature(&bytes).expect("the author proof carries a signature");
        let at = bytes
            .windows(signature.len())
            .position(|w| w == signature)
            .expect("the signature bytes are in the file");
        bytes[at] ^= 0xff;

        assert!(matches!(parse(&bytes), Err(ExtError::CrxSignatureInvalid)));
    }

    #[test]
    fn a_real_header_laid_over_someone_elses_archive_is_refused() {
        // The attack the id check alone could not stop: take a genuine,
        // correctly signed header and put any other ZIP behind it. The
        // signature covers the archive, so the transplant fails.
        let bytes = fixture("violentmonkey.crx");
        let header_size = u32::from_le_bytes(bytes[8..12].try_into().unwrap()) as usize;

        let mut swapped = bytes[..12 + header_size].to_vec();
        swapped.extend_from_slice(b"PK\x03\x04 definitely not what was signed");

        assert!(matches!(
            parse(&swapped),
            Err(ExtError::CrxSignatureInvalid)
        ));
    }

    #[test]
    fn a_real_package_cut_short_fails_its_signature_rather_than_passing() {
        // 1Password as served is 17.8 MB; the fixture keeps the header and
        // the start of the ZIP. Regenerate in full with the download URL in
        // `ext::download_url`, id `aeblfdkhhhdcdjpifhhbdiojplfjncoa`.
        //
        // A truncated package cannot verify — the signature covers bytes that
        // are not there — and the id check passing first changes nothing
        // about the answer.
        let bytes = fixture("1password-head-only.crx");

        assert!(matches!(parse(&bytes), Err(ExtError::CrxSignatureInvalid)));
        // The refusal is the signature's, not a structural accident.
        assert_eq!(
            test_support::declared_id_of(&bytes),
            "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
        );
    }

    #[test]
    fn a_file_that_is_not_a_crx_is_rejected() {
        assert!(matches!(parse(b"not a crx at all"), Err(ExtError::NotACrx)));
        assert!(matches!(parse(b""), Err(ExtError::NotACrx)));
    }

    #[test]
    fn crx2_is_refused_rather_than_misread() {
        let mut bytes = signed_package(b"zip");
        bytes[4..8].copy_from_slice(&2u32.to_le_bytes());

        assert!(matches!(
            parse(&bytes),
            Err(ExtError::UnsupportedCrxVersion { version: 2 })
        ));
    }

    #[test]
    fn a_header_longer_than_the_file_does_not_panic() {
        let mut bytes = signed_package(b"zip");
        bytes[8..12].copy_from_slice(&u32::MAX.to_le_bytes());

        assert!(matches!(parse(&bytes), Err(ExtError::Truncated)));
    }

    #[test]
    fn a_package_with_no_archive_is_rejected() {
        let bytes = signed_package(b"");

        assert!(matches!(parse(&bytes), Err(ExtError::Truncated)));
    }

    #[test]
    fn a_header_without_a_key_is_rejected() {
        let signed = test_support::field(FIELD_CRX_ID, &[0u8; 16]);
        let header = test_support::field(FIELD_SIGNED_HEADER_DATA, &signed);

        let mut bytes = Vec::new();
        bytes.extend_from_slice(MAGIC);
        bytes.extend_from_slice(&3u32.to_le_bytes());
        bytes.extend_from_slice(&(header.len() as u32).to_le_bytes());
        bytes.extend_from_slice(&header);
        bytes.extend_from_slice(b"zip");

        assert!(matches!(parse(&bytes), Err(ExtError::MalformedHeader)));
    }

    #[test]
    fn an_ecdsa_only_package_still_parses() {
        // Synthetic packages here are ECDSA-only; this names that fact so the
        // RSA side is understood to be carried by the store fixtures, which
        // carry both proof kinds.
        let bytes = signed_package(b"zip");

        assert!(parse(&bytes).is_ok());
    }

    #[test]
    fn garbage_in_the_header_does_not_panic() {
        for tail in [vec![0xff; 32], vec![0x08; 16], vec![0x0a, 0xff, 0xff]] {
            let mut bytes = Vec::new();
            bytes.extend_from_slice(MAGIC);
            bytes.extend_from_slice(&3u32.to_le_bytes());
            bytes.extend_from_slice(&(tail.len() as u32).to_le_bytes());
            bytes.extend_from_slice(&tail);
            bytes.extend_from_slice(b"zip");

            // Any error is fine. A panic is not.
            let _ = parse(&bytes);
        }
    }

    /// The signature bytes of the proof whose key derives the declared id —
    /// in a store package, the author's.
    fn author_signature(bytes: &[u8]) -> Option<&[u8]> {
        let header_size = u32::from_le_bytes(bytes[8..12].try_into().unwrap()) as usize;
        let header = &bytes[12..12 + header_size];
        let signed = fields(header)
            .find(|(number, _)| *number == FIELD_SIGNED_HEADER_DATA)
            .map(|(_, value)| value)?;

        for (_, proof) in fields(header).filter(|(number, _)| {
            *number == FIELD_SHA256_WITH_RSA || *number == FIELD_SHA256_WITH_ECDSA
        }) {
            let key = fields(proof)
                .find(|(number, _)| *number == FIELD_PUBLIC_KEY)
                .map(|(_, value)| value)?;
            let signature = fields(proof)
                .find(|(number, _)| *number == FIELD_SIGNATURE)
                .map(|(_, value)| value)?;
            let digest = Sha256::digest(key);
            if encode_id(&digest[..16]) == encode_id(&signed[2..18]) {
                return Some(signature);
            }
        }
        None
    }
}
