use uuid::Uuid;

use crate::domain::discrepancy::ResolutionAction;

#[derive(Debug, Clone)]
pub struct ResolveDiscrepancyCommand {
    pub item_id: Uuid,
    pub run_id: Uuid,
    pub tenant_id: Uuid,
    pub action: ResolutionAction,
    pub notes: String,
    pub resolved_by: String,
}
