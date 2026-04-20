#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Provider {
    EcoCash,
    OneMoney,
    TeleCash,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GatewayStrategy {
    Primary,
    Fallback,
    RoundRobin,
}

#[derive(Debug, Clone)]
pub struct ProviderReceipt {
    pub provider_ref: String,
    pub raw_response: String,
}
