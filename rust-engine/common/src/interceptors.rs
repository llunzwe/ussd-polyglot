use tonic::{metadata::MetadataValue, Request, Status};
use tracing::{info, Span};

/// Injects OpenTelemetry trace context and request metadata into gRPC metadata.
pub fn tracing_auth_interceptor(mut req: Request<()>) -> Result<Request<()>, Status> {
    let span = Span::current();

    // Example: propagate a synthetic request_id if missing
    if req.metadata().get("x-request-id").is_none() {
        let request_id = uuid::Uuid::new_v4().to_string();
        let value = MetadataValue::try_from(request_id).map_err(|e| {
            Status::internal(format!("invalid metadata value: {}", e))
        })?;
        req.metadata_mut().insert("x-request-id", value);
    }

    // Example: propagate auth token from context to metadata if available
    if req.metadata().get("authorization").is_none() {
        // In a real implementation, extract from application context
        info!(parent: &span, "No authorization header present; interceptor will allow downstream to enforce");
    }

    Ok(req)
}

/// Tower layer stub for more advanced interceptor chains.
#[derive(Clone, Debug)]
pub struct TracingLayer;

impl<S> tower::Layer<S> for TracingLayer {
    type Service = TracingService<S>;

    fn layer(&self, inner: S) -> Self::Service {
        TracingService { inner }
    }
}

#[derive(Clone, Debug)]
pub struct TracingService<S> {
    inner: S,
}

impl<S, Req> tower::Service<Req> for TracingService<S>
where
    S: tower::Service<Req>,
{
    type Response = S::Response;
    type Error = S::Error;
    type Future = S::Future;

    fn poll_ready(
        &mut self,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Result<(), Self::Error>> {
        self.inner.poll_ready(cx)
    }

    fn call(&mut self, req: Req) -> Self::Future {
        // Hook for distributed tracing / metrics
        self.inner.call(req)
    }
}
