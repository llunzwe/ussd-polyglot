use chrono::{DateTime, Utc};
use tracing::{info, instrument};
use uuid::Uuid;

use crate::domain::error::AuditError;
use crate::domain::merkle::{build_merkle_tree, merkle_proof, sha256, verify_merkle_proof};
use crate::infrastructure::postgres::{AuditRepository, BatchHashRecord, EventRecord};
use crate::infrastructure::signing::SigningService;

#[derive(Clone)]
pub struct AuditHandler {
    repo: AuditRepository,
    signer: SigningService,
}

impl AuditHandler {
    pub fn new(repo: AuditRepository, signer: SigningService) -> Self {
        Self { repo, signer }
    }

    /// Compute and sign the daily batch hash for the given date.
    /// This is the core M1 regulatory job: daily Merkle root -> integrity.batch_hashes.
    #[instrument(skip(self))]
    pub async fn compute_daily_batch(&self, date: chrono::NaiveDate) -> Result<BatchHashRecord, AuditError> {
        let record = self.repo.get_or_compute_batch_hash(date).await?;
        
        // Sign the batch hash
        let (signature, key_id) = self.signer.sign_batch_hash(&record.batch_hash)?;
        
        // Update the record with signature
        self.repo.update_batch_signature(record.batch_id, &signature, &key_id).await?;
        
        info!(
            batch_date = %date,
            batch_hash = %record.batch_hash,
            record_count = record.record_count,
            key_id = %key_id,
            "Daily batch hash computed and signed"
        );
        
        Ok(BatchHashRecord {
            batch_id: record.batch_id,
            batch_date: record.batch_date,
            batch_hash: record.batch_hash,
            record_count: record.record_count,
            source_data_hash: record.source_data_hash,
            computed_at: record.computed_at,
            previous_batch_hash: record.previous_batch_hash,
        })
    }

    #[instrument(skip(self))]
    pub async fn get_merkle_proof(
        &self,
        transaction_id: Option<String>,
        event_id: Option<String>,
        sequence_number: Option<i64>,
    ) -> Result<MerkleProofResult, AuditError> {
        let target_event_id = event_id.as_ref().map(|id| {
            Uuid::parse_str(id).map_err(|e| AuditError::Internal(e.to_string()))
        }).transpose()?;

        let lookup_key = event_id.clone()
            .or_else(|| sequence_number.map(|s| s.to_string()))
            .unwrap_or_default();

        let event = self
            .repo
            .fetch_event(target_event_id, sequence_number)
            .await?
            .ok_or_else(|| AuditError::EventNotFound(lookup_key))?;

        // Fetch all events for the day to build the Merkle tree
        let date = event.occurred_at.date_naive();
        let from = date.and_hms_opt(0, 0, 0).unwrap().and_utc();
        let to = from + chrono::Duration::days(1);
        let day_events = self.repo.fetch_events_for_range(from, to).await?;

        if day_events.is_empty() {
            return Err(AuditError::EventNotFound(event.event_id.to_string()));
        }

        let leaves: Vec<Vec<u8>> = day_events
            .iter()
            .map(|e| sha256(e.record_hash.as_bytes()))
            .collect();
        let (root, tree) = build_merkle_tree(&leaves);

        let leaf_index = day_events
            .iter()
            .position(|e| e.event_id == event.event_id)
            .ok_or_else(|| AuditError::EventNotFound(event.event_id.to_string()))?;

        let proof_hashes = merkle_proof(&tree, leaves.len(), leaf_index);
        let valid = verify_merkle_proof(
            &sha256(event.record_hash.as_bytes()),
            leaf_index,
            &proof_hashes,
            &root,
        );

        Ok(MerkleProofResult {
            event_id: event.event_id.to_string(),
            target_id: transaction_id.unwrap_or_else(|| event.event_id.to_string()),
            sequence_number: event.sequence_number,
            merkle_root: root,
            proof_hashes,
            valid,
            computed_at: Utc::now(),
            signature: String::new(),
            signer_key_id: String::new(),
        })
    }

    #[instrument(skip(self))]
    pub async fn get_ledger_checksum(
        &self,
        from_date: DateTime<Utc>,
        to_date: DateTime<Utc>,
    ) -> Result<LedgerChecksumResult, AuditError> {
        if from_date > to_date {
            return Err(AuditError::InvalidDateRange(
                "from_date must be before to_date".into(),
            ));
        }

        let events = self.repo.fetch_events_for_range(from_date, to_date).await?;
        let leaves: Vec<Vec<u8>> = events
            .iter()
            .map(|e| sha256(e.record_hash.as_bytes()))
            .collect();
        let (root, _) = build_merkle_tree(&leaves);

        let max_seq = events.iter().map(|e| e.sequence_number).max().unwrap_or(0);

        Ok(LedgerChecksumResult {
            merkle_root: root,
            event_count: events.len() as i64,
            computed_at: Utc::now(),
            checksum_id: format!("CHK-{}", hex::encode(uuid::Uuid::new_v4().as_bytes())[..16].to_string()),
            latest_sequence_number: max_seq,
            total_events: events.len() as i64,
            signature: String::new(),
            signer_key_id: String::new(),
        })
    }

