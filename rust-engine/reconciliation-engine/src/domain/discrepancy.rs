#[derive(Debug, Clone, PartialEq)]
pub enum DiscrepancyType {
    MissingInternal,
    MissingExternal,
    AmountMismatch,
    StatusMismatch,
    DuplicateInternal,
    DuplicateExternal,
    FeeMismatch,
    TimestampMismatch,
    CurrencyMismatch,
}

impl DiscrepancyType {
    pub fn as_str(&self) -> &'static str {
        match self {
            DiscrepancyType::MissingInternal => "missing_internal",
            DiscrepancyType::MissingExternal => "missing_external",
            DiscrepancyType::AmountMismatch => "amount_mismatch",
            DiscrepancyType::StatusMismatch => "status_mismatch",
            DiscrepancyType::DuplicateInternal => "duplicate_internal",
            DiscrepancyType::DuplicateExternal => "duplicate_external",
            DiscrepancyType::FeeMismatch => "fee_mismatch",
            DiscrepancyType::TimestampMismatch => "timestamp_mismatch",
            DiscrepancyType::CurrencyMismatch => "currency_mismatch",
        }
    }
}

impl std::fmt::Display for DiscrepancyType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum ResolutionAction {
    CorrectInternal,
    CorrectExternal,
    CreateAdjustment,
    Ignore,
    Escalate,
    Approve,
}

impl ResolutionAction {
    pub fn as_str(&self) -> &'static str {
        match self {
            ResolutionAction::CorrectInternal => "correct_internal",
            ResolutionAction::CorrectExternal => "correct_external",
            ResolutionAction::CreateAdjustment => "create_adjustment",
            ResolutionAction::Ignore => "ignore",
            ResolutionAction::Escalate => "escalate",
            ResolutionAction::Approve => "approve",
        }
    }
}

impl std::fmt::Display for ResolutionAction {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum ReconciliationStatus {
    Pending,
    Running,
    Completed,
    Failed,
    PartiallyResolved,
    Approved,
}

impl ReconciliationStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            ReconciliationStatus::Pending => "pending",
            ReconciliationStatus::Running => "running",
            ReconciliationStatus::Completed => "completed",
            ReconciliationStatus::Failed => "failed",
            ReconciliationStatus::PartiallyResolved => "partially_resolved",
            ReconciliationStatus::Approved => "approved",
        }
    }
}

impl std::fmt::Display for ReconciliationStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}
