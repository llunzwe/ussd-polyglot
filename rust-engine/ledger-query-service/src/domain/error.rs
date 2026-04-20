use thiserror::Error;

#[derive(Error, Debug, Clone, PartialEq)]
pub enum LedgerQueryError {
    #[error("Account not found: {0}")]
    AccountNotFound(String),

    #[error("Transaction not found: {0}")]
    TransactionNotFound(String),

    #[error("Virtual account not found: {0}")]
    VirtualAccountNotFound(String),

    #[error("Liquidity position not found: {0}")]
    LiquidityPositionNotFound(String),

    #[error("Settlement instruction not found: {0}")]
    SettlementNotFound(String),

    #[error("Suspense item not found: {0}")]
    SuspenseItemNotFound(String),

    #[error("COA entry not found: {0}")]
    CoaEntryNotFound(String),

    #[error("Period end balance not found: {0}")]
    PeriodEndBalanceNotFound(String),

    #[error("Invalid date range: {0}")]
    InvalidDateRange(String),

    #[error("Invalid argument: {0}")]
    InvalidArgument(String),

    #[error("Database error: {0}")]
    DatabaseError(String),

    #[error("Internal error: {0}")]
    Internal(String),
}
