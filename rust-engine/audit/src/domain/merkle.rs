use sha2::{Digest, Sha256};

/// Compute SHA-256 hash of input bytes.
pub fn sha256(data: &[u8]) -> Vec<u8> {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hasher.finalize().to_vec()
}

/// Build a Merkle tree from leaf hashes and return (root, tree).
/// Tree is stored level-order: leaves first, then internal nodes up to root.
pub fn build_merkle_tree(leaves: &[Vec<u8>]) -> (Vec<u8>, Vec<Vec<u8>>) {
    if leaves.is_empty() {
        let root = sha256(b"");
        return (root.clone(), vec![root]);
    }

    let mut tree: Vec<Vec<u8>> = leaves.to_vec();
    let mut level_start = 0usize;
    let mut level_len = leaves.len();

    while level_len > 1 {
        let mut next_level = Vec::new();
        for i in (0..level_len).step_by(2) {
            let left = tree[level_start + i].clone();
            let right = if i + 1 < level_len {
                tree[level_start + i + 1].clone()
            } else {
                left.clone()
            };
            let mut combined = left;
            combined.extend_from_slice(&right);
            next_level.push(sha256(&combined));
        }
        level_start += level_len;
        level_len = next_level.len();
        tree.extend(next_level);
    }

    let root = tree.last().cloned().unwrap_or_else(|| sha256(b""));
    (root, tree)
}

/// Generate a Merkle proof for the leaf at `leaf_index`.
/// Returns a list of sibling hashes from bottom to top.
pub fn merkle_proof(tree: &[Vec<u8>], leaf_count: usize, leaf_index: usize) -> Vec<Vec<u8>> {
    if leaf_count == 0 || tree.is_empty() {
        return vec![];
    }

    let mut proof = Vec::new();
    let mut idx = leaf_index;
    let mut level_start = 0usize;
    let mut level_len = leaf_count;

    while level_len > 1 {
        let sibling_idx = if idx % 2 == 0 {
            if idx + 1 < level_len {
                idx + 1
            } else {
                idx // duplicate last node
            }
        } else {
            idx - 1
        };

        proof.push(tree[level_start + sibling_idx].clone());
        idx /= 2;
        level_start += level_len;
        level_len = (level_len + 1) / 2;
    }

    proof
}

/// Verify a Merkle proof.
pub fn verify_merkle_proof(
    leaf_hash: &[u8],
    leaf_index: usize,
    proof_hashes: &[Vec<u8>],
    expected_root: &[u8],
) -> bool {
    let mut current = leaf_hash.to_vec();
    let mut idx = leaf_index;

    for sibling in proof_hashes {
        let combined = if idx % 2 == 0 {
            let mut c = current.clone();
            c.extend_from_slice(sibling);
            c
        } else {
            let mut c = sibling.clone();
            c.extend_from_slice(&current);
            c
        };
        current = sha256(&combined);
        idx /= 2;
    }

    current == expected_root
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_merkle_tree_basic() {
        let leaves: Vec<Vec<u8>> =
            vec![b"a", b"b", b"c", b"d"].into_iter().map(|s| sha256(s)).collect();
        let (root, tree) = build_merkle_tree(&leaves);
        assert!(!root.is_empty());
        assert_eq!(tree.len(), 7); // 4 leaves + 2 internal + 1 root
    }

    #[test]
    fn test_merkle_proof_verification() {
        let leaves: Vec<Vec<u8>> =
            vec![b"a", b"b", b"c", b"d"].into_iter().map(|s| sha256(s)).collect();
        let (root, tree) = build_merkle_tree(&leaves);
        let proof = merkle_proof(&tree, leaves.len(), 2);
        assert!(verify_merkle_proof(&leaves[2], 2, &proof, &root));
        assert!(!verify_merkle_proof(&leaves[0], 2, &proof, &root));
    }

    #[test]
    fn test_merkle_tree_odd_leaves() {
        let leaves: Vec<Vec<u8>> =
            vec![b"a", b"b", b"c"].into_iter().map(|s| sha256(s)).collect();
        let (root, tree) = build_merkle_tree(&leaves);
        let proof = merkle_proof(&tree, leaves.len(), 2);
        assert!(verify_merkle_proof(&leaves[2], 2, &proof, &root));
    }
}
