use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct GenerateReportCommand {
    pub run_id: Uuid,
    pub tenant_id: Uuid,
    pub format: String,
}

#[derive(Debug, Clone)]
pub struct GenerateReportResult {
    pub report_id: Uuid,
    pub download_url: String,
}
