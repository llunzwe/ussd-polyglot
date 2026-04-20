use std::path::PathBuf;

fn main() {
    let proto_dir = PathBuf::from("../../protos");

    let proto_files = walkdir::WalkDir::new(&proto_dir)
        .into_iter()
        .filter_map(|entry| entry.ok())
        .filter(|entry| {
            let path = entry.path();
            path.extension().map_or(false, |ext| ext == "proto")
        })
        .map(|entry| entry.path().to_string_lossy().into_owned())
        .collect::<Vec<_>>();

    tonic_build::configure()
        .build_server(true)
        .build_client(true)
        .bytes([
            ".ussd.v1.audit.GetMerkleProofResponse.merkle_root",
            ".ussd.v1.audit.GetLedgerChecksumResponse.merkle_root",
            ".ussd.v1.audit.VerifyBatchIntegrityRequest.expected_root",
        ])
        .compile(&proto_files, &[proto_dir])
        .expect("failed to compile protobufs");

    // Re-run if protos change
    println!("cargo:rerun-if-changed=../../protos");
}
