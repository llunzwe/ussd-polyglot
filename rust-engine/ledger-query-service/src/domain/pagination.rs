#[derive(Debug, Clone)]
pub struct Pagination {
    pub page_size: i32,
    pub page_token: String,
}

#[derive(Debug, Clone)]
pub struct PaginationMetadata {
    pub total_count: i32,
    pub next_page_token: String,
    pub previous_page_token: String,
    pub has_more: bool,
}
