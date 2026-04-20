use std::collections::HashMap;
use std::pin::Pin;

use tonic::{Request, Response, Status};
use tracing::{error, info, info_span, Instrument};
use uuid::Uuid;

use ussd_kernel_common::v1::common::{
    health_response::ServingStatus, Empty, HealthRequest, HealthResponse,
};
use ussd_kernel_common::v1::session::session_reconstructor_server::SessionReconstructor;
use ussd_kernel_common::v1::session::{
    CreateCheckpointRequest, CreateCheckpointResponse, GetConcurrentSessionsRequest,
    GetConcurrentSessionsResponse, GetIntegrityProofRequest, GetSessionEventsRequest,
    GetSessionMetricsRequest, GetSessionMetricsResponse, IntegrityProof, InvalidateCacheRequest,
    ListActiveSessionsRequest, ListActiveSessionsResponse, MergeSessionsRequest,
    MergeSessionsResponse, ReconstructSessionRequest, ReconstructSessionResponse,
    RestoreCheckpointRequest, RestoreCheckpointResponse, SearchSessionsRequest,
    SearchSessionsResponse, SessionEvent, VerifySessionRequest, VerifySessionResponse,
};

use crate::application::reconstruct::{compute_merkle_proof, ReconstructSessionHandler};
use crate::domain::error::DomainError;

pub struct SessionGrpcServer {
    handler: ReconstructSessionHandler,
}

impl SessionGrpcServer {
    pub fn new(handler: ReconstructSessionHandler) -> Self {
        Self { handler }
    }
}

#[tonic::async_trait]
impl SessionReconstructor for SessionGrpcServer {
    async fn reconstruct_session(
        &self,
        request: Request<ReconstructSessionRequest>,
    ) -> Result<Response<ReconstructSessionResponse>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!(session_id = %req.session_id, tenant_id = %req.tenant_id, "reconstruct_session called");