    #[instrument(skip(self))]
    pub async fn verify_batch_integrity(
        &self,
        start_event_id: i64,
        end_event_id: i64,
        expected_root_hex: Option<String>,
    ) -> Result<BatchIntegrityResult, AuditError> {
        if start_event_id > end_event_id {
            return Err(AuditError::InvalidDateRange(
                "start_event_id must be <= end_event_id".into(),
            ));
        }

        // Fetch events in the range
        let from = DateTime::UNIX_EPOCH; // Use a wide range and filter by sequence
        let to = Utc::now() + chrono::Duration::days(365 * 10);
        let all_events = self.repo.fetch_events_for_range(from, to).await?;
        let events: Vec<&EventRecord> = all_events
            .iter()
            .filter(|e| e.sequence_number >= start_event_id && e.sequence_number <= end_event_id)
            .collect();

        let leaves: Vec<Vec<u8>> = events.iter().map(|e| sha256(e.record_hash.as_bytes())).collect();
        let (computed_root, _) = build_merkle_tree(&leaves);
        let computed_root_hex = hex::encode(&computed_root);

        let valid = expected_root_hex
            .as_ref()
            .map(|exp| exp.to_lowercase() == computed_root_hex.to_lowercase())
            .unwrap_or(true);

        let violations = if !valid {
            vec![IntegrityViolation {
                transaction_id: events.first().map(|e| e.event_id.to_string()).unwrap_or_default(),
                expected_hash: expected_root_hex.unwrap_or_default(),
                actual_hash: computed_root_hex.clone(),
                violation_type: "ROOT_MISMATCH".into(),
            }]
        } else {
            vec![]
        };

        Ok(BatchIntegrityResult {
            valid,
            computed_root: computed_root_hex,
            period_start: events.first().map(|e| e.occurred_at),
            period_end: events.last().map(|e| e.occurred_at),
            total_transactions: events.len() as i64,
            verified_transactions: if valid { events.len() as i64 } else { 0 },
            failed_transactions: if valid { 0 } else { events.len() as i64 },
            is_fully_valid: valid,
            previous_batch_hash: None,
            violations,
        })
    }

    #[instrument(skip(self))]
    pub async fn verify_transaction_chain(
        &self,
        transaction_id: String,
        max_depth: i32,
    ) -> Result<ChainReportResult, AuditError> {
        let tx_uuid = Uuid::parse_str(&transaction_id)
            .map_err(|e| AuditError::Internal(e.to_string()))?;
        let records = self
            .repo
            .fetch_transactions_for_chain(tx_uuid, max_depth)
            .await?;

        if records.is_empty() {
            return Err(AuditError::EventNotFound(transaction_id));
        }

        let mut is_valid = true;
        let mut broken_at = None;
        let mut expected_hash = None;
        let mut actual_hash = None;

        for (i, record) in records.iter().enumerate() {
            if i > 0 {
                let prev = &records[i - 1];
                if record.previous_hash.as_ref() != Some(&prev.record_hash) {
                    is_valid = false;
                    broken_at = Some(record.transaction_uuid.to_string());
                    expected_hash = Some(prev.record_hash.clone());
                    actual_hash = record.previous_hash.clone();
                    break;
                }
            }
        }

        Ok(ChainReportResult {
            start_transaction_id: transaction_id,
            is_valid,
            chain_length: records.len() as i32,
            broken_at_transaction_id: broken_at,
            expected_hash,
            actual_hash,
        })
    }

    #[instrument(skip(self))]
    pub async fn get_audit_trail(
        &self,
        record_id: String,
        table_name: String,
        page_size: i32,
        page_token: String,
    ) -> Result<Vec<AuditTrailResult>, AuditError> {
        let record_uuid = Uuid::parse_str(&record_id)
            .map_err(|e| AuditError::Internal(e.to_string()))?;
        let offset: i32 = page_token.parse().unwrap_or(0);
        let limit = if page_size > 0 { page_size } else { 50 };

        let records = self
            .repo
            .fetch_audit_trail(record_uuid, &table_name, limit, offset)
            .await?;

        Ok(records
            .into_iter()
            .map(|r| AuditTrailResult {
                audit_id: r.audit_id.to_string(),
                event_type: r.event_type,
                action: r.action,
                old_data: r.old_data,
                new_data: r.new_data,
                timestamp: r.timestamp,
                record_hash: r.record_hash,
                previous_hash: r.previous_hash,
            })
            .collect())
    }

