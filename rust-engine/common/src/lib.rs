pub mod v1 {
    pub mod common {
        tonic::include_proto!("ussd.v1.common");
    }
    pub mod orchestrator {
        tonic::include_proto!("ussd.v1.orchestrator");
    }
    pub mod payment {
        tonic::include_proto!("ussd.v1.payment");
    }
    pub mod session {
        tonic::include_proto!("ussd.v1.session");
    }
    pub mod tenant {
        tonic::include_proto!("ussd.v1.tenant");
    }
    pub mod audit {
        tonic::include_proto!("ussd.v1.audit");
    }
    pub mod admin {
        tonic::include_proto!("ussd.v1.admin");
    }
    pub mod ledger {
        tonic::include_proto!("ussd.v1.ledger");
    }
    pub mod messaging {
        tonic::include_proto!("ussd.v1.messaging");
    }
    pub mod reconciliation {
        tonic::include_proto!("ussd.v1.reconciliation");
    }
    pub mod webhook {
        tonic::include_proto!("ussd.v1.webhook");
    }
    pub mod gateway {
        tonic::include_proto!("ussd.v1.gateway");
    }
    pub mod ai {
        tonic::include_proto!("ussd.v1.ai");
    }
    pub mod tenant_application {
        tonic::include_proto!("ussd.v1.tenant_application");
    }
}

pub mod interceptors;
pub mod metrics;
pub mod telemetry;
pub mod tls;