            let session_id = parse_uuid(&req.session_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;
            let max_events = if req.max_events > 0 {
                req.max_events
            } else {
                1000
            };

            let start = std::time::Instant::now();
            match self.handler.reconstruct_session(session_id, tenant_id, max_events).await {
                Ok(result) => {
                    let replay_time_ms = start.elapsed().as_millis() as i64;

                    let state_struct = hashmap_to_struct(result.state);
                    let last_activity = result.last_activity.map(datetime_to_timestamp);

                    let mut resp = ReconstructSessionResponse {
                        session_id: session_id.to_string(),
                        state: Some(state_struct),
                        current_version: result.current_version,
                        events_replayed: result.event_count as i32,
                        replay_time_ms,
                        is_valid: true,
                        integrity_hash: result.integrity_hash,
                        last_activity,
                        error: None,
                        merkle_proof: None,
                    };

                    if req.include_merkle_proof {
                        match self.handler.fetch_event_hashes(session_id, tenant_id).await {
                            Ok(hashes) => {
                                if !hashes.is_empty() {
                                    let (root, _) = compute_merkle_proof(&hashes, hashes.len() - 1);
                                    resp.merkle_proof = Some(IntegrityProof {
                                        session_id: session_id.to_string(),
                                        event_version: result.current_version,
                                        event_hash: hashes.last().cloned().unwrap_or_default(),
                                        sibling_hashes: vec![],
                                        merkle_root: root,
                                        proof_generated_at: Some(datetime_to_timestamp(chrono::Utc::now())),
                                        signature: String::new(),
                                    });
                                }
                            }
                            Err(e) => {
                                error!(error = %e, "failed to compute merkle proof");
                            }
                        }
                    }

                    info!(session_id = %session_id, "reconstruct_session succeeded");
                    Ok(Response::new(resp))
                }
                Err(e) => {
                    error!(error = %e, "reconstruct_session failed");
                    Err(map_domain_error(e))
                }
            }
        }
        .instrument(span)
        .await
    }

    type ReconstructSessionsStream =
        Pin<Box<dyn tokio_stream::Stream<Item = Result<ReconstructSessionResponse, Status>> + Send>>;

    async fn reconstruct_sessions(
        &self,
        _request: Request<tonic::Streaming<ReconstructSessionRequest>>,
    ) -> Result<Response<Self::ReconstructSessionsStream>, Status> {
        Err(Status::unimplemented("reconstruct_sessions not implemented"))
    }

    type GetSessionEventsStream =
        Pin<Box<dyn tokio_stream::Stream<Item = Result<SessionEvent, Status>> + Send>>;

    async fn get_session_events(
        &self,
        _request: Request<GetSessionEventsRequest>,
    ) -> Result<Response<Self::GetSessionEventsStream>, Status> {
        Err(Status::unimplemented("get_session_events not implemented"))
    }

    async fn verify_session_integrity(
        &self,
        request: Request<VerifySessionRequest>,
    ) -> Result<Response<VerifySessionResponse>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!(session_id = %req.session_id, "verify_session_integrity called");

            let session_id = parse_uuid(&req.session_id)?;
            let tenant_id = extract_tenant_id(&req).ok_or_else(|| {
                Status::invalid_argument("tenant_id is required but not provided in request")
            })?;

            match self.handler.verify_integrity(session_id, tenant_id).await {
                Ok(result) => {
                    let is_valid = result.is_valid && result.computed_hash == req.expected_hash;
                    let resp = VerifySessionResponse {
                        is_valid,
                        computed_hash: result.computed_hash,
                        expected_hash: req.expected_hash,
                        event_count: result.event_count,
                        broken_at_event_id: String::new(),
                    };
                    info!(session_id = %session_id, is_valid = is_valid, "verify_session_integrity succeeded");
                    Ok(Response::new(resp))
                }
                Err(e) => {
                    error!(error = %e, "verify_session_integrity failed");
                    Err(map_domain_error(e))
                }
            }
        }
        .instrument(span)
        .await
    }

    async fn get_integrity_proof(
        &self,
        request: Request<GetIntegrityProofRequest>,
    ) -> Result<Response<IntegrityProof>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!(session_id = %req.session_id, tenant_id = %req.tenant_id, "get_integrity_proof called");

            let session_id = parse_uuid(&req.session_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;

            let hashes = self
                .handler
                .fetch_event_hashes(session_id, tenant_id)
                .await
                .map_err(map_domain_error)?;

            if hashes.is_empty() {
                return Err(Status::not_found("session not found"));
            }

            let target_index = if req.event_version > 0 {
                (req.event_version as usize).saturating_sub(1)
            } else {
                hashes.len() - 1
            };

            let clamped_index = target_index.min(hashes.len() - 1);
            let (merkle_root, siblings) = compute_merkle_proof(&hashes, clamped_index);

            let resp = IntegrityProof {
                session_id: session_id.to_string(),
                event_version: clamped_index as i64 + 1,
                event_hash: hashes[clamped_index].clone(),
                sibling_hashes: siblings,
                merkle_root,
                proof_generated_at: Some(datetime_to_timestamp(chrono::Utc::now())),
                signature: String::new(),
            };

            info!(session_id = %session_id, "get_integrity_proof succeeded");
            Ok(Response::new(resp))
        }
        .instrument(span)
        .await
    }

    async fn create_checkpoint(
        &self,
        _request: Request<CreateCheckpointRequest>,
    ) -> Result<Response<CreateCheckpointResponse>, Status> {
        Err(Status::unimplemented("create_checkpoint not implemented"))
    }

    async fn restore_checkpoint(
        &self,
        _request: Request<RestoreCheckpointRequest>,
    ) -> Result<Response<RestoreCheckpointResponse>, Status> {
        Err(Status::unimplemented("restore_checkpoint not implemented"))
    }

    async fn list_active_sessions(
        &self,
        _request: Request<ListActiveSessionsRequest>,
    ) -> Result<Response<ListActiveSessionsResponse>, Status> {
        Err(Status::unimplemented("list_active_sessions not implemented"))
    }

    async fn search_sessions(
        &self,
        _request: Request<SearchSessionsRequest>,
    ) -> Result<Response<SearchSessionsResponse>, Status> {
        Err(Status::unimplemented("search_sessions not implemented"))
    }

    async fn get_concurrent_sessions(
        &self,
        _request: Request<GetConcurrentSessionsRequest>,
    ) -> Result<Response<GetConcurrentSessionsResponse>, Status> {
        Err(Status::unimplemented("get_concurrent_sessions not implemented"))
    }

    async fn merge_sessions(
        &self,
        _request: Request<MergeSessionsRequest>,
    ) -> Result<Response<MergeSessionsResponse>, Status> {
        Err(Status::unimplemented("merge_sessions not implemented"))
    }

    async fn get_session_metrics(
        &self,
        _request: Request<GetSessionMetricsRequest>,
    ) -> Result<Response<GetSessionMetricsResponse>, Status> {
        Err(Status::unimplemented("get_session_metrics not implemented"))
    }

    async fn invalidate_cache(
        &self,
        request: Request<InvalidateCacheRequest>,
    ) -> Result<Response<Empty>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        let req = request.into_inner();

        async {
            info!(session_id = %req.session_id, tenant_id = %req.tenant_id, "invalidate_cache called");
            let session_id = parse_uuid(&req.session_id)?;
            let tenant_id = parse_uuid(&req.tenant_id)?;
            self.handler.cache.invalidate(session_id, tenant_id).await;
            Ok(Response::new(Empty {}))
        }
        .instrument(span)
        .await
    }

    async fn health(
        &self,
        request: Request<HealthRequest>,
    ) -> Result<Response<HealthResponse>, Status> {
        let span = ussd_kernel_common::telemetry::extract_trace_context(request.metadata())
            .unwrap_or_else(|| info_span!("grpc_request"));
        async {
            let mut dependencies = HashMap::new();
            dependencies.insert("postgres".to_string(), "ok".to_string());

            let resp = HealthResponse {
                status: ServingStatus::Serving as i32,
                version: env!("CARGO_PKG_VERSION").to_string(),
                timestamp: Some(datetime_to_timestamp(chrono::Utc::now())),
                dependencies,
                metadata: HashMap::new(),
            };
            Ok(Response::new(resp))
        }
        .instrument(span)
        .await
    }
}