    #[instrument(skip(self))]
    pub async fn get_audit_report(
        &self,
        tenant_id: String,
        from_date: DateTime<Utc>,
        to_date: DateTime<Utc>,
        event_types: Vec<String>,
    ) -> Result<AuditReportResult, AuditError> {
        let events = self.repo.fetch_events_for_range(from_date, to_date).await?;
        let filtered: Vec<_> = if event_types.is_empty() {
            events
        } else {
            events
                .into_iter()
                .filter(|e| event_types.contains(&e.event_type))
                .collect()
        };

        let included_types: Vec<_> = filtered
            .iter()
            .map(|e| e.event_type.clone())
            .collect::<std::collections::HashSet<_>>()
            .into_iter()
            .collect();

        let checksum = hex::encode(sha256(
            &filtered
                .iter()
                .flat_map(|e| e.record_hash.as_bytes().to_vec())
                .collect::<Vec<u8>>(),
        ));

        Ok(AuditReportResult {
            report_id: format!("RPT-{}", hex::encode(uuid::Uuid::new_v4().as_bytes())[..16].to_string()),
            total_events: filtered.len() as i64,
            included_event_types: included_types,
            generated_at: Utc::now(),
            checksum,
        })
    }

    #[instrument(skip(self))]
    pub async fn export_audit_report(
        &self,
        report_id: String,
        tenant_id: String,
    ) -> Result<AuditExportResult, AuditError> {
        // Generate a deterministic checksum based on report_id
        let checksum = hex::encode(sha256(report_id.as_bytes()));
        let download_url = format!("https://api.ussd-kernel.org/exports/{}.json", report_id);
        let signature = sha256(checksum.as_bytes());

        Ok(AuditExportResult {
            report_id,
            download_url,
            checksum,
            signature,
            expires_at: Utc::now() + chrono::Duration::days(7),
        })
    }

    #[instrument(skip(self))]
    pub async fn stream_audit_events(
        &self,
        from: DateTime<Utc>,
        event_types: Vec<String>,
    ) -> Result<Vec<EventRecord>, AuditError> {
        let types: Vec<String> = if event_types.is_empty() {
            vec![]
        } else {
            event_types
        };
        self.repo.stream_audit_events(from, &types).await
    }
}

pub struct MerkleProofResult {
    pub event_id: String,
    pub target_id: String,
    pub sequence_number: i64,
    pub merkle_root: Vec<u8>,
    pub proof_hashes: Vec<Vec<u8>>,
    pub valid: bool,
    pub computed_at: DateTime<Utc>,
    pub signature: String,
    pub signer_key_id: String,
}

pub struct LedgerChecksumResult {
    pub merkle_root: Vec<u8>,
    pub event_count: i64,
    pub computed_at: DateTime<Utc>,
    pub checksum_id: String,
    pub latest_sequence_number: i64,
    pub total_events: i64,
    pub signature: String,
    pub signer_key_id: String,
}

pub struct BatchIntegrityResult {
    pub valid: bool,
    pub computed_root: String,
    pub period_start: Option<DateTime<Utc>>,
    pub period_end: Option<DateTime<Utc>>,
    pub total_transactions: i64,
    pub verified_transactions: i64,
    pub failed_transactions: i64,
    pub is_fully_valid: bool,
    pub previous_batch_hash: Option<String>,
    pub violations: Vec<IntegrityViolation>,
}

pub struct IntegrityViolation {
    pub transaction_id: String,
    pub expected_hash: String,
    pub actual_hash: String,
    pub violation_type: String,
}

pub struct ChainReportResult {
    pub start_transaction_id: String,
    pub is_valid: bool,
    pub chain_length: i32,
    pub broken_at_transaction_id: Option<String>,
    pub expected_hash: Option<String>,
    pub actual_hash: Option<String>,
}

pub struct AuditTrailResult {
    pub audit_id: String,
    pub event_type: String,
    pub action: String,
    pub old_data: Option<serde_json::Value>,
    pub new_data: Option<serde_json::Value>,
    pub timestamp: DateTime<Utc>,
    pub record_hash: String,
    pub previous_hash: Option<String>,
}

pub struct AuditReportResult {
    pub report_id: String,
    pub total_events: i64,
    pub included_event_types: Vec<String>,
    pub generated_at: DateTime<Utc>,
    pub checksum: String,
}

pub struct AuditExportResult {
    pub report_id: String,
    pub download_url: String,
    pub checksum: String,
    pub signature: Vec<u8>,
    pub expires_at: DateTime<Utc>,
}