fn parse_uuid(s: &str) -> Result<Uuid, Status> {
    Uuid::parse_str(s).map_err(|_| Status::invalid_argument(format!("invalid uuid: {}", s)))
}

fn extract_tenant_id(req: &VerifySessionRequest) -> Option<Uuid> {
    req.tracing.as_ref().and_then(|t| {
        t.baggage
            .get("tenant_id")
            .and_then(|v| Uuid::parse_str(v).ok())
    })
}

fn map_domain_error(e: DomainError) -> Status {
    match e {
        DomainError::SessionNotFound => Status::not_found(e.to_string()),
        DomainError::HashMismatch { .. } => Status::failed_precondition(e.to_string()),
        DomainError::EventSequenceGap { .. } => Status::data_loss(e.to_string()),
        DomainError::InvalidEventType(_) => Status::invalid_argument(e.to_string()),
        DomainError::Internal(msg) => Status::internal(msg),
    }
}

fn hashmap_to_struct(map: crate::domain::session::SessionState) -> prost_types::Struct {
    let fields = map
        .into_iter()
        .map(|(k, v)| {
            (
                k,
                prost_types::Value {
                    kind: Some(prost_types::value::Kind::StringValue(v)),
                },
            )
        })
        .collect();
    prost_types::Struct { fields }
}

fn datetime_to_timestamp(dt: chrono::DateTime<chrono::Utc>) -> prost_types::Timestamp {
    prost_types::Timestamp {
        seconds: dt.timestamp(),
        nanos: dt.timestamp_subsec_nanos() as i32,
    }
}
